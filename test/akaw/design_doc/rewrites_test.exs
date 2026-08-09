defmodule Akaw.DesignDoc.RewritesTest do
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
    assert JSON.decode!(body) == %{"name" => "x"}
  end

  test "call/5 sends a body on the default :get method verbatim", %{client: client} do
    # The verb is never rewritten: a rule pinned to "method": "GET"
    # keeps matching even when the request carries a body. (The Req-era
    # transport promoted GET-with-body to POST, so this once raised.)
    assert {:ok, _} =
             Akaw.DesignDoc.Rewrites.call(client, "db", "d", "items", body: %{name: "x"})

    assert_receive %{method: "GET", body: body}
    assert JSON.decode!(body) == %{"name" => "x"}
  end

  test "call/5 sends a GET with a body when the method is the string \"GET\" too", %{
    client: client
  } do
    # Atom and string spellings are interchangeable now — both go to the
    # wire verbatim.
    assert {:ok, _} =
             Akaw.DesignDoc.Rewrites.call(client, "db", "d", "items",
               method: "GET",
               body: %{name: "x"}
             )

    assert_receive %{method: "GET", body: body}
    assert JSON.decode!(body) == %{"name" => "x"}
  end

  test "call/5 merges :params into a query the path already carries", %{client: client} do
    # The documented contract: :params override same-named parameters in
    # the rewrite path rather than appending — and never produce a
    # second "?". (This regressed silently in the transport swap's first
    # cut; the URL came out as ...?limit=5?limit=10.)
    assert {:ok, _} =
             Akaw.DesignDoc.Rewrites.call(client, "db", "d", "search?limit=5&skip=2",
               params: [limit: 10]
             )

    assert_receive %{path: "/db/_design/d/_rewrite/search", query_string: qs}
    decoded = URI.decode_query(qs)
    assert decoded["limit"] == "10"
    assert decoded["skip"] == "2"
    refute qs =~ "?"
  end

  test "call/5 leaves a path-embedded query untouched when there are no :params", %{
    client: client
  } do
    assert {:ok, _} = Akaw.DesignDoc.Rewrites.call(client, "db", "d", "search?q=a%20b")
    assert_receive %{path: "/db/_design/d/_rewrite/search", query_string: "q=a%20b"}
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
