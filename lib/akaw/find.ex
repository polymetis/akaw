defmodule Akaw.Find do
  @moduledoc """
  Mango query endpoints (`_find`, `_index`, `_explain`).

  Mango is CouchDB's MongoDB-style declarative query language. `find/4`
  runs a query, `create_index/4` and friends manage the indexes that back
  Mango selectors, and `explain/3` returns the query plan.

  See <https://docs.couchdb.org/en/latest/api/database/find.html>.
  """

  alias Akaw.{Client, Request, Path}

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

  For large result sets there are two streaming flavors: `stream_find/3`
  (lazy `Enumerable.t()`; consumes the caller's mailbox) and
  `reduce_while/5` (synchronous callback; real TCP backpressure and safe
  from a GenServer or LiveView).
  """
  @spec find(Client.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def find(%Client{} = client, db, query) when is_binary(db) and is_map(query) do
    Request.request(client, :post, "/#{Path.encode(db)}/_find", json: query)
  end

  @doc """
  Streaming counterpart to `find/3` — emits one decoded document per element.

  Useful when a Mango selector matches more documents than fit comfortably
  in memory. Note that `bookmark`, `warning`, and `execution_stats` (which
  appear after the `docs` array in the non-streaming response) are not
  surfaced by this stream — call `find/3` directly if you need them.
  """
  @spec stream_find(Client.t(), String.t(), map()) :: Enumerable.t(map())
  def stream_find(%Client{} = client, db, query)
      when is_binary(db) and is_map(query) do
    Akaw.Streaming.chunks(client, :post, "/#{Path.encode(db)}/_find", json: query)
    |> Akaw.JsonItemStream.items()
  end

  @doc """
  Callback variant of `stream_find/3` — runs the reducer synchronously
  inside the HTTP read loop. Backpressured (blocking in `reducer` stalls
  CouchDB) and safe from a GenServer / LiveView since it doesn't use the
  calling process's mailbox.

  The reducer returns `{:cont, acc}` to continue or `{:halt, acc}` to
  stop early. Returns `{:ok, final_acc}` or `{:error, %Akaw.Error{}}`.

  `opts` accepts the Req-level escape hatches `:receive_timeout`,
  `:pool_timeout`, `:connect_options`; everything else is ignored
  (Mango doesn't take query params besides the body).
  """
  @spec reduce_while(
          Client.t(),
          String.t(),
          map(),
          acc,
          (map(), acc -> {:cont, acc} | {:halt, acc}),
          keyword()
        ) :: {:ok, acc} | {:error, Akaw.Error.t()}
        when acc: term()
  def reduce_while(%Client{} = client, db, query, acc, reducer, opts \\ [])
      when is_binary(db) and is_map(query) and is_function(reducer, 2) do
    {req_opts, _} = Akaw.Streaming.split_req_opts(opts)

    Akaw.Streaming.reduce_items_while(
      client,
      :post,
      "/#{Path.encode(db)}/_find",
      [json: query] ++ req_opts,
      acc,
      reducer
    )
  end

  @doc """
  `POST /{db}/_explain` — return the query plan CouchDB would use for the
  given Mango query (which index, range, etc.) without executing it.
  """
  @spec explain(Client.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def explain(%Client{} = client, db, query) when is_binary(db) and is_map(query) do
    Request.request(client, :post, "/#{Path.encode(db)}/_explain", json: query)
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
    Request.request(client, :post, "/#{Path.encode(db)}/_index", json: index_def)
  end

  @doc "`GET /{db}/_index` — list the Mango indexes on the database."
  @spec list_indexes(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def list_indexes(%Client{} = client, db) when is_binary(db) do
    Request.request(client, :get, "/#{Path.encode(db)}/_index")
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
      "/#{Path.encode(db)}/_index/#{Path.encode(ddoc)}/#{Path.encode(type)}/#{Path.encode(name)}"
    )
  end
end
