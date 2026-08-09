defmodule Akaw.DesignDoc.ShowsTest do
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

  test "call/5 → GET /_show/{func} without doc", %{client: client} do
    assert {:ok, _} = Akaw.DesignDoc.Shows.call(client, "db", "d", "f")
    assert_receive %{method: "GET", path: "/db/_design/d/_show/f"}
  end

  test "call/5 with :doc_id appends docid to path", %{client: client} do
    assert {:ok, _} = Akaw.DesignDoc.Shows.call(client, "db", "d", "f", doc_id: "u1")
    assert_receive %{path: "/db/_design/d/_show/f/u1"}
  end

  test "call/5 with method: :post sends a POST", %{client: client} do
    assert {:ok, _} =
             Akaw.DesignDoc.Shows.call(client, "db", "d", "f",
               method: :post,
               body: %{x: 1}
             )

    assert_receive %{method: "POST", body: body}
    assert JSON.decode!(body) == %{"x" => 1}
  end

  test "call/5 forwards :params as query string", %{client: client} do
    assert {:ok, _} = Akaw.DesignDoc.Shows.call(client, "db", "d", "f", params: [foo: "bar"])
    assert_receive %{query_string: "foo=bar"}
  end

  test "preserves _design/ prefix in :doc_id", %{client: client} do
    assert {:ok, _} =
             Akaw.DesignDoc.Shows.call(client, "db", "d", "f", doc_id: "_design/other")

    assert_receive %{path: "/db/_design/d/_show/f/_design/other"}
  end

  test "call/5 sends a body on the default :get method verbatim", %{client: client} do
    # The verb is never rewritten: a show function branching on
    # req.method still sees GET even when the request carries a body.
    # (The Req-era transport promoted GET-with-body to POST, so this
    # once raised.)
    assert {:ok, _} = Akaw.DesignDoc.Shows.call(client, "db", "d", "f", body: %{a: 1})

    assert_receive %{method: "GET", body: body}
    assert JSON.decode!(body) == %{"a" => 1}
  end
end
