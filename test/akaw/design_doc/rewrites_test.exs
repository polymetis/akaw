defmodule Akaw.DesignDoc.RewritesTest do
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

  test "call/5 appends path verbatim", %{client: client} do
    assert {:ok, _} = Akaw.DesignDoc.Rewrites.call(client, "db", "d", "test/path")
    assert_receive %{method: "GET", path: "/db/_design/d/_rewrite/test/path"}
  end

  test "call/5 does NOT URL-encode the path argument", %{client: client} do
    # Rewrite paths often include literal /, ?, etc. — we pass through.
    assert {:ok, _} =
             Akaw.DesignDoc.Rewrites.call(client, "db", "d", "users/u1/profile")

    assert_receive %{path: "/db/_design/d/_rewrite/users/u1/profile"}
  end

  test "call/5 with :method and :body", %{client: client} do
    assert {:ok, _} =
             Akaw.DesignDoc.Rewrites.call(client, "db", "d", "items",
               method: :post,
               body: %{name: "x"}
             )

    assert_receive %{method: "POST", body: body}
    assert Jason.decode!(body) == %{"name" => "x"}
  end

  test "call/5 with :params", %{client: client} do
    assert {:ok, _} =
             Akaw.DesignDoc.Rewrites.call(client, "db", "d", "search",
               params: [q: "shoes", limit: 10]
             )

    assert_receive %{query_string: qs}
    assert qs =~ "q=shoes"
    assert qs =~ "limit=10"
  end
end
