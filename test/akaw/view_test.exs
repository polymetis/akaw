defmodule Akaw.ViewTest do
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

      Req.Test.json(conn, %{"rows" => []})
    end

    {:ok, client: Akaw.new(base_url: "http://x", req_options: [plug: plug])}
  end

  describe "get/5" do
    test "→ GET /{db}/_design/{ddoc}/_view/{view}", %{client: client} do
      assert {:ok, _} = Akaw.View.get(client, "mydb", "ddoc1", "by_name")
      assert_receive %{method: "GET", path: "/mydb/_design/ddoc1/_view/by_name"}
    end

    test "forwards plain opts as query params", %{client: client} do
      assert {:ok, _} =
               Akaw.View.get(client, "mydb", "ddoc1", "by_name",
                 limit: 50,
                 reduce: false,
                 group_level: 2
               )

      assert_receive %{query_string: qs}
      assert qs =~ "limit=50"
      assert qs =~ "reduce=false"
      assert qs =~ "group_level=2"
    end

    test "JSON-encodes startkey/endkey/key", %{client: client} do
      assert {:ok, _} =
               Akaw.View.get(client, "mydb", "ddoc1", "by_name",
                 startkey: "alice",
                 endkey: "bob"
               )

      assert_receive %{query_string: qs}
      decoded = URI.decode_query(qs)
      assert decoded["startkey"] == "\"alice\""
      assert decoded["endkey"] == "\"bob\""
    end
  end

  describe "post_keys/6" do
    test "POSTs {keys: [...]} body", %{client: client} do
      assert {:ok, _} =
               Akaw.View.post_keys(client, "mydb", "ddoc1", "by_name", ["alice", "bob"])

      assert_receive %{
        method: "POST",
        path: "/mydb/_design/ddoc1/_view/by_name",
        body: body
      }

      assert Jason.decode!(body) == %{"keys" => ["alice", "bob"]}
    end
  end

  describe "queries/5" do
    test "POSTs to /_view/{view}/queries", %{client: client} do
      qs = [%{key: "alice", limit: 10}, %{startkey: "b", endkey: "c"}]
      assert {:ok, _} = Akaw.View.queries(client, "mydb", "ddoc1", "by_name", qs)

      assert_receive %{
        method: "POST",
        path: "/mydb/_design/ddoc1/_view/by_name/queries",
        body: body
      }

      decoded = Jason.decode!(body)
      assert length(decoded["queries"]) == 2
    end
  end
end
