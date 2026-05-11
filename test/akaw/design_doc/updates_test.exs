defmodule Akaw.DesignDoc.UpdatesTest do
  use ExUnit.Case, async: true

  setup do
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(test, %{
        method: conn.method,
        path: conn.request_path,
        body: body
      })

      Req.Test.json(conn, %{"ok" => true})
    end

    {:ok, client: Akaw.new(base_url: "http://x", req_options: [plug: plug])}
  end

  test "call/5 → POST /_update/{func} without doc", %{client: client} do
    assert {:ok, _} = Akaw.DesignDoc.Updates.call(client, "db", "d", "f")
    assert_receive %{method: "POST", path: "/db/_design/d/_update/f", body: body}
    assert Jason.decode!(body) == %{}
  end

  test "call/5 with :doc_id targets a specific doc", %{client: client} do
    assert {:ok, _} = Akaw.DesignDoc.Updates.call(client, "db", "d", "f", doc_id: "u1")
    assert_receive %{path: "/db/_design/d/_update/f/u1"}
  end

  test "call/5 with :method :put", %{client: client} do
    assert {:ok, _} =
             Akaw.DesignDoc.Updates.call(client, "db", "d", "f",
               doc_id: "u1",
               method: :put,
               body: %{n: 1}
             )

    assert_receive %{method: "PUT", body: body}
    assert Jason.decode!(body) == %{"n" => 1}
  end

  test "preserves _design/ in doc id", %{client: client} do
    assert {:ok, _} =
             Akaw.DesignDoc.Updates.call(client, "db", "d", "f", doc_id: "_design/target")

    assert_receive %{path: "/db/_design/d/_update/f/_design/target"}
  end
end
