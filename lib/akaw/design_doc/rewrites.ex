defmodule Akaw.DesignDoc.Rewrites do
  @moduledoc """
  CouchDB `_rewrite` design-doc rules
  (`/{db}/_design/{ddoc}/_rewrite/{path}`).

  Rewrites turn a URL inside `_rewrite/...` into another CouchDB resource
  according to rules defined in the design doc's `rewrites` field
  (either a list of `{"from": "...", "to": "..."}` rules or, in older
  CouchDB versions, a JavaScript function).

  This is **legacy** and somewhat restricted in CouchDB 3+ (function-form
  rewrites are disabled by default). Prefer reverse-proxy / load-balancer
  level routing for new deployments.

  See <https://docs.couchdb.org/en/latest/api/ddoc/rewrites.html>.
  """

  alias Akaw.{Client, Request}

  @doc """
  Make a request through a `_rewrite` rule.

  `path` is appended verbatim to `/{db}/_design/{ddoc}/_rewrite/`; it is
  **not** URL-encoded, since rewrite paths often contain literal `/`,
  query strings, and other path components that the rules match on.

  ## Options

    * `:method` — `:get` (default), or anything else accepted by
      `Akaw.Request`
    * `:body` — request body (sent as JSON if given)
    * `:params` — query-string parameters forwarded verbatim
  """
  @spec call(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call(%Client{} = client, db, ddoc, path, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(path) do
    {method, opts} = Keyword.pop(opts, :method, :get)
    {body, opts} = Keyword.pop(opts, :body)
    {params, _opts} = Keyword.pop(opts, :params, [])

    full = "/#{encode(db)}/_design/#{encode(ddoc)}/_rewrite/#{path}"

    req_opts = [params: params]
    req_opts = if body, do: [{:json, body} | req_opts], else: req_opts

    Request.request(client, method, full, req_opts)
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
