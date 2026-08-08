defmodule Akaw.RequestTest do
  use ExUnit.Case, async: true

  alias Akaw.Request

  defp client_with(plug, extra \\ []) do
    Akaw.new([base_url: "http://couch.example", req_options: [plug: plug, retry: false]] ++ extra)
  end

  describe "URL composition" do
    test "joins base_url and path verbatim" do
      test = self()

      plug = fn conn ->
        send(test, {:url, conn.scheme, conn.host, conn.request_path})
        Req.Test.json(conn, %{})
      end

      assert {:ok, _} = Request.request(client_with(plug), :get, "/_all_dbs")
      assert_receive {:url, :http, "couch.example", "/_all_dbs"}
    end

    test "forwards :params as the query string" do
      test = self()

      plug = fn conn ->
        send(test, {:qs, conn.query_string})
        Req.Test.json(conn, %{})
      end

      assert {:ok, _} =
               Request.request(client_with(plug), :get, "/_uuids", params: [count: 5])

      assert_receive {:qs, "count=5"}
    end
  end

  describe "auth" do
    test "{:basic, user, pass} sets Authorization: Basic" do
      test = self()
      expected = "Basic " <> Base.encode64("user:pw")

      plug = fn conn ->
        send(test, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{})
      end

      client = client_with(plug, auth: {:basic, "user", "pw"})
      assert {:ok, _} = Request.request(client, :get, "/")
      assert_receive {:auth, [^expected]}
    end

    test "{:bearer, token} sets Authorization: Bearer" do
      test = self()

      plug = fn conn ->
        send(test, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{})
      end

      client = client_with(plug, auth: {:bearer, "abc.def.ghi"})
      assert {:ok, _} = Request.request(client, :get, "/")
      assert_receive {:auth, ["Bearer abc.def.ghi"]}
    end
  end

  describe "error handling" do
    test "non-2xx with CouchDB error body returns %Akaw.Error{}" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          Jason.encode!(%{"error" => "not_found", "reason" => "missing"})
        )
      end

      assert {:error, %Akaw.Error{} = err} =
               Request.request(client_with(plug), :get, "/_nope")

      assert err.status == 404
      assert err.error == "not_found"
      assert err.reason == "missing"
      assert err.body == %{"error" => "not_found", "reason" => "missing"}
    end

    test "non-2xx without an error/reason body still wraps as %Akaw.Error{}" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end

      assert {:error, %Akaw.Error{status: 500, error: nil, reason: nil}} =
               Request.request(client_with(plug), :get, "/")
    end

    test "Akaw.Error implements Exception.message/1" do
      err = %Akaw.Error{status: 404, error: "not_found", reason: "missing"}
      assert Exception.message(err) =~ "404"
      assert Exception.message(err) =~ "not_found"
      assert Exception.message(err) =~ "missing"
    end

    test "requests negotiate compression and decode a gzipped response body" do
      test = self()

      plug = fn conn ->
        send(test, {:accept_encoding, Plug.Conn.get_req_header(conn, "accept-encoding")})

        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, :zlib.gzip(~s({"ok":true})))
      end

      assert {:ok, %{"ok" => true}} = Request.request(client_with(plug), :get, "/")

      # Req 0.6.1 made this opt-in; Akaw.Request opts back in, so CouchDB
      # still gets asked for gzip and the body still arrives decoded rather
      # than as a raw compressed binary.
      assert_receive {:accept_encoding, [encodings]}
      assert encodings =~ "gzip"
    end

    test "a caller can still turn compression off per call" do
      test = self()

      plug = fn conn ->
        send(test, {:accept_encoding, Plug.Conn.get_req_header(conn, "accept-encoding")})
        Req.Test.json(conn, %{})
      end

      assert {:ok, _} = Request.request(client_with(plug), :get, "/", compressed: false)
      assert_receive {:accept_encoding, []}
    end

    test "a flat :pool_timeout is folded into finch: [...] rather than deprecated" do
      plug = fn conn -> Req.Test.json(conn, %{}) end

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:ok, _} =
                   Request.request(client_with(plug), :get, "/", pool_timeout: 5_000)
        end)

      refute stderr =~ "deprecated"
    end

    test ":pool_timeout stays flat alongside :connect_options, where Req would raise" do
      # Req raises "cannot set both :finch and :connect_options" if :finch is
      # present at all, so folding here would turn a warning into a crash.
      # We keep the warning instead. Documented, deliberate corner.
      plug = fn conn -> Req.Test.json(conn, %{}) end

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:ok, _} =
                   Request.request(client_with(plug), :get, "/",
                     connect_options: [timeout: 1_000],
                     pool_timeout: 5_000
                   )
        end)

      assert stderr =~ "pool_timeout" and stderr =~ "deprecated"
    end

    test "transport exceptions are wrapped into %Akaw.Error{status: nil}" do
      plug = fn conn -> Req.Test.transport_error(conn, :econnrefused) end
      client = client_with(plug)

      assert {:error, %Akaw.Error{} = err} = Request.request(client, :get, "/")
      assert err.status == nil
      assert err.error == "transport_error"
      assert err.reason =~ "connection refused" or err.reason =~ "econnrefused"
      assert is_struct(err.body.exception)
    end

    test "a 200 with a corrupt JSON body is a decode_error, not a transport_error" do
      # A proxy truncating the response mid-body. Tagging this
      # "transport_error" sent the documented retry-on-transport pattern
      # into a loop against a permanently corrupt endpoint.
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s|{"total_rows": 3, "rows": [{"id|)
      end

      assert {:error, %Akaw.Error{} = err} =
               Request.request(client_with(plug), :get, "/db/_all_docs")

      assert err.status == nil
      assert err.error == "decode_error"
      assert %Jason.DecodeError{} = err.body.exception
    end

    test "Akaw.Error.message/1 for transport errors shows 'Akaw transport_error: ...'" do
      err = %Akaw.Error{
        status: nil,
        error: "transport_error",
        reason: "connection refused"
      }

      msg = Exception.message(err)
      assert msg =~ "transport_error"
      assert msg =~ "connection refused"
      refute msg =~ "CouchDB returned HTTP"
    end
  end

  describe "headers" do
    test "client headers are sent with every request" do
      test = self()

      plug = fn conn ->
        send(test, {:headers, conn.req_headers})
        Req.Test.json(conn, %{})
      end

      client = client_with(plug, headers: [{"x-couch-feature", "akaw"}])
      assert {:ok, _} = Request.request(client, :get, "/")
      assert_receive {:headers, headers}
      assert {"x-couch-feature", "akaw"} in headers
    end

    test "per-call headers are concatenated with client headers" do
      test = self()

      plug = fn conn ->
        send(test, {:headers, conn.req_headers})
        Req.Test.json(conn, %{})
      end

      client = client_with(plug, headers: [{"x-from-client", "yes"}])

      assert {:ok, _} =
               Request.request(client, :get, "/", headers: [{"x-from-call", "also"}])

      assert_receive {:headers, headers}
      assert {"x-from-client", "yes"} in headers
      assert {"x-from-call", "also"} in headers
    end

    test "per-call header overrides client header with the same name" do
      test = self()

      plug = fn conn ->
        send(test, {:headers, conn.req_headers})
        Req.Test.json(conn, %{})
      end

      client = client_with(plug, headers: [{"cookie", "AuthSession=OLD"}])

      assert {:ok, _} =
               Request.request(client, :get, "/", headers: [{"cookie", "AuthSession=NEW"}])

      assert_receive {:headers, headers}
      cookies = for {"cookie", v} <- headers, do: v
      assert cookies == ["AuthSession=NEW"]
    end
  end
end
