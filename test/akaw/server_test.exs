defmodule Akaw.ServerTest do
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

      Loopback.json(conn, %{"ok" => true})
    end

    {:ok, client: Loopback.client(plug)}
  end

  test "info/1 → GET /", %{client: client} do
    assert {:ok, %{"ok" => true}} = Akaw.Server.info(client)
    assert_receive %{method: "GET", path: "/"}
  end

  test "up/1 → GET /_up", %{client: client} do
    assert {:ok, _} = Akaw.Server.up(client)
    assert_receive %{method: "GET", path: "/_up"}
  end

  test "uuids/2 forwards :count as a query param", %{client: client} do
    assert {:ok, _} = Akaw.Server.uuids(client, count: 5)
    assert_receive %{method: "GET", path: "/_uuids", query_string: "count=5"}
  end

  test "uuids/1 with no opts → /_uuids and empty query string", %{client: client} do
    assert {:ok, _} = Akaw.Server.uuids(client)
    assert_receive %{path: "/_uuids", query_string: ""}
  end

  test "all_dbs/2 forwards opts as query params", %{client: client} do
    assert {:ok, _} = Akaw.Server.all_dbs(client, limit: 10, descending: true)
    assert_receive %{path: "/_all_dbs", query_string: qs}
    assert qs =~ "limit=10"
    assert qs =~ "descending=true"
  end

  test "all_dbs/2 JSON-encodes startkey/endkey like its _all_docs siblings", %{client: client} do
    # _all_dbs startkey/endkey are JSON-typed: ?startkey=users (bare) is
    # a 400 from CouchDB, ?startkey="users" matches. Verified against
    # real CouchDB 3.5.
    assert {:ok, _} = Akaw.Server.all_dbs(client, startkey: "users", endkey: "usersz")

    assert_receive %{path: "/_all_dbs", query_string: qs}
    decoded = URI.decode_query(qs)
    assert decoded["startkey"] == ~s|"users"|
    assert decoded["endkey"] == ~s|"usersz"|
  end

  test "dbs_info/2 POSTs a {keys: [...]} body", %{client: client} do
    assert {:ok, _} = Akaw.Server.dbs_info(client, ["a", "b"])
    assert_receive %{method: "POST", path: "/_dbs_info", body: body}
    assert JSON.decode!(body) == %{"keys" => ["a", "b"]}
  end

  test "active_tasks/1 → GET /_active_tasks", %{client: client} do
    assert {:ok, _} = Akaw.Server.active_tasks(client)
    assert_receive %{method: "GET", path: "/_active_tasks"}
  end

  test "replicate/2 POSTs the given body", %{client: client} do
    assert {:ok, _} =
             Akaw.Server.replicate(client, %{source: "a", target: "b", continuous: true})

    assert_receive %{method: "POST", path: "/_replicate", body: body}
    decoded = JSON.decode!(body)
    assert decoded["source"] == "a"
    assert decoded["target"] == "b"
    assert decoded["continuous"] == true
  end

  test "db_updates/2 forwards feed/timeout/since as params", %{client: client} do
    assert {:ok, _} =
             Akaw.Server.db_updates(client, feed: "longpoll", timeout: 30_000, since: "now")

    assert_receive %{path: "/_db_updates", query_string: qs}
    assert qs =~ "feed=longpoll"
    assert qs =~ "timeout=30000"
    assert qs =~ "since=now"
  end

  test "db_updates/2 routes transport opts to the transport, not the query string", %{
    client: client
  } do
    # Sibling of Changes.get/3's held-open treatment: a quiet longpoll
    # _db_updates must not die at the transport's 15s default, and a
    # caller's :receive_timeout must reach Finch, not CouchDB.
    assert {:ok, _} =
             Akaw.Server.db_updates(client,
               feed: "longpoll",
               receive_timeout: 90_000,
               pool_timeout: 500
             )

    assert_receive %{path: "/_db_updates", query_string: qs}
    assert qs == "feed=longpoll"
  end

  test "membership/1 → GET /_membership", %{client: client} do
    assert {:ok, _} = Akaw.Server.membership(client)
    assert_receive %{method: "GET", path: "/_membership"}
  end

  test "search_analyze/2 POSTs the analyzer+text body to /_search_analyze",
       %{client: client} do
    assert {:ok, _} =
             Akaw.Server.search_analyze(client, %{
               analyzer: "standard",
               text: "running shoes"
             })

    assert_receive %{method: "POST", path: "/_search_analyze", body: body}
    decoded = JSON.decode!(body)
    assert decoded["analyzer"] == "standard"
    assert decoded["text"] == "running shoes"
  end

  test "nouveau_analyze/2 POSTs to /_nouveau_analyze", %{client: client} do
    assert {:ok, _} =
             Akaw.Server.nouveau_analyze(client, %{
               analyzer: "standard",
               text: "hello world"
             })

    assert_receive %{method: "POST", path: "/_nouveau_analyze", body: body}
    decoded = JSON.decode!(body)
    assert decoded["analyzer"] == "standard"
    assert decoded["text"] == "hello world"
  end

  test "stream_db_updates/2 forces feed=continuous and forwards other opts" do
    # Observed via ETS, not send/assert_receive: consuming a lazy stream
    # drains the caller's mailbox, so a message sent mid-stream would be
    # eaten before the test could assert on it. (The plug also runs in a
    # Bandit acceptor process, so Process.put/get can't reach the test.)
    seen = :ets.new(:akaw_db_updates_qs, [:public])

    plug = fn conn ->
      :ets.insert(seen, {:qs, conn.query_string})
      Loopback.json(conn, %{})
    end

    client = Loopback.client(plug)

    try do
      client |> Akaw.Server.stream_db_updates(since: "now") |> Enum.take(1)
    rescue
      _ -> :ok
    end

    assert [{:qs, qs}] = :ets.lookup(seen, :qs)
    assert qs =~ "feed=continuous"
    assert qs =~ "since=now"
  end
end
