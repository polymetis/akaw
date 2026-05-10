defmodule Akaw.View do
  @moduledoc """
  View-query endpoints (`/{db}/_design/{ddoc}/_view/{view}`).

  Views are precomputed indexes defined inside a design document. This
  module exposes three flavors:

    * `get/5` — `GET /…/_view/{view}` with options forwarded as query
      params (the common case).
    * `post_keys/6` — `POST /…/_view/{view}` with a body of `keys` to
      filter on (use this when you have a long keys list — `?keys=…` would
      blow URL limits).
    * `queries/5` — `POST /…/_view/{view}/queries` to bundle several
      queries into one round-trip.

  As with `Akaw.Documents.all_docs/3`, JSON-typed query params (`startkey`,
  `endkey`, `key`) are auto-encoded.

  > #### Streaming {: .warning}
  >
  > Large views buffer fully in memory in this version. Streaming via
  > incremental JSON parsing lands in phase 2.

  See <https://docs.couchdb.org/en/latest/api/ddoc/views.html>.
  """

  alias Akaw.{Client, Params, Request}

  @doc """
  `GET /{db}/_design/{ddoc}/_view/{view}` — query a view.

  ## Common options

    * `:include_docs`, `:limit`, `:skip`, `:descending`, `:inclusive_end`
    * `:startkey`, `:endkey`, `:key` — auto-encoded as JSON
    * `:startkey_docid`, `:endkey_docid`
    * `:reduce`, `:group`, `:group_level`
    * `:stale`, `:stable`, `:update`, `:update_seq`
    * `:conflicts`, `:attachments`, `:att_encoding_info`
  """
  @spec get(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get(%Client{} = client, db, ddoc, view, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(view) do
    Request.request(client, :get, view_path(db, ddoc, view),
      params: Params.encode_json_keys(opts)
    )
  end

  @doc """
  `POST /{db}/_design/{ddoc}/_view/{view}` — query a view filtered to a
  specific list of keys (sent in the body, not the URL).
  """
  @spec post_keys(Client.t(), String.t(), String.t(), String.t(), [term()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def post_keys(%Client{} = client, db, ddoc, view, keys, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(view) and is_list(keys) do
    Request.request(client, :post, view_path(db, ddoc, view),
      json: %{keys: keys},
      params: Params.encode_json_keys(opts)
    )
  end

  @doc """
  `POST /{db}/_design/{ddoc}/_view/{view}/queries` — run multiple view
  queries in one request.

  `queries` is a list of maps mirroring the `get/5` option set:

      Akaw.View.queries(client, "events", "by_user", "recent", [
        %{startkey: "u1", endkey: "u1\\ufff0", limit: 50},
        %{key: "u2", limit: 50}
      ])
  """
  @spec queries(Client.t(), String.t(), String.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  def queries(%Client{} = client, db, ddoc, view, queries)
      when is_binary(db) and is_binary(ddoc) and is_binary(view) and is_list(queries) do
    Request.request(client, :post, view_path(db, ddoc, view) <> "/queries",
      json: %{queries: queries}
    )
  end

  defp view_path(db, ddoc, view) do
    "/#{encode(db)}/_design/#{encode(ddoc)}/_view/#{encode(view)}"
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
