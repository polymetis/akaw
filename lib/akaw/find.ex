defmodule Akaw.Find do
  @moduledoc """
  Mango query endpoints (`_find`, `_index`, `_explain`).

  Mango is CouchDB's MongoDB-style declarative query language. `find/4`
  runs a query, `create_index/4` and friends manage the indexes that back
  Mango selectors, and `explain/3` returns the query plan.

  See <https://docs.couchdb.org/en/latest/api/database/find.html>.
  """

  alias Akaw.{Client, Request}

  @doc """
  `POST /{db}/_find` — run a Mango query.

  `query` is the full Mango request body — at minimum a `selector`. Other
  common keys: `fields`, `sort`, `limit`, `skip`, `bookmark`, `use_index`,
  `r`, `conflicts`, `update`, `stable`, `stale`, `execution_stats`.

      Akaw.Find.find(client, "users", %{
        selector: %{age: %{"$gt" => 21}},
        fields: ["_id", "name"],
        sort: [%{age: "asc"}],
        limit: 25
      })

  For large result sets use `stream_find/3` to avoid buffering the full
  response.
  """
  @spec find(Client.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def find(%Client{} = client, db, query) when is_binary(db) and is_map(query) do
    Request.request(client, :post, "/#{encode(db)}/_find", json: query)
  end

  @doc """
  Streaming counterpart to `find/3` — emits one decoded document per element.

  Useful when a Mango selector matches more documents than fit comfortably
  in memory. Note that `bookmark`, `warning`, and `execution_stats` (which
  appear after the `docs` array in the non-streaming response) are not
  surfaced by this stream — call `find/3` directly if you need them.
  """
  @spec stream_find(Client.t(), String.t(), map()) :: Enumerable.t()
  def stream_find(%Client{} = client, db, query)
      when is_binary(db) and is_map(query) do
    Akaw.Streaming.chunks(client, :post, "/#{encode(db)}/_find", json: query)
    |> Akaw.JsonItemStream.items()
  end

  @doc """
  `POST /{db}/_explain` — return the query plan CouchDB would use for the
  given Mango query (which index, range, etc.) without executing it.
  """
  @spec explain(Client.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def explain(%Client{} = client, db, query) when is_binary(db) and is_map(query) do
    Request.request(client, :post, "/#{encode(db)}/_explain", json: query)
  end

  @doc """
  `POST /{db}/_index` — create a Mango index.

  `index_def` is the full body — typically:

      %{
        index: %{fields: ["name", "email"]},
        name: "by_name_email",
        type: "json"
      }
  """
  @spec create_index(Client.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_index(%Client{} = client, db, index_def)
      when is_binary(db) and is_map(index_def) do
    Request.request(client, :post, "/#{encode(db)}/_index", json: index_def)
  end

  @doc "`GET /{db}/_index` — list the Mango indexes on the database."
  @spec list_indexes(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def list_indexes(%Client{} = client, db) when is_binary(db) do
    Request.request(client, :get, "/#{encode(db)}/_index")
  end

  @doc """
  `DELETE /{db}/_index/{ddoc}/{type}/{name}` — remove a Mango index.

  `type` is `"json"` (default) or `"text"` (for full-text indexes).
  """
  @spec delete_index(Client.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def delete_index(%Client{} = client, db, ddoc, type \\ "json", name)
      when is_binary(db) and is_binary(ddoc) and is_binary(type) and is_binary(name) do
    Request.request(
      client,
      :delete,
      "/#{encode(db)}/_index/#{encode(ddoc)}/#{type}/#{encode(name)}"
    )
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
