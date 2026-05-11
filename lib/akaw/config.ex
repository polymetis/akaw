defmodule Akaw.Config do
  @moduledoc """
  Per-node runtime configuration (`/_node/{node}/_config/...`).

  Config changes apply immediately to the live server. Most are persisted
  to the node's local.ini and survive restarts.

  As with `Akaw.Node`, every function defaults to the special `"_local"`
  node name; pass `node: "..."` in opts to target another cluster member.

  See <https://docs.couchdb.org/en/latest/api/server/configuration.html>.
  """

  alias Akaw.{Client, Request, Path}

  @doc "`GET /_node/{node}/_config` — entire configuration map."
  @spec get(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(%Client{} = client, opts \\ []) do
    Request.request(client, :get, "/_node/#{node_name(opts)}/_config")
  end

  @doc "`GET /_node/{node}/_config/{section}` — one config section."
  @spec get_section(Client.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_section(%Client{} = client, section, opts \\ []) when is_binary(section) do
    Request.request(client, :get, "/_node/#{node_name(opts)}/_config/#{Path.encode(section)}")
  end

  @doc """
  `GET /_node/{node}/_config/{section}/{key}` — one config value.

  Returns the value (a string) wrapped in `{:ok, ...}`.
  """
  @spec get_value(Client.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def get_value(%Client{} = client, section, key, opts \\ [])
      when is_binary(section) and is_binary(key) do
    Request.request(
      client,
      :get,
      "/_node/#{node_name(opts)}/_config/#{Path.encode(section)}/#{Path.encode(key)}"
    )
  end

  @doc """
  `PUT /_node/{node}/_config/{section}/{key}` — set a config value.

  Returns the previous value (a string), per CouchDB convention.
  """
  @spec put(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def put(%Client{} = client, section, key, value, opts \\ [])
      when is_binary(section) and is_binary(key) and is_binary(value) do
    Request.request(
      client,
      :put,
      "/_node/#{node_name(opts)}/_config/#{Path.encode(section)}/#{Path.encode(key)}",
      json: value
    )
  end

  @doc "`DELETE /_node/{node}/_config/{section}/{key}` — remove a config key."
  @spec delete(Client.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def delete(%Client{} = client, section, key, opts \\ [])
      when is_binary(section) and is_binary(key) do
    Request.request(
      client,
      :delete,
      "/_node/#{node_name(opts)}/_config/#{Path.encode(section)}/#{Path.encode(key)}"
    )
  end

  @doc """
  `POST /_node/{node}/_config/_reload` — reload configuration from disk
  (e.g. after editing local.ini manually).
  """
  @spec reload(Client.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reload(%Client{} = client, opts \\ []) do
    Request.request(client, :post, "/_node/#{node_name(opts)}/_config/_reload", json: %{})
  end

  defp node_name(opts), do: opts |> Keyword.get(:node, "_local") |> Path.encode()
end
