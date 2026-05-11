defmodule Akaw.Replication do
  @moduledoc """
  Persistent replication via the `_replicator` database and the
  `_scheduler` endpoints.

  CouchDB has two replication APIs:

    * One-shot/transient — `POST /_replicate`. Survives only as long as
      the cluster process is up. Exposed as `Akaw.Server.replicate/2`.
    * Persistent — write a *replication document* into the `_replicator`
      database. The replicator scheduler picks it up and runs it; the doc
      survives restarts. This module covers that path.

  Replication documents are normal CouchDB documents with well-known
  fields (`source`, `target`, `continuous`, `filter`, `selector`,
  `doc_ids`, `create_target`, `cancel`, …). A typical create looks like:

      Akaw.Replication.create(client, "users-archive", %{
        source: "http://source-host:5984/users",
        target: "users-archive",
        continuous: true,
        create_target: true
      })

  See <https://docs.couchdb.org/en/latest/replication/replicator.html>.
  """

  alias Akaw.{Client, Document, Documents, Request, Path}

  @db "_replicator"

  @doc """
  Create or update a replication. Equivalent to
  `Akaw.Document.put(client, "_replicator", id, doc, opts)`.

  Include `_rev` in the doc (or pass `rev:` in `opts`) to update an
  existing replication.
  """
  @spec create(Client.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create(%Client{} = client, id, doc, opts \\ [])
      when is_binary(id) and is_map(doc) do
    Document.put(client, @db, id, doc, opts)
  end

  @doc "Fetch a replication document."
  @spec get(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(%Client{} = client, id, opts \\ []) when is_binary(id) do
    Document.get(client, @db, id, opts)
  end

  @doc "Delete a replication document — stops the replication."
  @spec delete(Client.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def delete(%Client{} = client, id, rev, opts \\ [])
      when is_binary(id) and is_binary(rev) do
    Document.delete(client, @db, id, rev, opts)
  end

  @doc "List all replication documents."
  @spec list(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list(%Client{} = client, opts \\ []) do
    Documents.all_docs(client, @db, opts)
  end

  @doc """
  `GET /_scheduler/docs/_replicator/{id}` — runtime status of one
  replication, as the scheduler sees it (state, errors, last update, …).
  """
  @spec status(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def status(%Client{} = client, id) when is_binary(id) do
    Request.request(client, :get, "/_scheduler/docs/_replicator/#{Path.encode(id)}")
  end

  @doc """
  `GET /_scheduler/docs` — runtime status of every replication on the
  cluster.
  """
  @spec all_status(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def all_status(%Client{} = client, opts \\ []) do
    Request.request(client, :get, "/_scheduler/docs", params: opts)
  end

  @doc """
  `GET /_scheduler/jobs` — currently scheduled replication jobs (the
  scheduler's queue, not just the persistent docs).
  """
  @spec jobs(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def jobs(%Client{} = client, opts \\ []) do
    Request.request(client, :get, "/_scheduler/jobs", params: opts)
  end
end
