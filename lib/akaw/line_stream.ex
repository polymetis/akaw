defmodule Akaw.LineStream do
  @moduledoc false

  # Splits an enumerable of binary chunks into a stream of newline-delimited
  # lines. Used by `Akaw.Changes.stream/3` to turn raw HTTP chunks (which can
  # split mid-line) into one-JSON-object-per-element.
  #
  # Empty lines are dropped — CouchDB uses them as continuous-feed
  # heartbeats. The trailing partial line is buffered until the next chunk
  # arrives; when the source halts, any non-empty trailing buffer is emitted
  # as a final line.

  @doc """
  Convert an enumerable of binary chunks into a stream of complete lines.
  Heartbeat (empty) lines are filtered out.
  """
  @spec lines(Enumerable.t(binary())) :: Enumerable.t(String.t())
  def lines(chunks) do
    Stream.transform(
      chunks,
      fn -> "" end,
      fn chunk, buffer -> split(buffer <> chunk) end,
      fn
        "" -> {[], ""}
        trailing -> {[trailing], ""}
      end,
      fn _ -> :ok end
    )
    |> Stream.reject(&(&1 == ""))
  end

  defp split(buffer) do
    parts = :binary.split(buffer, "\n", [:global])
    {complete, [tail]} = Enum.split(parts, length(parts) - 1)
    {complete, tail}
  end
end
