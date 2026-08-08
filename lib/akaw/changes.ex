defmodule Akaw.Changes do
  @moduledoc """
  `_changes` feed endpoints (`/{db}/_changes`).

  CouchDB exposes a single endpoint with several feed modes controlled by
  the `:feed` option:

    * `"normal"` (default) — single response with `{"results": [...],
      "last_seq": ...}`. Use `get/3` or `post/4`.
    * `"longpoll"` — same shape as normal, but the server holds the
      connection until at least one change occurs (or `:timeout`). Use
      `get/3` or `post/4` with `feed: "longpoll"`.
    * `"continuous"` — a long-lived connection that emits one JSON object
      per change, separated by newlines. Use `stream/3` or `stream_post/4`
      to consume as a lazy `Stream`.
    * `"eventsource"` — Server-Sent Events. Not currently exposed as a
      stream; use `get/3` with `feed: "eventsource"` if you want the raw
      bytes.

  ## Filtering

    * `filter: "_doc_ids"` + `:doc_ids` — pass `doc_ids` via query string
      (small lists), or via the request body using `post/4` /
      `stream_post/4` (longer lists).
    * `filter: "_design"` — only design documents.
    * `filter: "_view"` + `:view: "{ddoc}/{view}"` — emit a change for any
      doc the view would emit.
    * `filter: "{ddoc}/{filter}"` — custom filter function defined in a
      design doc.
    * `filter: "_selector"` + `:selector` — Mango-style selector (POST body).

  See <https://docs.couchdb.org/en/latest/api/database/changes.html>.
  """

  alias Akaw.{Client, LineStream, Request, Streaming, Path}

  @doc """
  `GET /{db}/_changes` — fetch changes.

  Use this for the `"normal"` and `"longpoll"` feeds. For continuous
  streaming use `stream/3`; for filtering by a long doc-id list or by a
  Mango selector use `post/4`.

  ## Common options (all forward as query parameters)

    * `:since`, `:limit`, `:descending`
    * `:feed` — `"normal"` (default) or `"longpoll"`
    * `:timeout`, `:heartbeat`
    * `:include_docs`, `:attachments`, `:att_encoding_info`, `:conflicts`
    * `:filter`, `:doc_ids` (short lists), `:view`
    * `:style` — `"main_only"` (default) or `"all_docs"`
    * `:seq_interval`

  ## Longpoll and the receive timeout

  With `feed: "longpoll"` CouchDB holds the response until a change
  arrives or `:timeout` (milliseconds, server default 60s) elapses —
  longer than the transport's default 15s receive timeout, which would
  kill every quiet longpoll client-side before the server could answer.
  For any held-open feed, `get/3` defaults the transport's
  `:receive_timeout` to cover the server's window: `heartbeat * 2` for
  an integer `:heartbeat`, otherwise `:timeout` plus slack.

  `:receive_timeout` / `:pool_timeout` / `:connect_options` in `opts`
  route to the transport rather than the query string; an explicit
  `:receive_timeout` always wins.
  """
  @spec get(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(%Client{} = client, db, opts \\ []) when is_binary(db) do
    {req_opts, params} = split_feed_opts(client, opts)
    Request.request(client, :get, "/#{Path.encode(db)}/_changes", [params: params] ++ req_opts)
  end

  @doc """
  `POST /{db}/_changes` — fetch changes with a request body.

  Use this when the filter requires data in the body — typically
  `filter: "_doc_ids"` with a long `doc_ids` list, or `filter: "_selector"`
  with a Mango selector. Other options forward as query parameters.

      Akaw.Changes.post(client, "users", %{doc_ids: ids},
        filter: "_doc_ids", since: "now")

  Held-open feeds get the same `:receive_timeout` defaulting as `get/3`
  (see "Longpoll and the receive timeout" there).
  """
  @spec post(Client.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def post(%Client{} = client, db, body, opts \\ [])
      when is_binary(db) and is_map(body) do
    {req_opts, params} = split_feed_opts(client, opts)

    Request.request(
      client,
      :post,
      "/#{Path.encode(db)}/_changes",
      [json: body, params: params] ++ req_opts
    )
  end

  @doc """
  Stream the continuous changes feed as a lazy `Stream`.

  Each element is a decoded change object:

      %{"seq" => "...", "id" => "doc_42",
        "changes" => [%{"rev" => "1-..."}],
        "deleted" => true,                 # optional
        "doc" => %{...}}                   # if include_docs: true

  Heartbeat lines are filtered out. The stream blocks waiting for the next
  change; bound it with `Stream.take/2`, `Stream.take_while/2`, or by
  killing the consuming process.

  ## Options

  All `get/3` options are accepted. `:feed` is forced to `"continuous"`.
  Recommended starting points:

    * `since: "now"` — start at the present (otherwise replays history)
    * `heartbeat: 30_000` — tells CouchDB to send an empty line every 30s
      so dropped TCP connections fail faster
    * `include_docs: true` — include the doc body in each change

  ## Errors

  Errors raise during enumeration, always as `Akaw.Error`:

    * HTTP non-2xx (e.g. 404 missing db) — CouchDB's status and error body
    * transport failures — `error: "stream_transport_error"`, with the
      underlying Mint/Finch exception in `body.exception`
    * a corrupt feed line — `error: "stream_decode_error"` with the
      offending line excerpted in `:reason`

  > #### Backpressure & mailbox ownership {: .warning}
  >
  > `stream/3` uses Req's `into: :self` mode under the hood, which means
  > chunks arrive in the calling process's mailbox and a `receive` loop
  > drains them. Two consequences:
  >
  >   * **Slow consumers buffer.** CouchDB pushes as fast as it can; if
  >     you can't keep up, messages pile up in your mailbox.
  >   * **Not safe from a GenServer / LiveView.** The `receive` swallows
  >     *any* message, not just Finch ones. Run it from a `Task` or use
  >     `reduce_while/5` — the synchronous callback variant — which
  >     runs the reducer inline (real TCP backpressure, no mailbox
  >     involvement).
  """
  @spec stream(Client.t(), String.t(), keyword()) :: Enumerable.t(map())
  def stream(%Client{} = client, db, opts \\ []) when is_binary(db) do
    {req_opts, params} = continuous_stream_opts(client, opts)

    Streaming.chunks(client, :get, "/#{Path.encode(db)}/_changes", [params: params] ++ req_opts)
    |> LineStream.lines()
    |> Stream.map(&Streaming.decode_feed_line!/1)
  end

  @doc """
  Like `stream/3`, but POSTs a body — for `filter: "_doc_ids"` with long
  doc-id lists or `filter: "_selector"` with a Mango selector.
  """
  @spec stream_post(Client.t(), String.t(), map(), keyword()) :: Enumerable.t(map())
  def stream_post(%Client{} = client, db, body, opts \\ [])
      when is_binary(db) and is_map(body) do
    {req_opts, params} = continuous_stream_opts(client, opts)

    Streaming.chunks(
      client,
      :post,
      "/#{Path.encode(db)}/_changes",
      [params: params, json: body] ++ req_opts
    )
    |> LineStream.lines()
    |> Stream.map(&Streaming.decode_feed_line!/1)
  end

  @doc """
  Callback variant of `stream/3` — runs the reducer synchronously inside
  the HTTP read loop. Unlike the lazy `stream/3`, this is safe to call
  from a GenServer or LiveView: chunks are consumed inline rather than
  delivered to the calling process's mailbox, so no unrelated messages
  get drained.

  `reducer` is called with each decoded change object. Return
  `{:cont, acc}` to keep reading or `{:halt, acc}` to close the
  connection. Returns `{:ok, final_acc}` or `{:error, %Akaw.Error{}}`.

  ## Idle timeout

  `opts` is a flat keyword of CouchDB query params; you can also drop
  `:receive_timeout` / `:pool_timeout` / `:connect_options` in there
  and they'll be routed to the transport (Finch/Mint, via Req) instead
  of becoming query params.

  Continuous feeds can sit silent for long stretches. `:receive_timeout`
  defaults to cover CouchDB's legitimate quiet window — `heartbeat * 2`
  if you pass an integer `:heartbeat`, otherwise the feed's `:timeout`
  (milliseconds, server default 60s) plus slack — so Finch's 15s default
  can't kill a healthy quiet feed. An explicit `:receive_timeout`
  always wins.

      # heartbeat 30s → receive_timeout auto-set to 60s
      Akaw.Changes.reduce_while(client, "users", 0,
        fn _, n -> {:cont, n + 1} end,
        since: "now", heartbeat: 30_000)

  ## Retry

  Req's automatic retry is disabled on streaming paths: a mid-feed
  transport failure surfaces as `{:error, %Akaw.Error{}}` rather than
  transparently re-running the request — which would reset the
  accumulator and feed every change to the reducer again. If your
  reducer is idempotent and you'd rather have the restart, opt back in
  per call (`retry: :safe_transient` in `opts`, routed to the transport
  like `:receive_timeout`) or per client
  (`Akaw.new(req_options: [retry: :safe_transient])`).
  """
  @spec reduce_while(
          Client.t(),
          String.t(),
          acc,
          (map(), acc -> {:cont, acc} | {:halt, acc}),
          keyword()
        ) :: {:ok, acc} | {:error, Akaw.Error.t()}
        when acc: term()
  def reduce_while(%Client{} = client, db, acc, reducer, opts \\ [])
      when is_binary(db) and is_function(reducer, 2) do
    {req_opts, params_opts} = build_continuous_opts(client, opts)

    Streaming.reduce_lines_while(
      client,
      :get,
      "/#{Path.encode(db)}/_changes",
      [params: params_opts] ++ req_opts,
      acc,
      decode_then(reducer)
    )
  end

  @doc """
  Like `reduce_while/5`, but POSTs a body. See `stream_post/4` for the
  filter-list / selector use cases.
  """
  @spec reduce_while_post(
          Client.t(),
          String.t(),
          map(),
          acc,
          (map(), acc -> {:cont, acc} | {:halt, acc}),
          keyword()
        ) :: {:ok, acc} | {:error, Akaw.Error.t()}
        when acc: term()
  def reduce_while_post(%Client{} = client, db, body, acc, reducer, opts \\ [])
      when is_binary(db) and is_map(body) and is_function(reducer, 2) do
    {req_opts, params_opts} = build_continuous_opts(client, opts)

    Streaming.reduce_lines_while(
      client,
      :post,
      "/#{Path.encode(db)}/_changes",
      [params: params_opts, json: body] ++ req_opts,
      acc,
      decode_then(reducer)
    )
  end

  defp build_continuous_opts(client, opts) do
    reject_feed_override!(opts)
    {req_opts, couchdb_opts} = Streaming.split_req_opts(opts)
    params_opts = continuous_params(couchdb_opts)
    req_opts = Streaming.default_receive_timeout(client, req_opts, couchdb_opts)
    {req_opts, params_opts}
  end

  defp continuous_params(opts), do: Keyword.put(opts, :feed, "continuous")

  # The lazy streams force feed=continuous, so they always get the
  # held-open receive-timeout defaulting — the mailbox idle_timeout in
  # Streaming.chunks/4 is a separate, later line of defense.
  defp continuous_stream_opts(client, opts) do
    {req_opts, couchdb_opts} = Streaming.split_req_opts(opts)
    params = continuous_params(couchdb_opts)
    {Streaming.default_receive_timeout(client, req_opts, params), params}
  end

  defp split_feed_opts(client, opts), do: Streaming.held_open_feed_opts(client, opts)

  defp reject_feed_override!(opts) do
    if Keyword.has_key?(opts, :feed) do
      raise ArgumentError,
            "Akaw.Changes.reduce_while/N implies feed=\"continuous\"; " <>
              "remove :feed from opts. For non-streaming feeds use " <>
              "Akaw.Changes.get/3 or Akaw.Changes.post/4."
    end
  end

  defp decode_then(reducer) do
    fn line, acc -> reducer.(Streaming.decode_feed_line!(line), acc) end
  end
end
