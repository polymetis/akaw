defmodule Akaw.DocumentsTest do
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

  describe "all_docs/3" do
    test "→ GET /{db}/_all_docs", %{client: client} do
      assert {:ok, _} = Akaw.Documents.all_docs(client, "mydb")
      assert_receive %{method: "GET", path: "/mydb/_all_docs"}
    end

    test "forwards plain opts as query params", %{client: client} do
      assert {:ok, _} =
               Akaw.Documents.all_docs(client, "mydb", limit: 10, include_docs: true)

      assert_receive %{query_string: qs}
      assert qs =~ "limit=10"
      assert qs =~ "include_docs=true"
    end

    test "JSON-encodes startkey/endkey/key", %{client: client} do
      assert {:ok, _} =
               Akaw.Documents.all_docs(client, "mydb",
                 startkey: "user_",
                 endkey: "user_z"
               )

      # JSON-encoded -> "user_" -> URI-encoded -> %22user_%22
      assert_receive %{query_string: qs}
      decoded = URI.decode_query(qs)
      assert decoded["startkey"] == "\"user_\""
      assert decoded["endkey"] == "\"user_z\""
    end

    test "JSON-encodes a list-typed key", %{client: client} do
      assert {:ok, _} = Akaw.Documents.all_docs(client, "mydb", key: ["2026", "click"])
      assert_receive %{query_string: qs}
      decoded = URI.decode_query(qs)
      assert decoded["key"] == ~s|["2026","click"]|
    end

    test "leaves non-JSON-typed params untouched", %{client: client} do
      assert {:ok, _} =
               Akaw.Documents.all_docs(client, "mydb",
                 startkey_docid: "user_42",
                 limit: 5
               )

      assert_receive %{query_string: qs}
      decoded = URI.decode_query(qs)
      assert decoded["startkey_docid"] == "user_42"
      assert decoded["limit"] == "5"
    end
  end

  describe "all_docs_keys/4" do
    test "POSTs {keys: [...]} body", %{client: client} do
      assert {:ok, _} =
               Akaw.Documents.all_docs_keys(client, "mydb", ["a", "b", "c"])

      assert_receive %{method: "POST", path: "/mydb/_all_docs", body: body}
      assert Jason.decode!(body) == %{"keys" => ["a", "b", "c"]}
    end
  end

  describe "all_docs_queries/3" do
    test "POSTs to /_all_docs/queries with {queries: [...]}", %{client: client} do
      queries = [%{include_docs: true, limit: 10}, %{keys: ["x"]}]
      assert {:ok, _} = Akaw.Documents.all_docs_queries(client, "mydb", queries)

      assert_receive %{method: "POST", path: "/mydb/_all_docs/queries", body: body}
      decoded = Jason.decode!(body)

      assert decoded["queries"] == [
               %{"include_docs" => true, "limit" => 10},
               %{"keys" => ["x"]}
             ]
    end
  end

  describe "design_docs/3" do
    test "→ GET /{db}/_design_docs", %{client: client} do
      assert {:ok, _} = Akaw.Documents.design_docs(client, "mydb")
      assert_receive %{method: "GET", path: "/mydb/_design_docs"}
    end
  end

  describe "stream_all_docs/3" do
    test "→ GET /{db}/_all_docs and forwards JSON-typed params encoded" do
      plug = fn conn ->
        Process.put(:akaw_doc_stream_method, conn.method)
        Process.put(:akaw_doc_stream_path, conn.request_path)
        Process.put(:akaw_doc_stream_qs, conn.query_string)
        Req.Test.json(conn, %{})
      end

      client = Akaw.new(base_url: "http://x", req_options: [plug: plug, retry: false])

      try do
        client |> Akaw.Documents.stream_all_docs("mydb", startkey: "u_") |> Enum.take(1)
      rescue
        _ -> :ok
      end

      assert Process.get(:akaw_doc_stream_method) == "GET"
      assert Process.get(:akaw_doc_stream_path) == "/mydb/_all_docs"

      qs = Process.get(:akaw_doc_stream_qs) || ""
      decoded = URI.decode_query(qs)
      assert decoded["startkey"] == "\"u_\""
    end
  end

  describe "stream_design_docs/3" do
    test "→ GET /{db}/_design_docs (streaming variant)" do
      plug = fn conn ->
        Process.put(:akaw_ddocs_stream_path, conn.request_path)
        Req.Test.json(conn, %{})
      end

      client = Akaw.new(base_url: "http://x", req_options: [plug: plug, retry: false])

      try do
        client |> Akaw.Documents.stream_design_docs("mydb") |> Enum.take(1)
      rescue
        _ -> :ok
      end

      assert Process.get(:akaw_ddocs_stream_path) == "/mydb/_design_docs"
    end
  end

  describe "design_docs_keys/4" do
    test "POSTs {keys: [...]} body", %{client: client} do
      assert {:ok, _} =
               Akaw.Documents.design_docs_keys(client, "mydb", ["_design/a"])

      assert_receive %{method: "POST", path: "/mydb/_design_docs", body: body}
      assert Jason.decode!(body) == %{"keys" => ["_design/a"]}
    end
  end

  describe "bulk_get/4" do
    test "POSTs {docs: [...]} with id+rev refs", %{client: client} do
      refs = [%{id: "a"}, %{id: "b", rev: "1-x"}]
      assert {:ok, _} = Akaw.Documents.bulk_get(client, "mydb", refs)

      assert_receive %{method: "POST", path: "/mydb/_bulk_get", body: body}

      assert Jason.decode!(body) == %{
               "docs" => [%{"id" => "a"}, %{"id" => "b", "rev" => "1-x"}]
             }
    end
  end

  describe "bulk_docs/4" do
    test "POSTs {docs: [...]} body", %{client: client} do
      docs = [%{name: "alice"}, %{name: "bob"}]
      assert {:ok, _} = Akaw.Documents.bulk_docs(client, "mydb", docs)

      assert_receive %{method: "POST", path: "/mydb/_bulk_docs", body: body}
      decoded = Jason.decode!(body)
      assert decoded["docs"] == [%{"name" => "alice"}, %{"name" => "bob"}]
    end

    test "folds new_edits into the body, not the query string", %{client: client} do
      assert {:ok, _} =
               Akaw.Documents.bulk_docs(client, "mydb", [%{_id: "a", _rev: "1-x"}],
                 new_edits: false
               )

      assert_receive %{path: "/mydb/_bulk_docs", query_string: "", body: body}
      decoded = Jason.decode!(body)
      assert decoded["new_edits"] == false
      assert decoded["docs"] == [%{"_id" => "a", "_rev" => "1-x"}]
    end

    test "explicit docs argument wins over a stray :docs option", %{client: client} do
      # Caller passes :docs in opts by mistake; the positional argument wins.
      assert {:ok, _} =
               Akaw.Documents.bulk_docs(client, "mydb", [%{n: "right"}],
                 docs: [%{n: "wrong"}],
                 new_edits: false
               )

      assert_receive %{body: body}
      decoded = Jason.decode!(body)
      assert decoded["docs"] == [%{"n" => "right"}]
      assert decoded["new_edits"] == false
    end
  end
end
