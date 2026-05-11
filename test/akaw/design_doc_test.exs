defmodule Akaw.DesignDocTest do
  use ExUnit.Case, async: true

  setup do
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(test, %{
        method: conn.method,
        path: conn.request_path,
        query_string: conn.query_string,
        body: body,
        headers: conn.req_headers
      })

      Req.Test.json(conn, %{"ok" => true})
    end

    {:ok, client: Akaw.new(base_url: "http://x", req_options: [plug: plug])}
  end

  test "head/3 → HEAD /{db}/_design/{ddoc}", %{client: client} do
    assert :ok = Akaw.DesignDoc.head(client, "mydb", "myddoc")
    assert_receive %{method: "HEAD", path: "/mydb/_design/myddoc"}
  end

  test "get/4 → GET /{db}/_design/{ddoc}", %{client: client} do
    assert {:ok, _} = Akaw.DesignDoc.get(client, "mydb", "myddoc")
    assert_receive %{method: "GET", path: "/mydb/_design/myddoc"}
  end

  test "put/5 → PUT /{db}/_design/{ddoc}", %{client: client} do
    ddoc = %{language: "javascript", views: %{by_name: %{map: "function(d){...}"}}}
    assert {:ok, _} = Akaw.DesignDoc.put(client, "mydb", "myddoc", ddoc)
    assert_receive %{method: "PUT", path: "/mydb/_design/myddoc", body: body}
    assert Jason.decode!(body)["language"] == "javascript"
  end

  test "delete/5 → DELETE /{db}/_design/{ddoc}?rev=…", %{client: client} do
    assert {:ok, _} = Akaw.DesignDoc.delete(client, "mydb", "myddoc", "2-x")
    assert_receive %{method: "DELETE", path: "/mydb/_design/myddoc", query_string: "rev=2-x"}
  end

  test "copy/5 → COPY /{db}/_design/{src} with Destination: _design/{dest}",
       %{client: client} do
    assert {:ok, _} = Akaw.DesignDoc.copy(client, "mydb", "src", "dest")
    assert_receive %{method: "COPY", path: "/mydb/_design/src", headers: headers}
    assert {"destination", "_design/dest"} in headers
  end

  test "info/3 → GET /{db}/_design/{ddoc}/_info", %{client: client} do
    assert {:ok, _} = Akaw.DesignDoc.info(client, "mydb", "myddoc")
    assert_receive %{method: "GET", path: "/mydb/_design/myddoc/_info"}
  end
end
