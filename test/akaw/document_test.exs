defmodule Akaw.DocumentTest do
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

  test "head/3 → HEAD /{db}/{id}", %{client: client} do
    assert :ok = Akaw.Document.head(client, "mydb", "doc1")
    assert_receive %{method: "HEAD", path: "/mydb/doc1"}
  end

  test "get/4 → GET /{db}/{id}", %{client: client} do
    assert {:ok, _} = Akaw.Document.get(client, "mydb", "doc1")
    assert_receive %{method: "GET", path: "/mydb/doc1"}
  end

  test "get/4 forwards opts as query params", %{client: client} do
    assert {:ok, _} =
             Akaw.Document.get(client, "mydb", "doc1", rev: "2-abc", attachments: true)

    assert_receive %{path: "/mydb/doc1", query_string: qs}
    assert qs =~ "rev=2-abc"
    assert qs =~ "attachments=true"
  end

  test "put/5 → PUT /{db}/{id} with JSON body", %{client: client} do
    assert {:ok, _} = Akaw.Document.put(client, "mydb", "doc1", %{name: "alice"})
    assert_receive %{method: "PUT", path: "/mydb/doc1", body: body}
    assert Jason.decode!(body) == %{"name" => "alice"}
  end

  test "put/5 forwards :rev as a query param", %{client: client} do
    assert {:ok, _} = Akaw.Document.put(client, "mydb", "doc1", %{x: 1}, rev: "1-a")
    assert_receive %{path: "/mydb/doc1", query_string: "rev=1-a"}
  end

  test "delete/5 → DELETE /{db}/{id}?rev=…", %{client: client} do
    assert {:ok, _} = Akaw.Document.delete(client, "mydb", "doc1", "2-bcd")
    assert_receive %{method: "DELETE", path: "/mydb/doc1", query_string: "rev=2-bcd"}
  end

  test "copy/5 → COPY /{db}/{id} with Destination header", %{client: client} do
    assert {:ok, _} = Akaw.Document.copy(client, "mydb", "doc1", "doc2")
    assert_receive %{method: "COPY", path: "/mydb/doc1", headers: headers}
    assert {"destination", "doc2"} in headers
  end

  test "copy/5 with :destination_rev formats Destination as 'dest?rev=…'",
       %{client: client} do
    assert {:ok, _} =
             Akaw.Document.copy(client, "mydb", "doc1", "doc2", destination_rev: "1-x")

    assert_receive %{headers: headers}
    assert {"destination", "doc2?rev=1-x"} in headers
  end

  test "copy/5 forwards :rev as query param (source revision)", %{client: client} do
    assert {:ok, _} = Akaw.Document.copy(client, "mydb", "doc1", "doc2", rev: "1-a")
    assert_receive %{query_string: "rev=1-a"}
  end

  describe "doc id encoding" do
    test "URL-encodes a slash in a regular doc id", %{client: client} do
      assert {:ok, _} = Akaw.Document.get(client, "mydb", "with/slash")
      assert_receive %{path: "/mydb/with%2Fslash"}
    end

    test "preserves the literal slash for _design/ prefix", %{client: client} do
      assert {:ok, _} = Akaw.Document.get(client, "mydb", "_design/myddoc")
      assert_receive %{path: "/mydb/_design/myddoc"}
    end

    test "preserves the literal slash for _local/ prefix", %{client: client} do
      assert {:ok, _} = Akaw.Document.get(client, "mydb", "_local/checkpoint")
      assert_receive %{path: "/mydb/_local/checkpoint"}
    end

    test "encodes the suffix after _design/", %{client: client} do
      assert {:ok, _} = Akaw.Document.get(client, "mydb", "_design/with space")
      assert_receive %{path: "/mydb/_design/with%20space"}
    end
  end
end
