defmodule Akaw.DocumentsTest do
  use ExUnit.Case, async: true

  alias Akaw.Loopback

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

      Loopback.json(conn, %{"rows" => []})
    end

    {:ok, client: Loopback.client(plug)}
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
      assert JSON.decode!(body) == %{"keys" => ["a", "b", "c"]}
    end
  end

  describe "all_docs_queries/3" do
    test "POSTs to /_all_docs/queries with {queries: [...]}", %{client: client} do
      queries = [%{include_docs: true, limit: 10}, %{keys: ["x"]}]
      assert {:ok, _} = Akaw.Documents.all_docs_queries(client, "mydb", queries)

      assert_receive %{method: "POST", path: "/mydb/_all_docs/queries", body: body}
      decoded = JSON.decode!(body)

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
      # Observed via ETS, not the process dictionary or send/assert_receive:
      # the plug runs in a Bandit connection-handler process, and consuming a lazy
      # stream drains the caller's mailbox.
      seen = :ets.new(:akaw_doc_stream, [:public])

      plug = fn conn ->
        :ets.insert(seen, {:method, conn.method})
        :ets.insert(seen, {:path, conn.request_path})
        :ets.insert(seen, {:qs, conn.query_string})
        Loopback.json(conn, %{})
      end

      client = Loopback.client(plug)

      client |> Akaw.Documents.stream_all_docs("mydb", startkey: "u_") |> Enum.take(1)

      assert [{:method, "GET"}] = :ets.lookup(seen, :method)
      assert [{:path, "/mydb/_all_docs"}] = :ets.lookup(seen, :path)

      assert [{:qs, qs}] = :ets.lookup(seen, :qs)
      decoded = URI.decode_query(qs)
      assert decoded["startkey"] == "\"u_\""
    end
  end

  describe "stream_design_docs/3" do
    test "→ GET /{db}/_design_docs (streaming variant)" do
      # ETS for the same reason as the stream_all_docs test above.
      seen = :ets.new(:akaw_ddocs_stream, [:public])

      plug = fn conn ->
        :ets.insert(seen, {:path, conn.request_path})
        Loopback.json(conn, %{})
      end

      client = Loopback.client(plug)

      client |> Akaw.Documents.stream_design_docs("mydb") |> Enum.take(1)

      assert [{:path, "/mydb/_design_docs"}] = :ets.lookup(seen, :path)
    end
  end

  describe "design_docs_keys/4" do
    test "POSTs {keys: [...]} body", %{client: client} do
      assert {:ok, _} =
               Akaw.Documents.design_docs_keys(client, "mydb", ["_design/a"])

      assert_receive %{method: "POST", path: "/mydb/_design_docs", body: body}
      assert JSON.decode!(body) == %{"keys" => ["_design/a"]}
    end
  end

  describe "bulk_get/4" do
    test "POSTs {docs: [...]} with id+rev refs", %{client: client} do
      refs = [%{id: "a"}, %{id: "b", rev: "1-x"}]
      assert {:ok, _} = Akaw.Documents.bulk_get(client, "mydb", refs)

      assert_receive %{method: "POST", path: "/mydb/_bulk_get", body: body}

      assert JSON.decode!(body) == %{
               "docs" => [%{"id" => "a"}, %{"id" => "b", "rev" => "1-x"}]
             }
    end

    test "JSON-encodes the atts_since query param", %{client: client} do
      assert {:ok, _} =
               Akaw.Documents.bulk_get(client, "mydb", [%{id: "a"}], atts_since: ["1-abc"])

      assert_receive %{path: "/mydb/_bulk_get", query_string: qs}
      assert URI.decode_query(qs)["atts_since"] == ~s|["1-abc"]|
    end
  end

  describe "bulk_docs/4" do
    test "POSTs {docs: [...]} body", %{client: client} do
      docs = [%{name: "alice"}, %{name: "bob"}]
      assert {:ok, _} = Akaw.Documents.bulk_docs(client, "mydb", docs)

      assert_receive %{method: "POST", path: "/mydb/_bulk_docs", body: body}
      decoded = JSON.decode!(body)
      assert decoded["docs"] == [%{"name" => "alice"}, %{"name" => "bob"}]
    end

    test "folds new_edits into the body, not the query string", %{client: client} do
      assert {:ok, _} =
               Akaw.Documents.bulk_docs(client, "mydb", [%{_id: "a", _rev: "1-x"}],
                 new_edits: false
               )

      assert_receive %{path: "/mydb/_bulk_docs", query_string: "", body: body}
      decoded = JSON.decode!(body)
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
      decoded = JSON.decode!(body)
      assert decoded["docs"] == [%{"n" => "right"}]
      assert decoded["new_edits"] == false
    end
  end
end
