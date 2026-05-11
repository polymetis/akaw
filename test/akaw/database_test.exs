defmodule Akaw.DatabaseTest do
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

    {:ok, client: Akaw.new(base_url: "http://couch.example", req_options: [plug: plug])}
  end

  test "head/2 returns :ok on a 200", %{client: client} do
    assert :ok = Akaw.Database.head(client, "mydb")
    assert_receive %{method: "HEAD", path: "/mydb"}
  end

  test "head/2 surfaces a 404 as %Akaw.Error{}" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 404, "") end
    client = Akaw.new(base_url: "http://x", req_options: [plug: plug, retry: false])

    assert {:error, %Akaw.Error{status: 404}} = Akaw.Database.head(client, "missing")
  end

  test "info/2 → GET /{db}", %{client: client} do
    assert {:ok, _} = Akaw.Database.info(client, "mydb")
    assert_receive %{method: "GET", path: "/mydb"}
  end

  test "create/3 → PUT /{db}", %{client: client} do
    assert {:ok, _} = Akaw.Database.create(client, "mydb")
    assert_receive %{method: "PUT", path: "/mydb"}
  end

  test "create/3 forwards options as query params", %{client: client} do
    assert {:ok, _} = Akaw.Database.create(client, "mydb", q: 8, n: 3, partitioned: true)
    assert_receive %{method: "PUT", path: "/mydb", query_string: qs}
    assert qs =~ "q=8"
    assert qs =~ "n=3"
    assert qs =~ "partitioned=true"
  end

  test "delete/2 → DELETE /{db}", %{client: client} do
    assert {:ok, _} = Akaw.Database.delete(client, "mydb")
    assert_receive %{method: "DELETE", path: "/mydb"}
  end

  test "post/3 POSTs the doc body", %{client: client} do
    assert {:ok, _} = Akaw.Database.post(client, "mydb", %{name: "alice", age: 30})
    assert_receive %{method: "POST", path: "/mydb", body: body}
    assert Jason.decode!(body) == %{"name" => "alice", "age" => 30}
  end

  test "compact/2 → POST /{db}/_compact", %{client: client} do
    assert {:ok, _} = Akaw.Database.compact(client, "mydb")
    assert_receive %{method: "POST", path: "/mydb/_compact"}
  end

  test "compact_views/3 → POST /{db}/_compact/{ddoc}", %{client: client} do
    assert {:ok, _} = Akaw.Database.compact_views(client, "mydb", "myddoc")
    assert_receive %{method: "POST", path: "/mydb/_compact/myddoc"}
  end

  test "view_cleanup/2 → POST /{db}/_view_cleanup", %{client: client} do
    assert {:ok, _} = Akaw.Database.view_cleanup(client, "mydb")
    assert_receive %{method: "POST", path: "/mydb/_view_cleanup"}
  end

  test "ensure_full_commit/2 → POST /{db}/_ensure_full_commit", %{client: client} do
    assert {:ok, _} = Akaw.Database.ensure_full_commit(client, "mydb")
    assert_receive %{method: "POST", path: "/mydb/_ensure_full_commit"}
  end

  test "revs_limit/2 → GET /{db}/_revs_limit", %{client: client} do
    assert {:ok, _} = Akaw.Database.revs_limit(client, "mydb")
    assert_receive %{method: "GET", path: "/mydb/_revs_limit"}
  end

  test "put_revs_limit/3 → PUT /{db}/_revs_limit with integer body", %{client: client} do
    assert {:ok, _} = Akaw.Database.put_revs_limit(client, "mydb", 500)
    assert_receive %{method: "PUT", path: "/mydb/_revs_limit", body: body}
    assert Jason.decode!(body) == 500
  end

  test "URL-encodes db names with special characters", %{client: client} do
    assert {:ok, _} = Akaw.Database.info(client, "weird/name")
    assert_receive %{path: "/weird%2Fname"}
  end
end
