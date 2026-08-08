defmodule Akaw.Streaming do
  @moduledoc false

  # Shared HTTP-streaming primitives for endpoints that consume long-lived
  # responses (`_changes` continuous feed, line-delimited `_all_docs`,
  # views, `_find`). Two flavors:
  #
  #   * `chunks/4` — lazy `Stream` of raw binary chunks. Uses Req's
  #     `into: :self` mode plus `Req.parse_message/2`, then drives the
  #     producer/consumer through `Stream.resource/3`. Ergonomic but
  #     drains the calling process's mailbox; not safe to call from a
  #     GenServer / LiveView / anything with its own mail.
  #
  #   * `reduce_chunks_while/6`, `reduce_lines_while/6`,
  #     `reduce_items_while/6` — synchronous, backpressured callback API
  #     built on Req's `into: fun`. The user reducer runs inline inside
  #     `Finch.stream_while`, so (a) no mailbox messages reach the
  #     calling process and (b) blocking in the reducer stalls socket
  #     reads and applies real TCP backpressure to CouchDB.
  #
  # ## Retry: off by default, both flavors
  #
  # Req's default `retry: :safe_transient` re-runs the whole request after
  # a transient failure. For a complete-response request that's a
  # convenience; for a streaming request it's a correctness bug: with
  # `into:` collectors the body consumed before the failure has already
  # been fed to the caller (or their mailbox), and the retried attempt
  # builds a fresh `%Req.Response{}` — the private accumulator resets to
  # `init_acc` and every row is delivered again. `{:ok, final_acc}` must
  # mean "each item was delivered exactly once", so streaming requests
  # default `retry: false`. An explicit `:retry` (per call, or per client
  # via `req_options`) is respected — opting in means opting into
  # re-delivery.
  #
  # ## chunks/4 — idle timeout
  #
  # `next_chunk/1` does a `receive` with an `after` clause keyed on the
  # `:idle_timeout` opt (default 5 minutes). If no chunk arrives within
  # that window the stream raises `%Akaw.Error{}` — guards against silent
  # stalls where a load balancer or NAT has dropped a connection and TCP
  # hasn't noticed. For `_changes` feeds, set this to slightly more than
  # your `:heartbeat` so heartbeats always reset the clock.
  #
  # ## chunks/4 — mailbox ownership
  #
  # The `receive` consumes any message and routes it through
  # `Req.parse_message/2`; non-Finch messages return `:unknown` and we
  # recurse. This means consuming an Akaw stream from a process that also
  # receives other mail (a GenServer, LiveView, monitor) will drain those
  # unrelated messages and break the consumer's contract. Run streams from
  # a process you own — typically a `Task` or a spawned helper — or use
  # the `reduce_*_while` callback API instead.
  #
  # ## chunks/4 — open errors
  #
  # The `start_fun` raises `Akaw.Error` in both cases:
  #
  #   * HTTP non-2xx — the async body is drained once and decoded to
  #     extract CouchDB's `error` / `reason` into the struct.
  #   * Transport failure — `error: "stream_transport_error"` with the
  #     underlying exception in `body.exception`, the same shape as a
  #     mid-stream failure. One tag per API mode: every transport
  #     failure on a streaming call, whatever its phase, reads the same.
  #
  # ## reduce_*_while — idle timeout
  #
  # No mailbox `receive` here; the between-chunk timeout is Finch's
  # `:receive_timeout`. The continuous-feed wrappers default it via
  # `default_receive_timeout/2` to cover CouchDB's legitimate quiet
  # window; pass `receive_timeout:` in opts to override.
  #
  # ## reduce_*_while — error body
  #
  # When the response is non-2xx, the user reducer is *not* called.
  # Chunks accumulate in `resp.private[:akaw_error_body]` and after the
  # request finishes we decode them into the final `%Akaw.Error{}`.

  alias Akaw.{Client, Error, JsonItemStream, Request}

  @drain_timeout 5_000
  @default_idle_timeout to_timeout(minute: 5)

  @doc """
  Lazy stream of raw binary chunks from the HTTP response body.

  `opts` is forwarded to `Akaw.Request.request_raw/4`; `into: :self` is set
  for you. Per-call options like `:params`, `:json`, and `:headers` work
  the same way as in non-streaming requests.

  Additional streaming-only option:

    * `:idle_timeout` — milliseconds to wait between chunks before raising
      `%Akaw.Error{error: "stream_idle_timeout"}` (default 5 minutes).
  """
  @spec chunks(Client.t(), Request.method(), String.t(), keyword()) :: Enumerable.t(binary())
  def chunks(%Client{} = client, method, path, opts \\ []) do
    Stream.resource(
      fn -> open(client, method, path, opts) end,
      &next_chunk/1,
      &close/1
    )
  end

  defp open(client, method, path, opts) do
    {idle_timeout, opts} = Keyword.pop(opts, :idle_timeout, @default_idle_timeout)

    opts =
      opts
      |> Keyword.put(:into, :self)
      |> default_retry_off(client)

    case Request.request_raw(client, method, path, opts) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        %{response: resp, idle_timeout: idle_timeout, finished: false}

      {:ok, %Req.Response{status: status} = resp} ->
        raise build_open_error(resp, status)

      {:error, exception} ->
        raise stream_transport_error(exception)
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
            raise stream_transport_error(reason)

          :unknown ->
            next_chunk(state)
        end
    after
      state.idle_timeout ->
        raise %Error{
          status: nil,
          error: "stream_idle_timeout",
          reason: "no data received within #{state.idle_timeout}ms"
        }
    end
  end

  # `Req.parse_message/2` hands back the raw transport exception without
  # running Req's own error normalization, so the struct depends on the
  # Finch version — Finch 0.23 wraps Mint's error, turning
  # `%Mint.TransportError{reason: :closed}` into
  # `%Finch.TransportError{reason: :closed, source: %Mint.TransportError{...}}`.
  # `inspect/1`-ing that leaked the difference straight into the documented
  # `:reason` string. `Exception.message/1` is stable across both ("socket
  # closed"), and stashing the struct in `:body` matches what `Akaw.Error`'s
  # moduledoc already promises for transport failures — and what the
  # non-streaming path has always done.
  defp stream_transport_error(reason) do
    %Error{
      status: nil,
      error: "stream_transport_error",
      reason: if(is_exception(reason), do: Exception.message(reason), else: inspect(reason)),
      body: %{exception: reason}
    }
  end

  defp collect_chunks(parts) do
    # Build a reversed accumulator with O(1) prepends, then reverse once
    # at the end — `acc ++ [chunk]` is O(n) per element and runs in the
    # hot streaming path.
    {rev_chunks, finished?} =
      Enum.reduce(parts, {[], false}, fn
        {:data, chunk}, {acc, fin} -> {[chunk | acc], fin}
        :done, {acc, _} -> {acc, true}
        _, acc -> acc
      end)

    {Enum.reverse(rev_chunks), finished?}
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
      @drain_timeout -> acc
    end
  end

  defp safe_decode(bin) do
    JSON.decode!(bin)
  rescue
    _ -> %{raw: bin}
  end

  # ---------------------------------------------------------------------
  # Callback-style reducers (synchronous, backpressured)
  # ---------------------------------------------------------------------

  @type reducer_result(acc) :: {:cont, acc} | {:halt, acc}

  # Transport-level options that we accept as per-call escape hatches on
  # the `reduce_while/N` wrappers. Anything not in this list stays in
  # `opts` and is treated as a CouchDB query param. `:retry` is here so
  # the documented per-call retry opt-in actually routes to Req instead
  # of leaking into the query string and then being pinned off by
  # `default_retry_off/2` — the exact inversion of the caller's intent.
  @req_opt_keys [:receive_timeout, :pool_timeout, :connect_options, :retry]

  @doc """
  Split a `reduce_while` opts keyword into `{req_opts, couchdb_opts}`,
  pulling out the small set of transport-level options we let callers
  override per call (everything else is destined for query params).

  `:receive_timeout`, `:connect_options`, and `:retry` ride to Req
  through its option passthrough. `:pool_timeout` is folded into
  Req 0.7's `finch: [...]` keyword by `Akaw.Request`, which keeps the
  flat spelling here warning-free.
  """
  @spec split_req_opts(keyword()) :: {keyword(), keyword()}
  def split_req_opts(opts) when is_list(opts) do
    Keyword.split(opts, @req_opt_keys)
  end

  # If the user lets CouchDB pick the heartbeat (heartbeat: true /
  # "true"), the server's default is ~60s. Doubled-with-slack gives a
  # safe ceiling that won't fire mid-feed on a healthy connection.
  @server_picked_heartbeat_timeout 120_000

  # Without a heartbeat, CouchDB ends a quiet longpoll/continuous feed
  # after the `:timeout` param — milliseconds, server default 60s. The
  # slack covers delivering the final response over a slow link.
  @server_default_feed_timeout 60_000
  @feed_timeout_slack 5_000

  @doc """
  For held-open feeds (`_changes` longpoll/continuous, `_db_updates`):
  default `:receive_timeout` to cover the window CouchDB may
  legitimately stay silent, if the caller didn't set it explicitly.

  Finch's own default (15s) is *shorter* than CouchDB's default quiet
  window (60s), so without this a legitimately quiet feed was guaranteed
  to die client-side with a transport timeout.

    * Integer `heartbeat > 0` → `receive_timeout = heartbeat * 2`
      (absorbs one missed heartbeat without spurious timeouts).
    * `heartbeat: true` / `"true"` (server picks the interval, default
      ~60s) → `receive_timeout = #{@server_picked_heartbeat_timeout}`.
    * No usable heartbeat → the server answers by `:timeout`
      (milliseconds, its default #{@server_default_feed_timeout}), so
      `receive_timeout = timeout + #{@feed_timeout_slack}` slack.

  Explicit `:receive_timeout` always wins — per call *or* per client.
  The per-call opts merge after the client's `req_options` in
  `Akaw.Request.build/4`, so putting a derived value into per-call opts
  would silently override a client-level setting; hence the check on
  both layers, same as `default_retry_off/2`.
  """
  @spec default_receive_timeout(Client.t(), keyword(), keyword()) :: keyword()
  def default_receive_timeout(%Client{} = client, req_opts, couchdb_opts) do
    explicit? =
      Keyword.has_key?(req_opts, :receive_timeout) or
        Keyword.has_key?(client.req_options, :receive_timeout)

    if explicit? do
      req_opts
    else
      Keyword.put(req_opts, :receive_timeout, derive_receive_timeout(couchdb_opts))
    end
  end

  defp derive_receive_timeout(couchdb_opts) do
    case Keyword.get(couchdb_opts, :heartbeat) do
      hb when is_integer(hb) and hb > 0 ->
        hb * 2

      server_picked when server_picked in [true, "true"] ->
        @server_picked_heartbeat_timeout

      _ ->
        case Keyword.get(couchdb_opts, :timeout) do
          server_timeout when is_integer(server_timeout) and server_timeout >= 0 ->
            server_timeout + @feed_timeout_slack

          _ ->
            @server_default_feed_timeout + @feed_timeout_slack
        end
    end
  end

  # Feeds where CouchDB may legitimately hold the connection open past
  # the transport's default receive timeout. "normal" answers
  # immediately, so it keeps the transport default.
  @held_open_feeds ["longpoll", "continuous", "eventsource"]

  @doc """
  Split `opts` into `{req_opts, params}` and, when `params` names a
  held-open feed (longpoll/continuous/eventsource), default
  `:receive_timeout` via `default_receive_timeout/3`.

  Shared by every endpoint that accepts a `:feed` option
  (`Akaw.Changes.get/3`/`post/4`, `Akaw.Server.db_updates/2`), so a
  quiet held-open feed can't be killed by the transport's default
  before the server's own answer window elapses.
  """
  @spec held_open_feed_opts(Client.t(), keyword()) :: {keyword(), keyword()}
  def held_open_feed_opts(%Client{} = client, opts) do
    {req_opts, params} = split_req_opts(opts)

    if to_string(Keyword.get(params, :feed, "normal")) in @held_open_feeds do
      {default_receive_timeout(client, req_opts, params), params}
    else
      {req_opts, params}
    end
  end

  @doc """
  Reduce over raw binary chunks of the response body. Returns
  `{:ok, final_acc}` on completion (including early `:halt`), or
  `{:error, %Akaw.Error{}}` on HTTP or transport failure.

  See the module doc for the backpressure / mailbox guarantees.
  """
  @spec reduce_chunks_while(
          Client.t(),
          Request.method(),
          String.t(),
          keyword(),
          acc,
          (binary(), acc -> reducer_result(acc))
        ) :: {:ok, acc} | {:error, Error.t()}
        when acc: term()
  def reduce_chunks_while(%Client{} = client, method, path, opts, init_acc, reducer)
      when is_function(reducer, 2) do
    collector = fn {:data, chunk}, {req, resp} ->
      if ok_status?(resp.status) do
        acc = Req.Response.get_private(resp, :akaw_acc, init_acc)

        case reducer.(chunk, acc) do
          {:cont, new_acc} ->
            {:cont, {req, Req.Response.put_private(resp, :akaw_acc, new_acc)}}

          {:halt, new_acc} ->
            {:halt, {req, Req.Response.put_private(resp, :akaw_acc, new_acc)}}

          other ->
            raise ArgumentError,
                  "reducer must return {:cont, acc} or {:halt, acc}, got: #{inspect(other)}"
        end
      else
        handle_error_chunk(resp, chunk, req)
      end
    end

    run_reduce(client, method, path, opts, init_acc, collector)
  end

  @doc """
  Reduce over newline-delimited lines of the response body. Empty
  (heartbeat) lines are filtered. The trailing partial line is buffered
  across chunks; any non-empty trailing buffer at connection close is
  emitted as a final line.

  Returns `{:ok, final_acc}` or `{:error, %Akaw.Error{}}`.
  """
  @spec reduce_lines_while(
          Client.t(),
          Request.method(),
          String.t(),
          keyword(),
          acc,
          (String.t(), acc -> reducer_result(acc))
        ) :: {:ok, acc} | {:error, Error.t()}
        when acc: term()
  def reduce_lines_while(%Client{} = client, method, path, opts, init_acc, reducer)
      when is_function(reducer, 2) do
    collector = fn {:data, chunk}, {req, resp} ->
      if ok_status?(resp.status) do
        acc = Req.Response.get_private(resp, :akaw_acc, init_acc)
        buf = Req.Response.get_private(resp, :akaw_line_buf, "")
        {lines, new_buf} = split_lines(buf <> chunk)

        case feed_lines(lines, acc, reducer) do
          {:cont, new_acc} ->
            {:cont,
             {req,
              resp
              |> Req.Response.put_private(:akaw_acc, new_acc)
              |> Req.Response.put_private(:akaw_line_buf, new_buf)}}

          {:halt, new_acc} ->
            {:halt,
             {req,
              resp
              |> Req.Response.put_private(:akaw_acc, new_acc)
              |> Req.Response.put_private(:akaw_line_buf, new_buf)
              |> Req.Response.put_private(:akaw_halted, true)}}
        end
      else
        handle_error_chunk(resp, chunk, req)
      end
    end

    with {:ok, resp} <- run_request(client, method, path, opts, collector),
         :ok <- check_status(resp) do
      acc = Req.Response.get_private(resp, :akaw_acc, init_acc)

      if Req.Response.get_private(resp, :akaw_halted, false) do
        {:ok, acc}
      else
        tail = Req.Response.get_private(resp, :akaw_line_buf, "")
        {:ok, flush_tail_line(tail, acc, reducer)}
      end
    end
  end

  @doc """
  Reduce over decoded row maps from CouchDB's pretty-printed
  array-of-objects response shape (`_all_docs`, views, `_find`).

  Returns `{:ok, final_acc}` or `{:error, %Akaw.Error{}}`.
  Raises `%Akaw.Error{}` if the response shape isn't pretty-printed
  one-row-per-line (same diagnostic as the lazy `stream/N` variant).
  """
  @spec reduce_items_while(
          Client.t(),
          Request.method(),
          String.t(),
          keyword(),
          acc,
          (map(), acc -> reducer_result(acc))
        ) :: {:ok, acc} | {:error, Error.t()}
        when acc: term()
  def reduce_items_while(%Client{} = client, method, path, opts, init_acc, reducer)
      when is_function(reducer, 2) do
    line_reducer = fn line, {parser_state, user_acc} ->
      case JsonItemStream.step(line, parser_state) do
        {[], new_state} ->
          {:cont, {new_state, user_acc}}

        {items, new_state} ->
          case feed_items(items, user_acc, reducer) do
            {:cont, new_user_acc} -> {:cont, {new_state, new_user_acc}}
            {:halt, new_user_acc} -> {:halt, {new_state, new_user_acc}}
          end
      end
    end

    case reduce_lines_while(client, method, path, opts, {:seek_array, init_acc}, line_reducer) do
      {:ok, {_state, user_acc}} -> {:ok, user_acc}
      {:error, _} = err -> err
    end
  end

  defp run_reduce(client, method, path, opts, init_acc, collector) do
    with {:ok, resp} <- run_request(client, method, path, opts, collector),
         :ok <- check_status(resp) do
      {:ok, Req.Response.get_private(resp, :akaw_acc, init_acc)}
    end
  end

  defp run_request(client, method, path, opts, collector) do
    opts =
      opts
      |> Keyword.put(:into, collector)
      |> default_retry_off(client)

    case Request.request_raw(client, method, path, opts) do
      {:ok, %Req.Response{} = resp} -> {:ok, resp}
      {:error, exception} -> {:error, stream_transport_error(exception)}
    end
  end

  # See "Retry: off by default" in the module comment. The per-call opts
  # merge after the client's req_options in Request.build/4, so a bare
  # `Keyword.put` here would override a client-level opt-in — hence the
  # explicit has_key? checks on both layers.
  defp default_retry_off(opts, %Client{req_options: req_options}) do
    if Keyword.has_key?(opts, :retry) or Keyword.has_key?(req_options, :retry) do
      opts
    else
      Keyword.put(opts, :retry, false)
    end
  end

  defp check_status(%Req.Response{status: status}) when status in 200..299, do: :ok

  defp check_status(%Req.Response{status: status} = resp) do
    body =
      resp
      |> Req.Response.get_private(:akaw_error_body, "")
      |> IO.iodata_to_binary()

    decoded =
      case body do
        "" -> %{}
        bin -> safe_decode(bin)
      end

    {:error,
     %Error{
       status: status,
       error: get_in(decoded, ["error"]),
       reason: get_in(decoded, ["reason"]),
       body: decoded
     }}
  end

  defp ok_status?(status), do: is_integer(status) and status in 200..299

  # Error responses get buffered into `resp.private` so we can decode
  # the JSON `{error, reason}` after the request completes. Capped so a
  # misbehaving server returning a multi-megabyte HTML error page can't
  # grow our heap: once we hit the cap the collector returns `:halt`,
  # which closes the connection without consuming the rest of the body.
  @max_error_body 64 * 1024

  defp handle_error_chunk(resp, chunk, req) do
    case append_error_chunk(resp, chunk) do
      {:cont, new_resp} -> {:cont, {req, new_resp}}
      {:halt, new_resp} -> {:halt, {req, new_resp}}
    end
  end

  defp append_error_chunk(resp, chunk) do
    size_so_far = Req.Response.get_private(resp, :akaw_error_body_size, 0)
    remaining = @max_error_body - size_so_far

    cond do
      remaining <= 0 ->
        {:halt, resp}

      byte_size(chunk) <= remaining ->
        {:cont, store_error_chunk(resp, chunk, size_so_far + byte_size(chunk))}

      true ->
        truncated = binary_part(chunk, 0, remaining)
        {:halt, store_error_chunk(resp, truncated, @max_error_body)}
    end
  end

  defp store_error_chunk(resp, chunk, size) do
    resp
    |> Req.Response.update_private(:akaw_error_body, [chunk], &[&1, chunk])
    |> Req.Response.put_private(:akaw_error_body_size, size)
  end

  defp split_lines(buffer) do
    parts = :binary.split(buffer, "\n", [:global])
    {complete, [tail]} = Enum.split(parts, length(parts) - 1)
    {Enum.reject(complete, &(&1 == "")), tail}
  end

  defp feed_lines([], acc, _reducer), do: {:cont, acc}

  defp feed_lines([line | rest], acc, reducer) do
    case reducer.(line, acc) do
      {:cont, new_acc} ->
        feed_lines(rest, new_acc, reducer)

      {:halt, new_acc} ->
        {:halt, new_acc}

      other ->
        raise ArgumentError,
              "reducer must return {:cont, acc} or {:halt, acc}, got: #{inspect(other)}"
    end
  end

  defp feed_items([], acc, _reducer), do: {:cont, acc}

  defp feed_items([item | rest], acc, reducer) do
    case reducer.(item, acc) do
      {:cont, new_acc} ->
        feed_items(rest, new_acc, reducer)

      {:halt, new_acc} ->
        {:halt, new_acc}

      other ->
        raise ArgumentError,
              "reducer must return {:cont, acc} or {:halt, acc}, got: #{inspect(other)}"
    end
  end

  defp flush_tail_line("", acc, _reducer), do: acc

  defp flush_tail_line(tail, acc, reducer) do
    case reducer.(tail, acc) do
      {:cont, new_acc} ->
        new_acc

      {:halt, new_acc} ->
        new_acc

      other ->
        raise ArgumentError,
              "reducer must return {:cont, acc} or {:halt, acc}, got: #{inspect(other)}"
    end
  end
end
