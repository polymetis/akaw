defmodule Akaw.Partition do
  @moduledoc """
  Partition-scoped endpoints for partitioned databases
  (`/{db}/_partition/{partition_id}/...`).

  A partitioned database (created with `Akaw.Database.create/3` and
  `partitioned: true`) groups documents by a partition key embedded in the
  doc id (`{partition}:{rest}`). Operations scoped to a partition stay on
  a single shard, which can be much faster than the unpartitioned variant.

  See <https://docs.couchdb.org/en/latest/partitioned-dbs/index.html>.
  """

  alias Akaw.{Client, Params, Request}

  @doc "`GET /{db}/_partition/{partition}` — info about a partition."
  @spec info(Client.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def info(%Client{} = client, db, partition)
      when is_binary(db) and is_binary(partition) do
    Request.request(client, :get, "/#{encode(db)}/_partition/#{encode(partition)}")
  end

  @doc """
  `GET /{db}/_partition/{partition}/_all_docs` — list documents within a
  single partition. Same options as `Akaw.Documents.all_docs/3`.
  """
  @spec all_docs(Client.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def all_docs(%Client{} = client, db, partition, opts \\ [])
      when is_binary(db) and is_binary(partition) do
    Request.request(
      client,
      :get,
      "/#{encode(db)}/_partition/#{encode(partition)}/_all_docs",
      params: Params.encode_json_keys(opts)
    )
  end

  @doc """
  `GET /{db}/_partition/{partition}/_design/{ddoc}/_view/{view}` —
  partition-scoped view query. Same options as `Akaw.View.get/5`.
  """
  @spec view(Client.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def view(%Client{} = client, db, partition, ddoc, view, opts \\ [])
      when is_binary(db) and is_binary(partition) and is_binary(ddoc) and is_binary(view) do
    Request.request(
      client,
      :get,
      "/#{encode(db)}/_partition/#{encode(partition)}/_design/#{encode(ddoc)}/_view/#{encode(view)}",
      params: Params.encode_json_keys(opts)
    )
  end

  @doc """
  `POST /{db}/_partition/{partition}/_find` — partition-scoped Mango find.
  """
  @spec find(Client.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def find(%Client{} = client, db, partition, query)
      when is_binary(db) and is_binary(partition) and is_map(query) do
    Request.request(
      client,
      :post,
      "/#{encode(db)}/_partition/#{encode(partition)}/_find",
      json: query
    )
  end

  @doc """
  `POST /{db}/_partition/{partition}/_explain` — explain a partition-scoped
  Mango query.
  """
  @spec explain(Client.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def explain(%Client{} = client, db, partition, query)
      when is_binary(db) and is_binary(partition) and is_map(query) do
    Request.request(
      client,
      :post,
      "/#{encode(db)}/_partition/#{encode(partition)}/_explain",
      json: query
    )
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
