defmodule Akaw.DesignDoc.Updates do
  @moduledoc """
  CouchDB `_update` design-doc functions
  (`/{db}/_design/{ddoc}/_update/{func}[/{docid}]`).

  Update functions run server-side code to transform / create / delete a
  document and produce an arbitrary HTTP response. Compared to a normal
  `Akaw.Document.put/5`, this lets the server compute the new doc shape
  rather than the client.

  This is **legacy**. Most apps now prefer client-side computation +
  bulk_docs, but update functions still ship in CouchDB.

  See <https://docs.couchdb.org/en/latest/api/ddoc/render.html#db-design-design-doc-update-update-name>.
  """

  alias Akaw.{Client, Request, Path}

  @doc """
  Invoke an update function.

  ## Options

    * `:doc_id` — invoke against a specific document
      (`_update/{func}/{docid}`). Without it, the function runs without
      a target doc.
    * `:method` — `:post` (default) or `:put`
    * `:body` — request body (defaults to `%{}` so CouchDB sees
      `Content-Type: application/json`)
    * `:params` — query-string parameters forwarded verbatim
  """
  @spec call(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call(%Client{} = client, db, ddoc, func, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(func) do
    {doc_id, opts} = Keyword.pop(opts, :doc_id)
    {method, opts} = Keyword.pop(opts, :method, :post)
    {body, opts} = Keyword.pop(opts, :body, %{})
    {params, _opts} = Keyword.pop(opts, :params, [])

    path = build_path(db, ddoc, func, doc_id)
    Request.request(client, method, path, json: body, params: params)
  end

  defp build_path(db, ddoc, func, nil),
    do: "/#{Path.encode(db)}/_design/#{Path.encode(ddoc)}/_update/#{Path.encode(func)}"

  defp build_path(db, ddoc, func, doc_id),
    do:
      "/#{Path.encode(db)}/_design/#{Path.encode(ddoc)}/_update/#{Path.encode(func)}/#{Path.encode_id(doc_id)}"
end
