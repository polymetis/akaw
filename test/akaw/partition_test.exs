defmodule Akaw.PartitionTest do
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

      Req.Test.json(conn, %{"rows" => []})
    end

    {:ok, client: Akaw.new(base_url: "http://x", req_options: [plug: plug])}
  end

  test "info/3 → GET /{db}/_partition/{p}", %{client: client} do
    assert {:ok, _} = Akaw.Partition.info(client, "mydb", "tenant42")
    assert_receive %{method: "GET", path: "/mydb/_partition/tenant42"}
  end

  test "all_docs/4 → GET /{db}/_partition/{p}/_all_docs", %{client: client} do
    assert {:ok, _} =
             Akaw.Partition.all_docs(client, "mydb", "tenant42",
               include_docs: true,
               startkey: "user_"
             )

    assert_receive %{path: "/mydb/_partition/tenant42/_all_docs", query_string: qs}
    assert qs =~ "include_docs=true"
    decoded = URI.decode_query(qs)
    assert decoded["startkey"] == "\"user_\""
  end

  test "view/6 → GET /.../_partition/{p}/_design/{ddoc}/_view/{view}", %{client: client} do
    assert {:ok, _} = Akaw.Partition.view(client, "mydb", "t42", "by_email", "all")
    assert_receive %{path: "/mydb/_partition/t42/_design/by_email/_view/all"}
  end

  test "find/4 → POST /.../_partition/{p}/_find", %{client: client} do
    query = %{selector: %{tenant: "t42", active: true}}
    assert {:ok, _} = Akaw.Partition.find(client, "mydb", "t42", query)
    assert_receive %{method: "POST", path: "/mydb/_partition/t42/_find", body: body}
    assert Jason.decode!(body) == %{"selector" => %{"tenant" => "t42", "active" => true}}
  end

  test "explain/4 → POST /.../_partition/{p}/_explain", %{client: client} do
    assert {:ok, _} =
             Akaw.Partition.explain(client, "mydb", "t42", %{selector: %{a: 1}})

    assert_receive %{method: "POST", path: "/mydb/_partition/t42/_explain"}
  end
end
