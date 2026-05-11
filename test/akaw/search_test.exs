defmodule Akaw.SearchTest do
  use ExUnit.Case, async: true

  setup do
    test = self()

    plug = fn conn ->
      send(test, %{
        method: conn.method,
        path: conn.request_path,
        query_string: conn.query_string
      })

      Req.Test.json(conn, %{"rows" => []})
    end

    {:ok, client: Akaw.new(base_url: "http://x", req_options: [plug: plug])}
  end

  test "search/5 → GET /_search/{index}", %{client: client} do
    assert {:ok, _} = Akaw.Search.search(client, "db", "d", "idx", query: "shoes")
    assert_receive %{method: "GET", path: "/db/_design/d/_search/idx", query_string: qs}
    assert qs =~ "query=shoes"
  end

  test "search/5 auto JSON-encodes :sort", %{client: client} do
    assert {:ok, _} =
             Akaw.Search.search(client, "db", "d", "idx",
               query: "x",
               sort: ["price", "-popularity"]
             )

    assert_receive %{query_string: qs}
    decoded = URI.decode_query(qs)
    assert decoded["sort"] == ~s|["price","-popularity"]|
  end

  test "search/5 auto JSON-encodes :ranges", %{client: client} do
    assert {:ok, _} =
             Akaw.Search.search(client, "db", "d", "idx",
               query: "*",
               ranges: %{price: %{"0-50": "[0 TO 50]"}}
             )

    assert_receive %{query_string: qs}
    decoded = URI.decode_query(qs)

    assert Jason.decode!(decoded["ranges"]) == %{
             "price" => %{"0-50" => "[0 TO 50]"}
           }
  end

  test "search/5 leaves scalar params untouched", %{client: client} do
    assert {:ok, _} =
             Akaw.Search.search(client, "db", "d", "idx",
               query: "x",
               limit: 10,
               include_docs: true,
               bookmark: "abc"
             )

    assert_receive %{query_string: qs}
    decoded = URI.decode_query(qs)
    assert decoded["limit"] == "10"
    assert decoded["include_docs"] == "true"
    assert decoded["bookmark"] == "abc"
  end

  test "info/4 → GET /_search_info/{index}", %{client: client} do
    assert {:ok, _} = Akaw.Search.info(client, "db", "d", "idx")
    assert_receive %{path: "/db/_design/d/_search_info/idx"}
  end
end
