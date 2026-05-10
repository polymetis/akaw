defmodule Akaw.LocalDocTest do
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

  test "head/3 → HEAD /{db}/_local/{id}", %{client: client} do
    assert :ok = Akaw.LocalDoc.head(client, "mydb", "checkpoint")
    assert_receive %{method: "HEAD", path: "/mydb/_local/checkpoint"}
  end

  test "get/4 → GET /{db}/_local/{id}", %{client: client} do
    assert {:ok, _} = Akaw.LocalDoc.get(client, "mydb", "checkpoint")
    assert_receive %{method: "GET", path: "/mydb/_local/checkpoint"}
  end

  test "put/5 → PUT /{db}/_local/{id} with body", %{client: client} do
    assert {:ok, _} =
             Akaw.LocalDoc.put(client, "mydb", "checkpoint", %{seq: "1-abc"})

    assert_receive %{method: "PUT", path: "/mydb/_local/checkpoint", body: body}
    assert Jason.decode!(body) == %{"seq" => "1-abc"}
  end

  test "delete/5 → DELETE /{db}/_local/{id}?rev=…", %{client: client} do
    assert {:ok, _} = Akaw.LocalDoc.delete(client, "mydb", "checkpoint", "1-x")
    assert_receive %{method: "DELETE", path: "/mydb/_local/checkpoint", query_string: "rev=1-x"}
  end

  test "list/3 → GET /{db}/_local_docs", %{client: client} do
    assert {:ok, _} = Akaw.LocalDoc.list(client, "mydb", limit: 5)
    assert_receive %{method: "GET", path: "/mydb/_local_docs", query_string: qs}
    assert qs =~ "limit=5"
  end

  test "list/3 JSON-encodes startkey/endkey", %{client: client} do
    assert {:ok, _} = Akaw.LocalDoc.list(client, "mydb", startkey: "_local/")
    assert_receive %{query_string: qs}
    decoded = URI.decode_query(qs)
    assert decoded["startkey"] == "\"_local/\""
  end

  test "list_keys/4 POSTs {keys: [...]}", %{client: client} do
    assert {:ok, _} = Akaw.LocalDoc.list_keys(client, "mydb", ["a", "b"])
    assert_receive %{method: "POST", path: "/mydb/_local_docs", body: body}
    assert Jason.decode!(body) == %{"keys" => ["a", "b"]}
  end

  test "list_queries/3 POSTs to /_local_docs/queries", %{client: client} do
    queries = [%{include_docs: true}, %{keys: ["x"]}]
    assert {:ok, _} = Akaw.LocalDoc.list_queries(client, "mydb", queries)
    assert_receive %{method: "POST", path: "/mydb/_local_docs/queries", body: body}
    decoded = Jason.decode!(body)
    assert length(decoded["queries"]) == 2
  end
end
