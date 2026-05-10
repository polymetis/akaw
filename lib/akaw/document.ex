defmodule Akaw.Document do
  @moduledoc """
  Single-document endpoints (`/{db}/{docid}`).

  For design documents see `Akaw.DesignDoc`; for local (non-replicated)
  documents see `Akaw.LocalDoc`. For collection-level operations
  (`_all_docs`, `_bulk_get`, `_bulk_docs`) see `Akaw.Documents`.

  Document IDs are URL-encoded automatically. The `_design/` and `_local/`
  prefixes are passed through verbatim so paths like
  `_design/myddoc` keep their literal slash, but the suffix is still encoded.
  """

  alias Akaw.{Client, Request}

  @doc """
  `HEAD /{db}/{docid}` — verify a document exists.

  Returns `:ok` on a 200. The HTTP response carries the current revision in
  an `ETag` header, but `HEAD` discards the body — use `get/4` if you need
  the rev programmatically.
  """
  @spec head(Client.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def head(%Client{} = client, db, doc_id)
      when is_binary(db) and is_binary(doc_id) do
    case Request.request(client, :head, path(db, doc_id)) do
      {:ok, _body} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  `GET /{db}/{docid}` — fetch a document.

  ## Common options (forwarded as query params)

    * `:rev` — fetch a specific revision
    * `:revs`, `:revs_info`, `:open_revs` — revision metadata
    * `:conflicts`, `:deleted_conflicts` — include conflict info
    * `:attachments`, `:att_encoding_info`, `:atts_since` — attachment handling
    * `:latest`, `:local_seq`, `:meta`

  See <https://docs.couchdb.org/en/latest/api/document/common.html#get--db-docid>.
  """
  @spec get(Client.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get(%Client{} = client, db, doc_id, opts \\ [])
      when is_binary(db) and is_binary(doc_id) do
    Request.request(client, :get, path(db, doc_id), params: opts)
  end

  @doc """
  `PUT /{db}/{docid}` — create or update a document.

  When updating, include `_rev` in the document body or pass `rev:` in
  `opts`.

  ## Options

    * `:rev` — current revision (alternative to `_rev` in body)
    * `:batch` — `"ok"` to batch the write (eventually consistent, may
      return before persisted)
    * `:new_edits` — `false` to write replication-style (preserves the
      provided `_rev` instead of generating a new one)
  """
  @spec put(Client.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def put(%Client{} = client, db, doc_id, doc, opts \\ [])
      when is_binary(db) and is_binary(doc_id) and is_map(doc) do
    Request.request(client, :put, path(db, doc_id), json: doc, params: opts)
  end

  @doc """
  `DELETE /{db}/{docid}?rev=…` — soft-delete a document.

  CouchDB writes a tombstone (a `_deleted: true` revision) rather than
  physically removing the document, so the current rev is required.
  """
  @spec delete(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def delete(%Client{} = client, db, doc_id, rev, opts \\ [])
      when is_binary(db) and is_binary(doc_id) and is_binary(rev) do
    Request.request(client, :delete, path(db, doc_id), params: [rev: rev] ++ opts)
  end

  @doc """
  `COPY /{db}/{docid}` — copy a document under a new id.

  ## Options

    * `:rev` — copy a specific source revision
    * `:destination_rev` — overwrite an existing destination at this rev
      (formatted into the `Destination` header as `"{dest}?rev={rev}"`)
  """
  @spec copy(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def copy(%Client{} = client, db, src_id, destination, opts \\ [])
      when is_binary(db) and is_binary(src_id) and is_binary(destination) do
    {dest_rev, opts} = Keyword.pop(opts, :destination_rev)

    destination_value =
      case dest_rev do
        nil -> destination
        rev -> "#{destination}?rev=#{rev}"
      end

    Request.request(client, "COPY", path(db, src_id),
      headers: [{"destination", destination_value}],
      params: opts
    )
  end

  defp path(db, doc_id), do: "/#{encode(db)}/#{encode_id(doc_id)}"

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp encode_id("_design/" <> rest), do: "_design/" <> encode(rest)
  defp encode_id("_local/" <> rest), do: "_local/" <> encode(rest)
  defp encode_id(id), do: encode(id)
end
