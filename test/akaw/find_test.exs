defmodule Akaw.FindTest do
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

      Req.Test.json(conn, %{"docs" => []})
    end

    {:ok, client: Akaw.new(base_url: "http://x", req_options: [plug: plug])}
  end

  test "find/3 POSTs to /{db}/_find with the query body", %{client: client} do
    query = %{
      selector: %{age: %{"$gt" => 21}},
      fields: ["_id", "name"],
      limit: 25
    }

    assert {:ok, _} = Akaw.Find.find(client, "users", query)
    assert_receive %{method: "POST", path: "/users/_find", body: body}
    decoded = Jason.decode!(body)
    assert decoded["selector"] == %{"age" => %{"$gt" => 21}}
    assert decoded["limit"] == 25
  end

  test "explain/3 POSTs to /{db}/_explain with the query body", %{client: client} do
    assert {:ok, _} = Akaw.Find.explain(client, "users", %{selector: %{name: "alice"}})
    assert_receive %{method: "POST", path: "/users/_explain", body: body}
    assert Jason.decode!(body) == %{"selector" => %{"name" => "alice"}}
  end

  test "create_index/3 POSTs the index definition", %{client: client} do
    index = %{
      index: %{fields: ["name", "email"]},
      name: "by_name_email",
      type: "json"
    }

    assert {:ok, _} = Akaw.Find.create_index(client, "users", index)
    assert_receive %{method: "POST", path: "/users/_index", body: body}
    decoded = Jason.decode!(body)
    assert decoded["name"] == "by_name_email"
    assert decoded["index"]["fields"] == ["name", "email"]
  end

  test "list_indexes/2 → GET /{db}/_index", %{client: client} do
    assert {:ok, _} = Akaw.Find.list_indexes(client, "users")
    assert_receive %{method: "GET", path: "/users/_index"}
  end

  test "delete_index/5 with default type=json", %{client: client} do
    assert {:ok, _} = Akaw.Find.delete_index(client, "users", "ddoc1", "by_name")
    assert_receive %{method: "DELETE", path: "/users/_index/ddoc1/json/by_name"}
  end

  test "delete_index/5 supports type=text", %{client: client} do
    assert {:ok, _} =
             Akaw.Find.delete_index(client, "users", "ddoc1", "text", "by_search")

    assert_receive %{method: "DELETE", path: "/users/_index/ddoc1/text/by_search"}
  end
end
