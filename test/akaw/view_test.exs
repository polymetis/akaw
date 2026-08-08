defmodule Akaw.ViewTest do
  use ExUnit.Case, async: true

  alias Akaw.Loopback

  setup do
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(test, %{
        method: conn.method,
        path: conn.request_path,
        query_string: conn.query_string,
        body: body
      })

      Loopback.json(conn, %{"rows" => []})
    end

    {:ok, client: Loopback.client(plug)}
  end

  describe "get/5" do
    test "→ GET /{db}/_design/{ddoc}/_view/{view}", %{client: client} do
      assert {:ok, _} = Akaw.View.get(client, "mydb", "ddoc1", "by_name")
      assert_receive %{method: "GET", path: "/mydb/_design/ddoc1/_view/by_name"}
    end

    test "forwards plain opts as query params", %{client: client} do
      assert {:ok, _} =
               Akaw.View.get(client, "mydb", "ddoc1", "by_name",
                 limit: 50,
                 reduce: false,
                 group_level: 2
               )

      assert_receive %{query_string: qs}
      assert qs =~ "limit=50"
      assert qs =~ "reduce=false"
      assert qs =~ "group_level=2"
    end

    test "JSON-encodes startkey/endkey/key", %{client: client} do
      assert {:ok, _} =
               Akaw.View.get(client, "mydb", "ddoc1", "by_name",
                 startkey: "alice",
                 endkey: "bob"
               )

      assert_receive %{query_string: qs}
      decoded = URI.decode_query(qs)
      assert decoded["startkey"] == "\"alice\""
      assert decoded["endkey"] == "\"bob\""
    end
  end

  describe "post_keys/6" do
    test "POSTs {keys: [...]} body", %{client: client} do
      assert {:ok, _} =
               Akaw.View.post_keys(client, "mydb", "ddoc1", "by_name", ["alice", "bob"])

      assert_receive %{
        method: "POST",
        path: "/mydb/_design/ddoc1/_view/by_name",
        body: body
      }

      assert JSON.decode!(body) == %{"keys" => ["alice", "bob"]}
    end
  end

  describe "queries/5" do
    test "POSTs to /_view/{view}/queries", %{client: client} do
      qs = [%{key: "alice", limit: 10}, %{startkey: "b", endkey: "c"}]
      assert {:ok, _} = Akaw.View.queries(client, "mydb", "ddoc1", "by_name", qs)

      assert_receive %{
        method: "POST",
        path: "/mydb/_design/ddoc1/_view/by_name/queries",
        body: body
      }

      decoded = JSON.decode!(body)
      assert length(decoded["queries"]) == 2
    end
  end

  describe "stream/5" do
    test "→ GET /_view/{view} (streaming variant); JSON-encodes startkey/endkey" do
      # Observed via ETS, not send/assert_receive: consuming a lazy
      # stream drains the caller's mailbox, so a message sent mid-stream
      # would be eaten before the test could assert on it.
      seen = :ets.new(:akaw_view_stream, [:public])

      plug = fn conn ->
        :ets.insert(seen, {:method, conn.method})
        :ets.insert(seen, {:path, conn.request_path})
        :ets.insert(seen, {:qs, conn.query_string})
        Loopback.json(conn, %{})
      end

      client = Loopback.client(plug)

      try do
        client
        |> Akaw.View.stream("mydb", "ddoc1", "by_name", startkey: "a", endkey: "z")
        |> Enum.take(1)
      rescue
        _ -> :ok
      end

      assert :ets.lookup(seen, :method) == [{:method, "GET"}]

      assert :ets.lookup(seen, :path) ==
               [{:path, "/mydb/_design/ddoc1/_view/by_name"}]

      [{:qs, qs}] = :ets.lookup(seen, :qs)
      decoded = URI.decode_query(qs)
      assert decoded["startkey"] == "\"a\""
      assert decoded["endkey"] == "\"z\""
    end
  end

  describe "stream_post_keys/6" do
    test "POSTs to /_view/{view} with {keys: [...]} body (streaming)" do
      # ETS for the same lazy-stream mailbox-draining reason as above.
      seen = :ets.new(:akaw_view_postk, [:public])

      plug = fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        :ets.insert(seen, {:method, conn.method})
        :ets.insert(seen, {:path, conn.request_path})
        :ets.insert(seen, {:body, body})
        Loopback.json(conn, %{})
      end

      client = Loopback.client(plug)

      try do
        client
        |> Akaw.View.stream_post_keys("mydb", "ddoc1", "by_name", ["alice", "bob"])
        |> Enum.take(1)
      rescue
        _ -> :ok
      end

      assert :ets.lookup(seen, :method) == [{:method, "POST"}]

      assert :ets.lookup(seen, :path) ==
               [{:path, "/mydb/_design/ddoc1/_view/by_name"}]

      [{:body, body}] = :ets.lookup(seen, :body)
      assert JSON.decode!(body) == %{"keys" => ["alice", "bob"]}
    end
  end
end
