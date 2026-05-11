defmodule Akaw.ConfigTest do
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

  test "get/2 → /_node/_local/_config", %{client: client} do
    assert {:ok, _} = Akaw.Config.get(client)
    assert_receive %{method: "GET", path: "/_node/_local/_config"}
  end

  test "get_section/3 → /_node/_local/_config/{section}", %{client: client} do
    assert {:ok, _} = Akaw.Config.get_section(client, "couchdb")
    assert_receive %{method: "GET", path: "/_node/_local/_config/couchdb"}
  end

  test "get_value/4 → /_node/_local/_config/{section}/{key}", %{client: client} do
    assert {:ok, _} = Akaw.Config.get_value(client, "couchdb", "max_document_size")
    assert_receive %{method: "GET", path: "/_node/_local/_config/couchdb/max_document_size"}
  end

  test "put/5 PUTs a JSON-encoded string value", %{client: client} do
    assert {:ok, _} = Akaw.Config.put(client, "log", "level", "debug")
    assert_receive %{method: "PUT", path: "/_node/_local/_config/log/level", body: body}
    assert Jason.decode!(body) == "debug"
  end

  test "delete/4 → DELETE", %{client: client} do
    assert {:ok, _} = Akaw.Config.delete(client, "log", "level")
    assert_receive %{method: "DELETE", path: "/_node/_local/_config/log/level"}
  end

  test "reload/2 → POST /_config/_reload", %{client: client} do
    assert {:ok, _} = Akaw.Config.reload(client)
    assert_receive %{method: "POST", path: "/_node/_local/_config/_reload", body: body}
    assert Jason.decode!(body) == %{}
  end

  test "all functions accept :node option", %{client: client} do
    assert {:ok, _} = Akaw.Config.get(client, node: "couchdb@host")
    assert_receive %{path: "/_node/couchdb%40host/_config"}
  end
end
