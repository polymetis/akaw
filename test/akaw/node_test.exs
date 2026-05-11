defmodule Akaw.NodeTest do
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

  test "info/2 defaults to _local", %{client: client} do
    assert {:ok, _} = Akaw.Node.info(client)
    assert_receive %{method: "GET", path: "/_node/_local"}
  end

  test "info/2 accepts :node option", %{client: client} do
    assert {:ok, _} = Akaw.Node.info(client, node: "couchdb@host")
    assert_receive %{method: "GET", path: "/_node/couchdb%40host"}
  end

  test "stats/2 → /_node/_local/_stats", %{client: client} do
    assert {:ok, _} = Akaw.Node.stats(client)
    assert_receive %{method: "GET", path: "/_node/_local/_stats"}
  end

  test "prometheus/2 → /_node/_local/_prometheus", %{client: client} do
    assert {:ok, _} = Akaw.Node.prometheus(client)
    assert_receive %{method: "GET", path: "/_node/_local/_prometheus"}
  end

  test "system/2 → /_node/_local/_system", %{client: client} do
    assert {:ok, _} = Akaw.Node.system(client)
    assert_receive %{method: "GET", path: "/_node/_local/_system"}
  end

  test "smoosh_status/2 → /_node/_local/_smoosh/status", %{client: client} do
    assert {:ok, _} = Akaw.Node.smoosh_status(client)
    assert_receive %{method: "GET", path: "/_node/_local/_smoosh/status"}
  end

  test "versions/2 → /_node/_local/_versions", %{client: client} do
    assert {:ok, _} = Akaw.Node.versions(client)
    assert_receive %{method: "GET", path: "/_node/_local/_versions"}
  end

  test "restart/2 POSTs an empty body", %{client: client} do
    assert {:ok, _} = Akaw.Node.restart(client)
    assert_receive %{method: "POST", path: "/_node/_local/_restart", body: body}
    assert Jason.decode!(body) == %{}
  end
end
