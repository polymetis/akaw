defmodule Akaw.Streaming do
  @moduledoc false

  # Shared HTTP-streaming primitives for endpoints that consume long-lived
  # responses (`_changes` continuous feed, line-delimited `_all_docs`,
  # views, `_find`).
  #
  # `chunks/4` returns a lazy `Stream` of raw binary chunks. Internally it
  # uses Req's `into: :self` mode plus `Req.parse_message/2`, then drives
  # the producer/consumer through `Stream.resource/3`.
  #
  # ## Idle timeout
  #
  # `next_chunk/1` does a `receive` with an `after` clause keyed on the
  # `:idle_timeout` opt (default 5 minutes). If no chunk arrives within
  # that window the stream raises `%Akaw.Error{}` — guards against silent
  # stalls where a load balancer or NAT has dropped a connection and TCP
  # hasn't noticed. For `_changes` feeds, set this to slightly more than
  # your `:heartbeat` so heartbeats always reset the clock.
  #
  # ## Mailbox ownership
  #
  # The `receive` consumes any message and routes it through
  # `Req.parse_message/2`; non-Finch messages return `:unknown` and we
  # recurse. This means consuming an Akaw stream from a process that also
  # receives other mail (a GenServer, LiveView, monitor) will drain those
  # unrelated messages and break the consumer's contract. Run streams from
  # a process you own — typically a `Task` or a spawned helper — until we
  # land a proper owner-process refactor (planned alongside backpressure).
  #
  # ## Open errors
  #
  # The `start_fun` raises:
  #
  #   * `Akaw.Error` for HTTP non-2xx responses (the async body is drained
  #     once and decoded to extract CouchDB's `error` / `reason`).
  #   * The underlying transport exception for network failures.

  alias Akaw.{Client, Error, Request}

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
  @spec chunks(Client.t(), Request.method(), String.t(), keyword()) :: Enumerable.t()
  def chunks(%Client{} = client, method, path, opts \\ []) do
    Stream.resource(
      fn -> open(client, method, path, opts) end,
      &next_chunk/1,
      &close/1
    )
  end

  defp open(client, method, path, opts) do
    {idle_timeout, opts} = Keyword.pop(opts, :idle_timeout, @default_idle_timeout)
    opts = Keyword.put(opts, :into, :self)

    case Request.request_raw(client, method, path, opts) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        %{response: resp, idle_timeout: idle_timeout, finished: false}

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
            raise %Error{
              status: nil,
              error: "stream_transport_error",
              reason: inspect(reason)
            }

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
end
