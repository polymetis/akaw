defmodule Akaw.Nouveau do
  @moduledoc """
  Full-text search via the Nouveau plugin
  (`/{db}/_design/{ddoc}/_nouveau/{index}`).

  Nouveau is CouchDB's newer search backend, intended to replace Clouseau.
  Requires the Nouveau plugin to be enabled on the cluster; stock CouchDB
  does not ship it.

  ## Query parameters

  JSON-typed params (`sort`, `ranges`, etc.) are auto-encoded — same set
  as `Akaw.Search` since the parameter names overlap.

  See <https://docs.couchdb.org/en/latest/ddocs/search.html#nouveau>.
  """

  alias Akaw.{Client, Params, Request, Path}

  @doc """
  `GET /{db}/_design/{ddoc}/_nouveau/{index}` — run a Nouveau full-text
  query.

  ## Common options

    * `:q` (or `:query`) — the Lucene-style query string
    * `:limit`, `:bookmark`, `:include_docs`
    * `:sort` — auto JSON-encoded
    * `:ranges` — auto JSON-encoded
    * `:counts`, `:drilldown`, `:group_sort` — auto JSON-encoded
    * `:highlight_fields`, and the associated `:highlight_*` tuning knobs
  """
  @spec search(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def search(%Client{} = client, db, ddoc, index, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(index) do
    Request.request(
      client,
      :get,
      "/#{Path.encode(db)}/_design/#{Path.encode(ddoc)}/_nouveau/#{Path.encode(index)}",
      params: Params.encode_search_keys(opts)
    )
  end

  @doc """
  `GET /{db}/_design/{ddoc}/_nouveau_info/{index}` — Nouveau index
  statistics.
  """
  @spec info(Client.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def info(%Client{} = client, db, ddoc, index)
      when is_binary(db) and is_binary(ddoc) and is_binary(index) do
    Request.request(
      client,
      :get,
      "/#{Path.encode(db)}/_design/#{Path.encode(ddoc)}/_nouveau_info/#{Path.encode(index)}"
    )
  end
end
