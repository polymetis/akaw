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

  alias Akaw.{Client, Request, Path}

  @doc """
  Make a request through a `_rewrite` rule.

  `path` is appended verbatim to `/{db}/_design/{ddoc}/_rewrite/`; it is
  **not** URL-encoded, since rewrite paths often contain literal `/`,
  query strings, and other path components that the rules match on.

  > #### Verbatim means verbatim {: .warning}
  >
  > Because nothing is encoded, `path` is the one place in Akaw where a
  > caller-supplied string can reshape the request URL — `../`
  > segments, `?`, and `#` all reach the wire as-is. Never build it
  > from untrusted input; if a user-supplied fragment must appear in a
  > rewrite path, percent-encode that fragment yourself —
  > `URI.encode(fragment, &URI.char_unreserved?/1)`, the same predicate
  > Akaw uses for path segments — before splicing it in. (Not
  > `URI.encode_www_form/1`: form encoding turns spaces into `+`,
  > which stays a literal `+` in path context.)

  ## Options

    * `:method` — `:get` (default), any other HTTP verb atom (`:post`,
      `:put`, `:delete`, `:head`, `:patch`, `:options`), or a string for a
      non-standard verb
    * `:body` — request body, sent as JSON. Requires a method that carries
      one: passing a body with `method: :get` raises `ArgumentError`, since
      a rewrite rule pinned to `"method": "GET"` would stop matching. Use
      `method: :post`, or the string `method: "GET"` to send a GET that
      carries a body verbatim.
    * `:params` — query-string parameters. These **override** same-named
      params already present in `path` rather than appending to them.
  """
  @spec call(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call(%Client{} = client, db, ddoc, path, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(path) do
    {method, opts} = Keyword.pop(opts, :method, :get)
    {body, opts} = Keyword.pop(opts, :body)
    {params, _opts} = Keyword.pop(opts, :params, [])

    full = "/#{Path.encode(db)}/_design/#{Path.encode(ddoc)}/_rewrite/#{path}"

    req_opts = [params: params]
    req_opts = if body, do: [{:json, body} | req_opts], else: req_opts

    Request.request(client, method, full, req_opts)
  end
end
