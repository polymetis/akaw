defmodule Akaw.LocalDoc do
  @moduledoc """
  Local-document endpoints (`/{db}/_local/{docid}` and `/{db}/_local_docs`).

  Local documents are stored in the database but **not replicated**. The
  most common use case is replication checkpoints (CouchDB itself uses
  them), but they're also handy for instance-local state: cluster-node
  housekeeping flags, ephemeral counters, anything that shouldn't follow a
  doc when the database is replicated.

  CRUD on a single local doc looks the same as a regular doc — pass the
  bare id (no `_local/` prefix); this module adds it.

  See <https://docs.couchdb.org/en/latest/api/local.html>.
  """

  alias Akaw.{Client, Document, Params, Request}

  @doc "`HEAD /{db}/_local/{id}` — verify a local doc exists."
  @spec head(Client.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def head(%Client{} = client, db, id) when is_binary(db) and is_binary(id) do
    Document.head(client, db, "_local/" <> id)
  end

  @doc "`GET /{db}/_local/{id}` — fetch a local doc."
  @spec get(Client.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get(%Client{} = client, db, id, opts \\ [])
      when is_binary(db) and is_binary(id) do
    Document.get(client, db, "_local/" <> id, opts)
  end

  @doc "`PUT /{db}/_local/{id}` — create or update a local doc."
  @spec put(Client.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def put(%Client{} = client, db, id, doc, opts \\ [])
      when is_binary(db) and is_binary(id) and is_map(doc) do
    Document.put(client, db, "_local/" <> id, doc, opts)
  end

  @doc "`DELETE /{db}/_local/{id}` — remove a local doc."
  @spec delete(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def delete(%Client{} = client, db, id, rev, opts \\ [])
      when is_binary(db) and is_binary(id) and is_binary(rev) do
    Document.delete(client, db, "_local/" <> id, rev, opts)
  end

  @doc """
  `GET /{db}/_local_docs` — list local docs (same shape as `_all_docs`).

  Same options as `Akaw.Documents.all_docs/3`.
  """
  @spec list(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list(%Client{} = client, db, opts \\ []) when is_binary(db) do
    Request.request(client, :get, "/#{encode(db)}/_local_docs",
      params: Params.encode_json_keys(opts)
    )
  end

  @doc """
  `POST /{db}/_local_docs` — keys-filtered list of local docs.
  """
  @spec list_keys(Client.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def list_keys(%Client{} = client, db, keys, opts \\ [])
      when is_binary(db) and is_list(keys) do
    Request.request(client, :post, "/#{encode(db)}/_local_docs",
      json: %{keys: keys},
      params: Params.encode_json_keys(opts)
    )
  end

  @doc """
  `POST /{db}/_local_docs/queries` — multiple local-doc queries in one
  request.
  """
  @spec list_queries(Client.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  def list_queries(%Client{} = client, db, queries)
      when is_binary(db) and is_list(queries) do
    Request.request(client, :post, "/#{encode(db)}/_local_docs/queries",
      json: %{queries: queries}
    )
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
