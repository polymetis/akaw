defmodule Akaw.ChangesTest do
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

      Req.Test.json(conn, %{"results" => [], "last_seq" => "0"})
    end

    {:ok, client: Akaw.new(base_url: "http://x", req_options: [plug: plug])}
  end

  describe "get/3" do
    test "→ GET /{db}/_changes", %{client: client} do
      assert {:ok, _} = Akaw.Changes.get(client, "mydb")
      assert_receive %{method: "GET", path: "/mydb/_changes"}
    end

    test "forwards opts as query params", %{client: client} do
      assert {:ok, _} =
               Akaw.Changes.get(client, "mydb",
                 since: "now",
                 feed: "longpoll",
                 timeout: 30_000,
                 include_docs: true
               )

      assert_receive %{path: "/mydb/_changes", query_string: qs}
      assert qs =~ "since=now"
      assert qs =~ "feed=longpoll"
      assert qs =~ "timeout=30000"
      assert qs =~ "include_docs=true"
    end
  end

  describe "post/4" do
    test "POSTs body with doc_ids filter", %{client: client} do
      assert {:ok, _} =
               Akaw.Changes.post(client, "mydb", %{doc_ids: ["a", "b"]},
                 filter: "_doc_ids",
                 since: "now"
               )

      assert_receive %{
        method: "POST",
        path: "/mydb/_changes",
        body: body,
        query_string: qs
      }

      assert Jason.decode!(body) == %{"doc_ids" => ["a", "b"]}
      assert qs =~ "filter=_doc_ids"
      assert qs =~ "since=now"
    end
  end

  describe "stream/3 — error handling" do
    test "raises Akaw.Error for HTTP non-2xx on open" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          Jason.encode!(%{"error" => "not_found", "reason" => "no_db_file"})
        )
      end

      client = Akaw.new(base_url: "http://x", req_options: [plug: plug, retry: false])

      assert_raise Akaw.Error, ~r/404/, fn ->
        client |> Akaw.Changes.stream("missing") |> Enum.take(1)
      end
    end
  end

  describe "stream_post/4" do
    test "POSTs body with filter and forces feed=continuous" do
      plug = fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        Process.put(:akaw_changes_post_method, conn.method)
        Process.put(:akaw_changes_post_path, conn.request_path)
        Process.put(:akaw_changes_post_qs, conn.query_string)
        Process.put(:akaw_changes_post_body, body)
        Req.Test.json(conn, %{})
      end

      client = Akaw.new(base_url: "http://x", req_options: [plug: plug, retry: false])

      try do
        client
        |> Akaw.Changes.stream_post("mydb", %{doc_ids: ["a", "b"]},
          filter: "_doc_ids",
          since: "now"
        )
        |> Enum.take(1)
      rescue
        _ -> :ok
      end

      assert Process.get(:akaw_changes_post_method) == "POST"
      assert Process.get(:akaw_changes_post_path) == "/mydb/_changes"

      assert Jason.decode!(Process.get(:akaw_changes_post_body)) == %{
               "doc_ids" => ["a", "b"]
             }

      qs = Process.get(:akaw_changes_post_qs) || ""
      assert qs =~ "feed=continuous"
      assert qs =~ "filter=_doc_ids"
      assert qs =~ "since=now"
    end
  end

  describe "stream/3 — feed forcing" do
    # We capture the query string into the process dictionary rather than
    # sending it as a message — `next_chunk`'s `receive` eagerly drains the
    # mailbox and would swallow a regular `send`. End-to-end streaming
    # (multiple chunks, line splitting across them) is exercised against a
    # real CouchDB in tests tagged `:integration` because Req.Test's plug
    # transport buffers the body rather than chunking it.
    test "forces feed=continuous and forwards other opts" do
      plug = fn conn ->
        Process.put(:akaw_changes_qs, conn.query_string)
        Req.Test.json(conn, %{})
      end

      client = Akaw.new(base_url: "http://x", req_options: [plug: plug, retry: false])

      try do
        client
        |> Akaw.Changes.stream("mydb", since: "now", heartbeat: 30_000)
        |> Enum.take(1)
      rescue
        _ -> :ok
      end

      qs = Process.get(:akaw_changes_qs) || ""
      assert qs =~ "feed=continuous"
      assert qs =~ "since=now"
      assert qs =~ "heartbeat=30000"
    end
  end
end
