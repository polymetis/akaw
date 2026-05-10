defmodule Akaw.PropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Akaw.{LineStream, Params}

  describe "Akaw.LineStream.lines/1" do
    property "reconstructs the original lines regardless of chunk boundaries" do
      check all(
              original_lines <- list_of(line_gen(), min_length: 1, max_length: 30),
              chunk_sizes <- list_of(positive_integer(), max_length: 20)
            ) do
        full = Enum.join(original_lines, "\n") <> "\n"
        chunks = chunk_binary(full, chunk_sizes)

        assert LineStream.lines(chunks) |> Enum.to_list() == original_lines
      end
    end

    property "never emits empty lines (heartbeats are filtered)" do
      check all(chunks <- list_of(string(:alphanumeric, max_length: 20), max_length: 30)) do
        result = LineStream.lines(chunks) |> Enum.to_list()
        refute "" in result
      end
    end

    property "every emitted line is a non-empty binary with no embedded newline" do
      check all(
              original_lines <- list_of(line_gen(), max_length: 20),
              chunk_sizes <- list_of(positive_integer(), max_length: 10)
            ) do
        full = Enum.join(original_lines, "\n") <> if original_lines == [], do: "", else: "\n"
        chunks = chunk_binary(full, chunk_sizes)

        for line <- LineStream.lines(chunks) do
          assert is_binary(line)
          assert byte_size(line) > 0
          refute String.contains?(line, "\n")
        end
      end
    end

    property "rechunking the same bytes gives the same output" do
      check all(
              original_lines <- list_of(line_gen(), min_length: 1, max_length: 20),
              sizes_a <- list_of(positive_integer(), max_length: 10),
              sizes_b <- list_of(positive_integer(), max_length: 10)
            ) do
        full = Enum.join(original_lines, "\n") <> "\n"
        a = full |> chunk_binary(sizes_a) |> LineStream.lines() |> Enum.to_list()
        b = full |> chunk_binary(sizes_b) |> LineStream.lines() |> Enum.to_list()
        assert a == b
      end
    end
  end

  describe "Akaw.Params.encode_json_keys/1" do
    property "JSON-typed values produce valid JSON that roundtrips" do
      check all(
              key <- member_of([:startkey, :endkey, :key, :start_key, :end_key]),
              value <- json_value_gen()
            ) do
        result = Params.encode_json_keys([{key, value}])
        assert [{^key, encoded}] = result
        assert is_binary(encoded)
        assert Jason.decode!(encoded) == jsonify(value)
      end
    end

    property "non-JSON-typed entries pass through unchanged" do
      check all(
              entries <-
                list_of(
                  {member_of([:limit, :skip, :descending, :include_docs]),
                   one_of([integer(), boolean(), string(:alphanumeric)])},
                  max_length: 6
                )
            ) do
        assert Params.encode_json_keys(entries) == entries
      end
    end

    property "mixed input — JSON keys get encoded, others unchanged" do
      check all(
              json_v <- json_value_gen(),
              limit <- positive_integer()
            ) do
        input = [startkey: json_v, limit: limit]
        result = Params.encode_json_keys(input)

        assert {:limit, ^limit} = List.keyfind(result, :limit, 0)
        {:startkey, encoded} = List.keyfind(result, :startkey, 0)
        assert Jason.decode!(encoded) == jsonify(json_v)
      end
    end
  end

  describe "URL doc-id encoding" do
    property "URI.encode + URI.decode roundtrip preserves arbitrary UTF-8" do
      check all(id <- string(:utf8, min_length: 1, max_length: 60)) do
        encoded = URI.encode(id, &URI.char_unreserved?/1)
        assert URI.decode(encoded) == id
      end
    end

    property "encoded path is ASCII-only (no unreserved characters escape)" do
      check all(id <- string(:utf8, min_length: 1, max_length: 60)) do
        encoded = URI.encode(id, &URI.char_unreserved?/1)
        # Result must be valid 7-bit ASCII; percent-encoding handles everything else
        assert String.printable?(encoded)
        refute encoded =~ ~r/[^\x20-\x7E]/
      end
    end
  end

  describe "basic auth header" do
    property "Authorization: Basic roundtrips through Base.decode64 to 'user:pass'" do
      check all(
              user <- string(:alphanumeric, min_length: 1, max_length: 20),
              pass <- string(:printable, max_length: 30)
            ) do
        test = self()

        plug = fn conn ->
          send(test, Plug.Conn.get_req_header(conn, "authorization"))
          Req.Test.json(conn, %{})
        end

        client =
          Akaw.new(
            base_url: "http://x",
            auth: {:basic, user, pass},
            req_options: [plug: plug]
          )

        assert {:ok, _} = Akaw.Server.info(client)
        assert_receive [auth_header]
        "Basic " <> b64 = auth_header
        assert Base.decode64!(b64) == user <> ":" <> pass
      end
    end
  end

  # --- generators & helpers ---

  defp line_gen do
    # Alphanumeric to avoid the need to filter newlines; covers the
    # buffering/splitting logic, which doesn't care about content.
    string(:alphanumeric, min_length: 1, max_length: 30)
  end

  defp json_value_gen do
    one_of([
      integer(),
      float(),
      boolean(),
      constant(nil),
      string(:alphanumeric, max_length: 20),
      list_of(integer(), max_length: 5),
      map_of(string(:alphanumeric, min_length: 1, max_length: 5), integer(), max_length: 5)
    ])
  end

  # Round-trip a value through Jason — atom map keys become strings, etc.
  defp jsonify(v), do: v |> Jason.encode!() |> Jason.decode!()

  # Split a binary into chunks of the given byte sizes. If `sizes` runs
  # out before the binary, the rest is emitted as one final chunk.
  defp chunk_binary("", _sizes), do: []
  defp chunk_binary(binary, []), do: [binary]

  defp chunk_binary(binary, [size | rest]) do
    size = max(size, 1)
    binary_size = byte_size(binary)

    if size >= binary_size do
      [binary]
    else
      <<chunk::binary-size(size), tail::binary>> = binary
      [chunk | chunk_binary(tail, rest)]
    end
  end
end
