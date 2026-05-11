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
  """
  @spec get(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(%Client{} = client, db, opts \\ []) when is_binary(db) do
    Request.request(client, :get, "/#{Path.encode(db)}/_changes", params: opts)
  end

  @doc """
  `POST /{db}/_changes` — fetch changes with a request body.

  Use this when the filter requires data in the body — typically
  `filter: "_doc_ids"` with a long `doc_ids` list, or `filter: "_selector"`
  with a Mango selector. Other options forward as query parameters.

      Akaw.Changes.post(client, "users", %{doc_ids: ids},
        filter: "_doc_ids", since: "now")
  """
  @spec post(Client.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def post(%Client{} = client, db, body, opts \\ [])
      when is_binary(db) and is_map(body) do
    Request.request(client, :post, "/#{Path.encode(db)}/_changes",
      json: body,
      params: opts
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

  Errors raise during enumeration:

    * `Akaw.Error` for HTTP non-2xx responses (e.g. 404 missing db)
    * Mint/Finch transport exceptions on network failure

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
    Streaming.chunks(client, :get, "/#{Path.encode(db)}/_changes",
      params: continuous_params(opts)
    )
    |> LineStream.lines()
    |> Stream.map(&JSON.decode!/1)
  end

  @doc """
  Like `stream/3`, but POSTs a body — for `filter: "_doc_ids"` with long
  doc-id lists or `filter: "_selector"` with a Mango selector.
  """
  @spec stream_post(Client.t(), String.t(), map(), keyword()) :: Enumerable.t(map())
  def stream_post(%Client{} = client, db, body, opts \\ [])
      when is_binary(db) and is_map(body) do
    Streaming.chunks(client, :post, "/#{Path.encode(db)}/_changes",
      params: continuous_params(opts),
      json: body
    )
    |> LineStream.lines()
    |> Stream.map(&JSON.decode!/1)
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
  and they'll be routed to Req instead of becoming query params.

  Continuous feeds can sit silent for long stretches. If you pass an
  integer `:heartbeat`, `:receive_timeout` defaults to `heartbeat * 2`
  automatically — no spurious 15s timeouts from Finch's default. An
  explicit `:receive_timeout` always wins.

      # heartbeat 30s → receive_timeout auto-set to 60s
      Akaw.Changes.reduce_while(client, "users", 0,
        fn _, n -> {:cont, n + 1} end,
        since: "now", heartbeat: 30_000)
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
    {req_opts, params_opts} = build_continuous_opts(opts)

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
    {req_opts, params_opts} = build_continuous_opts(opts)

    Streaming.reduce_lines_while(
      client,
      :post,
      "/#{Path.encode(db)}/_changes",
      [params: params_opts, json: body] ++ req_opts,
      acc,
      decode_then(reducer)
    )
  end

  defp build_continuous_opts(opts) do
    reject_feed_override!(opts)
    {req_opts, couchdb_opts} = Streaming.split_req_opts(opts)
    params_opts = continuous_params(couchdb_opts)
    req_opts = Streaming.default_receive_timeout(req_opts, couchdb_opts)
    {req_opts, params_opts}
  end

  defp continuous_params(opts), do: Keyword.put(opts, :feed, "continuous")

  defp reject_feed_override!(opts) do
    if Keyword.has_key?(opts, :feed) do
      raise ArgumentError,
            "Akaw.Changes.reduce_while/N implies feed=\"continuous\"; " <>
              "remove :feed from opts. For non-streaming feeds use " <>
              "Akaw.Changes.get/3 or Akaw.Changes.post/4."
    end
  end

  defp decode_then(reducer) do
    fn line, acc -> reducer.(JSON.decode!(line), acc) end
  end
end
