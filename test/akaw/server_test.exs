defmodule Akaw.ServerTest do
  use ExUnit.Case, async: true

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

      Req.Test.json(conn, %{"ok" => true})
    end

    client = Akaw.new(base_url: "http://couch.example", req_options: [plug: plug])
    {:ok, client: client}
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

  test "dbs_info/2 POSTs a {keys: [...]} body", %{client: client} do
    assert {:ok, _} = Akaw.Server.dbs_info(client, ["a", "b"])
    assert_receive %{method: "POST", path: "/_dbs_info", body: body}
    assert Jason.decode!(body) == %{"keys" => ["a", "b"]}
  end

  test "active_tasks/1 → GET /_active_tasks", %{client: client} do
    assert {:ok, _} = Akaw.Server.active_tasks(client)
    assert_receive %{method: "GET", path: "/_active_tasks"}
  end

  test "replicate/2 POSTs the given body", %{client: client} do
    assert {:ok, _} =
             Akaw.Server.replicate(client, %{source: "a", target: "b", continuous: true})

    assert_receive %{method: "POST", path: "/_replicate", body: body}
    decoded = Jason.decode!(body)
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

  test "membership/1 → GET /_membership", %{client: client} do
    assert {:ok, _} = Akaw.Server.membership(client)
    assert_receive %{method: "GET", path: "/_membership"}
  end
end
