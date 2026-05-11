defmodule Akaw.NouveauTest do
  use ExUnit.Case, async: true

  setup do
    test = self()

    plug = fn conn ->
      send(test, %{
        method: conn.method,
        path: conn.request_path,
        query_string: conn.query_string
      })

      Req.Test.json(conn, %{"hits" => []})
    end

    {:ok, client: Akaw.new(base_url: "http://x", req_options: [plug: plug])}
  end

  test "search/5 → GET /_nouveau/{index}", %{client: client} do
    assert {:ok, _} = Akaw.Nouveau.search(client, "db", "d", "idx", q: "shoes", limit: 25)
    assert_receive %{method: "GET", path: "/db/_design/d/_nouveau/idx", query_string: qs}
    assert qs =~ "q=shoes"
    assert qs =~ "limit=25"
  end

  test "search/5 auto JSON-encodes :sort and :ranges", %{client: client} do
    assert {:ok, _} =
             Akaw.Nouveau.search(client, "db", "d", "idx",
               q: "*",
               sort: ["price"],
               ranges: %{price: %{cheap: "[0 TO 50]"}}
             )

    assert_receive %{query_string: qs}
    decoded = URI.decode_query(qs)
    assert decoded["sort"] == ~s|["price"]|
    assert Jason.decode!(decoded["ranges"]) == %{"price" => %{"cheap" => "[0 TO 50]"}}
  end

  test "info/4 → GET /_nouveau_info/{index}", %{client: client} do
    assert {:ok, _} = Akaw.Nouveau.info(client, "db", "d", "idx")
    assert_receive %{path: "/db/_design/d/_nouveau_info/idx"}
  end
end
