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

  defp encode_with_keys(opts, keys) do
    Enum.map(opts, fn
      {k, v} -> if k in keys, do: {k, JSON.encode!(v)}, else: {k, v}
    end)
  end
end
