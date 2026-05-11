defmodule Akaw.Node do
  @moduledoc """
  Per-node admin endpoints (`/_node/{node-name}/...`).

  CouchDB accepts the literal string `"_local"` in place of a node name to
  target the node that received the request — that's the default for every
  function here. Pass `node: "couchdb@host"` (or the full erlang node name)
  to target another cluster member.

  See <https://docs.couchdb.org/en/latest/api/server/common.html#node>.
  """

  alias Akaw.{Client, Request, Path}

  @doc "`GET /_node/{node}` — meta info about a node (name, otp_release)."
  @spec info(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def info(%Client{} = client, opts \\ []) do
    Request.request(client, :get, "/_node/#{node_name(opts)}")
  end

  @doc "`GET /_node/{node}/_stats` — runtime statistics (counters, histograms)."
  @spec stats(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stats(%Client{} = client, opts \\ []) do
    Request.request(client, :get, "/_node/#{node_name(opts)}/_stats")
  end

  @doc """
  `GET /_node/{node}/_prometheus` — runtime statistics in Prometheus text
  exposition format.

  Returns the raw bytes (not JSON). Useful when pointing a Prometheus
  scraper directly at CouchDB.
  """
  @spec prometheus(Client.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def prometheus(%Client{} = client, opts \\ []) do
    Request.request(client, :get, "/_node/#{node_name(opts)}/_prometheus")
  end

  @doc """
  `GET /_node/{node}/_system` — VM-level info (memory, message queues, run
  queue, GC stats, etc.).
  """
  @spec system(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def system(%Client{} = client, opts \\ []) do
    Request.request(client, :get, "/_node/#{node_name(opts)}/_system")
  end

  @doc """
  `GET /_node/{node}/_smoosh/status` — status of the smoosh channels, which
  govern automatic compaction work in the cluster.
  """
  @spec smoosh_status(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def smoosh_status(%Client{} = client, opts \\ []) do
    Request.request(client, :get, "/_node/#{node_name(opts)}/_smoosh/status")
  end

  @doc "`GET /_node/{node}/_versions` — CouchDB and OTP version strings."
  @spec versions(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def versions(%Client{} = client, opts \\ []) do
    Request.request(client, :get, "/_node/#{node_name(opts)}/_versions")
  end

  @doc """
  `POST /_node/{node}/_restart` — restart a node.

  > #### Destructive {: .error}
  >
  > Drops in-flight requests and resets connections. Don't run this against
  > production without coordinating.
  """
  @spec restart(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restart(%Client{} = client, opts \\ []) do
    Request.request(client, :post, "/_node/#{node_name(opts)}/_restart", json: %{})
  end

  defp node_name(opts), do: opts |> Keyword.get(:node, "_local") |> Path.encode()
end
