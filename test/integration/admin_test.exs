defmodule Akaw.Integration.AdminTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  import Akaw.IntegrationHelpers

  setup do
    {:ok, client: client()}
  end

  describe "Akaw.Node" do
    test "info/2 returns the local node's name", %{client: client} do
      assert {:ok, info} = Akaw.Node.info(client)
      assert is_binary(info["name"])
    end

    test "stats/2 returns nested CouchDB stats", %{client: client} do
      assert {:ok, stats} = Akaw.Node.stats(client)
      # stats are nested by section, e.g. couchdb, couch_replicator, etc.
      assert is_map(stats)
      assert Map.has_key?(stats, "couchdb")
    end

    test "system/2 returns VM-level metrics", %{client: client} do
      assert {:ok, sys} = Akaw.Node.system(client)
      # Memory, run_queue, etc.
      assert is_map(sys["memory"])
      assert is_integer(sys["run_queue"])
    end

    test "versions/2 returns Erlang/JS/ICU version info", %{client: client} do
      assert {:ok, vers} = Akaw.Node.versions(client)
      assert is_binary(vers["erlang"]["version"])
      assert is_list(vers["erlang"]["supported_hashes"])
      assert is_binary(vers["javascript_engine"]["name"])
      assert is_binary(vers["collation_driver"]["library_version"])
    end

    test "smoosh_status/2 returns channel status map", %{client: client} do
      assert {:ok, smoosh} = Akaw.Node.smoosh_status(client)
      assert is_map(smoosh)
    end
  end

  describe "Akaw.Config" do
    @section "akaw_test_section"
    @key "akaw_test_key"

    test "get/2 returns the full config map", %{client: client} do
      assert {:ok, cfg} = Akaw.Config.get(client)
      assert is_map(cfg)
      # CouchDB always has at least the "couchdb" section
      assert is_map(cfg["couchdb"])
    end

    test "get_section/3 → one section", %{client: client} do
      assert {:ok, section} = Akaw.Config.get_section(client, "couchdb")
      assert is_map(section)
      assert is_binary(section["uuid"])
    end

    test "get_value/4 → a single value", %{client: client} do
      assert {:ok, uuid} = Akaw.Config.get_value(client, "couchdb", "uuid")
      assert is_binary(uuid) and byte_size(uuid) > 0
    end

    test "put → get_value → delete roundtrip", %{client: client} do
      # Use a custom section/key so we don't disturb anything important.
      assert {:ok, _} = Akaw.Config.put(client, @section, @key, "hello")

      try do
        assert {:ok, "hello"} = Akaw.Config.get_value(client, @section, @key)
      after
        Akaw.Config.delete(client, @section, @key)
      end

      assert {:error, %Akaw.Error{status: 404}} =
               Akaw.Config.get_value(client, @section, @key)
    end
  end

  describe "Akaw.Cluster" do
    test "get/1 returns the cluster setup state", %{client: client} do
      assert {:ok, state} = Akaw.Cluster.get(client)
      assert is_binary(state["state"])
    end
  end

  describe "Akaw.Reshard" do
    test "summary/1 returns state + counts", %{client: client} do
      assert {:ok, info} = Akaw.Reshard.summary(client)
      assert is_binary(info["state"])
      assert is_integer(info["total"])
    end

    test "state/1 returns running/stopped", %{client: client} do
      assert {:ok, st} = Akaw.Reshard.state(client)
      assert st["state"] in ["running", "stopped"]
    end

    test "jobs/1 returns a {jobs, offset, total_rows} map", %{client: client} do
      assert {:ok, %{"jobs" => jobs, "offset" => offset, "total_rows" => total}} =
               Akaw.Reshard.jobs(client)

      assert is_list(jobs)
      assert is_integer(offset)
      assert is_integer(total)
    end
  end
end
