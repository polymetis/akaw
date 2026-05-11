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
      headers: headers
    ]
    |> apply_auth(client.auth)
    |> apply_finch(client.finch)
    |> Keyword.merge(req_options)
    |> Keyword.merge(opts)
    |> Req.new()
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
