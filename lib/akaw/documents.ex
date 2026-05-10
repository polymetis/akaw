defmodule Akaw.Documents do
  @moduledoc """
  Multi-document endpoints — `_all_docs`, `_design_docs`, `_bulk_get`,
  `_bulk_docs`.

  These currently buffer the full response in memory. Streaming variants
  for `_all_docs` and friends land in phase 2 alongside `_changes` and view
  streaming.

  ## A note on JSON-typed query params

  CouchDB expects the values of `startkey`, `endkey`, `key`, `start_key`,
  `end_key` to be valid JSON in the URL — e.g. `?startkey="user_"` not
  `?startkey=user_`. Akaw auto-encodes these for you, so pass the raw value:

      Akaw.Documents.all_docs(client, "users", startkey: "user_", endkey: "user_z")
      Akaw.Documents.all_docs(client, "events", key: ["2026-05-10", "click"])

  See <https://docs.couchdb.org/en/latest/api/database/bulk-api.html>.
  """

  alias Akaw.{Client, Params, Request}

  @doc """
  `GET /{db}/_all_docs` — list documents in the database.

  ## Common options

    * `:include_docs`, `:limit`, `:skip`, `:descending`, `:inclusive_end`,
      `:update_seq`, `:conflicts`, `:attachments`, `:att_encoding_info`,
      `:stale`, `:stable`, `:update`
    * `:startkey`, `:endkey`, `:key` — auto-encoded as JSON for the URL
    * `:startkey_docid`, `:endkey_docid`

  Use `all_docs_keys/4` for a `?keys=…` filter; CouchDB requires that to be
  POSTed, not GETted.

  > #### Streaming {: .warning}
  >
  > Loads the full response into memory. Streaming will land in phase 2.
  """
  @spec all_docs(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def all_docs(%Client{} = client, db, opts \\ []) when is_binary(db) do
    Request.request(client, :get, "/#{encode(db)}/_all_docs",
      params: Params.encode_json_keys(opts)
    )
  end

  @doc """
  `POST /{db}/_all_docs` — keys-filtered list of documents.

  Same shape as `all_docs/3` but with the keys list in the body. Other
  options forward as query params.
  """
  @spec all_docs_keys(Client.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def all_docs_keys(%Client{} = client, db, keys, opts \\ [])
      when is_binary(db) and is_list(keys) do
    Request.request(client, :post, "/#{encode(db)}/_all_docs",
      json: %{keys: keys},
      params: Params.encode_json_keys(opts)
    )
  end

  @doc """
  `POST /{db}/_all_docs/queries` — run multiple `_all_docs` queries in a
  single request.

  `queries` is a list of maps mirroring the `all_docs/3` option set:

      Akaw.Documents.all_docs_queries(client, "users", [
        %{include_docs: true, limit: 10},
        %{keys: ["user_42", "user_43"]}
      ])
  """
  @spec all_docs_queries(Client.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  def all_docs_queries(%Client{} = client, db, queries)
      when is_binary(db) and is_list(queries) do
    Request.request(client, :post, "/#{encode(db)}/_all_docs/queries", json: %{queries: queries})
  end

  @doc """
  `GET /{db}/_design_docs` — list design documents.

  Same options as `all_docs/3`.
  """
  @spec design_docs(Client.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def design_docs(%Client{} = client, db, opts \\ []) when is_binary(db) do
    Request.request(client, :get, "/#{encode(db)}/_design_docs",
      params: Params.encode_json_keys(opts)
    )
  end

  @doc """
  `POST /{db}/_design_docs` — keys-filtered list of design documents.
  """
  @spec design_docs_keys(Client.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def design_docs_keys(%Client{} = client, db, keys, opts \\ [])
      when is_binary(db) and is_list(keys) do
    Request.request(client, :post, "/#{encode(db)}/_design_docs",
      json: %{keys: keys},
      params: Params.encode_json_keys(opts)
    )
  end

  @doc """
  `POST /{db}/_bulk_get` — fetch many documents by `{id, rev}` reference.

  `refs` is a list of maps, e.g.:

      [%{id: "user_42"}, %{id: "user_43", rev: "1-abc"}]

  ## Options (query params)

    * `:revs`, `:attachments`, `:atts_since`, `:latest`
  """
  @spec bulk_get(Client.t(), String.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def bulk_get(%Client{} = client, db, refs, opts \\ [])
      when is_binary(db) and is_list(refs) do
    Request.request(client, :post, "/#{encode(db)}/_bulk_get",
      json: %{docs: refs},
      params: opts
    )
  end

  @doc """
  `POST /{db}/_bulk_docs` — write many documents in one round-trip.

  Each entry in `docs` is a map. To create a doc, omit `_id`/`_rev`. To
  update, include both. To delete, include `_id`, `_rev`, and `_deleted: true`.

  ## Options (folded into the request body)

    * `:new_edits` — pass `false` to perform replication-style writes
      (CouchDB will preserve `_rev` exactly as provided rather than
      generating new revisions)
  """
  @spec bulk_docs(Client.t(), String.t(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def bulk_docs(%Client{} = client, db, docs, opts \\ [])
      when is_binary(db) and is_list(docs) do
    body = opts |> Map.new() |> Map.put(:docs, docs)
    Request.request(client, :post, "/#{encode(db)}/_bulk_docs", json: body)
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
