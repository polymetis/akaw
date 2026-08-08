defmodule Akaw.DesignDoc.ListsTest do
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
    assert JSON.decode!(body) == %{"filter" => "x"}
  end

  test "call/6 sends a body on the default :get method verbatim", %{client: client} do
    # The verb is never rewritten: a list function branching on
    # req.method still sees GET even when the request carries a body.
    # (The Req-era transport promoted GET-with-body to POST, so this
    # once raised.)
    assert {:ok, _} =
             Akaw.DesignDoc.Lists.call(client, "db", "d", "fmt", "v", body: %{filter: "x"})

    assert_receive %{method: "GET", body: body}
    assert JSON.decode!(body) == %{"filter" => "x"}
  end
end
