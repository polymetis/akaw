defmodule Akaw.Integration.DatabaseTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  import Akaw.IntegrationHelpers

  setup do
    {:ok, client: client()}
  end

  describe "Database lifecycle" do
    test "create → info → head → delete", %{client: client} do
      db = unique_db_name()

      assert {:ok, %{"ok" => true}} = Akaw.Database.create(client, db)
      assert {:ok, info} = Akaw.Database.info(client, db)
      assert info["db_name"] == db
      assert info["doc_count"] == 0

      assert :ok = Akaw.Database.head(client, db)
      assert {:ok, _} = Akaw.Database.delete(client, db)

      assert {:error, %Akaw.Error{status: 404}} = Akaw.Database.head(client, db)
    end

    test "create on an existing db returns 412", %{client: client} do
      db = setup_temp_db(client)
      assert {:error, %Akaw.Error{status: 412}} = Akaw.Database.create(client, db)
    end

    test "delete on missing db returns 404", %{client: client} do
      assert {:error, %Akaw.Error{status: 404}} =
               Akaw.Database.delete(client, "definitely_does_not_exist")
    end

    test "post/3 creates a doc with a server-generated id", %{client: client} do
      db = setup_temp_db(client)

      assert {:ok, %{"id" => id, "rev" => rev, "ok" => true}} =
               Akaw.Database.post(client, db, %{name: "alice"})

      assert is_binary(id) and byte_size(id) > 0
      assert String.starts_with?(rev, "1-")
    end
  end

  describe "Maintenance" do
    test "compact/2", %{client: client} do
      db = setup_temp_db(client)
      assert {:ok, %{"ok" => true}} = Akaw.Database.compact(client, db)
    end

    test "view_cleanup/2", %{client: client} do
      db = setup_temp_db(client)
      assert {:ok, %{"ok" => true}} = Akaw.Database.view_cleanup(client, db)
    end

    test "ensure_full_commit/2", %{client: client} do
      db = setup_temp_db(client)
      assert {:ok, %{"ok" => true}} = Akaw.Database.ensure_full_commit(client, db)
    end

    test "revs_limit get/put roundtrip", %{client: client} do
      db = setup_temp_db(client)
      assert {:ok, original} = Akaw.Database.revs_limit(client, db)
      assert is_integer(original)

      assert {:ok, _} = Akaw.Database.put_revs_limit(client, db, 500)
      assert {:ok, 500} = Akaw.Database.revs_limit(client, db)
    end
  end

  describe "Akaw.Security" do
    test "get on a fresh db returns an empty security object", %{client: client} do
      db = setup_temp_db(client)
      assert {:ok, sec} = Akaw.Security.get(client, db)
      # CouchDB returns either {} or {admins: {names:[],roles:[]}, members: {...}}
      assert is_map(sec)
    end

    test "put + get roundtrip", %{client: client} do
      db = setup_temp_db(client)

      sec = %{
        admins: %{names: ["alice"], roles: ["dba"]},
        members: %{names: ["bob"], roles: ["users"]}
      }

      assert {:ok, %{"ok" => true}} = Akaw.Security.put(client, db, sec)
      assert {:ok, fetched} = Akaw.Security.get(client, db)
      assert fetched["admins"]["names"] == ["alice"]
      assert fetched["members"]["roles"] == ["users"]
    end
  end

  describe "Akaw.Purge" do
    test "purge a doc revision physically removes it", %{client: client} do
      db = setup_temp_db(client)
      {:ok, %{"id" => id, "rev" => rev}} = Akaw.Database.post(client, db, %{n: 1})

      assert {:ok, %{"purged" => purged}} =
               Akaw.Purge.purge(client, db, %{id => [rev]})

      assert purged[id] == [rev]

      assert {:error, %Akaw.Error{status: 404}} = Akaw.Document.get(client, db, id)
    end

    test "purged_infos and purged_infos_limit", %{client: client} do
      db = setup_temp_db(client)
      assert {:ok, %{"purged_infos" => _}} = Akaw.Purge.purged_infos(client, db)
      assert {:ok, limit} = Akaw.Purge.purged_infos_limit(client, db)
      assert is_integer(limit)
      assert {:ok, _} = Akaw.Purge.put_purged_infos_limit(client, db, 1000)
    end
  end
end
