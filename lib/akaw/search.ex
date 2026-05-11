defmodule Akaw.Search do
  @moduledoc """
  Lucene-based full-text search via the Clouseau plugin
  (`/{db}/_design/{ddoc}/_search/{index}`).

  Requires CouchDB to be built with the Clouseau full-text search plugin
  enabled. Stock CouchDB does not ship it; on a vanilla install these
  endpoints return 500 ("`text_search_disabled`"). For the modern
  alternative see `Akaw.Nouveau`.

  ## Query parameters

  JSON-typed parameters (`startkey`, `endkey`, `key`, `sort`, `ranges`,
  `drilldown`, `counts`, `group_sort`) are auto-encoded — pass raw values:

      Akaw.Search.search(client, "products", "by_name", "main",
        query: "running shoes",
        sort: ["price"],
        limit: 25
      )

  See <https://docs.couchdb.org/en/latest/api/ddoc/search.html>.
  """

  alias Akaw.{Client, Params, Request, Path}

  @doc """
  `GET /{db}/_design/{ddoc}/_search/{index}` — run a full-text search.

  ## Common options

    * `:query` (or `:q`) — the Lucene query string
    * `:limit`, `:bookmark`, `:include_docs`
    * `:sort` — list of fields; auto JSON-encoded
    * `:ranges` — facet ranges; auto JSON-encoded
    * `:drilldown` — facet drilldowns; auto JSON-encoded
    * `:counts`, `:group_sort` — auto JSON-encoded
    * `:highlight_fields`, `:highlight_pre_tag`, `:highlight_post_tag`,
      `:highlight_number`, `:highlight_size`
    * `:stale`
  """
  @spec search(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def search(%Client{} = client, db, ddoc, index, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(index) do
    Request.request(
      client,
      :get,
      "/#{Path.encode(db)}/_design/#{Path.encode(ddoc)}/_search/#{Path.encode(index)}",
      params: Params.encode_search_keys(opts)
    )
  end

  @doc """
  `GET /{db}/_design/{ddoc}/_search_info/{index}` — index statistics
  (committed seq, disk size, doc counts, etc.).
  """
  @spec info(Client.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def info(%Client{} = client, db, ddoc, index)
      when is_binary(db) and is_binary(ddoc) and is_binary(index) do
    Request.request(
      client,
      :get,
      "/#{Path.encode(db)}/_design/#{Path.encode(ddoc)}/_search_info/#{Path.encode(index)}"
    )
  end
end
