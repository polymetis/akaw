defmodule Akaw.DesignDoc do
  @moduledoc """
  Design-document endpoints (`/{db}/_design/{ddoc}`).

  A design document is a regular CouchDB document with a special id prefix
  (`_design/…`) and well-known fields (`views`, `language`, `validate_doc_update`,
  `filters`, `updates`, `shows`, `lists`, `rewrites`). Most CRUD operations
  on a design doc are identical to a normal document — this module
  delegates `head/3`, `get/4`, `put/5`, `delete/5`, and `copy/5` to
  `Akaw.Document` with the `_design/` prefix added for you.

  The one extra endpoint is `info/3`, which returns view-index statistics
  (size on disk, build progress, signature, etc.).

  For querying views see `Akaw.View`.

  See <https://docs.couchdb.org/en/latest/api/ddoc/common.html>.
  """

  alias Akaw.{Client, Document, Request}

  @doc "`HEAD /{db}/_design/{ddoc}` — verify a design doc exists."
  @spec head(Client.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def head(%Client{} = client, db, ddoc) when is_binary(db) and is_binary(ddoc) do
    Document.head(client, db, "_design/" <> ddoc)
  end

  @doc "`GET /{db}/_design/{ddoc}` — fetch a design doc."
  @spec get(Client.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get(%Client{} = client, db, ddoc, opts \\ [])
      when is_binary(db) and is_binary(ddoc) do
    Document.get(client, db, "_design/" <> ddoc, opts)
  end

  @doc """
  `PUT /{db}/_design/{ddoc}` — create or update a design doc.

  See `Akaw.Document.put/5` for the option list.
  """
  @spec put(Client.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def put(%Client{} = client, db, ddoc, doc, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_map(doc) do
    Document.put(client, db, "_design/" <> ddoc, doc, opts)
  end

  @doc "`DELETE /{db}/_design/{ddoc}?rev=…` — remove a design doc."
  @spec delete(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def delete(%Client{} = client, db, ddoc, rev, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(rev) do
    Document.delete(client, db, "_design/" <> ddoc, rev, opts)
  end

  @doc """
  `COPY /{db}/_design/{ddoc}` — copy a design doc to a new id.

  `destination` is the bare ddoc name without the `_design/` prefix; it's
  added for you in the `Destination` header.
  """
  @spec copy(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def copy(%Client{} = client, db, src_ddoc, dest_ddoc, opts \\ [])
      when is_binary(db) and is_binary(src_ddoc) and is_binary(dest_ddoc) do
    Document.copy(client, db, "_design/" <> src_ddoc, "_design/" <> dest_ddoc, opts)
  end

  @doc """
  `GET /{db}/_design/{ddoc}/_info` — view-index statistics for the design
  document (signature, sizes, update progress, …).
  """
  @spec info(Client.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def info(%Client{} = client, db, ddoc) when is_binary(db) and is_binary(ddoc) do
    Request.request(client, :get, "/#{encode(db)}/_design/#{encode(ddoc)}/_info")
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
