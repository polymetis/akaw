defmodule Akaw.Path do
  @moduledoc false

  # URL-path encoding helpers shared by every endpoint module. CouchDB
  # path segments need RFC-3986 unreserved-char encoding, with the
  # additional rule that the `_design/` and `_local/` reserved prefixes
  # keep their literal slash so CouchDB routes them correctly.
  #
  # Lives in one place to keep encoding tweaks (e.g. supporting more
  # unreserved chars in db names) a single-line change rather than a
  # rewrite of 22 modules.

  @doc "URL-encode a path segment using RFC 3986 unreserved-char predicate."
  @spec encode(String.t()) :: String.t()
  def encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  @doc """
  URL-encode a document id, preserving the literal slash of `_design/`
  and `_local/` reserved prefixes. The suffix after the slash is still
  encoded so doc ids like `_design/with space` become `_design/with%20space`.
  """
  @spec encode_id(String.t()) :: String.t()
  def encode_id("_design/" <> rest), do: "_design/" <> encode(rest)
  def encode_id("_local/" <> rest), do: "_local/" <> encode(rest)
  def encode_id(id), do: encode(id)
end
