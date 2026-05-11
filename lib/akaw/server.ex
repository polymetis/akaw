defmodule Akaw.Server do
  @moduledoc """
  Server-level CouchDB endpoints — endpoints that operate on the CouchDB
  instance as a whole, rather than on a particular database.

  See <https://docs.couchdb.org/en/latest/api/server/common.html>.
  """

  alias Akaw.{Client, Request}

  @doc """
  `GET /` — meta information about the CouchDB instance.

  See <https://docs.couchdb.org/en/latest/api/server/common.html#get--->.
  """
  @spec info(Client.t()) :: {:ok, map()} | {:error, term()}
  def info(%Client{} = client), do: Request.request(client, :get, "/")

  @doc """
  `GET /_up` — confirms the server is up, running, and ready to respond.

  Returns `{:ok, %{"status" => "ok"}}` on success. CouchDB returns 404 if the
  server is in maintenance mode.

  See <https://docs.couchdb.org/en/latest/api/server/common.html#up>.
  """
  @spec up(Client.t()) :: {:ok, map()} | {:error, term()}
  def up(%Client{} = client), do: Request.request(client, :get, "/_up")

  @doc """
  `GET /_uuids` — server-generated UUIDs.

  ## Options

    * `:count` — number of UUIDs to return (default 1; server-side max is
      governed by the `[uuids] max_count` config).

  See <https://docs.couchdb.org/en/latest/api/server/common.html#uuids>.
  """
  @spec uuids(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def uuids(%Client{} = client, opts \\ []) do
    Request.request(client, :get, "/_uuids", params: opts)
  end

  @doc """
  `GET /_all_dbs` — list of all databases on the instance.

  ## Options

    * `:descending`, `:endkey`, `:limit`, `:skip`, `:startkey` — passed
      through as query parameters.

  See <https://docs.couchdb.org/en/latest/api/server/common.html#all-dbs>.
  """
  @spec all_dbs(Client.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def all_dbs(%Client{} = client, opts \\ []) do
    Request.request(client, :get, "/_all_dbs", params: opts)
  end

  @doc """
  `POST /_dbs_info` — information for a list of databases.

  CouchDB returns up to 100 entries per request.

  ## Examples

      Akaw.Server.dbs_info(client, ["users", "orders"])

  See <https://docs.couchdb.org/en/latest/api/server/common.html#dbs-info>.
  """
  @spec dbs_info(Client.t(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def dbs_info(%Client{} = client, dbs) when is_list(dbs) do
    Request.request(client, :post, "/_dbs_info", json: %{keys: dbs})
  end

  @doc """
  `GET /_active_tasks` — list of currently running internal tasks
  (compaction, replication, indexing, …).

  See <https://docs.couchdb.org/en/latest/api/server/common.html#active-tasks>.
  """
  @spec active_tasks(Client.t()) :: {:ok, [map()]} | {:error, term()}
  def active_tasks(%Client{} = client),
    do: Request.request(client, :get, "/_active_tasks")

  @doc """
  `POST /_replicate` — request, configure, or stop a replication operation.

  The `body` map is sent as the JSON request body. See the CouchDB docs for
  the full schema (source, target, continuous, doc_ids, filter, …).

  See <https://docs.couchdb.org/en/latest/api/server/common.html#replicate>.
  """
  @spec replicate(Client.t(), map()) :: {:ok, map()} | {:error, term()}
  def replicate(%Client{} = client, body) when is_map(body) do
    Request.request(client, :post, "/_replicate", json: body)
  end

  @doc """
  `GET /_db_updates` — feed of database-level events (created, updated,
  deleted) across the instance.

  ## Options

    * `:feed` — `"normal"` (default), `"longpoll"`, `"continuous"`,
      `"eventsource"`
    * `:timeout`, `:heartbeat`, `:since` — passed through as query params

  > #### Streaming feeds {: .warning}
  >
  > For `feed: "continuous"` use `stream_db_updates/2` instead — the
  > response is unbounded and will fill memory if buffered.

  See <https://docs.couchdb.org/en/latest/api/server/common.html#db-updates>.
  """
  @spec db_updates(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def db_updates(%Client{} = client, opts \\ []) do
    Request.request(client, :get, "/_db_updates", params: opts)
  end

  @doc """
  Stream the `_db_updates` continuous feed — db-level lifecycle events
  (created, updated, deleted) across the entire cluster, as a lazy
  `Stream` of decoded event maps.

  Same shape as `Akaw.Changes.stream/3` but operates at the server level.
  `:feed` is forced to `"continuous"`. Errors raise during enumeration.
  """
  @spec stream_db_updates(Client.t(), keyword()) :: Enumerable.t(map())
  def stream_db_updates(%Client{} = client, opts \\ []) do
    params = Keyword.put(opts, :feed, "continuous")

    Akaw.Streaming.chunks(client, :get, "/_db_updates", params: params)
    |> Akaw.LineStream.lines()
    |> Stream.map(&JSON.decode!/1)
  end

  @doc """
  `GET /_membership` — node membership information for the cluster.

  See <https://docs.couchdb.org/en/latest/api/server/common.html#membership>.
  """
  @spec membership(Client.t()) :: {:ok, map()} | {:error, term()}
  def membership(%Client{} = client),
    do: Request.request(client, :get, "/_membership")

  @doc """
  `POST /_search_analyze` — run a Lucene analyzer over a piece of text
  without indexing. Useful for debugging full-text search ddocs.

  ## Example

      Akaw.Server.search_analyze(client, %{
        analyzer: "standard",
        text: "running shoes"
      })

  Available on clusters built with the Clouseau (Java) full-text search
  plugin.
  """
  @spec search_analyze(Client.t(), map()) :: {:ok, map()} | {:error, term()}
  def search_analyze(%Client{} = client, body) when is_map(body) do
    Request.request(client, :post, "/_search_analyze", json: body)
  end

  @doc """
  `POST /_nouveau_analyze` — analyzer test endpoint for the newer Nouveau
  search backend. Same shape as `search_analyze/2` but goes through
  Nouveau instead of Clouseau.
  """
  @spec nouveau_analyze(Client.t(), map()) :: {:ok, map()} | {:error, term()}
  def nouveau_analyze(%Client{} = client, body) when is_map(body) do
    Request.request(client, :post, "/_nouveau_analyze", json: body)
  end
end
