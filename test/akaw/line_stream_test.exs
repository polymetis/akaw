defmodule Akaw.LineStreamTest do
  use ExUnit.Case, async: true

  alias Akaw.LineStream

  test "splits a single chunk into lines" do
    assert ["a", "b", "c"] = ["a\nb\nc\n"] |> LineStream.lines() |> Enum.to_list()
  end

  test "joins lines split across chunks" do
    chunks = ["he", "llo\nwo", "rld\n"]
    assert ["hello", "world"] = chunks |> LineStream.lines() |> Enum.to_list()
  end

  test "filters out empty (heartbeat) lines" do
    chunks = ["a\n\n\nb\n", "\n\nc\n"]
    assert ["a", "b", "c"] = chunks |> LineStream.lines() |> Enum.to_list()
  end

  test "emits trailing partial line when source halts" do
    chunks = ["a\nb\nc"]
    assert ["a", "b", "c"] = chunks |> LineStream.lines() |> Enum.to_list()
  end

  test "doesn't emit a trailing empty line on halt" do
    chunks = ["a\nb\n"]
    assert ["a", "b"] = chunks |> LineStream.lines() |> Enum.to_list()
  end

  test "handles a chunk that ends exactly on a newline" do
    chunks = ["a\n", "b\n", "c\n"]
    assert ["a", "b", "c"] = chunks |> LineStream.lines() |> Enum.to_list()
  end

  test "handles a chunk boundary inside a JSON-shaped string" do
    chunks = [~s|{"seq":"1","id":"a","changes":|, ~s|[{"rev":"1-x"}]}\n|]
    assert [line] = chunks |> LineStream.lines() |> Enum.to_list()
    assert JSON.decode!(line) == %{"seq" => "1", "id" => "a", "changes" => [%{"rev" => "1-x"}]}
  end

  test "is lazy — doesn't pull more chunks than needed" do
    pulled = :counters.new(1, [])

    chunks =
      Stream.unfold(0, fn n ->
        :counters.add(pulled, 1, 1)
        {"line#{n}\n", n + 1}
      end)

    chunks |> LineStream.lines() |> Enum.take(3)
    assert :counters.get(pulled, 1) <= 4
  end
end
