defmodule Akaw.AttachmentTest do
  use ExUnit.Case, async: true

  defp recording_client(reply_fn) do
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

      reply_fn.(conn)
    end

    Akaw.new(base_url: "http://x", req_options: [plug: plug])
  end

  describe "head/4" do
    test "→ HEAD /{db}/{doc}/{att}; returns :ok on a 200" do
      client = recording_client(fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
      assert :ok = Akaw.Attachment.head(client, "mydb", "doc1", "thumb.png")
      assert_receive %{method: "HEAD", path: "/mydb/doc1/thumb.png"}
    end

    test "404 surfaces as %Akaw.Error{}" do
      client =
        Akaw.new(
          base_url: "http://x",
          req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 404, "") end, retry: false]
        )

      assert {:error, %Akaw.Error{status: 404}} =
               Akaw.Attachment.head(client, "mydb", "doc1", "missing.png")
    end
  end

  describe "get/5" do
    test "returns {:ok, body, meta} with content-type and etag" do
      client =
        recording_client(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "image/png")
          |> Plug.Conn.put_resp_header("etag", ~s|"3-rev"|)
          |> Plug.Conn.send_resp(200, <<137, 80, 78, 71>>)
        end)

      assert {:ok, body, meta} =
               Akaw.Attachment.get(client, "mydb", "doc1", "thumb.png")

      assert body == <<137, 80, 78, 71>>
      assert meta.content_type == "image/png"
      assert meta.etag == ~s|"3-rev"|
    end

    test "forwards :rev as a query param" do
      client =
        recording_client(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
          |> Plug.Conn.send_resp(200, "data")
        end)

      assert {:ok, _, _} =
               Akaw.Attachment.get(client, "mydb", "doc1", "f.bin", rev: "1-x")

      assert_receive %{path: "/mydb/doc1/f.bin", query_string: "rev=1-x"}
    end
  end

  describe "put/6" do
    test "→ PUT /{db}/{doc}/{att} with body, content-type, and rev" do
      client =
        recording_client(fn conn ->
          Req.Test.json(conn, %{"id" => "doc1", "rev" => "2-x", "ok" => true})
        end)

      assert {:ok, _} =
               Akaw.Attachment.put(client, "mydb", "doc1", "thumb.png", <<1, 2, 3>>,
                 content_type: "image/png",
                 rev: "1-old"
               )

      assert_receive %{
        method: "PUT",
        path: "/mydb/doc1/thumb.png",
        body: body,
        headers: headers,
        query_string: qs
      }

      assert body == <<1, 2, 3>>
      assert {"content-type", "image/png"} in headers
      assert qs == "rev=1-old"
    end

    test "defaults content-type to application/octet-stream" do
      client =
        recording_client(fn conn ->
          Req.Test.json(conn, %{"ok" => true})
        end)

      assert {:ok, _} =
               Akaw.Attachment.put(client, "mydb", "doc1", "f.bin", <<0>>, rev: "1-x")

      assert_receive %{headers: headers}
      assert {"content-type", "application/octet-stream"} in headers
    end
  end

  describe "delete/6" do
    test "→ DELETE /{db}/{doc}/{att}?rev=…" do
      client = recording_client(fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

      assert {:ok, _} =
               Akaw.Attachment.delete(client, "mydb", "doc1", "thumb.png", "2-y")

      assert_receive %{method: "DELETE", path: "/mydb/doc1/thumb.png", query_string: "rev=2-y"}
    end
  end

  test "preserves _design/ in the path" do
    test = self()

    plug = fn conn ->
      send(test, conn.request_path)
      Req.Test.json(conn, %{"ok" => true})
    end

    client = Akaw.new(base_url: "http://x", req_options: [plug: plug])

    assert {:ok, _} =
             Akaw.Attachment.put(client, "mydb", "_design/myddoc", "logo.png", <<0>>,
               rev: "1-a",
               content_type: "image/png"
             )

    assert_receive "/mydb/_design/myddoc/logo.png"
  end
end
