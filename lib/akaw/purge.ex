defmodule Akaw.Purge do
  @moduledoc """
  Purge endpoints — physical removal of document revisions.

  A purge is *not* the same as a delete. `Akaw.Document.delete/5` writes a
  tombstone (a `_deleted: true` revision) so the deletion replicates and
  conflicts can still be resolved. A purge actually removes the revision
  history from disk on this node — it doesn't replicate, and it can
  re-introduce a deleted doc on other nodes after replication. Use it for
  GDPR-style "destroy this data" requests, not as a regular delete.

  See <https://docs.couchdb.org/en/latest/api/database/misc.html#db-purge>.
  """

  alias Akaw.{Client, Request}

  @doc """
  `POST /{db}/_purge` — purge specific revisions of specific documents.

  `purges` is a map of `doc_id => [rev, …]`:

      Akaw.Purge.purge(client, "users", %{
        "user_42" => ["3-abc"],
        "user_43" => ["1-def", "2-ghi"]
      })
  """
  @spec purge(Client.t(), String.t(), %{optional(String.t()) => [String.t()]}) ::
          {:ok, map()} | {:error, term()}
  def purge(%Client{} = client, db, purges) when is_binary(db) and is_map(purges) do
    Request.request(client, :post, "/#{encode(db)}/_purge", json: purges)
  end

  @doc "`GET /{db}/_purged_infos` — list of historical purges on the database."
  @spec purged_infos(Client.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def purged_infos(%Client{} = client, db, opts \\ []) when is_binary(db) do
    Request.request(client, :get, "/#{encode(db)}/_purged_infos", params: opts)
  end

  @doc """
  `GET /{db}/_purged_infos_limit` — current limit on the number of purge
  records the database keeps (used by replication to detect
  already-purged docs).
  """
  @spec purged_infos_limit(Client.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  def purged_infos_limit(%Client{} = client, db) when is_binary(db) do
    Request.request(client, :get, "/#{encode(db)}/_purged_infos_limit")
  end

  @doc "`PUT /{db}/_purged_infos_limit` — change the purge-history limit."
  @spec put_purged_infos_limit(Client.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def put_purged_infos_limit(%Client{} = client, db, limit)
      when is_binary(db) and is_integer(limit) and limit > 0 do
    Request.request(client, :put, "/#{encode(db)}/_purged_infos_limit", json: limit)
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
