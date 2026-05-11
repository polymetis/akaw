defmodule Akaw.DesignDoc.ListsTest do
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

  test "call/6 with same-ddoc view (string)", %{client: client} do
    assert {:ok, _} = Akaw.DesignDoc.Lists.call(client, "db", "d", "fmt", "all")
    assert_receive %{method: "GET", path: "/db/_design/d/_list/fmt/all"}
  end

  test "call/6 with cross-ddoc view tuple", %{client: client} do
    assert {:ok, _} =
             Akaw.DesignDoc.Lists.call(client, "db", "d", "fmt", {"other_d", "v1"})

    assert_receive %{path: "/db/_design/d/_list/fmt/other_d/v1"}
  end

  test "call/6 forwards JSON-typed params auto-encoded", %{client: client} do
    assert {:ok, _} =
             Akaw.DesignDoc.Lists.call(client, "db", "d", "fmt", "v",
               params: [startkey: "a", endkey: "z", limit: 50]
             )

    assert_receive %{query_string: qs}
    decoded = URI.decode_query(qs)
    assert decoded["startkey"] == "\"a\""
    assert decoded["endkey"] == "\"z\""
    assert decoded["limit"] == "50"
  end

  test "call/6 supports :method :post + :body", %{client: client} do
    assert {:ok, _} =
             Akaw.DesignDoc.Lists.call(client, "db", "d", "fmt", "v",
               method: :post,
               body: %{filter: "x"}
             )

    assert_receive %{method: "POST", body: body}
    assert Jason.decode!(body) == %{"filter" => "x"}
  end
end
