defmodule Akaw.Database do
  @moduledoc """
  Database-level CouchDB endpoints — operations that target a single
  database (`/{db}`).

  Maintenance operations (compact, view_cleanup, ensure_full_commit,
  revs_limit) live alongside the basic CRUD here; security and purge live in
  their own modules (`Akaw.Security`, `Akaw.Purge`) since they're separate
  enough concerns. Document operations live in `Akaw.Document`,
  `Akaw.Documents`, and `Akaw.Attachment`.

  See <https://docs.couchdb.org/en/latest/api/database/common.html>.
  """

  alias Akaw.{Client, Request}

  @doc """
  `HEAD /{db}` — check whether a database exists.

  Returns `:ok` for HTTP 200 and `{:error, %Akaw.Error{status: 404}}` if the
  database is missing.
  """
  @spec head(Client.t(), String.t()) :: :ok | {:error, term()}
  def head(%Client{} = client, db) when is_binary(db) do
    case Request.request(client, :head, "/" <> encode(db)) do
      {:ok, _body} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  `GET /{db}` — metadata about the database (size, doc count, update_seq, …).
  """
  @spec info(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def info(%Client{} = client, db) when is_binary(db) do
    Request.request(client, :get, "/" <> encode(db))
  end

  @doc """
  `PUT /{db}` — create a new database.

  ## Options

    * `:q` — number of shards (cluster only)
    * `:n` — replicas per shard (cluster only)
    * `:partitioned` — `true` to enable partitioned mode

  Returns `{:error, %Akaw.Error{status: 412}}` if the database already
  exists.
  """
  @spec create(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(%Client{} = client, db, opts \\ []) when is_binary(db) do
    Request.request(client, :put, "/" <> encode(db), params: opts)
  end

  @doc """
  `DELETE /{db}` — delete a database (and all its documents).
  """
  @spec delete(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete(%Client{} = client, db) when is_binary(db) do
    Request.request(client, :delete, "/" <> encode(db))
  end

  @doc """
  `POST /{db}` — create a new document with a server-generated UUID.

  For PUT-with-known-id, see `Akaw.Document.put/4`.
  """
  @spec post(Client.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def post(%Client{} = client, db, doc) when is_binary(db) and is_map(doc) do
    Request.request(client, :post, "/" <> encode(db), json: doc)
  end

  @doc """
  `POST /{db}/_compact` — start a compaction of the database.
  """
  @spec compact(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def compact(%Client{} = client, db) when is_binary(db) do
    Request.request(client, :post, "/" <> encode(db) <> "/_compact")
  end

  @doc """
  `POST /{db}/_compact/{ddoc}` — compact a specific design document's view
  indexes.
  """
  @spec compact_views(Client.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def compact_views(%Client{} = client, db, ddoc)
      when is_binary(db) and is_binary(ddoc) do
    Request.request(client, :post, "/#{encode(db)}/_compact/#{encode(ddoc)}")
  end

  @doc """
  `POST /{db}/_view_cleanup` — remove view files no longer required.
  """
  @spec view_cleanup(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def view_cleanup(%Client{} = client, db) when is_binary(db) do
    Request.request(client, :post, "/" <> encode(db) <> "/_view_cleanup")
  end

  @doc """
  `POST /{db}/_ensure_full_commit` — flush headers to disk.

  Note: as of CouchDB 3.x this endpoint is a no-op (commits are
  synchronous), but it's still wired up for older clusters.
  """
  @spec ensure_full_commit(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def ensure_full_commit(%Client{} = client, db) when is_binary(db) do
    Request.request(client, :post, "/" <> encode(db) <> "/_ensure_full_commit")
  end

  @doc """
  `GET /{db}/_revs_limit` — current revision-history limit (default 1000).
  """
  @spec revs_limit(Client.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  def revs_limit(%Client{} = client, db) when is_binary(db) do
    Request.request(client, :get, "/" <> encode(db) <> "/_revs_limit")
  end

  @doc """
  `PUT /{db}/_revs_limit` — set the revision-history limit.
  """
  @spec put_revs_limit(Client.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def put_revs_limit(%Client{} = client, db, limit)
      when is_binary(db) and is_integer(limit) and limit > 0 do
    Request.request(client, :put, "/#{encode(db)}/_revs_limit", json: limit)
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
