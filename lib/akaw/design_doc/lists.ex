defmodule Akaw.DesignDoc.Lists do
  @moduledoc """
  CouchDB `_list` design-doc functions
  (`/{db}/_design/{ddoc}/_list/{func}/{view}` or
   `/{db}/_design/{ddoc}/_list/{func}/{other-ddoc}/{view}`).

  List functions transform the rows of a view into an arbitrary HTTP
  response — useful for CSV exports, custom JSON shapes, RSS feeds, etc.

  This is **legacy**. Prefer views / Mango for new code; list functions
  are kept for compatibility with existing apps.

  See <https://docs.couchdb.org/en/latest/api/ddoc/render.html#db-design-design-doc-list-list-name-view-name>.
  """

  alias Akaw.{Client, Params, Request, Path}

  @doc """
  Run a list function against a view.

  `view` is either:

    * a string `"view_name"` — uses a view in the same design doc as the
      list function
    * a tuple `{"other_ddoc", "view_name"}` — uses a view in a different
      design doc

  ## Options

    * `:method` — `:get` (default) or `:post`
    * `:body` — request body (only meaningful for `:post`)
    * `:params` — query-string parameters; JSON-typed keys (`startkey`,
      `endkey`, `key`) are auto-encoded
  """
  @spec call(
          Client.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | {String.t(), String.t()},
          keyword()
        ) :: {:ok, term()} | {:error, term()}
  def call(%Client{} = client, db, ddoc, func, view, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(func) do
    {method, opts} = Keyword.pop(opts, :method, :get)
    {body, opts} = Keyword.pop(opts, :body)
    {params, _opts} = Keyword.pop(opts, :params, [])

    path = build_path(db, ddoc, func, view)

    req_opts = [params: Params.encode_json_keys(params)]
    req_opts = if body, do: [{:json, body} | req_opts], else: req_opts

    Request.request(client, method, path, req_opts)
  end

  defp build_path(db, ddoc, func, {other_ddoc, view}) do
    "/#{Path.encode(db)}/_design/#{Path.encode(ddoc)}/_list/#{Path.encode(func)}/#{Path.encode(other_ddoc)}/#{Path.encode(view)}"
  end

  defp build_path(db, ddoc, func, view) when is_binary(view) do
    "/#{Path.encode(db)}/_design/#{Path.encode(ddoc)}/_list/#{Path.encode(func)}/#{Path.encode(view)}"
  end
end
