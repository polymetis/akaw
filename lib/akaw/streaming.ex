defmodule Akaw.Streaming do
  @moduledoc false

  # Shared HTTP-streaming primitives for endpoints that consume long-lived
  # responses (`_changes` continuous feed, line-delimited `_all_docs`,
  # views, `_find`). Two flavors:
  #
  #   * `chunks/4` — lazy `Stream` of raw binary chunks. Uses
  #     `Finch.async_request/3`: response parts arrive as ref-tagged
  #     mailbox messages, consumed with a selective `receive`. Ergonomic,
  #     but body parts pile into the calling process's mailbox with no
  #     backpressure; prefer the reduce API from anything long-lived.
  #
  #   * `reduce_chunks_while/6`, `reduce_lines_while/6`,
  #     `reduce_items_while/6` — synchronous, backpressured callback API
  #     built on `Finch.stream_while/5`. The user reducer runs inline in
  #     the calling process, so (a) no mailbox messages are involved and
  #     (b) blocking in the reducer stalls socket reads and applies real
  #     TCP backpressure to CouchDB.
  #
  # The backpressure claim is an HTTP/1 fact. A caller-supplied Finch
  # pool configured for HTTP/2 has NO flow control on streams (Finch's
  # own docs box-warn against h2 for non-terminating responses) —
  # streaming endpoints require an HTTP/1 pool, which is also all
  # CouchDB speaks. Two cost notes: every early `:halt` closes the
  # pooled connection (HTTP/1 can't abandon a half-read body), so a
  # halt-after-N-rows pattern pays a reconnect per call; and on a
  # transport failure the accumulator is LOST — the error tuple carries
  # no acc. That's by design: checkpoints live in caller-owned storage,
  # never the accumulator (see "resume, don't retry" below).
  #
  # ## Retry: off, structurally — resume is the caller's job
  #
  # Streaming and held-open requests NEVER retry: these paths contain no
  # retry code at all, and there is no opt-in at any layer (a per-call
  # `retry:` raises; a client-level `req_options[:retry]` applies only to
  # plain requests). The transport underneath keeps that promise too:
  # Finch's one internal retry (:read_only, HTTP/2 pool draining) fires
  # strictly before any response part flows and can't occur on an
  # HTTP/1 pool at all — delivery-once holds through it either way.
  # Two reasons, both from the design record:
  #
  # 1. Correctness: body already consumed before a failure has already
  #    been fed to the caller; a retried attempt would reset the
  #    accumulator and re-deliver every row. `{:ok, final_acc}` must mean
  #    delivered-once.
  # 2. Liveness at scale: streaming exists for datasets larger than RAM.
  #    Restart-from-row-zero on a walk whose duration approaches the
  #    connection's MTBF has completion probability trending to zero;
  #    checkpoint-resume (startkey/startkey_docid/since — caller-owned)
  #    trends to one. Transparent retry is an anti-resume that also
  #    hides that it ran.
  #
  # Held-open feed requests (longpoll included, non-streaming) ride
  # `Akaw.Request` and pin `retry: false` there — retrying a
  # client-side-timed-out longpoll is guaranteed to time out again while
  # abandoning server-side connections.
  #
  # ## Compression: never advertised on streaming paths
  #
  # Every streaming request pins `compressed: false`: the line splitter
  # and the JSON-item state machine parse bytes as they arrive, and a
  # gzip-encoded body would reach them as compressed garbage. Complete
  # (non-streaming) responses negotiate gzip as usual.
  #
  # ## chunks/4 — idle timeout
  #
  # `next_chunk/1` does a selective `receive` with an `after` clause
  # keyed on the `:idle_timeout` opt (default 5 minutes). On the feed
  # paths the transport's `:receive_timeout` (auto-derived from the
  # heartbeat) fires first and surfaces as a transport error — the idle
  # clock is really a dead-man's switch on the request process itself,
  # the guard for stalls the socket timeout can't see. Tune
  # `:receive_timeout` for connection quietness; leave `:idle_timeout`
  # for the pathological case.
  #
  # ## chunks/4 — mailbox behavior
  #
  # Response parts arrive as `{request_ref, part}` messages and are
  # consumed with a selective `receive` — unrelated messages in the
  # calling process's mailbox are left untouched. (The Req-era
  # implementation had to receive *everything* and could eat a
  # GenServer's own mail; that hazard is gone.) What remains: parts
  # arrive with no backpressure, so a consumer slower than the server
  # accumulates them in its mailbox, and an unconsumed stream must be
  # closed (Stream.resource does this) or its messages linger. Prefer
  # `reduce_*_while` from anything with a long-lived mailbox.
  #
  # Two honest edges for long-lived consumers. The close-time flush is
  # best-effort: cancellation is an async exit signal, so one in-flight
  # part can land after `close/1` returns and sit in the mailbox as a
  # stray `{ref, part}`. And the transport's helper process is LINKED to
  # the consumer: a process trapping exits sees `{:EXIT, _, :normal}`
  # after a fully-consumed stream, and an abnormal helper death (pool
  # checkout exhaustion included) kills a non-trapping consumer outright
  # — the reduce API classifies that same condition as
  # {:error, "pool_timeout"}; this one can't.
  #
  # ## chunks/4 — open errors
  #
  # The `start_fun` raises `Akaw.Error` in both cases:
  #
  #   * HTTP non-2xx — the async body is drained once (capped at
  #     @max_error_body, hard deadline) and decoded to extract CouchDB's
  #     `error` / `reason` into the struct.
  #   * Transport failure — `error: "stream_transport_error"` with the
  #     underlying exception in `body.exception`, the same shape as a
  #     mid-stream failure. One tag per API mode: every transport
  #     failure on a streaming call, whatever its phase, reads the same.
  #
  # ## reduce_*_while — idle timeout
  #
  # No mailbox `receive` here; the between-chunk timeout is Finch's
  # `:receive_timeout`. The continuous-feed wrappers default it via
  # `default_receive_timeout/3` to cover CouchDB's legitimate quiet
  # window; pass `receive_timeout:` in opts to override.
  #
  # ## reduce_*_while — error body
  #
  # When the response is non-2xx, the user reducer is *not* called.
  # Chunks accumulate (capped) in the stream state and are decoded into
  # the final `%Akaw.Error{}` after the request finishes.

  alias Akaw.{Client, Error, JsonItemStream, Request}

  @drain_timeout 5_000
  @default_idle_timeout to_timeout(minute: 5)

  # Error-body ceiling, shared by both flavors of non-2xx buffering (the
  # reduce path's collector and the async open drain): a misbehaving
  # server returning a multi-megabyte HTML error page can't grow our
  # heap — we keep the first 64 KiB and close.
  @max_error_body 64 * 1024

  @doc """
  Lazy stream of raw binary chunks from the HTTP response body.

  `opts` accepts the same per-call options as non-streaming requests
  (`:params`, `:json`, `:headers`, ...) plus one streaming-only option:

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
    opts = Keyword.put(opts, :compressed, false)

    {finch_request, pool, finch_opts, _retry} = Request.prepared(client, method, path, opts)
    ref = Finch.async_request(finch_request, pool, finch_opts)

    await_open(%{ref: ref, idle_timeout: idle_timeout, finished: false})
  end

  # The response status is the first part to arrive; a held-open feed's
  # can legitimately be slow, so the wait runs on the same idle clock as
  # the body. A 1xx is informational — the real status follows on the
  # same ref, so keep waiting (its headers fall through the same way).
  defp await_open(%{ref: ref} = state) do
    receive do
      {^ref, {:status, status}} when status in 100..199 ->
        await_open(state)

      {^ref, {:status, status}} when status in 200..299 ->
        state

      {^ref, {:status, status}} ->
        raise open_error(ref, status)

      {^ref, {:headers, _headers}} ->
        await_open(state)

      {^ref, {:error, exception}} ->
        raise stream_transport_error(exception)
    after
      state.idle_timeout ->
        cancel_and_flush(ref)
        raise idle_error(state.idle_timeout)
    end
  end

  defp next_chunk(%{finished: true} = state), do: {:halt, state}

  defp next_chunk(%{ref: ref} = state) do
    receive do
      {^ref, {:data, chunk}} ->
        {[chunk], state}

      # Response headers before the body, trailers after it (the async
      # path tags them distinctly) — neither is part of the chunk stream.
      {^ref, {:headers, _headers}} ->
        next_chunk(state)

      {^ref, {:trailers, _trailers}} ->
        next_chunk(state)

      {^ref, :done} ->
        {[], %{state | finished: true}}

      {^ref, {:error, exception}} ->
        raise stream_transport_error(exception)
    after
      state.idle_timeout ->
        raise idle_error(state.idle_timeout)
    end
  end

  defp close(%{ref: ref}) do
    cancel_and_flush(ref)
    :ok
  end

  # Cancel is idempotent (a completed request just ignores it); the
  # flush clears any parts already delivered so they can't linger in the
  # caller's mailbox after the stream is closed.
  defp cancel_and_flush(ref) do
    Finch.cancel_async_request(ref)
    flush_ref(ref)
  end

  defp flush_ref(ref) do
    receive do
      {^ref, _part} -> flush_ref(ref)
    after
      0 -> :ok
    end
  end

  defp idle_error(idle_timeout) do
    %Error{
      status: nil,
      error: "stream_idle_timeout",
      reason: "no data received within #{idle_timeout}ms"
    }
  end

  defp open_error(ref, status) do
    body = drain(ref, [], 0, System.monotonic_time(:millisecond) + @drain_timeout)
    cancel_and_flush(ref)

    decoded =
      case IO.iodata_to_binary(body) do
        "" -> %{}
        bin -> safe_decode(bin)
      end

    %Error{
      status: status,
      error: get_in(decoded, ["error"]),
      reason: get_in(decoded, ["reason"]),
      body: decoded
    }
  end

  # Bounded twice, like the reduce path's error buffering: at most
  # @max_error_body bytes (a misbehaving server returning a
  # multi-megabyte HTML error page can't grow our heap), and at most
  # @drain_timeout total — a hard deadline, not a per-message window a
  # dripping server could reset forever.
  defp drain(ref, acc, size, deadline) do
    remaining_time = deadline - System.monotonic_time(:millisecond)

    if remaining_time <= 0 or size >= @max_error_body do
      acc
    else
      receive do
        {^ref, {:data, chunk}} -> drain(ref, [acc | chunk], size + byte_size(chunk), deadline)
        {^ref, {:headers, _headers}} -> drain(ref, acc, size, deadline)
        {^ref, {:trailers, _trailers}} -> drain(ref, acc, size, deadline)
        {^ref, :done} -> acc
        {^ref, {:error, _exception}} -> acc
      after
        remaining_time -> acc
      end
    end
  end

  # The transport hands back its raw exception struct — Mint's, or
  # Finch's own. `inspect/1`-ing it once leaked the transport's
  # internals straight into the documented `:reason` string;
  # `Exception.message/1` is stable ("socket closed"), and stashing the
  # struct in `:body` matches what `Akaw.Error`'s moduledoc promises for
  # transport failures — and what the non-streaming path has always done.
  defp stream_transport_error(reason) do
    %Error{
      status: nil,
      error: "stream_transport_error",
      reason: if(is_exception(reason), do: Exception.message(reason), else: inspect(reason)),
      body: %{exception: reason}
    }
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
  # `opts` and is treated as a CouchDB query param. `:retry` is
  # deliberately NOT here: streaming/feed requests never retry (see the
  # module comment), and `split_req_opts/1` rejects it loudly rather
  # than letting it leak into the query string.
  @req_opt_keys [:receive_timeout, :pool_timeout]

  @doc """
  Split a flat opts keyword into `{req_opts, couchdb_opts}`, pulling out
  the small set of transport-level options we let callers override per
  call (everything else is destined for query params). Shared by every
  streaming entry point — reduce wrappers, lazy streams, and the
  feed-mode endpoints via `held_open_feed_opts/2`.

  `:receive_timeout` and `:pool_timeout` ride to Finch as request
  options. Connection-level options (TLS, proxy) are not per-call —
  configure a named Finch pool and pass it via `Akaw.new(finch: ...)`.
  """
  @spec split_req_opts(keyword()) :: {keyword(), keyword()}
  def split_req_opts(opts) when is_list(opts) do
    reject_retry!(opts)
    reject_connect_options!(opts)
    Keyword.split(opts, @req_opt_keys)
  end

  # Same posture as Akaw.Changes' reject_feed_override!/1: a loud,
  # immediate ArgumentError beats a silently ignored (or worse,
  # query-param-leaked) option. Fires for every feed mode on the
  # feed-capable endpoints, "normal" included — these endpoints take no
  # per-call retry policy at all.
  defp reject_retry!(opts) do
    if Keyword.has_key?(opts, :retry) do
      raise ArgumentError,
            "the streaming and feed endpoints take no per-call :retry. " <>
              "Streaming and held-open requests never retry — a transparent " <>
              "retry restarts the walk from row zero with the accumulator " <>
              "reset and every side effect re-run, which at larger-than-RAM " <>
              "scale is a walk that may never complete; resume from a " <>
              "checkpoint you own instead (see \"Interrupted walks: resume, " <>
              "don't retry\" in the reduce_while docs). Plain normal-feed " <>
              "requests take retry policy at the client level: " <>
              "Akaw.new(req_options: [retry: ...])."
    end
  end

  # :connect_options left the per-call surface in the Phase 0 contract
  # narrowing. Same loud-beats-leaked posture: without this it would
  # fall into the CouchDB params bucket and die inside URI encoding
  # with an error pointing away from the cause.
  defp reject_connect_options!(opts) do
    if Keyword.has_key?(opts, :connect_options) do
      raise ArgumentError,
            "per-call :connect_options was removed — connection-level " <>
              "options (TLS for self-signed CouchDB, proxies) are configured " <>
              "on a named Finch pool: {Finch, name: MyApp.CouchPool, pools: " <>
              "%{default: [conn_opts: [transport_opts: [...]]]}} and " <>
              "Akaw.new(base_url: url, finch: MyApp.CouchPool)."
    end
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
  `Akaw.Request.prepared/4`, so putting a derived value into per-call
  opts would silently override a client-level setting; hence the check
  on both layers. (Retry takes the opposite stance on purpose: the feed
  paths pin it off unconditionally — see the module comment.)
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
    heartbeat = Keyword.get(couchdb_opts, :heartbeat)

    case positive_ms(heartbeat) do
      nil when heartbeat in [true, "true"] -> @server_picked_heartbeat_timeout
      nil -> quiet_window(couchdb_opts) + @feed_timeout_slack
      hb -> hb * 2
    end
  end

  defp quiet_window(couchdb_opts) do
    case non_negative_ms(Keyword.get(couchdb_opts, :timeout)) do
      nil -> @server_default_feed_timeout
      server_timeout -> server_timeout
    end
  end

  # CouchDB accepts numeric query params as strings — `heartbeat: "30000"`
  # reaches the server exactly like `heartbeat: 30_000`, so both
  # spellings must derive the same ceiling. A string that isn't a plain
  # integer falls through to the defaults.
  defp positive_ms(value) when is_integer(value) and value > 0, do: value

  defp positive_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp positive_ms(_), do: nil

  defp non_negative_ms(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp non_negative_ms(_), do: nil

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
      # Held-open feeds also pin retry off (client-level opt-ins
      # included): these ride the plain request path, whose keep-alive
      # retry would re-issue a longpoll that timed out client-side —
      # guaranteed to time out again while abandoning a server-side
      # connection per attempt. Measured live as an explicit 2s deadline
      # stretching to 14.7s across four abandoned connections in the
      # Req era; the policy survives the transport.
      req_opts =
        client
        |> default_receive_timeout(req_opts, params)
        |> Keyword.put(:retry, false)

      {req_opts, params}
    else
      {req_opts, params}
    end
  end

  @doc """
  Decode one line of a line-delimited feed as JSON, raising a legible
  `%Akaw.Error{error: "stream_decode_error"}` instead of a bare
  `JSON.DecodeError` when the line is corrupt — the same posture
  `Akaw.JsonItemStream` takes for row streams. Shared by the `_changes`
  and `_db_updates` feed decoders.
  """
  @spec decode_feed_line!(String.t()) :: term()
  def decode_feed_line!(line) do
    JSON.decode!(line)
  rescue
    decode_error ->
      reraise %Error{
                status: nil,
                error: "stream_decode_error",
                reason:
                  "feed line failed to decode: #{inspect(decode_error)}. Source line: " <>
                    inspect(String.slice(line, 0, 200))
              },
              __STACKTRACE__
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
    on_data = fn chunk, acc -> validate_step(reducer.(chunk, acc)) end

    case run_stream(client, method, path, opts, init_acc, on_data) do
      {:ok, %{flavor: acc}} -> {:ok, acc}
      {:error, _} = error -> error
    end
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
    on_data = fn chunk, {acc, buffer} ->
      {lines, new_buffer} = split_lines(buffer <> chunk)

      case feed_lines(lines, acc, reducer) do
        {:cont, new_acc} -> {:cont, {new_acc, new_buffer}}
        {:halt, new_acc} -> {:halt, {new_acc, new_buffer}}
      end
    end

    case run_stream(client, method, path, opts, {init_acc, ""}, on_data) do
      {:ok, %{halted: true, flavor: {acc, _buffer}}} ->
        {:ok, acc}

      {:ok, %{flavor: {acc, tail}}} ->
        {:ok, flush_tail_line(tail, acc, reducer)}

      {:error, _} = error ->
        error
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

  # ---------------------------------------------------------------------
  # The stream_while plumbing
  # ---------------------------------------------------------------------

  # Every reduce flavor runs through here: one `Finch.stream_while/5`
  # carrying an explicit state map. On an ok status, `:data` parts feed
  # the flavor's `on_data`; on an error status they accumulate (capped)
  # for the final `%Akaw.Error{}`. The `halted` flag records a user
  # `:halt` so the lines flavor knows not to flush its tail.
  defp run_stream(client, method, path, opts, init_flavor, on_data) do
    opts = Keyword.put(opts, :compressed, false)
    {finch_request, pool, finch_opts, _retry} = Request.prepared(client, method, path, opts)

    initial_state = %{
      status: nil,
      flavor: init_flavor,
      halted: false,
      error_body: [],
      error_size: 0
    }

    stream_fun = fn
      # A 1xx interim status is followed by the real one — keeping the
      # latest means data (which only ever follows the final status)
      # gates on the right value.
      {:status, status}, state -> {:cont, %{state | status: status}}
      {:headers, _headers}, state -> {:cont, state}
      {:data, chunk}, state -> handle_data(chunk, state, on_data)
      # Trailers are part of Finch's stream contract even though CouchDB
      # never sends them — an intermediary can. Without this clause a
      # trailer-bearing response was a FunctionClauseError on a
      # checked-out connection instead of a completed stream.
      {:trailers, _trailers}, state -> {:cont, state}
    end

    case run_finch_stream(finch_request, pool, initial_state, stream_fun, finch_opts) do
      {:ok, %{status: status} = state} when status in 200..299 ->
        {:ok, state}

      {:ok, state} ->
        {:error, error_from_state(state)}

      {:error, %RuntimeError{} = exception, _state} ->
        # The rescued checkout-exhaustion raise (see run_finch_stream/5):
        # the pool is saturated, not the network — same tag as the plain
        # path so operators see one signal for one condition.
        {:error,
         %Error{
           status: nil,
           error: "pool_timeout",
           reason: Exception.message(exception),
           body: %{exception: exception}
         }}

      {:error, exception, _state} ->
        {:error, stream_transport_error(exception)}
    end
  end

  # Finch reports checkout exhaustion by raising; the reduce API
  # promises {:ok, acc} | {:error, %Akaw.Error{}}, so that raise is
  # rescued into the error channel. The message guard is load-bearing,
  # not cosmetic: the user's reducer runs INSIDE stream_while, and a
  # reducer's `raise "boom"` is a RuntimeError too — type alone would
  # misclassify user bugs as pool saturation. Everything that isn't the
  # exhaustion raise propagates untouched. (The message match is pinned
  # by a saturation test against real Finch, so a Finch wording change
  # fails loudly there rather than silently here.)
  defp run_finch_stream(finch_request, pool, initial_state, stream_fun, finch_opts) do
    Finch.stream_while(finch_request, pool, initial_state, stream_fun, finch_opts)
  rescue
    exception in RuntimeError ->
      if Akaw.Request.pool_exhaustion?(exception) do
        {:error, exception, initial_state}
      else
        reraise(exception, __STACKTRACE__)
      end
  end

  defp handle_data(chunk, %{status: status} = state, on_data) when status in 200..299 do
    case on_data.(chunk, state.flavor) do
      {:cont, flavor} -> {:cont, %{state | flavor: flavor}}
      {:halt, flavor} -> {:halt, %{state | flavor: flavor, halted: true}}
    end
  end

  defp handle_data(chunk, state, _on_data), do: append_error_chunk(state, chunk)

  defp error_from_state(%{status: status} = state) do
    decoded =
      case IO.iodata_to_binary(state.error_body) do
        "" -> %{}
        bin -> safe_decode(bin)
      end

    %Error{
      status: status,
      error: get_in(decoded, ["error"]),
      reason: get_in(decoded, ["reason"]),
      body: decoded
    }
  end

  # Error responses get buffered so we can decode the JSON
  # `{error, reason}` after the request completes. Capped at
  # @max_error_body: once we hit the cap the stream halts, which closes
  # the connection without consuming the rest of the body.
  defp append_error_chunk(state, chunk) do
    remaining = @max_error_body - state.error_size

    cond do
      remaining <= 0 ->
        {:halt, state}

      byte_size(chunk) <= remaining ->
        {:cont,
         %{
           state
           | error_body: [state.error_body | chunk],
             error_size: state.error_size + byte_size(chunk)
         }}

      true ->
        truncated = binary_part(chunk, 0, remaining)

        {:halt,
         %{state | error_body: [state.error_body | truncated], error_size: @max_error_body}}
    end
  end

  defp validate_step({:cont, _acc} = step), do: step
  defp validate_step({:halt, _acc} = step), do: step

  defp validate_step(other) do
    raise ArgumentError,
          "reducer must return {:cont, acc} or {:halt, acc}, got: #{inspect(other)}"
  end

  defp split_lines(buffer) do
    parts = :binary.split(buffer, "\n", [:global])
    {complete, [tail]} = Enum.split(parts, length(parts) - 1)
    {Enum.reject(complete, &(&1 == "")), tail}
  end

  defp feed_lines([], acc, _reducer), do: {:cont, acc}

  defp feed_lines([line | rest], acc, reducer) do
    case validate_step(reducer.(line, acc)) do
      {:cont, new_acc} -> feed_lines(rest, new_acc, reducer)
      {:halt, new_acc} -> {:halt, new_acc}
    end
  end

  defp feed_items([], acc, _reducer), do: {:cont, acc}

  defp feed_items([item | rest], acc, reducer) do
    case validate_step(reducer.(item, acc)) do
      {:cont, new_acc} -> feed_items(rest, new_acc, reducer)
      {:halt, new_acc} -> {:halt, new_acc}
    end
  end

  defp flush_tail_line("", acc, _reducer), do: acc

  defp flush_tail_line(tail, acc, reducer) do
    case validate_step(reducer.(tail, acc)) do
      {:cont, new_acc} -> new_acc
      {:halt, new_acc} -> new_acc
    end
  end
end
