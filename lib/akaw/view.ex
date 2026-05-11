defmodule Akaw.View do
  @moduledoc """
  View-query endpoints (`/{db}/_design/{ddoc}/_view/{view}`).

  Views are precomputed indexes defined inside a design document. This
  module exposes three flavors:

    * `get/5` — `GET /…/_view/{view}` with options forwarded as query
      params (the common case).
    * `post_keys/6` — `POST /…/_view/{view}` with a body of `keys` to
      filter on (use this when you have a long keys list — `?keys=…` would
      blow URL limits).
    * `queries/5` — `POST /…/_view/{view}/queries` to bundle several
      queries into one round-trip.

  As with `Akaw.Documents.all_docs/3`, JSON-typed query params (`startkey`,
  `endkey`, `key`) are auto-encoded. For large views, two streaming
  flavors: `stream/5` (lazy `Enumerable.t()`; consumes the caller's
  mailbox) and `reduce_while/7` (synchronous callback; real TCP
  backpressure and safe from a GenServer or LiveView).

  See <https://docs.couchdb.org/en/latest/api/ddoc/views.html>.
  """

  alias Akaw.{Client, JsonItemStream, Params, Request, Streaming, Path}

  @doc """
  `GET /{db}/_design/{ddoc}/_view/{view}` — query a view.

  ## Common options

    * `:include_docs`, `:limit`, `:skip`, `:descending`, `:inclusive_end`
    * `:startkey`, `:endkey`, `:key` — auto-encoded as JSON
    * `:startkey_docid`, `:endkey_docid`
    * `:reduce`, `:group`, `:group_level`
    * `:stale`, `:stable`, `:update`, `:update_seq`
    * `:conflicts`, `:attachments`, `:att_encoding_info`
  """
  @spec get(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get(%Client{} = client, db, ddoc, view, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(view) do
    Request.request(client, :get, view_path(db, ddoc, view),
      params: Params.encode_json_keys(opts)
    )
  end

  @doc """
  `POST /{db}/_design/{ddoc}/_view/{view}` — query a view filtered to a
  specific list of keys (sent in the body, not the URL).
  """
  @spec post_keys(Client.t(), String.t(), String.t(), String.t(), [term()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def post_keys(%Client{} = client, db, ddoc, view, keys, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(view) and is_list(keys) do
    Request.request(client, :post, view_path(db, ddoc, view),
      json: %{keys: keys},
      params: Params.encode_json_keys(opts)
    )
  end

  @doc """
  `POST /{db}/_design/{ddoc}/_view/{view}/queries` — run multiple view
  queries in one request.

  `queries` is a list of maps mirroring the `get/5` option set:

      Akaw.View.queries(client, "events", "by_user", "recent", [
        %{startkey: "u1", endkey: "u1\\ufff0", limit: 50},
        %{key: "u2", limit: 50}
      ])
  """
  @spec queries(Client.t(), String.t(), String.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  def queries(%Client{} = client, db, ddoc, view, queries)
      when is_binary(db) and is_binary(ddoc) and is_binary(view) and is_list(queries) do
    Request.request(client, :post, view_path(db, ddoc, view) <> "/queries",
      json: %{queries: queries}
    )
  end

  @doc """
  Streaming counterpart to `get/5` — emits one decoded row map per element.

  Each element looks like:

      %{"id" => "...", "key" => ..., "value" => ...,
        "doc" => %{...}}    # if include_docs: true

  Memory-bounded: parses one row at a time, safe for arbitrarily large views.
  """
  @spec stream(Client.t(), String.t(), String.t(), String.t(), keyword()) :: Enumerable.t(map())
  def stream(%Client{} = client, db, ddoc, view, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(view) do
    Streaming.chunks(client, :get, view_path(db, ddoc, view),
      params: Params.encode_json_keys(opts)
    )
    |> JsonItemStream.items()
  end

  @doc """
  Streaming counterpart to `post_keys/6` — POSTs the keys list and emits
  decoded row maps.
  """
  @spec stream_post_keys(Client.t(), String.t(), String.t(), String.t(), [term()], keyword()) ::
          Enumerable.t(map())
  def stream_post_keys(%Client{} = client, db, ddoc, view, keys, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(view) and is_list(keys) do
    Streaming.chunks(client, :post, view_path(db, ddoc, view),
      json: %{keys: keys},
      params: Params.encode_json_keys(opts)
    )
    |> JsonItemStream.items()
  end

  @doc """
  Callback variant of `stream/5` — runs the reducer synchronously inside
  the HTTP read loop, so blocking in `reducer` applies real TCP
  backpressure (CouchDB stalls on send while you're processing). Safe
  to call from a GenServer / LiveView since it doesn't use the calling
  process's mailbox.

  The reducer returns `{:cont, acc}` to continue or `{:halt, acc}` to
  stop early (the connection is closed). Returns `{:ok, final_acc}` on
  success, `{:error, %Akaw.Error{}}` on HTTP or transport failure.

  ## Example

      Akaw.View.reduce_while(client, "events", "by_user", "recent", 0,
        fn row, count ->
          :ok = process(row)
          {:cont, count + 1}
        end)
  """
  @spec reduce_while(
          Client.t(),
          String.t(),
          String.t(),
          String.t(),
          acc,
          (map(), acc -> {:cont, acc} | {:halt, acc}),
          keyword()
        ) :: {:ok, acc} | {:error, Akaw.Error.t()}
        when acc: term()
  def reduce_while(%Client{} = client, db, ddoc, view, acc, reducer, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(view) and is_function(reducer, 2) do
    {req_opts, params_opts} = Streaming.split_req_opts(opts)

    Streaming.reduce_items_while(
      client,
      :get,
      view_path(db, ddoc, view),
      [params: Params.encode_json_keys(params_opts)] ++ req_opts,
      acc,
      reducer
    )
  end

  @doc """
  Callback variant of `stream_post_keys/6`. See `reduce_while/7` for the
  contract.
  """
  @spec reduce_while_post_keys(
          Client.t(),
          String.t(),
          String.t(),
          String.t(),
          [term()],
          acc,
          (map(), acc -> {:cont, acc} | {:halt, acc}),
          keyword()
        ) :: {:ok, acc} | {:error, Akaw.Error.t()}
        when acc: term()
  def reduce_while_post_keys(%Client{} = client, db, ddoc, view, keys, acc, reducer, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(view) and is_list(keys) and
             is_function(reducer, 2) do
    {req_opts, params_opts} = Streaming.split_req_opts(opts)

    Streaming.reduce_items_while(
      client,
      :post,
      view_path(db, ddoc, view),
      [json: %{keys: keys}, params: Params.encode_json_keys(params_opts)] ++ req_opts,
      acc,
      reducer
    )
  end

  defp view_path(db, ddoc, view) do
    "/#{Path.encode(db)}/_design/#{Path.encode(ddoc)}/_view/#{Path.encode(view)}"
  end
end
