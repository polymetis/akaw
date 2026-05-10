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

  alias Akaw.{Client, Error, LineStream, Request}

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
    Request.request(client, :get, "/#{encode(db)}/_changes", params: opts)
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
    Request.request(client, :post, "/#{encode(db)}/_changes",
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
    raw_chunks(client, :get, "/#{encode(db)}/_changes", params: continuous_params(opts))
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
    raw_chunks(client, :post, "/#{encode(db)}/_changes",
      params: continuous_params(opts),
      json: body
    )
    |> LineStream.lines()
    |> Stream.map(&JSON.decode!/1)
  end

  defp continuous_params(opts), do: Keyword.put(opts, :feed, "continuous")

  # Returns a Stream of raw binary chunks from the response body.
  # The HTTP request is opened lazily when the stream is enumerated; errors
  # raise from inside the resource start function.
  defp raw_chunks(client, method, path, opts) do
    Stream.resource(
      fn -> open(client, method, path, opts) end,
      &next_chunk/1,
      &close/1
    )
  end

  defp open(client, method, path, opts) do
    opts = Keyword.put(opts, :into, :self)

    case Request.request_raw(client, method, path, opts) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        %{response: resp, finished: false}

      {:ok, %Req.Response{status: status} = resp} ->
        raise build_open_error(resp, status)

      {:error, exception} ->
        raise exception
    end
  end

  defp next_chunk(%{finished: true} = state), do: {:halt, state}

  defp next_chunk(state) do
    receive do
      message ->
        case Req.parse_message(state.response, message) do
          {:ok, parts} ->
            {chunks, finished?} = collect_chunks(parts)
            {chunks, %{state | finished: finished?}}

          {:error, reason} ->
            raise "Akaw.Changes stream error: #{inspect(reason)}"

          :unknown ->
            next_chunk(state)
        end
    end
  end

  defp collect_chunks(parts) do
    Enum.reduce(parts, {[], false}, fn
      {:data, chunk}, {acc, fin} -> {acc ++ [chunk], fin}
      :done, {acc, _} -> {acc, true}
      _, acc -> acc
    end)
  end

  defp close(%{response: response}) do
    _ = Req.cancel_async_response(response)
    :ok
  end

  defp build_open_error(%Req.Response{body: body} = resp, status) do
    decoded = drain_async_body(resp, body)

    %Error{
      status: status,
      error: get_in(decoded, ["error"]),
      reason: get_in(decoded, ["reason"]),
      body: decoded
    }
  end

  defp drain_async_body(resp, %Req.Response.Async{} = _async) do
    chunks = drain(resp, [])
    _ = Req.cancel_async_response(resp)

    case IO.iodata_to_binary(chunks) do
      "" -> %{}
      bin -> safe_decode(bin)
    end
  end

  defp drain_async_body(_resp, body) when is_map(body), do: body
  defp drain_async_body(_resp, body) when is_binary(body), do: safe_decode(body)
  defp drain_async_body(_resp, _body), do: %{}

  defp drain(resp, acc) do
    receive do
      msg ->
        case Req.parse_message(resp, msg) do
          {:ok, parts} ->
            {chunks, done?} = collect_chunks(parts)
            new_acc = acc ++ chunks
            if done?, do: new_acc, else: drain(resp, new_acc)

          {:error, _} ->
            acc

          :unknown ->
            drain(resp, acc)
        end
    after
      5_000 -> acc
    end
  end

  defp safe_decode(bin) do
    JSON.decode!(bin)
  rescue
    _ -> %{raw: bin}
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
