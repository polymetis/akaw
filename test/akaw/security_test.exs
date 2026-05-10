defmodule Akaw.SecurityTest do
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

  test "get/2 → GET /{db}/_security", %{client: client} do
    assert {:ok, _} = Akaw.Security.get(client, "mydb")
    assert_receive %{method: "GET", path: "/mydb/_security"}
  end

  test "put/3 → PUT /{db}/_security with the security map", %{client: client} do
    sec = %{
      admins: %{names: ["alice"], roles: ["dba"]},
      members: %{names: [], roles: []}
    }

    assert {:ok, _} = Akaw.Security.put(client, "mydb", sec)
    assert_receive %{method: "PUT", path: "/mydb/_security", body: body}
    decoded = Jason.decode!(body)
    assert decoded["admins"]["names"] == ["alice"]
    assert decoded["members"]["roles"] == []
  end
end
