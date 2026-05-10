defmodule Akaw.EdgeCasesTest do
  use ExUnit.Case, async: true

  # Edge-case unit tests not tied to one specific module — empty inputs,
  # auth-encoding quirks, header dedup interactions, and Akaw.Params
  # encoding for less common value types.

  defp recording_client(client_opts \\ []) do
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(test, %{
        method: conn.method,
        path: conn.request_path,
        body: body,
        headers: conn.req_headers
      })

      Req.Test.json(conn, %{})
    end

    Akaw.new([base_url: "http://x", req_options: [plug: plug, retry: false]] ++ client_opts)
  end

  describe "empty bulk inputs (still go through, body is just empty)" do
    test "bulk_docs with empty list" do
      client = recording_client()
      assert {:ok, _} = Akaw.Documents.bulk_docs(client, "db", [])
      assert_receive %{method: "POST", path: "/db/_bulk_docs", body: body}
      assert Jason.decode!(body) == %{"docs" => []}
    end

    test "bulk_get with empty list" do
      client = recording_client()
      assert {:ok, _} = Akaw.Documents.bulk_get(client, "db", [])
      assert_receive %{method: "POST", path: "/db/_bulk_get", body: body}
      assert Jason.decode!(body) == %{"docs" => []}
    end

    test "all_docs_keys with empty keys list" do
      client = recording_client()
      assert {:ok, _} = Akaw.Documents.all_docs_keys(client, "db", [])
      assert_receive %{method: "POST", path: "/db/_all_docs", body: body}
      assert Jason.decode!(body) == %{"keys" => []}
    end

    test "all_docs_queries with empty queries list" do
      client = recording_client()
      assert {:ok, _} = Akaw.Documents.all_docs_queries(client, "db", [])
      assert_receive %{path: "/db/_all_docs/queries", body: body}
      assert Jason.decode!(body) == %{"queries" => []}
    end

    test "purge with empty map" do
      client = recording_client()
      assert {:ok, _} = Akaw.Purge.purge(client, "db", %{})
      assert_receive %{method: "POST", path: "/db/_purge", body: body}
      assert Jason.decode!(body) == %{}
    end

    test "find with empty selector" do
      client = recording_client()
      assert {:ok, _} = Akaw.Find.find(client, "db", %{selector: %{}})
      assert_receive %{method: "POST", path: "/db/_find", body: body}
      assert Jason.decode!(body) == %{"selector" => %{}}
    end
  end

  describe "basic auth encoding edges" do
    defp capture_auth_plug(test) do
      fn conn ->
        send(test, Plug.Conn.get_req_header(conn, "authorization"))
        Req.Test.json(conn, %{})
      end
    end

    test "password with @ and : passes through unencoded in basic auth" do
      test = self()

      client =
        Akaw.new(
          base_url: "http://x",
          auth: {:basic, "alice", "p@ss:word"},
          req_options: [plug: capture_auth_plug(test)]
        )

      assert {:ok, _} = Akaw.Server.info(client)
      assert_receive [auth]
      "Basic " <> b64 = auth
      assert Base.decode64!(b64) == "alice:p@ss:word"
    end

    test "empty password" do
      test = self()

      client =
        Akaw.new(
          base_url: "http://x",
          auth: {:basic, "alice", ""},
          req_options: [plug: capture_auth_plug(test)]
        )

      assert {:ok, _} = Akaw.Server.info(client)
      assert_receive [auth]
      assert Base.decode64!(String.trim_leading(auth, "Basic ")) == "alice:"
    end

    test "Unicode password is sent as raw UTF-8 bytes (CouchDB will decode)" do
      test = self()

      client =
        Akaw.new(
          base_url: "http://x",
          auth: {:basic, "alice", "pässwörd"},
          req_options: [plug: capture_auth_plug(test)]
        )

      assert {:ok, _} = Akaw.Server.info(client)
      assert_receive [auth]
      assert Base.decode64!(String.trim_leading(auth, "Basic ")) == "alice:pässwörd"
    end
  end

  describe "header dedup is case-insensitive" do
    test "per-call cookie wins over client cookie even with different case" do
      test = self()

      plug = fn conn ->
        cookies = for {name, v} <- conn.req_headers, String.downcase(name) == "cookie", do: v
        send(test, cookies)
        Req.Test.json(conn, %{})
      end

      client =
        Akaw.new(
          base_url: "http://x",
          headers: [{"Cookie", "AuthSession=OLD"}],
          req_options: [plug: plug]
        )

      Akaw.Request.request(client, :get, "/", headers: [{"cookie", "AuthSession=NEW"}])

      assert_receive ["AuthSession=NEW"]
    end

    test "client headers from req_options also participate in dedup" do
      test = self()

      plug = fn conn ->
        accepts =
          for {name, v} <- conn.req_headers, String.downcase(name) == "x-test", do: v

        send(test, accepts)
        Req.Test.json(conn, %{})
      end

      client =
        Akaw.new(
          base_url: "http://x",
          headers: [{"x-test", "from-client"}],
          req_options: [plug: plug, headers: [{"X-Test", "from-req-opts"}]]
        )

      Akaw.Request.request(client, :get, "/", headers: [{"X-TEST", "from-call"}])

      assert_receive ["from-call"]
    end
  end

  describe "Akaw.Params.encode_json_keys" do
    alias Akaw.Params

    test "integer value" do
      assert [{:key, "42"}] = Params.encode_json_keys(key: 42)
    end

    test "float value" do
      assert [{:key, "1.5"}] = Params.encode_json_keys(key: 1.5)
    end

    test "nil value" do
      assert [{:key, "null"}] = Params.encode_json_keys(key: nil)
    end

    test "boolean values" do
      assert [{:key, "true"}] = Params.encode_json_keys(key: true)
      assert [{:key, "false"}] = Params.encode_json_keys(key: false)
    end

    test "list (CouchDB compound key)" do
      assert [{:key, ~s|["a",1,true]|}] =
               Params.encode_json_keys(key: ["a", 1, true])
    end

    test "nested map" do
      assert [{:key, json}] = Params.encode_json_keys(key: %{a: 1, b: 2})
      assert Jason.decode!(json) == %{"a" => 1, "b" => 2}
    end

    test "leaves non-JSON-typed keys untouched" do
      assert [{:limit, 10}, {:include_docs, true}] =
               Params.encode_json_keys(limit: 10, include_docs: true)
    end

    test "handles all aliased keys" do
      result = Params.encode_json_keys(start_key: "x", end_key: "y", key: "z")
      assert {:start_key, "\"x\""} in result
      assert {:end_key, "\"y\""} in result
      assert {:key, "\"z\""} in result
    end

    test "mix of JSON-typed and plain in one keyword list" do
      result = Params.encode_json_keys(startkey: "user_", limit: 10, descending: true)
      assert {:startkey, "\"user_\""} in result
      assert {:limit, 10} in result
      assert {:descending, true} in result
    end
  end

  describe "Akaw.Error" do
    test "message/1 falls back gracefully when error/reason are nil" do
      err = %Akaw.Error{status: 500}
      msg = Exception.message(err)
      assert msg =~ "500"
      assert msg =~ "error"
      assert msg =~ "no reason given"
    end

    test "can be raised directly" do
      err = %Akaw.Error{status: 404, error: "not_found", reason: "missing"}

      assert_raise Akaw.Error, ~r/404/, fn -> raise err end
    end
  end

  describe "Akaw.new/1 trims trailing slashes idempotently" do
    test "single slash" do
      assert Akaw.new(base_url: "http://x:5984/").base_url == "http://x:5984"
    end

    test "no slash is unchanged" do
      assert Akaw.new(base_url: "http://x:5984").base_url == "http://x:5984"
    end

    test "URL with path keeps path, only trailing slash is trimmed" do
      assert Akaw.new(base_url: "http://x:5984/couch/").base_url == "http://x:5984/couch"
    end
  end
end
