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

  > #### Backpressure {: .warning}
  >
  > CouchDB pushes chunks at us as fast as it can — slow consumers will
  > accumulate messages in the calling process's mailbox. Either consume
  > promptly or arrange your own queue.
  """
  @spec stream(Client.t(), String.t(), keyword()) :: Enumerable.t()
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
  @spec stream_post(Client.t(), String.t(), map(), keyword()) :: Enumerable.t()
  def stream_post(%Client{} = client, db, body, opts \\ [])
      when is_binary(db) and is_map(body) do
    Streaming.chunks(client, :post, "/#{Path.encode(db)}/_changes",
      params: continuous_params(opts),
      json: body
    )
    |> LineStream.lines()
    |> Stream.map(&JSON.decode!/1)
  end

  defp continuous_params(opts), do: Keyword.put(opts, :feed, "continuous")
end
