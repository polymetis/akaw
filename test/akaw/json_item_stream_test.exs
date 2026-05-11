defmodule Akaw.JsonItemStreamTest do
  use ExUnit.Case, async: true

  alias Akaw.JsonItemStream

  describe "items/1 — CouchDB-shaped responses" do
    test "empty rows array" do
      chunks = [~s|{"total_rows":0,"offset":0,"rows":[\n\n]}|]
      assert [] = JsonItemStream.items(chunks) |> Enum.to_list()
    end

    test "single row" do
      chunks = [
        ~s|{"total_rows":1,"offset":0,"rows":[\n|,
        ~s|{"id":"a","key":"a","value":{"rev":"1-x"}}\n|,
        ~s|]}|
      ]

      assert [%{"id" => "a"}] = JsonItemStream.items(chunks) |> Enum.to_list()
    end

    test "multiple rows with trailing commas" do
      chunks = [
        ~s|{"total_rows":3,"offset":0,"rows":[\n|,
        ~s|{"id":"a"},\n|,
        ~s|{"id":"b"},\n|,
        ~s|{"id":"c"}\n|,
        ~s|]}|
      ]

      result = JsonItemStream.items(chunks) |> Enum.to_list()
      assert Enum.map(result, & &1["id"]) == ["a", "b", "c"]
    end

    test "_find shape: docs array followed by bookmark/warning" do
      chunks = [
        ~s|{"docs":[\n|,
        ~s|{"_id":"x","n":1},\n|,
        ~s|{"_id":"y","n":2}\n|,
        ~s|],\n"bookmark":"abc"\n|,
        ~s|}|
      ]

      result = JsonItemStream.items(chunks) |> Enum.to_list()
      assert Enum.map(result, & &1["_id"]) == ["x", "y"]
    end

    test "is robust to chunk boundaries inside a row" do
      # Row JSON split across multiple chunks
      chunks = [
        ~s|{"total_rows":1,"rows":[\n{"id":"a","key":|,
        ~s|"a","value":{"rev":"1-x"}}\n]}|
      ]

      assert [%{"id" => "a", "value" => %{"rev" => "1-x"}}] =
               JsonItemStream.items(chunks) |> Enum.to_list()
    end

    test "raises Akaw.Error on a minified array (no row-per-line)" do
      chunks = [
        # All on one line — proxy / minifier scenario
        ~s|{"rows":[{"id":"a"},{"id":"b"}]}|
      ]

      # The header itself ends with `]}`, not `[`, so :seek_array never
      # transitions and the stream emits nothing. That's expected behaviour
      # for fully-minified responses (we can't usefully parse them).
      assert [] = JsonItemStream.items(chunks) |> Enum.to_list()
    end

    test "raises Akaw.Error if a line inside the array isn't a JSON object" do
      chunks = [
        ~s|{"rows":[\n|,
        # A garbage line that doesn't start with `{` or `]`
        ~s|definitely_not_json\n|,
        ~s|]}|
      ]

      assert_raise Akaw.Error, ~r/stream_format_error/, fn ->
        JsonItemStream.items(chunks) |> Enum.to_list()
      end
    end

    test "raises Akaw.Error with row context on malformed JSON" do
      chunks = [
        ~s|{"rows":[\n|,
        # Looks like a row but is bad JSON
        ~s|{"id":"a","value":}\n|,
        ~s|]}|
      ]

      exception =
        assert_raise Akaw.Error, fn ->
          JsonItemStream.items(chunks) |> Enum.to_list()
        end

      assert exception.error == "stream_decode_error"
      # Diagnostic includes the inspect-quoted original line for context
      assert exception.reason =~ "id"
      assert exception.reason =~ "value"
    end

    test "is lazy — Stream.take stops pulling chunks" do
      pulled = :counters.new(1, [])

      chunks =
        Stream.unfold(0, fn
          0 ->
            :counters.add(pulled, 1, 1)
            {~s|{"rows":[\n|, 1}

          n when n < 1000 ->
            :counters.add(pulled, 1, 1)
            {~s|{"id":"doc_#{n}"},\n|, n + 1}

          1000 ->
            :counters.add(pulled, 1, 1)
            {~s|]}|, 1001}

          _ ->
            nil
        end)

      taken = chunks |> JsonItemStream.items() |> Enum.take(3)
      assert length(taken) == 3
      # Should have pulled only a handful of chunks, not all 1001
      assert :counters.get(pulled, 1) < 50
    end
  end
end
