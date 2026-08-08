defmodule Akaw.ChangesTest do
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

      Loopback.json(conn, %{"results" => [], "last_seq" => "0"})
    end

    {:ok, client: Loopback.client(plug)}
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

    test "JSON-encodes doc_ids for the query string", %{client: client} do
      # ?doc_ids=["a","c"] (a JSON array) is what filter=_doc_ids
      # requires; the raw list previously reached Req's query encoder
      # unserialized.
      assert {:ok, _} =
               Akaw.Changes.get(client, "mydb", filter: "_doc_ids", doc_ids: ["a", "c"])

      assert_receive %{path: "/mydb/_changes", query_string: qs}
      decoded = URI.decode_query(qs)
      assert decoded["doc_ids"] == ~s|["a","c"]|
      assert decoded["filter"] == "_doc_ids"
    end

    test "held-open feeds never retry — even with a client-level opt-in" do
      # The chaos run reproduced the CHANGELOG's ~67s anti-pattern in
      # miniature: an explicit 2s receive_timeout on a quiet longpoll
      # took 14.7s because Req retried a request that is guaranteed to
      # time out again, abandoning four server-side connections. Feed
      # requests pin retry off unconditionally.
      calls = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(calls, 1, 1)
        Plug.Conn.send_resp(conn, 503, "unavailable")
      end

      client =
        Loopback.client(plug,
          req_options: [retry: :safe_transient, retry_delay: fn _ -> 0 end]
        )

      assert {:error, %Akaw.Error{status: 503}} =
               Akaw.Changes.get(client, "mydb", feed: "longpoll")

      assert :counters.get(calls, 1) == 1
    end

    test "a per-call retry: on a feed request raises — every feed mode", %{client: client} do
      assert_raise ArgumentError, ~r/no per-call :retry/, fn ->
        Akaw.Changes.get(client, "mydb", feed: "longpoll", retry: false)
      end

      # The default "normal" feed raises too: the feed endpoints take no
      # per-call retry policy at all (client-level only for plain
      # requests), and the message says so rather than misdescribing a
      # plain request as a streaming walk.
      error =
        assert_raise ArgumentError, fn ->
          Akaw.Changes.get(client, "mydb", retry: false)
        end

      assert error.message =~ "client level"
    end

    test "routes transport opts to the transport, not the query string", %{client: client} do
      assert {:ok, _} =
               Akaw.Changes.get(client, "mydb",
                 feed: "longpoll",
                 receive_timeout: 90_000,
                 pool_timeout: 500
               )

      assert_receive %{path: "/mydb/_changes", query_string: qs}
      assert qs == "feed=longpoll"
    end
  end

  describe "feed line decoding" do
    defp corrupt_line_plug do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s|{"seq":"1-a","id":"ok"}\n{"seq": CORRUPT\n|)
      end
    end

    test "stream/3 raises stream_decode_error on a corrupt line, not a bare JSON error" do
      client = Loopback.client(corrupt_line_plug())

      error =
        assert_raise Akaw.Error, ~r/stream_decode_error|failed to decode/, fn ->
          client |> Akaw.Changes.stream("db") |> Enum.to_list()
        end

      assert error.error == "stream_decode_error"
    end

    test "reduce_while/5 raises the same legible error for a corrupt line" do
      client = Loopback.client(corrupt_line_plug())

      error =
        assert_raise Akaw.Error, fn ->
          Akaw.Changes.reduce_while(client, "db", [], fn change, acc ->
            {:cont, [change | acc]}
          end)
        end

      assert error.error == "stream_decode_error"
    end
  end

  describe "stream/3 transport opts" do
    test "JSON-encodes doc_ids on the continuous paths too" do
      # The encoding is wired at two independent seams — split_feed_opts
      # for get/post and continuous_params for the stream/reduce paths.
      # This pins the second so a refactor can't drop it undetected.
      seen = :ets.new(:akaw_continuous_docids_qs, [:public])

      plug = fn conn ->
        :ets.insert(seen, {:qs, conn.query_string})
        Loopback.json(conn, %{})
      end

      client = Loopback.client(plug)

      client
      |> Akaw.Changes.stream("mydb", filter: "_doc_ids", doc_ids: ["a", "c"])
      |> Enum.take(1)

      assert [{:qs, qs}] = :ets.lookup(seen, :qs)
      decoded = URI.decode_query(qs)
      assert decoded["feed"] == "continuous"
      assert decoded["doc_ids"] == ~s|["a","c"]|
    end

    test "routes transport opts out of the query string" do
      # The lazy continuous stream gets the same held-open
      # receive-timeout defaulting as the reduce paths; a caller's
      # :receive_timeout must reach the transport, not CouchDB.
      #
      # ETS, not send: the lazy stream's unselective receive drains the
      # test process's own mailbox during consumption — a message-based
      # probe gets eaten by the very footgun the reduce_while docs warn
      # about.
      seen = :ets.new(:akaw_stream_opts_qs, [:public])

      plug = fn conn ->
        :ets.insert(seen, {:qs, conn.query_string})
        Loopback.json(conn, %{})
      end

      client = Loopback.client(plug)

      client
      |> Akaw.Changes.stream("mydb", since: "now", receive_timeout: 90_000)
      |> Enum.take(1)

      assert [{:qs, qs}] = :ets.lookup(seen, :qs)
      assert qs =~ "since=now"
      assert qs =~ "feed=continuous"
      refute qs =~ "receive_timeout"
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

      assert JSON.decode!(body) == %{"doc_ids" => ["a", "b"]}
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
          JSON.encode!(%{"error" => "not_found", "reason" => "no_db_file"})
        )
      end

      client = Loopback.client(plug)

      assert_raise Akaw.Error, ~r/404/, fn ->
        client |> Akaw.Changes.stream("missing") |> Enum.take(1)
      end
    end
  end

  describe "stream_post/4" do
    test "POSTs body with filter and forces feed=continuous" do
      seen = :ets.new(:akaw_changes_post, [:public])

      plug = fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        :ets.insert(seen, {:method, conn.method})
        :ets.insert(seen, {:path, conn.request_path})
        :ets.insert(seen, {:qs, conn.query_string})
        :ets.insert(seen, {:body, body})
        Loopback.json(conn, %{})
      end

      client = Loopback.client(plug)

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

      assert [{:method, "POST"}] = :ets.lookup(seen, :method)
      assert [{:path, "/mydb/_changes"}] = :ets.lookup(seen, :path)

      assert [{:body, body}] = :ets.lookup(seen, :body)
      assert JSON.decode!(body) == %{"doc_ids" => ["a", "b"]}

      assert [{:qs, qs}] = :ets.lookup(seen, :qs)
      assert qs =~ "feed=continuous"
      assert qs =~ "filter=_doc_ids"
      assert qs =~ "since=now"
    end
  end

  describe "stream/3 — feed forcing" do
    # We capture the query string into an ETS table rather than sending it
    # as a message — `next_chunk`'s `receive` eagerly drains the mailbox
    # and would swallow a regular `send`. (The plug runs in a Bandit
    # acceptor process, so the process dictionary can't reach the test
    # either.)
    test "forces feed=continuous and forwards other opts" do
      seen = :ets.new(:akaw_changes_qs, [:public])

      plug = fn conn ->
        :ets.insert(seen, {:qs, conn.query_string})
        Loopback.json(conn, %{})
      end

      client = Loopback.client(plug)

      try do
        client
        |> Akaw.Changes.stream("mydb", since: "now", heartbeat: 30_000)
        |> Enum.take(1)
      rescue
        _ -> :ok
      end

      assert [{:qs, qs}] = :ets.lookup(seen, :qs)
      assert qs =~ "feed=continuous"
      assert qs =~ "since=now"
      assert qs =~ "heartbeat=30000"
    end
  end
end
