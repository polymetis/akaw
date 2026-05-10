defmodule Akaw.Integration.EdgeCasesTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  import Akaw.IntegrationHelpers

  setup do
    client = client()
    db = setup_temp_db(client)
    {:ok, client: client, db: db}
  end

  describe "non-ASCII doc ids" do
    test "Japanese doc id roundtrip", %{client: client, db: db} do
      id = "ドキュメント_42"
      {:ok, %{"rev" => rev}} = Akaw.Document.put(client, db, id, %{name: "テスト"})
      assert {:ok, doc} = Akaw.Document.get(client, db, id)
      assert doc["_id"] == id
      assert doc["name"] == "テスト"
      assert {:ok, _} = Akaw.Document.delete(client, db, id, rev)
    end

    test "emoji doc id roundtrip", %{client: client, db: db} do
      id = "user_🎉_v2"
      {:ok, _} = Akaw.Document.put(client, db, id, %{ok: true})
      assert {:ok, doc} = Akaw.Document.get(client, db, id)
      assert doc["_id"] == id
      assert doc["ok"] == true
    end

    test "doc id with slashes (encoded as %2F) roundtrips", %{client: client, db: db} do
      id = "path/with/slashes"
      {:ok, _} = Akaw.Document.put(client, db, id, %{n: 1})
      assert {:ok, doc} = Akaw.Document.get(client, db, id)
      assert doc["_id"] == id
    end

    test "doc id with %, &, =, ?, # roundtrips", %{client: client, db: db} do
      id = "weird=key&val=100%?x#y"
      {:ok, _} = Akaw.Document.put(client, db, id, %{ok: true})
      assert {:ok, doc} = Akaw.Document.get(client, db, id)
      assert doc["_id"] == id
    end

    test "doc id with spaces", %{client: client, db: db} do
      id = "doc with spaces"
      {:ok, _} = Akaw.Document.put(client, db, id, %{})
      assert {:ok, doc} = Akaw.Document.get(client, db, id)
      assert doc["_id"] == id
    end
  end

  describe "large payloads" do
    test "doc body of ~100 KB roundtrips", %{client: client, db: db} do
      large = String.duplicate("xyzzy_", 17_000)
      assert {:ok, _} = Akaw.Document.put(client, db, "big", %{data: large})
      assert {:ok, doc} = Akaw.Document.get(client, db, "big")
      assert doc["data"] == large
    end

    test "bulk_docs of 100 docs in one request", %{client: client, db: db} do
      docs = for i <- 1..100, do: %{_id: "doc_#{i}", n: i}
      assert {:ok, results} = Akaw.Documents.bulk_docs(client, db, docs)
      assert length(results) == 100
      assert Enum.all?(results, & &1["ok"])

      assert {:ok, %{"total_rows" => 100}} = Akaw.Documents.all_docs(client, db)
    end
  end

  describe "attachment filename edges" do
    test "filename with spaces", %{client: client, db: db} do
      {:ok, %{"rev" => rev}} = Akaw.Document.put(client, db, "u1", %{})

      {:ok, _} =
        Akaw.Attachment.put(client, db, "u1", "my photo.jpg", <<0, 1, 2, 3>>,
          content_type: "image/jpeg",
          rev: rev
        )

      assert {:ok, body, meta} = Akaw.Attachment.get(client, db, "u1", "my photo.jpg")
      assert body == <<0, 1, 2, 3>>
      assert meta.content_type == "image/jpeg"
    end

    test "filename with multiple dots", %{client: client, db: db} do
      {:ok, %{"rev" => rev}} = Akaw.Document.put(client, db, "u1", %{})

      {:ok, _} =
        Akaw.Attachment.put(client, db, "u1", "report.v2.final.pdf", <<37, 80, 68, 70>>,
          content_type: "application/pdf",
          rev: rev
        )

      assert :ok = Akaw.Attachment.head(client, db, "u1", "report.v2.final.pdf")
    end
  end

  describe "soft delete" do
    test "delete leaves a tombstone visible in _changes", %{client: client, db: db} do
      {:ok, %{"rev" => rev}} = Akaw.Document.put(client, db, "doomed", %{})
      {:ok, _} = Akaw.Document.delete(client, db, "doomed", rev)

      assert {:ok, %{"results" => results}} = Akaw.Changes.get(client, db, since: 0)
      tombstone = Enum.find(results, &(&1["id"] == "doomed"))
      assert tombstone["deleted"] == true
    end

    test "deleted doc returns 404 on GET (without ?rev)", %{client: client, db: db} do
      {:ok, %{"rev" => rev}} = Akaw.Document.put(client, db, "doomed", %{n: 1})
      {:ok, _} = Akaw.Document.delete(client, db, "doomed", rev)
      assert {:error, %Akaw.Error{status: 404}} = Akaw.Document.get(client, db, "doomed")
    end
  end

  describe "concurrent updates" do
    test "second writer with stale rev gets 409", %{client: client, db: db} do
      {:ok, %{"rev" => rev1}} = Akaw.Document.put(client, db, "race", %{n: 0})

      assert {:ok, _} = Akaw.Document.put(client, db, "race", %{n: 1, _rev: rev1})

      assert {:error, %Akaw.Error{status: 409, error: "conflict"}} =
               Akaw.Document.put(client, db, "race", %{n: 2, _rev: rev1})
    end
  end

  describe "stream halt + restart" do
    test "Stream.take(N) closes cleanly; another stream right after still works",
         %{client: client, db: db} do
      for i <- 1..5 do
        {:ok, _} = Akaw.Document.put(client, db, "doc_#{i}", %{i: i})
      end

      first = client |> Akaw.Changes.stream(db, since: 0) |> Enum.take(3)
      assert length(first) == 3

      # If the previous stream's resources weren't cleaned up properly, this
      # second stream might inherit stale messages from the old request and
      # see weird behavior.
      second = client |> Akaw.Changes.stream(db, since: 0) |> Enum.take(2)
      assert length(second) == 2
    end
  end

  describe "empty inputs against real CouchDB" do
    test "bulk_docs with empty list returns empty result list",
         %{client: client, db: db} do
      assert {:ok, []} = Akaw.Documents.bulk_docs(client, db, [])
    end

    test "all_docs_keys with empty keys returns empty rows",
         %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "a", %{})
      assert {:ok, %{"rows" => []}} = Akaw.Documents.all_docs_keys(client, db, [])
    end
  end
end
