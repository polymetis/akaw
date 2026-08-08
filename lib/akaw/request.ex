defmodule Akaw.Request do
  @moduledoc false

  alias Akaw.{Client, Error}

  # Standard HTTP method atoms accepted by Finch, plus a binary escape hatch
  # for non-standard verbs like "COPY" (CouchDB document copy).
  @type method ::
          :get | :post | :put | :delete | :head | :patch | :options | String.t()
  @type return_kind :: :body | :response

  @doc """
  Issue an HTTP request via Req.

  ## Internal options

    * `:return` — `:body` (default) returns `{:ok, decoded_body}`;
      `:response` returns `{:ok, %Req.Response{}}` so callers can inspect
      headers and status (used by `Akaw.Session` to capture the `AuthSession`
      cookie).

  Headers from `client.headers`, `client.req_options[:headers]`, and per-call
  `opts[:headers]` are concatenated in that order. If the same header name
  appears more than once, the later occurrence wins (per-call beats
  req_options beats client).

  Any other options are forwarded to `Req.new/1`.
  """
  @spec request(Client.t(), method(), String.t(), keyword()) ::
          {:ok, term()} | {:ok, Req.Response.t()} | {:error, Error.t() | Exception.t()}
  def request(%Client{} = client, method, path, opts \\ []) do
    {return_kind, opts} = Keyword.pop(opts, :return, :body)

    client
    |> build(method, path, opts)
    |> Req.request()
    |> handle_response(return_kind)
  end

  @doc """
  Like `request/4` but returns the raw `Req.request/1` result without
  wrapping non-2xx into `%Akaw.Error{}`.

  Used by `Akaw.Changes` for streaming opens, where the response body may
  be a `%Req.Response.Async{}` that needs special handling and the caller
  wants direct access to the response struct on every status.
  """
  @spec request_raw(Client.t(), method(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request_raw(%Client{} = client, method, path, opts \\ []) do
    client
    |> build(method, path, opts)
    |> Req.request()
  end

  defp build(client, method, path, opts) do
    {req_opt_headers, req_options} = Keyword.pop(client.req_options, :headers, [])
    {call_headers, opts} = Keyword.pop(opts, :headers, [])
    headers = combine_headers([client.headers, req_opt_headers, call_headers])

    [
      method: method,
      url: client.base_url <> path,
      headers: headers,
      # Req 0.6.1 made decompression opt-in, so without this akaw stopped
      # negotiating gzip and started pulling attachments uncompressed —
      # measured at 38x more bytes on the wire for a text/plain attachment
      # against CouchDB 3.5.1. Req's reason for the new default is
      # decompression-bomb DoS from arbitrary internet endpoints; akaw
      # only ever talks to the CouchDB you pointed it at, so opting back
      # in is the right default here. Please don't "fix" this back.
      #
      # It rides in the base list (not after the merges) so a caller can
      # still override it per-client or per-call with `compressed: false`.
      compressed: true
    ]
    |> apply_auth(client.auth)
    |> apply_finch(client.finch)
    |> Keyword.merge(req_options)
    |> Keyword.merge(opts)
    |> check_body_method!()
    |> normalize_finch()
    |> Req.new()
  end

  # Req 0.7 moved the Finch knobs behind a `finch: [...]` keyword and
  # deprecated the flat spellings, emitting an IO.warn *per request* —
  # measured at ~0.3ms each, which roughly doubled akaw's client-side
  # per-request cost for anyone using a named pool.
  #
  # akaw keeps its friendly flat public API (`Akaw.new(finch: MyApp.Finch)`,
  # `pool_timeout: 5_000`) and translates here instead. This runs last, after
  # the req_options and per-call merges, so it also catches a `:finch` a
  # caller set directly through `:req_options`.
  #
  # `:receive_timeout` and `:connect_options` are NOT deprecated and stay
  # flat — don't "helpfully" fold those in too.
  defp normalize_finch(opts) do
    opts
    |> normalize_finch_name()
    |> fold_finch_request_opts()
  end

  defp normalize_finch_name(opts) do
    case Keyword.get(opts, :finch) do
      nil -> opts
      name when is_atom(name) -> Keyword.put(opts, :finch, name: name)
      _already_keyword -> opts
    end
  end

  # `:pool_timeout` belongs inside `finch: [...]` now — except alongside
  # `:connect_options`, where Req raises if `:finch` is present at all
  # (`finch.ex`: "cannot set both :finch and :connect_options"). There we
  # leave it flat and let Req's deprecation warning stand, rather than
  # turning a warning into a crash.
  defp fold_finch_request_opts(opts) do
    if Keyword.has_key?(opts, :connect_options) do
      opts
    else
      case Keyword.split(opts, [:pool_timeout]) do
        {[], _} -> opts
        {flat, rest} -> Keyword.update(rest, :finch, flat, &Keyword.merge(&1, flat))
      end
    end
  end

  # Req option keys that end up setting `%Req.Request{}.body`.
  @body_opts [:json, :body, :form, :form_multipart]

  # Req 0.7's `encode_body` step silently rewrites a GET carrying a body
  # into a POST. For a CouchDB client that is never the right answer: a
  # `_rewrite` rule pinned to `"method": "GET"` stops matching and 404s,
  # and a `_show`/`_list` function branching on `req.method` quietly
  # takes the other branch without erroring at all.
  #
  # So akaw decides its own verb rather than inheriting Req's. Every
  # akaw-internal body-bearing call already pins an explicit `:post` or
  # `:put`; the only way to reach this is a caller passing `method: :get`
  # to `DesignDoc.Shows/Lists/Rewrites/Updates`, which the first three
  # already document as "only meaningful for `:post`".
  defp check_body_method!(opts) do
    if Keyword.get(opts, :method) == :get do
      case Enum.find(@body_opts, &(Keyword.get(opts, &1) != nil)) do
        nil -> opts
        key -> raise ArgumentError, body_method_message(key)
      end
    else
      opts
    end
  end

  defp body_method_message(key) do
    """
    cannot send a request body with `method: :get` — Req would silently \
    rewrite the request to POST, changing which CouchDB handler runs.

    Got `#{inspect(key)}` alongside `method: :get`.

    Either pass `method: :post` (what the `:body` option is documented for), \
    or pass the method as a string — `method: "GET"` — if you really do want \
    a GET that carries a body, which CouchDB accepts and akaw sends verbatim.\
    """
  end

  defp combine_headers(lists) do
    lists
    |> Enum.concat()
    |> Enum.reverse()
    |> Enum.uniq_by(fn {name, _value} -> String.downcase(name) end)
    |> Enum.reverse()
  end

  defp apply_auth(opts, nil), do: opts

  defp apply_auth(opts, {:basic, user, pass}),
    do: Keyword.put(opts, :auth, {:basic, "#{user}:#{pass}"})

  defp apply_auth(opts, {:bearer, token}),
    do: Keyword.put(opts, :auth, {:bearer, token})

  defp apply_finch(opts, nil), do: opts
  defp apply_finch(opts, name), do: Keyword.put(opts, :finch, name)

  defp handle_response({:ok, %Req.Response{status: status} = resp}, return_kind)
       when status in 200..299 do
    case return_kind do
      :body -> {:ok, resp.body}
      :response -> {:ok, resp}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _return_kind),
    do: {:error, build_error(status, body)}

  defp handle_response({:error, exception}, _return_kind),
    do: {:error, Error.wrap_transport(exception)}

  defp build_error(status, %{"error" => error, "reason" => reason} = body) do
    %Error{status: status, error: error, reason: reason, body: body}
  end

  defp build_error(status, body) do
    %Error{status: status, body: body}
  end
end
