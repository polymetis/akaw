defmodule Akaw.Params do
  @moduledoc false

  # CouchDB query params whose value must be JSON-encoded in the URL —
  # e.g. `?startkey="user_"` rather than `?startkey=user_`. Used by
  # `Akaw.Documents`, `Akaw.View`, and friends.
  @json_keys ~w(startkey endkey key start_key end_key)a

  # Additional JSON-typed params used by `_search` and `_nouveau` queries.
  # `sort` is a JSON array; `ranges` and `counts` are JSON objects/arrays;
  # `drilldown` is a JSON array of `[field, value]` arrays.
  @search_extra_keys ~w(sort ranges drilldown counts group_sort)a

  @doc """
  Walks a keyword list of query params and JSON-encodes any value whose key
  is in the JSON-typed param set. Other entries pass through untouched.

  ## Examples

      iex> Akaw.Params.encode_json_keys(startkey: "user_", limit: 10)
      [startkey: ~s|"user_"|, limit: 10]

      iex> Akaw.Params.encode_json_keys(key: ["a", 1])
      [key: ~s|["a",1]|]

      iex> Akaw.Params.encode_json_keys(endkey: nil)
      [endkey: "null"]

      iex> Akaw.Params.encode_json_keys(include_docs: true, descending: false)
      [include_docs: true, descending: false]
  """
  @spec encode_json_keys(keyword()) :: keyword()
  def encode_json_keys(opts) when is_list(opts) do
    encode_with_keys(opts, @json_keys)
  end

  @doc """
  Like `encode_json_keys/1` but with the additional JSON-typed param set
  used by `_search` and `_nouveau` (`sort`, `ranges`, `drilldown`, `counts`,
  `group_sort`).
  """
  @spec encode_search_keys(keyword()) :: keyword()
  def encode_search_keys(opts) when is_list(opts) do
    encode_with_keys(opts, @json_keys ++ @search_extra_keys)
  end

  @doc """
  Encoding for document-endpoint params (`Akaw.Document.get/4`,
  `Akaw.Documents.bulk_get/4`): `atts_since` is always a JSON array of
  revs; `open_revs` is either the literal `all` — which must pass
  through bare, CouchDB rejects a quoted `"all"` — or a JSON array.

  ## Examples

      iex> Akaw.Params.encode_doc_keys(atts_since: ["1-abc"], rev: "2-def")
      [atts_since: ~s|["1-abc"]|, rev: "2-def"]

      iex> Akaw.Params.encode_doc_keys(open_revs: ["1-abc", "2-def"])
      [open_revs: ~s|["1-abc","2-def"]|]

      iex> Akaw.Params.encode_doc_keys(open_revs: "all")
      [open_revs: "all"]
  """
  @spec encode_doc_keys(keyword()) :: keyword()
  def encode_doc_keys(opts) when is_list(opts) do
    Enum.map(opts, fn
      {:open_revs, revs} when is_list(revs) -> {:open_revs, JSON.encode!(revs)}
      {:atts_since, revs} -> {:atts_since, JSON.encode!(revs)}
      pair -> pair
    end)
  end

  @doc """
  Encoding for `_changes` params: `doc_ids` (with `filter: "_doc_ids"`)
  is a JSON array in the query string.

  ## Examples

      iex> Akaw.Params.encode_changes_keys(doc_ids: ["a", "c"], filter: "_doc_ids")
      [doc_ids: ~s|["a","c"]|, filter: "_doc_ids"]

      iex> Akaw.Params.encode_changes_keys(since: "now")
      [since: "now"]
  """
  @spec encode_changes_keys(keyword()) :: keyword()
  def encode_changes_keys(opts) when is_list(opts) do
    Enum.map(opts, fn
      {:doc_ids, ids} when is_list(ids) -> {:doc_ids, JSON.encode!(ids)}
      pair -> pair
    end)
  end

  defp encode_with_keys(opts, keys) do
    Enum.map(opts, fn
      {k, v} -> if k in keys, do: {k, JSON.encode!(v)}, else: {k, v}
    end)
  end
end
