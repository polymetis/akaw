defmodule Akaw.PurgeTest do
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

  test "purge/3 POSTs the {doc_id => revs} map to /_purge", %{client: client} do
    purges = %{"user_42" => ["3-abc"], "user_43" => ["1-def", "2-ghi"]}
    assert {:ok, _} = Akaw.Purge.purge(client, "mydb", purges)
    assert_receive %{method: "POST", path: "/mydb/_purge", body: body}
    assert Jason.decode!(body) == purges
  end

  test "purged_infos/3 → GET /{db}/_purged_infos", %{client: client} do
    assert {:ok, _} = Akaw.Purge.purged_infos(client, "mydb")
    assert_receive %{method: "GET", path: "/mydb/_purged_infos"}
  end

  test "purged_infos_limit/2 → GET /{db}/_purged_infos_limit", %{client: client} do
    assert {:ok, _} = Akaw.Purge.purged_infos_limit(client, "mydb")
    assert_receive %{method: "GET", path: "/mydb/_purged_infos_limit"}
  end

  test "put_purged_infos_limit/3 → PUT with integer body", %{client: client} do
    assert {:ok, _} = Akaw.Purge.put_purged_infos_limit(client, "mydb", 500)
    assert_receive %{method: "PUT", path: "/mydb/_purged_infos_limit", body: body}
    assert Jason.decode!(body) == 500
  end
end
