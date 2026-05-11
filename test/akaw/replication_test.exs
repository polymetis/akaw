defmodule Akaw.ReplicationTest do
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

    {:ok, client: Akaw.new(base_url: "http://x", req_options: [plug: plug])}
  end

  test "create/4 PUTs the doc into _replicator", %{client: client} do
    doc = %{source: "http://from/db", target: "to", continuous: true}
    assert {:ok, _} = Akaw.Replication.create(client, "my_repl", doc)
    assert_receive %{method: "PUT", path: "/_replicator/my_repl", body: body}
    decoded = Jason.decode!(body)
    assert decoded["source"] == "http://from/db"
    assert decoded["target"] == "to"
    assert decoded["continuous"] == true
  end

  test "get/3 → GET /_replicator/{id}", %{client: client} do
    assert {:ok, _} = Akaw.Replication.get(client, "my_repl")
    assert_receive %{method: "GET", path: "/_replicator/my_repl"}
  end

  test "delete/4 → DELETE /_replicator/{id}?rev=…", %{client: client} do
    assert {:ok, _} = Akaw.Replication.delete(client, "my_repl", "1-x")
    assert_receive %{method: "DELETE", path: "/_replicator/my_repl", query_string: "rev=1-x"}
  end

  test "list/2 → GET /_replicator/_all_docs", %{client: client} do
    assert {:ok, _} = Akaw.Replication.list(client)
    assert_receive %{method: "GET", path: "/_replicator/_all_docs"}
  end

  test "status/2 → GET /_scheduler/docs/_replicator/{id}", %{client: client} do
    assert {:ok, _} = Akaw.Replication.status(client, "my_repl")
    assert_receive %{method: "GET", path: "/_scheduler/docs/_replicator/my_repl"}
  end

  test "all_status/2 → GET /_scheduler/docs", %{client: client} do
    assert {:ok, _} = Akaw.Replication.all_status(client, limit: 10)
    assert_receive %{method: "GET", path: "/_scheduler/docs", query_string: qs}
    assert qs =~ "limit=10"
  end

  test "jobs/2 → GET /_scheduler/jobs", %{client: client} do
    assert {:ok, _} = Akaw.Replication.jobs(client)
    assert_receive %{method: "GET", path: "/_scheduler/jobs"}
  end
end
