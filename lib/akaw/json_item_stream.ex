defmodule Akaw.JsonItemStream do
  @moduledoc false

  # Stream items from inside a top-level JSON array within a CouchDB
  # `_all_docs` / view / `_find` response, without buffering the whole
  # response.
  #
  # CouchDB pretty-prints these responses with one row per line:
  #
  #     {"total_rows":3,"offset":0,"rows":[
  #     {"id":"a","key":"a","value":{...}},
  #     {"id":"b","key":"b","value":{...}},
  #     {"id":"c","key":"c","value":{...}}
  #     ]}
  #
  # `_find` is the same shape with `"docs"` instead of `"rows"`. We rely on
  # this layout: scan lines until one ends with `[`, treat each subsequent
  # line that starts with `{` as a row (stripping a trailing comma), and
  # halt at the line that starts with `]`.
  #
  # If CouchDB ever stops pretty-printing this output (e.g. a future
  # version, or a proxy that minifies), this approach will break and we'd
  # need to fall back to a real incremental JSON parser. Tested against
  # CouchDB 3.5 with empty arrays, single-row, and 500-row responses.

  alias Akaw.LineStream

  @doc "Stream decoded items from CouchDB's row-of-objects response shape."
  @spec items(Enumerable.t()) :: Enumerable.t()
  def items(chunks) do
    chunks
    |> LineStream.lines()
    |> Stream.transform(:seek_array, &handle_line/2)
  end

  defp handle_line(line, :seek_array) do
    if String.ends_with?(String.trim_trailing(line), "[") do
      {[], :in_array}
    else
      {[], :seek_array}
    end
  end

  defp handle_line(line, :in_array) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {[], :in_array}

      String.starts_with?(trimmed, "]") ->
        {[], :done}

      true ->
        item = trimmed |> String.trim_trailing(",") |> JSON.decode!()
        {[item], :in_array}
    end
  end

  defp handle_line(_line, :done), do: {[], :done}
end
