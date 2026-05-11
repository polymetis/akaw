defmodule Akaw.Cluster do
  @moduledoc """
  Cluster bring-up via `/_cluster_setup`.

  CouchDB ships in an "unfinished" state that needs to be either enabled
  as a single node or joined into a multi-node cluster before most
  operations work. This endpoint drives that bring-up.

  Typical single-node bootstrap (creates `_users`, `_replicator`,
  `_global_changes` and marks the node as initialized):

      Akaw.Cluster.setup(client, %{
        action: "enable_single_node",
        bind_address: "0.0.0.0",
        username: "admin",
        password: "password"
      })

  See <https://docs.couchdb.org/en/latest/api/server/common.html#cluster-setup>.
  """

  alias Akaw.{Client, Request}

  @doc "`GET /_cluster_setup` — current cluster setup state."
  @spec get(Client.t()) :: {:ok, map()} | {:error, term()}
  def get(%Client{} = client) do
    Request.request(client, :get, "/_cluster_setup")
  end

  @doc """
  `POST /_cluster_setup` — drive a setup action.

  `body` is the full request body. The `:action` field is required. See
  the linked docs for the per-action shape.
  """
  @spec setup(Client.t(), map()) :: {:ok, map()} | {:error, term()}
  def setup(%Client{} = client, body) when is_map(body) do
    Request.request(client, :post, "/_cluster_setup", json: body)
  end
end
