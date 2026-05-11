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
  # Defensive posture: if we see anything else inside the array — typically
  # because an intermediary proxy minified the JSON and collapsed rows onto
  # one line, or because CouchDB changed its output format — we raise an
  # `%Akaw.Error{}` with a diagnostic, rather than letting `JSON.decode!`
  # explode mid-stream with no context. Real SAX-style parsing is future
  # work; today's failure mode is at least legible.
  #
  # Tested against CouchDB 3.5 with empty arrays, single-row, and 500-row
  # responses.

  alias Akaw.{Error, LineStream}

  @type state :: :seek_array | :in_array | :done

  @doc "Stream decoded items from CouchDB's row-of-objects response shape."
  @spec items(Enumerable.t(binary())) :: Enumerable.t(map())
  def items(chunks) do
    chunks
    |> LineStream.lines()
    |> Stream.transform(:seek_array, &step/2)
  end

  @doc """
  One step of the line-by-line state machine: takes a line and the
  current parser state, returns `{items_emitted, new_state}`. Shared
  with `Akaw.Streaming.reduce_items_while/6` so the JSON-row parser
  lives in one place.
  """
  @spec step(String.t(), state()) :: {[map()], state()}
  def step(line, :seek_array) do
    if String.ends_with?(String.trim_trailing(line), "[") do
      {[], :in_array}
    else
      {[], :seek_array}
    end
  end

  def step(line, :in_array) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {[], :in_array}

      String.starts_with?(trimmed, "]") ->
        {[], :done}

      String.starts_with?(trimmed, "{") ->
        item = trimmed |> String.trim_trailing(",") |> safe_decode(line)
        {[item], :in_array}

      true ->
        raise %Error{
          status: nil,
          error: "stream_format_error",
          reason:
            "expected pretty-printed CouchDB response (one JSON object " <>
              "per line, starting with `{`). Got: " <>
              inspect(String.slice(trimmed, 0, 120)) <>
              ". If a proxy between you and CouchDB minifies responses, " <>
              "use the non-streaming variant or disable minification."
        }
    end
  end

  def step(_line, :done), do: {[], :done}

  defp safe_decode(text, original_line) do
    JSON.decode!(text)
  rescue
    decode_error ->
      reraise %Error{
                status: nil,
                error: "stream_decode_error",
                reason:
                  "row failed to decode: #{inspect(decode_error)}. Source line: " <>
                    inspect(String.slice(original_line, 0, 200))
              },
              __STACKTRACE__
  end
end
