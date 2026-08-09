defmodule Akaw.Request do
  @moduledoc false

  require Logger

  alias Akaw.{Client, Error, Response}

  # Standard HTTP method atoms accepted by Finch, plus a binary escape hatch
  # for non-standard verbs like "COPY" (CouchDB document copy). Both
  # spellings go to the wire verbatim — akaw never rewrites a verb.
  @type method ::
          :get | :post | :put | :delete | :head | :patch | :options | String.t()
  @type return_kind :: :body | :response

  @user_agent "akaw/#{Mix.Project.config()[:version]}"

  @doc """
  Issue an HTTP request via Finch.

  ## Internal options

    * `:return` — `:body` (default) returns `{:ok, decoded_body}`;
      `:response` returns `{:ok, %Akaw.Response{}}` so callers can inspect
      headers and status (used by `Akaw.Session` to capture the `AuthSession`
      cookie and `Akaw.Attachment` for content-type/ETag).

  Headers from `client.headers`, `client.req_options[:headers]`, and per-call
  `opts[:headers]` are concatenated in that order. If the same header name
  appears more than once, the later occurrence wins (per-call beats
  req_options beats client).

  Every other accepted option is named in `prepared/4`; an unknown key
  raises `ArgumentError` — this layer is a closed surface, not a
  passthrough.

  ## Retry: the pooled keep-alive race, once, loudly

  A pooled connection can be closed by the server between checkout and
  write — CouchDB's own keep-alive timeout guarantees this race occurs in
  normal operation. For idempotent methods (GET/HEAD) that failure
  (`%Mint.TransportError{reason: :closed}`) is retried exactly once, and
  every retry logs at `:warning` so the policy is observable rather than
  silent. Nothing else is retried: not other transport errors (a refused
  connect fails the same way twice), not 5xx statuses (surface them —
  the full status-classification port is a pre-Hex item, deliberately
  deferred). `retry: false` (per call or per client) disables even that;
  the streaming and held-open feed paths have no retry code path at all.
  """
  @spec request(Client.t(), method(), String.t(), keyword()) ::
          {:ok, term()} | {:ok, Response.t()} | {:error, Error.t()}
  def request(%Client{} = client, method, path, opts \\ []) do
    {return_kind, opts} = Keyword.pop(opts, :return, :body)
    {finch_request, pool, finch_opts, retry?} = prepared(client, method, path, opts)

    finch_request
    |> run_with_retry(pool, finch_opts, retry?)
    |> handle_response(return_kind, finch_request.method)
  end

  @doc """
  Build the `%Finch.Request{}` plus everything needed to run it:
  `{finch_request, pool_name, finch_opts, retry?}`.

  Shared with `Akaw.Streaming`, which runs the request through
  `Finch.stream_while/5` / `Finch.async_request/3` instead of
  `Finch.request/3` (and ignores `retry?` — streaming paths have no
  retry plumbing by design).
  """
  @spec prepared(Client.t(), method(), String.t(), keyword()) ::
          {Finch.Request.t(), module() | atom(), keyword(), boolean()}
  def prepared(%Client{} = client, method, path, opts) do
    {req_opt_headers, req_options} = Keyword.pop(client.req_options, :headers, [])
    {call_headers, opts} = Keyword.pop(opts, :headers, [])
    headers = combine_headers([client.headers, req_opt_headers, call_headers])

    merged = req_options |> Keyword.merge(opts)

    {params, merged} = Keyword.pop(merged, :params, [])
    {json, merged} = Keyword.pop(merged, :json)
    {body, merged} = Keyword.pop(merged, :body)
    {compressed, merged} = Keyword.pop(merged, :compressed, true)
    {receive_timeout, merged} = Keyword.pop(merged, :receive_timeout)
    {pool_timeout, merged} = Keyword.pop(merged, :pool_timeout)
    {retry, merged} = Keyword.pop(merged, :retry, :safe_transient)

    reject_unknown_options!(merged)

    {body, headers} = encode_json_body(json, body, headers)

    headers =
      headers
      |> apply_auth(client.auth)
      |> apply_compressed(compressed)
      |> put_new_header("user-agent", @user_agent)

    {pool, build_options} = pool_and_build_options(client.finch)

    finch_request =
      Finch.build(
        method,
        client.base_url <> path <> query_suffix(params),
        headers,
        body,
        build_options
      )

    finch_opts =
      Enum.reject(
        [receive_timeout: receive_timeout, pool_timeout: pool_timeout],
        fn {_key, value} -> is_nil(value) end
      )

    {finch_request, pool, finch_opts, retry != false}
  end

  # The closed option surface. Anything else is a bug at the endpoint
  # layer (or a Req-era option that no longer exists) — raise with the
  # inventory rather than silently dropping it.
  @known_options [
    :params,
    :json,
    :body,
    :headers,
    :compressed,
    :receive_timeout,
    :pool_timeout,
    :retry,
    :return
  ]

  defp reject_unknown_options!([]), do: :ok

  defp reject_unknown_options!(unknown) do
    raise ArgumentError, """
    unknown request option(s): #{inspect(Keyword.keys(unknown))}

    Akaw.Request accepts exactly #{inspect(@known_options)} — it is a \
    closed surface over the HTTP client, not a passthrough.\
    """
  end

  # ---------------------------------------------------------------------
  # Request building
  # ---------------------------------------------------------------------

  # One value per key, later occurrence winning — the same semantics
  # Req 0.7 applied (and Akaw's CHANGELOG documented), now implemented
  # here. Spaces encode as `+` (www-form), which CouchDB decodes.
  defp query_suffix([]), do: ""

  defp query_suffix(params) do
    encoded =
      params
      |> Enum.reduce([], fn {name, value}, deduped ->
        name = to_string(name)
        List.keystore(deduped, name, 0, {name, value})
      end)
      |> URI.encode_query()

    "?" <> encoded
  end

  # Bodies are encoded with the OTP-native JSON module. Mirrors the
  # header behavior of the Req era (content-type/accept are set only if
  # the caller didn't set them) so the wire shape is unchanged.
  defp encode_json_body(nil, body, headers), do: {body, headers}

  defp encode_json_body(json, _body, headers) do
    headers =
      headers
      |> put_new_header("content-type", "application/json")
      |> put_new_header("accept", "application/json")

    {JSON.encode_to_iodata!(json), headers}
  end

  defp apply_auth(headers, nil), do: headers

  # put_new, not put: headers follow "later occurrence wins", and an
  # explicit authorization header (per call or per client) is more
  # specific than the client-level :auth credential.
  defp apply_auth(headers, {:basic, user, pass}),
    do: put_new_header(headers, "authorization", "Basic " <> Base.encode64("#{user}:#{pass}"))

  defp apply_auth(headers, {:bearer, token}),
    do: put_new_header(headers, "authorization", "Bearer #{token}")

  # Ask for gzip by default: CouchDB compresses JSON bodies and text
  # attachments when allowed — measured at 38x fewer bytes on the wire
  # for a text attachment. The decompression-bomb rationale for
  # defaulting this off in general-purpose clients doesn't apply: akaw
  # only ever talks to the CouchDB you pointed it at. `compressed:
  # false` (per call or per client) opts out; streaming paths pin it
  # off unconditionally (chunk parsers must never see gzip bytes).
  defp apply_compressed(headers, false), do: headers
  defp apply_compressed(headers, _), do: put_new_header(headers, "accept-encoding", "gzip")

  defp put_new_header(headers, name, value) do
    if Enum.any?(headers, fn {header_name, _} -> String.downcase(header_name) == name end) do
      headers
    else
      headers ++ [{name, value}]
    end
  end

  defp combine_headers(lists) do
    lists
    |> Enum.concat()
    |> Enum.reverse()
    |> Enum.uniq_by(fn {name, _value} -> String.downcase(name) end)
    |> Enum.reverse()
  end

  # nil rides the default pool the Akaw application booted. The keyword
  # form carries a pool name plus Finch build options (:pool_tag).
  defp pool_and_build_options(nil), do: {Akaw.Finch, []}
  defp pool_and_build_options(name) when is_atom(name), do: {name, []}

  defp pool_and_build_options(options) when is_list(options) do
    {name, build_options} = Keyword.pop(options, :name, Akaw.Finch)
    {name, Keyword.take(build_options, [:pool_tag])}
  end

  # ---------------------------------------------------------------------
  # Running + retry
  # ---------------------------------------------------------------------

  @idempotent_methods ["GET", "HEAD"]

  defp run_with_retry(finch_request, pool, finch_opts, retry?) do
    case run_finch(finch_request, pool, finch_opts) do
      {:error, exception} = error ->
        if retry? and finch_request.method in @idempotent_methods and
             closed_socket?(exception) do
          retry_warning(finch_request, exception)
          emit_retry_telemetry(finch_request, pool)
          run_finch(finch_request, pool, finch_opts)
        else
          error
        end

      ok ->
        ok
    end
  end

  # Finch reports checkout exhaustion by RAISING (its pool catches the
  # NimblePool exit and reraises a RuntimeError) — which would break the
  # {:error, %Akaw.Error{}} contract at exactly the moment, overload,
  # when callers most need the documented shape. Classified here rather
  # than retried: retrying against a saturated pool only amplifies the
  # saturation, and closed_socket?/1 never matches a RuntimeError.
  # Anything else (ArgumentError from bad construction, exits from a
  # dead pool, unrelated RuntimeErrors) propagates — those are
  # programmer errors and supervision-level events respectively.
  defp run_finch(finch_request, pool, finch_opts) do
    Finch.request(finch_request, pool, finch_opts)
  rescue
    exception in RuntimeError ->
      if pool_exhaustion?(exception) do
        {:error, exception}
      else
        reraise(exception, __STACKTRACE__)
      end
  end

  @doc false
  # The message guard identifying Finch's checkout-exhaustion raise —
  # shared with Akaw.Streaming, where the guard is load-bearing (user
  # reducers run inside stream_while and can raise RuntimeErrors of
  # their own). Pinned by a saturation test against real Finch so a
  # wording change upstream fails loudly.
  def pool_exhaustion?(%RuntimeError{message: message}) do
    String.contains?(message, "unable to provide a connection")
  end

  def pool_exhaustion?(_other), do: false

  # The moment this line matters is a CouchDB restart, when every pooled
  # connection goes stale at once and the bursts arrive from *somewhere*
  # — so it names which somewhere, and carries metadata for filtering.
  defp retry_warning(finch_request, exception) do
    Logger.warning(
      "akaw: retrying #{finch_request.method} #{url_for_log(finch_request)} once — " <>
        "pooled connection closed mid-request (keep-alive race): " <>
        Exception.message(exception),
      akaw_host: finch_request.host,
      akaw_port: finch_request.port,
      akaw_method: finch_request.method
    )
  end

  # "Observable rather than silent" should hold for machines too:
  # counting keep-alive races beats scraping logs.
  defp emit_retry_telemetry(finch_request, pool) do
    :telemetry.execute(
      [:akaw, :request, :retry],
      %{count: 1},
      %{
        host: finch_request.host,
        port: finch_request.port,
        method: finch_request.method,
        path: finch_request.path,
        pool: pool
      }
    )
  end

  defp url_for_log(finch_request) do
    "#{finch_request.scheme}://#{finch_request.host}:#{finch_request.port}#{finch_request.path}"
  end

  # Finch 0.23 wraps Mint's exception (%Finch.TransportError{reason:
  # :closed, source: %Mint.TransportError{...}}); earlier versions
  # surfaced Mint's struct directly. Match both so a Finch bump can't
  # silently disable the policy — the exact drift class that bit the
  # error-reason strings once already.
  defp closed_socket?(%Finch.TransportError{reason: :closed}), do: true
  defp closed_socket?(%Mint.TransportError{reason: :closed}), do: true
  defp closed_socket?(_), do: false

  # ---------------------------------------------------------------------
  # Response handling
  # ---------------------------------------------------------------------

  # A HEAD response has no body to inflate or decode, but it may still
  # carry the content headers the body *would* have had (content-encoding
  # included) — running it through decompress would try to gunzip "".
  defp handle_response({:ok, %Finch.Response{} = response}, return_kind, "HEAD") do
    decode_and_wrap(%Finch.Response{response | body: ""}, return_kind)
  end

  defp handle_response({:ok, %Finch.Response{} = response}, return_kind, _method) do
    case decompress(response) do
      {:ok, response} -> decode_and_wrap(response, return_kind)
      {:error, _} = error -> error
    end
  end

  # The rescued checkout-exhaustion raise (see run_finch/3). Its own tag,
  # not "transport_error": the network is fine — the client-side pool is
  # saturated, and the remedies (bigger pool, fewer concurrent calls,
  # longer :pool_timeout) are different in kind from transport remedies.
  defp handle_response({:error, %RuntimeError{} = exception}, _return_kind, _method) do
    {:error,
     %Error{
       status: nil,
       error: "pool_timeout",
       reason: Exception.message(exception),
       body: %{exception: exception}
     }}
  end

  defp handle_response({:error, exception}, _return_kind, _method),
    do: {:error, Error.wrap_transport(exception)}

  defp decode_and_wrap(%Finch.Response{status: status} = response, return_kind)
       when status in 200..299 do
    case decode_body(response) do
      {:ok, body} ->
        case return_kind do
          :body -> {:ok, body}
          :response -> {:ok, %Response{status: status, headers: response.headers, body: body}}
        end

      {:error, _} = error ->
        error
    end
  end

  defp decode_and_wrap(%Finch.Response{status: status} = response, _return_kind) do
    # Error bodies decode on the same content-type terms (the probe pins
    # that CouchDB serves them as application/json) — but a *corrupt*
    # error body keeps its status and raw bytes rather than collapsing
    # into a status-less decode_error: the 404 is the signal, the body
    # is garnish.
    body =
      case decode_body(response) do
        {:ok, decoded} -> decoded
        {:error, _} -> response.body
      end

    {:error, build_error(status, body)}
  end

  # Response JSON decodes with the OTP-native JSON module, gated on the
  # content-type CouchDB declares. The probe (content_type_probe_test)
  # pins the facts that make the gate safe: every JSON endpoint class
  # answers application/json even with no Accept header, and the
  # not-JSON classes (attachments, eventsource, design functions)
  # declare themselves. A 200 whose declared-JSON body fails to decode
  # is not a network problem: it classifies as "decode_error", never
  # "transport_error" — a caller following the documented
  # retry-on-transport pattern must not spin on a permanently corrupt
  # endpoint (a proxy truncating responses, a misbehaving middlebox).
  defp decode_body(%Finch.Response{body: body} = response) do
    if json_content_type?(response.headers) and body not in [nil, ""] do
      {:ok, JSON.decode!(body)}
    else
      {:ok, body}
    end
  rescue
    exception in JSON.DecodeError ->
      {:error,
       %Error{
         status: nil,
         error: "decode_error",
         reason: Exception.message(exception),
         body: %{exception: exception}
       }}
  end

  defp json_content_type?(headers) do
    case header_value(headers, "content-type") do
      nil ->
        false

      value ->
        value
        |> String.split(";", parts: 2)
        |> hd()
        |> String.trim()
        |> String.downcase() == "application/json"
    end
  end

  # gzip is the only encoding akaw ever advertises, so it's the only one
  # handled. The content-encoding/content-length headers describe bytes
  # that no longer exist after inflation and are dropped with them. A
  # body that fails to inflate classifies like any other corrupt payload.
  defp decompress(%Finch.Response{} = response) do
    case header_value(response.headers, "content-encoding") do
      encoding when encoding in ["gzip", "x-gzip"] ->
        inflated = :zlib.gunzip(response.body)

        headers =
          Enum.reject(response.headers, fn {name, _value} ->
            String.downcase(name) in ["content-encoding", "content-length"]
          end)

        {:ok, %Finch.Response{response | body: inflated, headers: headers}}

      _ ->
        {:ok, response}
    end
  rescue
    _corrupt in ErlangError ->
      {:error,
       %Error{
         status: nil,
         error: "decode_error",
         reason: "response declared content-encoding gzip but failed to inflate",
         body: %{}
       }}
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {header_name, value} ->
      String.downcase(header_name) == name && value
    end)
  end

  defp build_error(status, %{"error" => error, "reason" => reason} = body) do
    %Error{status: status, error: error, reason: reason, body: body}
  end

  defp build_error(status, body) do
    %Error{status: status, body: body}
  end
end
