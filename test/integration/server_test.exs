defmodule Akaw.Integration.ServerTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  import Akaw.IntegrationHelpers

  setup_all do
    ensure_system_dbs(client())
    :ok
  end

  setup do
    {:ok, client: client()}
  end

  test "info/1 returns CouchDB welcome", %{client: client} do
    assert {:ok, info} = Akaw.Server.info(client)
    assert info["couchdb"] == "Welcome"
    assert is_binary(info["version"])
  end

  test "up/1 returns ok status", %{client: client} do
    assert {:ok, %{"status" => "ok"}} = Akaw.Server.up(client)
  end

  test "uuids/2 returns the requested count", %{client: client} do
    assert {:ok, %{"uuids" => uuids}} = Akaw.Server.uuids(client, count: 5)
    assert length(uuids) == 5
    assert Enum.all?(uuids, &is_binary/1)
  end

  test "all_dbs/2 returns a list including a temp db we just created", %{client: client} do
    db = setup_temp_db(client)
    assert {:ok, dbs} = Akaw.Server.all_dbs(client)
    assert is_list(dbs)
    assert db in dbs
  end

  test "dbs_info/2 returns info for given dbs", %{client: client} do
    db = setup_temp_db(client)
    assert {:ok, [%{"key" => ^db, "info" => info}]} = Akaw.Server.dbs_info(client, [db])
    assert info["db_name"] == db
  end

  test "active_tasks/1 returns a list (possibly empty)", %{client: client} do
    assert {:ok, tasks} = Akaw.Server.active_tasks(client)
    assert is_list(tasks)
  end

  test "membership/1 returns cluster info", %{client: client} do
    assert {:ok, info} = Akaw.Server.membership(client)
    assert is_list(info["all_nodes"])
    assert is_list(info["cluster_nodes"])
  end

  test "db_updates/2 with feed=normal returns immediately", %{client: client} do
    assert {:ok, %{"results" => results}} =
             Akaw.Server.db_updates(client, feed: "normal", timeout: 0)

    assert is_list(results)
  end
end

defmodule Akaw.Integration.ServerFinchPoolTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  import Akaw.IntegrationHelpers

  # The stderr captures these tests once carried died with the Req-era
  # deprecation warnings they refuted — nothing on the Finch-direct path
  # can emit one. What's left is the behavioral half: requests route
  # through the named pool (both spellings). The pool_tag *forwarding*
  # is pinned in the unit suite via Request.prepared/4, since Finch
  # silently falls back to the :default pool config for an unknown tag.
  describe "custom Finch pool" do
    test "a named pool routes requests" do
      name = :"akaw_it_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: name})

      assert {:ok, info} = Akaw.Server.info(client(finch: name))
      assert info["couchdb"] == "Welcome"
    end

    test "the keyword form routes too" do
      name = :"akaw_it_finch_kw_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: name})

      assert {:ok, info} = Akaw.Server.info(client(finch: [name: name, pool_tag: :bulk]))
      assert info["couchdb"] == "Welcome"
    end
  end
end
