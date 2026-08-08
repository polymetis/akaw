defmodule Akaw.ClusterTest do
  use ExUnit.Case, async: true

  alias Akaw.Loopback

  setup do
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(test, %{
        method: conn.method,
        path: conn.request_path,
        body: body
      })

      Loopback.json(conn, %{"state" => "cluster_finished"})
    end

    {:ok, client: Loopback.client(plug)}
  end

  test "get/1 → GET /_cluster_setup", %{client: client} do
    assert {:ok, _} = Akaw.Cluster.get(client)
    assert_receive %{method: "GET", path: "/_cluster_setup"}
  end

  test "setup/2 → POST /_cluster_setup with body", %{client: client} do
    body = %{
      action: "enable_single_node",
      bind_address: "0.0.0.0",
      username: "admin",
      password: "password"
    }

    assert {:ok, _} = Akaw.Cluster.setup(client, body)
    assert_receive %{method: "POST", path: "/_cluster_setup", body: payload}
    assert JSON.decode!(payload)["action"] == "enable_single_node"
  end
end
