defmodule Akaw.Params do
  @moduledoc false

  # CouchDB query params whose value must be JSON-encoded in the URL —
  # e.g. `?startkey="user_"` rather than `?startkey=user_`. Used by
  # `Akaw.Documents`, `Akaw.View`, and friends.
  @json_keys ~w(startkey endkey key start_key end_key)a

  @doc """
  Walks a keyword list of query params and JSON-encodes any value whose key
  is in the JSON-typed param set. Other entries pass through untouched.
  """
  @spec encode_json_keys(keyword()) :: keyword()
  def encode_json_keys(opts) when is_list(opts) do
    Enum.map(opts, fn
      {k, v} when k in @json_keys -> {k, JSON.encode!(v)}
      other -> other
    end)
  end
end
