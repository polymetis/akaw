defmodule Akaw.Integration.DocumentTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  import Akaw.IntegrationHelpers

  setup do
    client = client()
    db = setup_temp_db(client)
    {:ok, client: client, db: db}
  end

  describe "Akaw.Document" do
    test "put → get → update → delete lifecycle", %{client: client, db: db} do
      assert {:ok, %{"id" => "u1", "rev" => rev1}} =
               Akaw.Document.put(client, db, "u1", %{name: "alice"})

      assert {:ok, doc} = Akaw.Document.get(client, db, "u1")
      assert doc["name"] == "alice"
      assert doc["_rev"] == rev1

      assert {:ok, %{"rev" => rev2}} =
               Akaw.Document.put(client, db, "u1", %{name: "alice", age: 30, _rev: rev1})

      assert {:ok, %{"age" => 30}} = Akaw.Document.get(client, db, "u1")

      assert {:ok, _} = Akaw.Document.delete(client, db, "u1", rev2)
      assert {:error, %Akaw.Error{status: 404}} = Akaw.Document.get(client, db, "u1")
    end

    test "put with stale rev returns 409 conflict", %{client: client, db: db} do
      {:ok, %{"rev" => rev1}} = Akaw.Document.put(client, db, "u1", %{n: 1})
      # update once
      {:ok, _} = Akaw.Document.put(client, db, "u1", %{n: 2, _rev: rev1})
      # try update again with stale rev
      assert {:error, %Akaw.Error{status: 409}} =
               Akaw.Document.put(client, db, "u1", %{n: 3, _rev: rev1})
    end

    test "head/3 → :ok for existing, error for missing", %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "u1", %{})
      assert :ok = Akaw.Document.head(client, db, "u1")
      assert {:error, %Akaw.Error{status: 404}} = Akaw.Document.head(client, db, "missing")
    end

    test "copy/5 copies a doc to a new id", %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "src", %{name: "alice", age: 30})

      assert {:ok, %{"id" => "dest"}} = Akaw.Document.copy(client, db, "src", "dest")
      assert {:ok, copied} = Akaw.Document.get(client, db, "dest")
      assert copied["name"] == "alice"
      assert copied["age"] == 30
    end
  end

  describe "Akaw.Documents" do
    test "all_docs/3 returns the documents we put", %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "a", %{n: 1})
      {:ok, _} = Akaw.Document.put(client, db, "b", %{n: 2})
      {:ok, _} = Akaw.Document.put(client, db, "c", %{n: 3})

      assert {:ok, %{"rows" => rows, "total_rows" => 3}} =
               Akaw.Documents.all_docs(client, db)

      ids = Enum.map(rows, & &1["id"]) |> Enum.sort()
      assert ids == ["a", "b", "c"]
    end

    test "all_docs/3 with include_docs returns full bodies", %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "a", %{n: 1})

      assert {:ok, %{"rows" => [row]}} =
               Akaw.Documents.all_docs(client, db, include_docs: true)

      assert row["doc"]["n"] == 1
    end

    test "all_docs/3 with startkey/endkey filters by id", %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "user_1", %{})
      {:ok, _} = Akaw.Document.put(client, db, "user_2", %{})
      {:ok, _} = Akaw.Document.put(client, db, "post_1", %{})

      assert {:ok, %{"rows" => rows}} =
               Akaw.Documents.all_docs(client, db, startkey: "user_", endkey: "user_￰")

      ids = Enum.map(rows, & &1["id"])
      assert "user_1" in ids and "user_2" in ids
      refute "post_1" in ids
    end

    test "all_docs_keys/4 filters by an explicit key list", %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "a", %{})
      {:ok, _} = Akaw.Document.put(client, db, "b", %{})
      {:ok, _} = Akaw.Document.put(client, db, "c", %{})

      assert {:ok, %{"rows" => rows}} =
               Akaw.Documents.all_docs_keys(client, db, ["a", "c"])

      ids = Enum.map(rows, & &1["id"]) |> Enum.sort()
      assert ids == ["a", "c"]
    end

    test "bulk_docs/4 inserts many in one round-trip", %{client: client, db: db} do
      docs = [%{_id: "a", n: 1}, %{_id: "b", n: 2}, %{_id: "c", n: 3}]
      assert {:ok, results} = Akaw.Documents.bulk_docs(client, db, docs)
      assert length(results) == 3
      assert Enum.all?(results, & &1["ok"])
    end

    test "bulk_get/4 fetches many by id", %{client: client, db: db} do
      {:ok, %{"rev" => r1}} = Akaw.Document.put(client, db, "a", %{n: 1})
      {:ok, %{"rev" => r2}} = Akaw.Document.put(client, db, "b", %{n: 2})

      refs = [%{id: "a", rev: r1}, %{id: "b", rev: r2}]
      assert {:ok, %{"results" => results}} = Akaw.Documents.bulk_get(client, db, refs)
      assert length(results) == 2
    end
  end

  describe "Akaw.Attachment" do
    test "put → get → delete binary attachment roundtrip", %{client: client, db: db} do
      {:ok, %{"rev" => doc_rev}} = Akaw.Document.put(client, db, "u1", %{name: "alice"})

      png_bytes = <<137, 80, 78, 71, 13, 10, 26, 10>>

      {:ok, %{"rev" => att_rev}} =
        Akaw.Attachment.put(client, db, "u1", "thumb.png", png_bytes,
          content_type: "image/png",
          rev: doc_rev
        )

      assert {:ok, body, meta} = Akaw.Attachment.get(client, db, "u1", "thumb.png")
      assert body == png_bytes
      assert meta.content_type == "image/png"

      # ETag is the attachment's MD5 (in quotes per HTTP spec), not the
      # parent doc's rev — just verify it's a non-empty quoted string.
      assert is_binary(meta.etag)
      assert String.starts_with?(meta.etag, "\"")
      assert String.ends_with?(meta.etag, "\"")

      assert {:ok, _} = Akaw.Attachment.delete(client, db, "u1", "thumb.png", att_rev)

      assert {:error, %Akaw.Error{status: 404}} =
               Akaw.Attachment.head(client, db, "u1", "thumb.png")
    end
  end

  describe "Akaw.LocalDoc" do
    test "put → get → list → delete lifecycle", %{client: client, db: db} do
      assert {:ok, %{"rev" => rev}} =
               Akaw.LocalDoc.put(client, db, "checkpoint", %{seq: "1-abc"})

      assert {:ok, fetched} = Akaw.LocalDoc.get(client, db, "checkpoint")
      assert fetched["seq"] == "1-abc"
      assert fetched["_id"] == "_local/checkpoint"

      assert {:ok, %{"rows" => rows}} = Akaw.LocalDoc.list(client, db)
      assert Enum.any?(rows, &(&1["id"] == "_local/checkpoint"))

      assert {:ok, _} = Akaw.LocalDoc.delete(client, db, "checkpoint", rev)

      assert {:error, %Akaw.Error{status: 404}} =
               Akaw.LocalDoc.get(client, db, "checkpoint")
    end

    test "local docs are not returned by Documents.all_docs", %{client: client, db: db} do
      {:ok, _} = Akaw.LocalDoc.put(client, db, "checkpoint", %{seq: "1"})
      {:ok, _} = Akaw.Document.put(client, db, "regular", %{n: 1})

      assert {:ok, %{"rows" => rows}} = Akaw.Documents.all_docs(client, db)
      ids = Enum.map(rows, & &1["id"])
      assert "regular" in ids
      refute Enum.any?(ids, &String.starts_with?(&1, "_local/"))
    end
  end
end
