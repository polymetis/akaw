defmodule Akaw.Integration.ChangesTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  import Akaw.IntegrationHelpers

  setup do
    client = client()
    db = setup_temp_db(client)
    {:ok, client: client, db: db}
  end

  describe "Akaw.Changes.get/3 (normal feed)" do
    test "returns existing changes since=0", %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "a", %{n: 1})
      {:ok, _} = Akaw.Document.put(client, db, "b", %{n: 2})

      assert {:ok, %{"results" => results, "last_seq" => last_seq}} =
               Akaw.Changes.get(client, db, since: 0)

      assert is_binary(last_seq)
      ids = Enum.map(results, & &1["id"]) |> Enum.sort()
      assert ids == ["a", "b"]
    end

    test "include_docs returns the doc body", %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "a", %{name: "alice"})

      assert {:ok, %{"results" => [change]}} =
               Akaw.Changes.get(client, db, since: 0, include_docs: true)

      assert change["doc"]["name"] == "alice"
    end

    test "longpoll with timeout=0 returns immediately when no changes",
         %{client: client, db: db} do
      assert {:ok, %{"results" => [], "last_seq" => _}} =
               Akaw.Changes.get(client, db, feed: "longpoll", since: "now", timeout: 0)
    end
  end

  describe "Akaw.Changes.post/4" do
    test "filter=_doc_ids restricts to listed docs", %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "a", %{})
      {:ok, _} = Akaw.Document.put(client, db, "b", %{})
      {:ok, _} = Akaw.Document.put(client, db, "c", %{})

      assert {:ok, %{"results" => results}} =
               Akaw.Changes.post(client, db, %{doc_ids: ["a", "c"]},
                 filter: "_doc_ids",
                 since: 0
               )

      ids = Enum.map(results, & &1["id"]) |> Enum.sort()
      assert ids == ["a", "c"]
    end
  end

  describe "Akaw.Changes.stream/3" do
    test "emits existing changes from since=0 then halts via Stream.take",
         %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "a", %{n: 1})
      {:ok, _} = Akaw.Document.put(client, db, "b", %{n: 2})
      {:ok, _} = Akaw.Document.put(client, db, "c", %{n: 3})

      changes =
        client
        |> Akaw.Changes.stream(db, since: 0)
        |> Enum.take(3)

      ids = Enum.map(changes, & &1["id"]) |> Enum.sort()
      assert ids == ["a", "b", "c"]
    end

    test "include_docs in the stream returns full doc bodies",
         %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "a", %{name: "alice"})

      [change] =
        client
        |> Akaw.Changes.stream(db, since: 0, include_docs: true)
        |> Enum.take(1)

      assert change["doc"]["name"] == "alice"
    end

    test "picks up changes that arrive after the stream is open",
         %{client: client, db: db} do
      # Same sync-point shape as the reduce_while live-arrival test (see
      # write_sentinels_until_feed_open): a sleep raced on slow CI —
      # since: "now" resolves after any write that lands before the
      # connection is established, so those changes are never delivered
      # and Enum.take blocks on heartbeats until the await raises.
      test = self()

      task =
        Task.async(fn ->
          client
          |> Akaw.Changes.stream(db, since: "now", heartbeat: 5_000)
          |> Stream.each(fn change ->
            if match?("sentinel" <> _, change["id"]), do: send(test, :feed_open)
          end)
          |> Stream.reject(&match?("sentinel" <> _, &1["id"]))
          |> Enum.take(2)
        end)

      assert :ok = write_sentinels_until_feed_open(client, db),
             "continuous feed never reported a sentinel"

      {:ok, _} = Akaw.Document.put(client, db, "live1", %{n: 1})
      {:ok, _} = Akaw.Document.put(client, db, "live2", %{n: 2})

      changes = Task.await(task, 10_000)
      ids = Enum.map(changes, & &1["id"]) |> Enum.sort()
      assert ids == ["live1", "live2"]
    end

    test "raises Akaw.Error on a missing database", %{client: client} do
      assert_raise Akaw.Error, ~r/404/, fn ->
        client
        |> Akaw.Changes.stream("definitely_does_not_exist")
        |> Enum.take(1)
      end
    end
  end
end
