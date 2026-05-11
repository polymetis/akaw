defmodule Akaw.DesignDoc.Shows do
  @moduledoc """
  CouchDB `_show` design-doc functions
  (`/{db}/_design/{ddoc}/_show/{func}[/{docid}]`).

  Show functions transform a single document (or none) into an arbitrary
  HTTP response — useful for rendering HTML, CSV, plain text, or any
  non-JSON payload. The function lives inside a design doc's `shows`
  field.

  This is **legacy**. CouchDB has been steering users toward Mango (`_find`)
  and views for new development; show functions are mostly here for
  compatibility with existing apps.

  ## Response type

  The result type depends entirely on what the show function returns:
  Req auto-decodes responses with a JSON content-type into maps, and
  leaves everything else as a binary. Either lands in `{:ok, body}`.

  See <https://docs.couchdb.org/en/latest/api/ddoc/render.html#db-design-design-doc-show-show-name>.
  """

  alias Akaw.{Client, Request}

  @doc """
  Run a show function.

  ## Options

    * `:doc_id` — invoke the show against a specific document
      (`_show/{func}/{docid}`) rather than `_show/{func}`
    * `:method` — `:get` (default) or `:post`
    * `:body` — request body (only meaningful for `:post`)
    * `:params` — query-string parameters forwarded verbatim
  """
  @spec call(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call(%Client{} = client, db, ddoc, func, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(func) do
    {doc_id, opts} = Keyword.pop(opts, :doc_id)
    {method, opts} = Keyword.pop(opts, :method, :get)
    {body, opts} = Keyword.pop(opts, :body)
    {params, _opts} = Keyword.pop(opts, :params, [])

    path = build_path(db, ddoc, func, doc_id)
    req_opts = [params: params]
    req_opts = if body, do: [{:json, body} | req_opts], else: req_opts

    Request.request(client, method, path, req_opts)
  end

  defp build_path(db, ddoc, func, nil),
    do: "/#{encode(db)}/_design/#{encode(ddoc)}/_show/#{encode(func)}"

  defp build_path(db, ddoc, func, doc_id),
    do: "/#{encode(db)}/_design/#{encode(ddoc)}/_show/#{encode(func)}/#{encode_id(doc_id)}"

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp encode_id("_design/" <> rest), do: "_design/" <> encode(rest)
  defp encode_id("_local/" <> rest), do: "_local/" <> encode(rest)
  defp encode_id(id), do: encode(id)
end
