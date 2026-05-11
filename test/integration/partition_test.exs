defmodule Akaw.Integration.PartitionTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  import Akaw.IntegrationHelpers

  setup do
    client = client()
    db = unique_db_name()
    {:ok, _} = Akaw.Database.create(client, db, partitioned: true)
    on_exit(fn -> Akaw.Database.delete(client, db) end)

    # Seed two partitions
    {:ok, _} = Akaw.Document.put(client, db, "tenant1:u1", %{name: "alice"})
    {:ok, _} = Akaw.Document.put(client, db, "tenant1:u2", %{name: "bob"})
    {:ok, _} = Akaw.Document.put(client, db, "tenant2:u1", %{name: "carol"})

    {:ok, client: client, db: db}
  end

  test "info/3 returns partition stats", %{client: client, db: db} do
    assert {:ok, info} = Akaw.Partition.info(client, db, "tenant1")
    assert info["partition"] == "tenant1"
    assert info["doc_count"] == 2
  end

  test "all_docs/4 lists only docs in the partition", %{client: client, db: db} do
    assert {:ok, %{"rows" => rows}} = Akaw.Partition.all_docs(client, db, "tenant1")
    ids = Enum.map(rows, & &1["id"]) |> Enum.sort()
    assert ids == ["tenant1:u1", "tenant1:u2"]
  end

  test "find/4 scoped to a partition", %{client: client, db: db} do
    assert {:ok, %{"docs" => docs}} =
             Akaw.Partition.find(client, db, "tenant1", %{
               selector: %{name: %{"$regex" => "^a"}}
             })

    names = Enum.map(docs, & &1["name"])
    assert names == ["alice"]
  end

  test "explain/4 returns a plan for the partition", %{client: client, db: db} do
    assert {:ok, plan} =
             Akaw.Partition.explain(client, db, "tenant1", %{
               selector: %{name: "alice"}
             })

    assert plan["partitioned"] == true
  end
end
