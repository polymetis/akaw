defmodule Akaw.Attachment do
  @moduledoc """
  Attachment endpoints (`/{db}/{docid}/{attname}`).

  Attachments are arbitrary binary data attached to a CouchDB document.
  They live alongside the parent doc and share its revision lifecycle —
  every PUT or DELETE bumps the parent's `_rev`.

  Works for both regular documents and design documents: pass the design
  doc id verbatim, e.g. `"_design/myddoc"`, and the `/` will be preserved.

  See <https://docs.couchdb.org/en/latest/api/document/attachments.html>.
  """

  alias Akaw.{Client, Request}

  @doc """
  `HEAD /{db}/{docid}/{attname}` — verify an attachment exists.

  Returns `:ok` for HTTP 200. The response carries the current rev as an
  `ETag` header, but `HEAD` discards the body — use `get/5` if you need
  the rev or content-type programmatically.
  """
  @spec head(Client.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def head(%Client{} = client, db, doc_id, att_name)
      when is_binary(db) and is_binary(doc_id) and is_binary(att_name) do
    case Request.request(client, :head, path(db, doc_id, att_name)) do
      {:ok, _body} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  `GET /{db}/{docid}/{attname}` — fetch an attachment.

  Returns `{:ok, body, meta}` where `body` is the attachment bytes and
  `meta` is a map with `:content_type` and `:etag`. The ETag is CouchDB's
  base64-encoded MD5 of the attachment content (in quotes per HTTP spec) —
  useful for client-side caching, **not** the parent document's revision.
  Read the parent doc separately if you need its rev.

  ## Options

    * `:rev` — fetch the attachment from a specific revision of the parent
  """
  @spec get(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, binary() | term(), %{content_type: String.t() | nil, etag: String.t() | nil}}
          | {:error, term()}
  def get(%Client{} = client, db, doc_id, att_name, opts \\ [])
      when is_binary(db) and is_binary(doc_id) and is_binary(att_name) do
    case Request.request(client, :get, path(db, doc_id, att_name),
           params: opts,
           return: :response
         ) do
      {:ok, %Req.Response{body: body} = resp} ->
        meta = %{content_type: header(resp, "content-type"), etag: header(resp, "etag")}
        {:ok, body, meta}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  `PUT /{db}/{docid}/{attname}` — upload an attachment.

  `body` is the raw bytes (binary or iodata). Pass `:content_type` and the
  parent doc's current `:rev`.

  ## Options

    * `:rev` (required when updating an existing doc) — the parent doc's
      current revision
    * `:content_type` (default `"application/octet-stream"`) — set as the
      `Content-Type` header on the request
  """
  @spec put(Client.t(), String.t(), String.t(), String.t(), iodata(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def put(%Client{} = client, db, doc_id, att_name, body, opts \\ [])
      when is_binary(db) and is_binary(doc_id) and is_binary(att_name) do
    {content_type, opts} = Keyword.pop(opts, :content_type, "application/octet-stream")

    Request.request(client, :put, path(db, doc_id, att_name),
      body: body,
      headers: [{"content-type", content_type}],
      params: opts
    )
  end

  @doc """
  `DELETE /{db}/{docid}/{attname}?rev=…` — remove an attachment.

  Deleting an attachment bumps the parent doc's revision; `rev` is required.
  """
  @spec delete(Client.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def delete(%Client{} = client, db, doc_id, att_name, rev, opts \\ [])
      when is_binary(db) and is_binary(doc_id) and is_binary(att_name) and is_binary(rev) do
    Request.request(client, :delete, path(db, doc_id, att_name), params: [rev: rev] ++ opts)
  end

  defp path(db, doc_id, att_name) do
    "/#{encode(db)}/#{encode_id(doc_id)}/#{encode(att_name)}"
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp encode_id("_design/" <> rest), do: "_design/" <> encode(rest)
  defp encode_id("_local/" <> rest), do: "_local/" <> encode(rest)
  defp encode_id(id), do: encode(id)

  defp header(%Req.Response{} = resp, name) do
    resp |> Req.Response.get_header(name) |> List.first()
  end
end
