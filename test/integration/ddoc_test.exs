defmodule Akaw.Integration.DDocTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  import Akaw.IntegrationHelpers

  setup do
    client = client()
    db = setup_temp_db(client)
    {:ok, client: client, db: db}
  end

  describe "Akaw.DesignDoc" do
    test "put → get → info → delete", %{client: client, db: db} do
      ddoc = %{
        language: "javascript",
        views: %{
          by_name: %{
            map: "function(doc) { if (doc.name) emit(doc.name, doc); }"
          }
        }
      }

      assert {:ok, %{"id" => "_design/users", "rev" => rev}} =
               Akaw.DesignDoc.put(client, db, "users", ddoc)

      assert {:ok, fetched} = Akaw.DesignDoc.get(client, db, "users")
      assert fetched["language"] == "javascript"
      assert fetched["views"]["by_name"]["map"] =~ "emit"

      assert {:ok, info} = Akaw.DesignDoc.info(client, db, "users")
      assert info["name"] == "users"

      assert {:ok, _} = Akaw.DesignDoc.delete(client, db, "users", rev)
    end
  end

  describe "Akaw.View" do
    setup %{client: client, db: db} do
      ddoc = %{
        language: "javascript",
        views: %{
          by_name: %{
            map: "function(doc) { if (doc.name) emit(doc.name, doc.age); }"
          }
        }
      }

      {:ok, _} = Akaw.DesignDoc.put(client, db, "users", ddoc)
      {:ok, _} = Akaw.Document.put(client, db, "u1", %{name: "alice", age: 30})
      {:ok, _} = Akaw.Document.put(client, db, "u2", %{name: "bob", age: 25})
      {:ok, _} = Akaw.Document.put(client, db, "u3", %{name: "carol", age: 40})
      :ok
    end

    test "view returns the emitted rows", %{client: client, db: db} do
      assert {:ok, %{"rows" => rows, "total_rows" => 3}} =
               Akaw.View.get(client, db, "users", "by_name")

      keys = Enum.map(rows, & &1["key"])
      assert keys == ["alice", "bob", "carol"]
    end

    test "view with key filter", %{client: client, db: db} do
      assert {:ok, %{"rows" => [row]}} =
               Akaw.View.get(client, db, "users", "by_name", key: "bob")

      assert row["key"] == "bob"
      assert row["value"] == 25
    end

    test "view with startkey/endkey filter", %{client: client, db: db} do
      assert {:ok, %{"rows" => rows}} =
               Akaw.View.get(client, db, "users", "by_name", startkey: "b", endkey: "c￰")

      keys = Enum.map(rows, & &1["key"])
      assert keys == ["bob", "carol"]
    end

    test "view with include_docs", %{client: client, db: db} do
      assert {:ok, %{"rows" => rows}} =
               Akaw.View.get(client, db, "users", "by_name",
                 include_docs: true,
                 limit: 1
               )

      [row] = rows
      assert row["doc"]["name"] == "alice"
    end

    test "post_keys/6 with explicit key list", %{client: client, db: db} do
      assert {:ok, %{"rows" => rows}} =
               Akaw.View.post_keys(client, db, "users", "by_name", ["alice", "carol"])

      keys = Enum.map(rows, & &1["key"]) |> Enum.sort()
      assert keys == ["alice", "carol"]
    end
  end

  describe "Akaw.Find" do
    setup %{client: client, db: db} do
      {:ok, _} = Akaw.Document.put(client, db, "u1", %{name: "alice", age: 30})
      {:ok, _} = Akaw.Document.put(client, db, "u2", %{name: "bob", age: 25})
      {:ok, _} = Akaw.Document.put(client, db, "u3", %{name: "carol", age: 40})
      :ok
    end

    test "find/3 returns matching docs without an index", %{client: client, db: db} do
      assert {:ok, %{"docs" => docs, "warning" => _}} =
               Akaw.Find.find(client, db, %{
                 selector: %{age: %{"$gt" => 26}},
                 fields: ["_id", "name"]
               })

      names = Enum.map(docs, & &1["name"]) |> Enum.sort()
      assert names == ["alice", "carol"]
    end

    test "create_index → list_indexes → delete_index", %{client: client, db: db} do
      index_def = %{
        index: %{fields: ["age"]},
        name: "by_age",
        type: "json"
      }

      assert {:ok, %{"result" => "created", "id" => "_design/" <> ddoc_id}} =
               Akaw.Find.create_index(client, db, index_def)

      assert {:ok, %{"indexes" => indexes}} = Akaw.Find.list_indexes(client, db)
      assert Enum.any?(indexes, &(&1["name"] == "by_age"))

      assert {:ok, %{"ok" => true}} =
               Akaw.Find.delete_index(client, db, ddoc_id, "json", "by_age")
    end

    test "explain/3 returns the chosen index", %{client: client, db: db} do
      assert {:ok, plan} =
               Akaw.Find.explain(client, db, %{selector: %{name: "alice"}})

      assert plan["dbname"] == db
      assert is_map(plan["index"])
    end
  end
end
