defmodule Akaw.Integration.ReduceWhileTest do
  use ExUnit.Case, async: true

  # Integration tests for the synchronous `reduce_while` callback API.
  # Unlike the unit tests in test/akaw/reduce_while_test.exs (which use
  # Req's :plug adapter that buffers the body into one chunk), these run
  # against a real CouchDB so chunk-boundary behavior, line splitting,
  # and the JSON-item state machine are all exercised end-to-end.

  @moduletag :integration

  import Akaw.IntegrationHelpers

  setup do
    client = client()
    db = setup_temp_db(client)
    {:ok, client: client, db: db}
  end

  describe "Akaw.Documents.reduce_while_all_docs/5" do
    test "matches stream_all_docs/3 row-for-row", %{client: client, db: db} do
      docs = for i <- 1..50, do: %{_id: "doc_#{i}", n: i}
      {:ok, _} = Akaw.Documents.bulk_docs(client, db, docs)

      streamed =
        client
        |> Akaw.Documents.stream_all_docs(db)
        |> Enum.map(& &1["id"])
        |> Enum.sort()

      assert {:ok, reduced} =
               Akaw.Documents.reduce_while_all_docs(client, db, [], fn row, acc ->
                 {:cont, [row["id"] | acc]}
               end)

      assert Enum.sort(reduced) == streamed
    end

    test ":halt closes the connection early", %{client: client, db: db} do
      docs = for i <- 1..200, do: %{_id: "doc_#{i}", n: i}
      {:ok, _} = Akaw.Documents.bulk_docs(client, db, docs)

      assert {:ok, ids} =
               Akaw.Documents.reduce_while_all_docs(client, db, [], fn row, acc ->
                 if length(acc) >= 4 do
                   {:halt, [row["id"] | acc]}
                 else
                   {:cont, [row["id"] | acc]}
                 end
               end)

      assert length(ids) == 5
    end

    test "returns {:error, %Akaw.Error{}} for missing db", %{client: client} do
      assert {:error, %Akaw.Error{status: 404}} =
               Akaw.Documents.reduce_while_all_docs(
                 client,
                 "definitely_not_a_db",
                 0,
                 fn _, n -> {:cont, n + 1} end
               )
    end
  end

  describe "Akaw.View.reduce_while/7" do
    setup %{client: client, db: db} do
      ddoc = %{
        language: "javascript",
        views: %{by_n: %{map: "function(d){ if (d.n) emit(d.n, d.n); }"}}
      }

      {:ok, _} = Akaw.DesignDoc.put(client, db, "v", ddoc)

      docs = for i <- 1..30, do: %{_id: "doc_#{i}", n: i}
      {:ok, _} = Akaw.Documents.bulk_docs(client, db, docs)
      :ok
    end

    test "reduces all rows", %{client: client, db: db} do
      assert {:ok, n} =
               Akaw.View.reduce_while(client, db, "v", "by_n", 0, fn _, count ->
                 {:cont, count + 1}
               end)

      assert n == 30
    end

    test "startkey/endkey are JSON-encoded", %{client: client, db: db} do
      assert {:ok, keys} =
               Akaw.View.reduce_while(
                 client,
                 db,
                 "v",
                 "by_n",
                 [],
                 fn row, acc -> {:cont, [row["key"] | acc]} end,
                 startkey: 5,
                 endkey: 8
               )

      assert Enum.sort(keys) == [5, 6, 7, 8]
    end
  end

  describe "Akaw.Find.reduce_while/5" do
    test "reduces matching docs", %{client: client, db: db} do
      docs = for i <- 1..30, do: %{_id: "doc_#{i}", n: i}
      {:ok, _} = Akaw.Documents.bulk_docs(client, db, docs)

      assert {:ok, count} =
               Akaw.Find.reduce_while(
                 client,
                 db,
                 %{selector: %{n: %{"$gt" => 10}}, limit: 100},
                 0,
                 fn _, n -> {:cont, n + 1} end
               )

      assert count == 20
    end
  end

  describe "Akaw.Partition reduce_while_*" do
    setup do
      client = client()
      db = unique_db_name()
      {:ok, _} = Akaw.Database.create(client, db, partitioned: true)
      on_exit(fn -> Akaw.Database.delete(client, db) end)

      for i <- 1..5 do
        {:ok, _} = Akaw.Document.put(client, db, "tenant1:doc_#{i}", %{n: i})
        {:ok, _} = Akaw.Document.put(client, db, "tenant2:doc_#{i}", %{n: i})
      end

      {:ok, client: client, db: db}
    end

    test "reduce_while_all_docs/6 only sees the requested partition",
         %{client: client, db: db} do
      assert {:ok, ids} =
               Akaw.Partition.reduce_while_all_docs(client, db, "tenant1", [], fn row, acc ->
                 {:cont, [row["id"] | acc]}
               end)

      assert Enum.sort(ids) == [
               "tenant1:doc_1",
               "tenant1:doc_2",
               "tenant1:doc_3",
               "tenant1:doc_4",
               "tenant1:doc_5"
             ]
    end

    test "reduce_while_find/7 reduces docs in a single partition",
         %{client: client, db: db} do
      assert {:ok, count} =
               Akaw.Partition.reduce_while_find(
                 client,
                 db,
                 "tenant1",
                 %{selector: %{n: %{"$gt" => 0}}},
                 0,
                 fn _, n -> {:cont, n + 1} end
               )

      assert count == 5
    end
  end

  describe "Akaw.Changes.reduce_while/5" do
    # Live-arrival test: we want to prove the callback API sees changes
    # written *after* the connection opens, not just pre-existing ones.
    # That needs a sync point. Previously this used Process.sleep(300)
    # which races on slow CI; now the reducer sends a message back to
    # the test once it observes a sentinel doc, and we only write the
    # real test docs after that.
    test "picks up changes that arrive after the connection opens",
         %{client: client, db: db} do
      test = self()

      task =
        Task.async(fn ->
          Akaw.Changes.reduce_while(
            client,
            db,
            [],
            fn change, acc ->
              case change["id"] do
                "sentinel" ->
                  send(test, :feed_open)
                  {:cont, acc}

                id ->
                  new = [id | acc]
                  if length(new) >= 2, do: {:halt, new}, else: {:cont, new}
              end
            end,
            since: "now",
            heartbeat: 5_000
          )
        end)

      # Sentinel proves the feed is established and receiving;
      # writing live1/live2 only after we see it.
      {:ok, _} = Akaw.Document.put(client, db, "sentinel", %{})
      assert_receive :feed_open, 5_000

      {:ok, _} = Akaw.Document.put(client, db, "live1", %{n: 1})
      {:ok, _} = Akaw.Document.put(client, db, "live2", %{n: 2})

      assert {:ok, ids} = Task.await(task, 10_000)
      assert Enum.sort(ids) == ["live1", "live2"]
    end

    test "returns {:error, %Akaw.Error{}} for a missing db", %{client: client} do
      assert {:error, %Akaw.Error{status: 404}} =
               Akaw.Changes.reduce_while(
                 client,
                 "definitely_not_a_db",
                 0,
                 fn _, n -> {:cont, n + 1} end
               )
    end
  end
end
