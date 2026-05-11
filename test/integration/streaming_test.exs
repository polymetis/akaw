defmodule Akaw.Integration.StreamingTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  import Akaw.IntegrationHelpers

  setup do
    client = client()
    db = setup_temp_db(client)
    {:ok, client: client, db: db}
  end

  describe "Akaw.Documents.stream_all_docs/3" do
    test "empty db emits no items", %{client: client, db: db} do
      assert [] = Akaw.Documents.stream_all_docs(client, db) |> Enum.to_list()
    end

    test "matches all_docs/3 row-for-row", %{client: client, db: db} do
      for i <- 1..10 do
        {:ok, _} = Akaw.Document.put(client, db, "doc_#{i}", %{n: i})
      end

      {:ok, %{"rows" => sync_rows}} = Akaw.Documents.all_docs(client, db)
      streamed = Akaw.Documents.stream_all_docs(client, db) |> Enum.to_list()

      assert length(streamed) == length(sync_rows)

      assert Enum.map(streamed, & &1["id"]) |> Enum.sort() ==
               Enum.map(sync_rows, & &1["id"]) |> Enum.sort()
    end

    test "include_docs flag is forwarded", %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "a", %{name: "alice"})

      [row] = Akaw.Documents.stream_all_docs(client, db, include_docs: true) |> Enum.to_list()
      assert row["doc"]["name"] == "alice"
    end

    test "Stream.take(N) halts mid-stream and cleans up", %{client: client, db: db} do
      docs = for i <- 1..100, do: %{_id: "doc_#{i}", n: i}
      {:ok, _} = Akaw.Documents.bulk_docs(client, db, docs)

      taken = Akaw.Documents.stream_all_docs(client, db) |> Enum.take(5)
      assert length(taken) == 5

      # Connection cleanup didn't leave orphaned state — second stream still works
      again = Akaw.Documents.stream_all_docs(client, db) |> Enum.take(3)
      assert length(again) == 3
    end

    test "raises Akaw.Error for missing database", %{client: client} do
      assert_raise Akaw.Error, ~r/404/, fn ->
        Akaw.Documents.stream_all_docs(client, "definitely_not_a_db") |> Enum.take(1)
      end
    end
  end

  describe "Akaw.View.stream/5" do
    setup %{client: client, db: db} do
      ddoc = %{
        language: "javascript",
        views: %{by_n: %{map: "function(d){ if (d.n) emit(d.n, d.n); }"}}
      }

      {:ok, _} = Akaw.DesignDoc.put(client, db, "v", ddoc)

      docs = for i <- 1..20, do: %{_id: "doc_#{i}", n: i}
      {:ok, _} = Akaw.Documents.bulk_docs(client, db, docs)
      :ok
    end

    test "streams all rows", %{client: client, db: db} do
      streamed = Akaw.View.stream(client, db, "v", "by_n") |> Enum.to_list()
      assert length(streamed) == 20
    end

    test "respects limit option", %{client: client, db: db} do
      streamed = Akaw.View.stream(client, db, "v", "by_n", limit: 5) |> Enum.to_list()
      assert length(streamed) == 5
    end

    test "respects startkey/endkey", %{client: client, db: db} do
      streamed =
        Akaw.View.stream(client, db, "v", "by_n", startkey: 5, endkey: 8) |> Enum.to_list()

      keys = Enum.map(streamed, & &1["key"])
      assert keys == [5, 6, 7, 8]
    end
  end

  describe "Akaw.Find.stream_find/3" do
    setup %{client: client, db: db} do
      docs = for i <- 1..20, do: %{_id: "doc_#{i}", n: i}
      {:ok, _} = Akaw.Documents.bulk_docs(client, db, docs)
      :ok
    end

    test "streams all matching docs", %{client: client, db: db} do
      streamed =
        Akaw.Find.stream_find(client, db, %{
          selector: %{n: %{"$gt" => 10}},
          limit: 100
        })
        |> Enum.to_list()

      assert length(streamed) == 10
      assert Enum.all?(streamed, &(&1["n"] > 10))
    end

    test "empty result set", %{client: client, db: db} do
      assert [] =
               Akaw.Find.stream_find(client, db, %{selector: %{n: %{"$gt" => 1_000_000}}})
               |> Enum.to_list()
    end
  end
end
