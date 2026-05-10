defmodule Akaw.Security do
  @moduledoc """
  Per-database security (`/{db}/_security`).

  The security object describes who can read and write the database, in two
  groups:

      %{
        "admins"  => %{"names" => ["alice"], "roles" => ["dba"]},
        "members" => %{"names" => ["bob"],   "roles" => ["users"]}
      }

  An empty `members` (`%{"names" => [], "roles" => []}`) means the database
  is public.

  See <https://docs.couchdb.org/en/latest/api/database/security.html>.
  """

  alias Akaw.{Client, Request}

  @doc "`GET /{db}/_security` — fetch the security object."
  @spec get(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(%Client{} = client, db) when is_binary(db) do
    Request.request(client, :get, "/#{encode(db)}/_security")
  end

  @doc "`PUT /{db}/_security` — replace the security object."
  @spec put(Client.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(%Client{} = client, db, security) when is_binary(db) and is_map(security) do
    Request.request(client, :put, "/#{encode(db)}/_security", json: security)
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
