defmodule Akaw.ReduceWhileTest do
  use ExUnit.Case, async: true

  # Unit tests for the synchronous, backpressured `reduce_while` callback
  # API across the streaming endpoints. Req's :plug adapter delivers the
  # whole response body to our `into: fun` collector in a single chunk,
  # so chunk-boundary behavior (line splitting across chunks, etc.) is
  # exercised against real CouchDB in test/integration. Here we cover:
  #
  #   * request shape (method, path, params, body) per endpoint
  #   * the reducer is called with each parsed item / line
  #   * `:halt` stops iteration early
  #   * HTTP non-2xx is returned as `{:error, %Akaw.Error{}}`
  #   * the calling process's mailbox is *not* drained — the documented
  #     win over the lazy `stream/N` variants

  defp pretty_rows(rows, container \\ "rows") do
    body = Enum.map_join(rows, ",\n", &Jason.encode!/1)
    ~s({"total_rows":#{length(rows)},"offset":0,"#{container}":[\n#{body}\n]})
  end

  defp pretty_plug(rows, container \\ "rows") do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, pretty_rows(rows, container))
    end
  end

  defp lines_plug(objects) do
    fn conn ->
      body = Enum.map_join(objects, "\n", &Jason.encode!/1) <> "\n"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defp client_with(plug) do
    Akaw.new(base_url: "http://x", req_options: [plug: plug, retry: false])
  end

  defp error_client(status, body) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end

    client_with(plug)
  end

  describe "Akaw.View.reduce_while/7" do
    test "calls reducer for each decoded row and accumulates" do
      client =
        pretty_plug([
          %{"id" => "a", "key" => "a", "value" => 1},
          %{"id" => "b", "key" => "b", "value" => 2},
          %{"id" => "c", "key" => "c", "value" => 3}
        ])
        |> client_with()

      assert {:ok, ids} =
               Akaw.View.reduce_while(client, "db", "ddoc", "v", [], fn row, acc ->
                 {:cont, [row["id"] | acc]}
               end)

      assert Enum.reverse(ids) == ["a", "b", "c"]
    end

    test ":halt stops iteration and returns the halted acc" do
      client =
        pretty_plug([
          %{"id" => "a"},
          %{"id" => "b"},
          %{"id" => "c"}
        ])
        |> client_with()

      assert {:ok, ids} =
               Akaw.View.reduce_while(client, "db", "ddoc", "v", [], fn row, acc ->
                 case row["id"] do
                   "b" -> {:halt, [row["id"] | acc]}
                   _ -> {:cont, [row["id"] | acc]}
                 end
               end)

      assert Enum.reverse(ids) == ["a", "b"]
    end

    test "returns {:error, %Akaw.Error{}} for HTTP non-2xx" do
      client = error_client(404, %{"error" => "not_found", "reason" => "no_db_file"})

      assert {:error, %Akaw.Error{status: 404, error: "not_found", reason: "no_db_file"}} =
               Akaw.View.reduce_while(client, "missing", "d", "v", 0, fn _, acc ->
                 {:cont, acc + 1}
               end)
    end

    test "forwards opts as JSON-encoded query params (matches stream/5)" do
      test = self()

      plug = fn conn ->
        send(test, %{method: conn.method, path: conn.request_path, qs: conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, pretty_rows([]))
      end

      assert {:ok, 0} =
               client_with(plug)
               |> Akaw.View.reduce_while(
                 "db",
                 "d",
                 "v",
                 0,
                 fn _, acc -> {:cont, acc + 1} end,
                 startkey: "a",
                 endkey: "z",
                 limit: 10
               )

      assert_receive %{method: "GET", path: "/db/_design/d/_view/v", qs: qs}
      decoded = URI.decode_query(qs)
      assert decoded["startkey"] == "\"a\""
      assert decoded["endkey"] == "\"z\""
      assert decoded["limit"] == "10"
    end

    test "empty array returns the initial acc" do
      client = pretty_plug([]) |> client_with()

      assert {:ok, 0} =
               Akaw.View.reduce_while(client, "db", "d", "v", 0, fn _, acc ->
                 {:cont, acc + 1}
               end)
    end
  end

  describe "Akaw.View.reduce_while_post_keys/8" do
    test "POSTs keys body and reduces over rows" do
      test = self()

      plug = fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        send(test, %{method: conn.method, path: conn.request_path, body: body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, pretty_rows([%{"id" => "a"}, %{"id" => "b"}]))
      end

      assert {:ok, 2} =
               client_with(plug)
               |> Akaw.View.reduce_while_post_keys("db", "d", "v", ["a", "b"], 0, fn _, n ->
                 {:cont, n + 1}
               end)

      assert_receive %{method: "POST", path: "/db/_design/d/_view/v", body: body}
      assert Jason.decode!(body) == %{"keys" => ["a", "b"]}
    end
  end

  describe "Akaw.Find.reduce_while/5" do
    test "reduces over the docs container (not rows)" do
      client =
        pretty_plug([%{"_id" => "a", "n" => 1}, %{"_id" => "b", "n" => 2}], "docs")
        |> client_with()

      assert {:ok, ns} =
               Akaw.Find.reduce_while(client, "db", %{selector: %{n: %{"$gt" => 0}}}, [], fn d,
                                                                                             acc ->
                 {:cont, [d["n"] | acc]}
               end)

      assert Enum.reverse(ns) == [1, 2]
    end

    test "POSTs the selector body" do
      test = self()

      plug = fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        send(test, %{method: conn.method, path: conn.request_path, body: body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, pretty_rows([], "docs"))
      end

      assert {:ok, 0} =
               client_with(plug)
               |> Akaw.Find.reduce_while("db", %{selector: %{n: 1}}, 0, fn _, a ->
                 {:cont, a + 1}
               end)

      assert_receive %{method: "POST", path: "/db/_find", body: body}
      assert Jason.decode!(body) == %{"selector" => %{"n" => 1}}
    end
  end

  describe "Akaw.Documents.reduce_while_all_docs/5" do
    test "reduces over the rows container" do
      client =
        pretty_plug([
          %{"id" => "a", "key" => "a", "value" => %{"rev" => "1-x"}},
          %{"id" => "b", "key" => "b", "value" => %{"rev" => "1-y"}}
        ])
        |> client_with()

      assert {:ok, 2} =
               Akaw.Documents.reduce_while_all_docs(client, "db", 0, fn _, n -> {:cont, n + 1} end)
    end

    test "forwards opts as JSON-encoded query params" do
      test = self()

      plug = fn conn ->
        send(test, %{path: conn.request_path, qs: conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, pretty_rows([]))
      end

      assert {:ok, 0} =
               client_with(plug)
               |> Akaw.Documents.reduce_while_all_docs(
                 "db",
                 0,
                 fn _, a -> {:cont, a + 1} end,
                 startkey: "user_",
                 limit: 5
               )

      assert_receive %{path: "/db/_all_docs", qs: qs}
      decoded = URI.decode_query(qs)
      assert decoded["startkey"] == "\"user_\""
      assert decoded["limit"] == "5"
    end
  end

  describe "Akaw.Documents.reduce_while_design_docs/5" do
    test "hits /_design_docs" do
      test = self()

      plug = fn conn ->
        send(test, %{path: conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, pretty_rows([]))
      end

      assert {:ok, 0} =
               client_with(plug)
               |> Akaw.Documents.reduce_while_design_docs("db", 0, fn _, a -> {:cont, a + 1} end)

      assert_receive %{path: "/db/_design_docs"}
    end
  end

  describe "Akaw.Changes.reduce_while/5" do
    test "reduces over line-delimited change objects" do
      client =
        lines_plug([
          %{"seq" => "1", "id" => "doc_a", "changes" => [%{"rev" => "1-abc"}]},
          %{"seq" => "2", "id" => "doc_b", "changes" => [%{"rev" => "1-def"}]}
        ])
        |> client_with()

      assert {:ok, ids} =
               Akaw.Changes.reduce_while(client, "db", [], fn change, acc ->
                 {:cont, [change["id"] | acc]}
               end)

      assert Enum.reverse(ids) == ["doc_a", "doc_b"]
    end

    test ":halt closes the loop" do
      client =
        lines_plug([
          %{"id" => "a"},
          %{"id" => "b"},
          %{"id" => "c"}
        ])
        |> client_with()

      assert {:ok, ids} =
               Akaw.Changes.reduce_while(client, "db", [], fn change, acc ->
                 case change["id"] do
                   "b" -> {:halt, [change["id"] | acc]}
                   _ -> {:cont, [change["id"] | acc]}
                 end
               end)

      assert Enum.reverse(ids) == ["a", "b"]
    end

    test "forces feed=continuous and forwards other opts" do
      test = self()

      plug = fn conn ->
        send(test, %{path: conn.request_path, qs: conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "")
      end

      assert {:ok, 0} =
               client_with(plug)
               |> Akaw.Changes.reduce_while(
                 "db",
                 0,
                 fn _, a -> {:cont, a + 1} end,
                 since: "now",
                 heartbeat: 30_000
               )

      assert_receive %{path: "/db/_changes", qs: qs}
      assert qs =~ "feed=continuous"
      assert qs =~ "since=now"
      assert qs =~ "heartbeat=30000"
    end
  end

  describe "Akaw.Changes.reduce_while_post/6" do
    test "POSTs body, forces feed=continuous" do
      test = self()

      plug = fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        send(test, %{method: conn.method, path: conn.request_path, qs: conn.query_string, body: body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "")
      end

      assert {:ok, 0} =
               client_with(plug)
               |> Akaw.Changes.reduce_while_post(
                 "db",
                 %{doc_ids: ["a", "b"]},
                 0,
                 fn _, a -> {:cont, a + 1} end,
                 filter: "_doc_ids",
                 since: "now"
               )

      assert_receive %{
        method: "POST",
        path: "/db/_changes",
        qs: qs,
        body: body
      }

      assert Jason.decode!(body) == %{"doc_ids" => ["a", "b"]}
      assert qs =~ "feed=continuous"
      assert qs =~ "filter=_doc_ids"
      assert qs =~ "since=now"
    end
  end

  describe "Akaw.Partition reduce_while_*" do
    test "reduce_while_all_docs/6 hits the partition-scoped endpoint" do
      test = self()

      plug = fn conn ->
        send(test, %{method: conn.method, path: conn.request_path, qs: conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          pretty_rows([%{"id" => "t42:a"}, %{"id" => "t42:b"}])
        )
      end

      assert {:ok, 2} =
               client_with(plug)
               |> Akaw.Partition.reduce_while_all_docs(
                 "db",
                 "t42",
                 0,
                 fn _, n -> {:cont, n + 1} end,
                 include_docs: true
               )

      assert_receive %{
        method: "GET",
        path: "/db/_partition/t42/_all_docs",
        qs: qs
      }

      assert qs =~ "include_docs=true"
    end

    test "reduce_while_view/8 hits partition-scoped view path" do
      test = self()

      plug = fn conn ->
        send(test, %{path: conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, pretty_rows([]))
      end

      assert {:ok, 0} =
               client_with(plug)
               |> Akaw.Partition.reduce_while_view(
                 "db",
                 "t42",
                 "d",
                 "v",
                 0,
                 fn _, a -> {:cont, a + 1} end
               )

      assert_receive %{path: "/db/_partition/t42/_design/d/_view/v"}
    end

    test "reduce_while_find/7 POSTs the partition-scoped selector" do
      test = self()

      plug = fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        send(test, %{method: conn.method, path: conn.request_path, body: body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, pretty_rows([%{"_id" => "t42:a"}], "docs"))
      end

      assert {:ok, 1} =
               client_with(plug)
               |> Akaw.Partition.reduce_while_find(
                 "db",
                 "t42",
                 %{selector: %{active: true}},
                 0,
                 fn _, n -> {:cont, n + 1} end
               )

      assert_receive %{
        method: "POST",
        path: "/db/_partition/t42/_find",
        body: body
      }

      assert Jason.decode!(body) == %{"selector" => %{"active" => true}}
    end
  end

  describe "Akaw.Server.reduce_while_db_updates/4" do
    test "forces feed=continuous and forwards opts as query params" do
      test = self()

      plug = fn conn ->
        send(test, %{path: conn.request_path, qs: conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "")
      end

      assert {:ok, 0} =
               client_with(plug)
               |> Akaw.Server.reduce_while_db_updates(
                 0,
                 fn _, a -> {:cont, a + 1} end,
                 since: "now",
                 heartbeat: 30_000
               )

      assert_receive %{path: "/_db_updates", qs: qs}
      assert qs =~ "feed=continuous"
      assert qs =~ "since=now"
      assert qs =~ "heartbeat=30000"
    end

    test "reduces over line-delimited update events" do
      client =
        lines_plug([
          %{"db_name" => "alpha", "type" => "created"},
          %{"db_name" => "beta", "type" => "updated"}
        ])
        |> client_with()

      assert {:ok, names} =
               Akaw.Server.reduce_while_db_updates(client, [], fn evt, acc ->
                 {:cont, [evt["db_name"] | acc]}
               end)

      assert Enum.reverse(names) == ["alpha", "beta"]
    end
  end

  describe "opt routing: split_req_opts / default_receive_timeout" do
    # The helper that splits Req-level options out of an otherwise-CouchDB
    # opts keyword. Lives on Akaw.Streaming because it's shared by every
    # reduce_while wrapper.
    test "split_req_opts/1 pulls out :receive_timeout, :pool_timeout, :connect_options" do
      {req, rest} =
        Akaw.Streaming.split_req_opts(
          receive_timeout: 1_000,
          pool_timeout: 500,
          connect_options: [protocols: [:http1]],
          since: "now",
          heartbeat: 30_000
        )

      assert Keyword.get(req, :receive_timeout) == 1_000
      assert Keyword.get(req, :pool_timeout) == 500
      assert Keyword.get(req, :connect_options) == [protocols: [:http1]]
      assert Keyword.get(rest, :since) == "now"
      assert Keyword.get(rest, :heartbeat) == 30_000
      refute Keyword.has_key?(rest, :receive_timeout)
    end

    test "default_receive_timeout/2 honors an explicit receive_timeout" do
      req = Akaw.Streaming.default_receive_timeout([receive_timeout: 9_999], heartbeat: 30_000)
      assert Keyword.get(req, :receive_timeout) == 9_999
    end

    test "default_receive_timeout/2 derives 2x heartbeat when not set" do
      req = Akaw.Streaming.default_receive_timeout([], heartbeat: 30_000)
      assert Keyword.get(req, :receive_timeout) == 60_000
    end

    test "default_receive_timeout/2 picks 120s when heartbeat=true / \"true\" (server picks interval)" do
      req_true = Akaw.Streaming.default_receive_timeout([], heartbeat: true)
      req_str = Akaw.Streaming.default_receive_timeout([], heartbeat: "true")

      assert Keyword.get(req_true, :receive_timeout) == 120_000
      assert Keyword.get(req_str, :receive_timeout) == 120_000
    end

    test "default_receive_timeout/2 ignores heartbeat: 0 (no timeout set)" do
      assert Akaw.Streaming.default_receive_timeout([], heartbeat: 0) == []
    end

    test "default_receive_timeout/2 ignores negative heartbeat" do
      assert Akaw.Streaming.default_receive_timeout([], heartbeat: -1_000) == []
    end

    test "default_receive_timeout/2 ignores when no heartbeat at all" do
      assert Akaw.Streaming.default_receive_timeout([], []) == []
    end

    # The behavioral assertion: receive_timeout MUST NOT leak into the
    # query string. (Pre-fix, it became ?receive_timeout=..., silently
    # ignored by CouchDB, and the request still timed out at Finch's
    # default 15s.)
    test "Changes.reduce_while doesn't put receive_timeout in the URL" do
      test = self()

      plug = fn conn ->
        send(test, %{qs: conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "")
      end

      assert {:ok, 0} =
               client_with(plug)
               |> Akaw.Changes.reduce_while(
                 "db",
                 0,
                 fn _, a -> {:cont, a + 1} end,
                 since: "now",
                 heartbeat: 30_000,
                 receive_timeout: 45_000
               )

      assert_receive %{qs: qs}
      refute qs =~ "receive_timeout"
      assert qs =~ "heartbeat=30000"
      assert qs =~ "since=now"
    end

    test "View.reduce_while doesn't put receive_timeout in the URL" do
      test = self()

      plug = fn conn ->
        send(test, %{qs: conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, pretty_rows([]))
      end

      assert {:ok, 0} =
               client_with(plug)
               |> Akaw.View.reduce_while(
                 "db",
                 "d",
                 "v",
                 0,
                 fn _, a -> {:cont, a + 1} end,
                 limit: 5,
                 receive_timeout: 5_000
               )

      assert_receive %{qs: qs}
      refute qs =~ "receive_timeout"
      assert qs =~ "limit=5"
    end
  end

  describe "error body buffering" do
    test "returns Akaw.Error with empty body map for an empty 5xx body" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 500, "") end

      assert {:error, %Akaw.Error{status: 500, body: %{}, error: nil, reason: nil}} =
               client_with(plug)
               |> Akaw.View.reduce_while("db", "d", "v", 0, fn _, a -> {:cont, a + 1} end)
    end

    test "keeps raw bytes in :body when the error body isn't JSON" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(502, "<html>bad gateway</html>")
      end

      assert {:error, %Akaw.Error{status: 502, body: %{raw: "<html>bad gateway</html>"}}} =
               client_with(plug)
               |> Akaw.View.reduce_while("db", "d", "v", 0, fn _, a -> {:cont, a + 1} end)
    end

    test "caps the buffered error body at 64 KiB (truncates oversized responses)" do
      # Body is 96 KiB; we should only keep the first 64 KiB. The
      # leftover should not grow our heap or appear in the Error.
      oversized = String.duplicate("x", 96 * 1024)

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(500, oversized)
      end

      assert {:error, %Akaw.Error{status: 500, body: %{raw: raw}}} =
               client_with(plug)
               |> Akaw.View.reduce_while("db", "d", "v", 0, fn _, a -> {:cont, a + 1} end)

      assert byte_size(raw) == 64 * 1024
      assert raw == String.duplicate("x", 64 * 1024)
    end
  end

  describe ":feed rejection" do
    # Continuous-feed wrappers force feed=continuous internally. If the
    # user passes :feed themselves they almost certainly meant a different
    # endpoint — silent override would mask the mistake.
    test "Changes.reduce_while/5 raises on user-supplied :feed" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "") end

      assert_raise ArgumentError, ~r/feed="continuous"/, fn ->
        client_with(plug)
        |> Akaw.Changes.reduce_while(
          "db",
          0,
          fn _, a -> {:cont, a + 1} end,
          feed: "longpoll"
        )
      end
    end

    test "Changes.reduce_while_post/6 raises on user-supplied :feed" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "") end

      assert_raise ArgumentError, ~r/feed="continuous"/, fn ->
        client_with(plug)
        |> Akaw.Changes.reduce_while_post(
          "db",
          %{doc_ids: ["a"]},
          0,
          fn _, a -> {:cont, a + 1} end,
          feed: "longpoll"
        )
      end
    end

    test "Server.reduce_while_db_updates/4 raises on user-supplied :feed" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "") end

      assert_raise ArgumentError, ~r/feed="continuous"/, fn ->
        client_with(plug)
        |> Akaw.Server.reduce_while_db_updates(
          0,
          fn _, a -> {:cont, a + 1} end,
          feed: "longpoll"
        )
      end
    end
  end

  describe "mailbox isolation" do
    # The headline reason for this API: unlike `stream/N` which uses
    # `into: :self` and drains the calling process's mailbox via
    # `receive`, `reduce_while` runs the collector synchronously through
    # Req's `into: fun`. Unrelated messages should stay put.
    test "reduce_while doesn't drain unrelated messages from caller's mailbox" do
      client =
        pretty_plug([%{"id" => "a"}, %{"id" => "b"}])
        |> client_with()

      send(self(), :alpha)
      send(self(), {:beta, 42})
      send(self(), :gamma)

      assert {:ok, 2} =
               Akaw.View.reduce_while(client, "db", "d", "v", 0, fn _, n -> {:cont, n + 1} end)

      assert_received :alpha
      assert_received {:beta, 42}
      assert_received :gamma
    end
  end
end
