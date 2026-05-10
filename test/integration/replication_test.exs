defmodule Akaw.Integration.ReplicationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  import Akaw.IntegrationHelpers

  setup_all do
    ensure_system_dbs(client())
    :ok
  end

  setup do
    {:ok, client: client()}
  end

  test "list/2 returns the design doc + any replication docs", %{client: client} do
    assert {:ok, %{"rows" => rows}} = Akaw.Replication.list(client)
    assert is_list(rows)
  end

  test "all_status/2 returns the scheduler view", %{client: client} do
    assert {:ok, %{"docs" => _, "total_rows" => _}} = Akaw.Replication.all_status(client)
  end

  test "jobs/2 returns scheduled jobs", %{client: client} do
    assert {:ok, %{"jobs" => jobs}} = Akaw.Replication.jobs(client)
    assert is_list(jobs)
  end

  test "create → status → delete; replicates a doc end-to-end", %{client: client} do
    source = setup_temp_db(client)
    target = setup_temp_db(client)
    {:ok, _} = Akaw.Document.put(client, source, "doc1", %{name: "alice"})

    repl_id = "akaw_test_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    repl_doc = %{
      source: build_authed_url(client, source),
      target: build_authed_url(client, target),
      create_target: false
    }

    assert {:ok, %{"rev" => _stale_rev}} = Akaw.Replication.create(client, repl_id, repl_doc)

    on_exit(fn ->
      case Akaw.Replication.get(client(), repl_id) do
        {:ok, doc} -> Akaw.Replication.delete(client(), repl_id, doc["_rev"])
        _ -> :ok
      end
    end)

    # Wait for the doc to land in target
    assert :ok = wait_for_doc(client, target, "doc1", 10_000)

    # Status should be reachable
    assert {:ok, %{"doc_id" => ^repl_id}} = Akaw.Replication.status(client, repl_id)

    # CouchDB rewrites the replication doc as it processes (adding
    # _replication_state, _replication_id, etc.), so the rev from create/3
    # is stale by now — refetch the latest before deleting.
    {:ok, latest} = Akaw.Replication.get(client, repl_id)
    assert {:ok, _} = Akaw.Replication.delete(client, repl_id, latest["_rev"])
  end

  defp build_authed_url(client, db) do
    uri = URI.parse(client.base_url)
    user = System.get_env("AKAW_TEST_USER", "admin")
    pass = System.get_env("AKAW_TEST_PASS", "password")
    "#{uri.scheme}://#{user}:#{pass}@#{uri.host}:#{uri.port}/#{db}"
  end

  defp wait_for_doc(client, db, id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_for_doc(client, db, id, deadline)
  end

  defp poll_for_doc(client, db, id, deadline) do
    case Akaw.Document.get(client, db, id) do
      {:ok, _} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :timeout}
        else
          Process.sleep(200)
          poll_for_doc(client, db, id, deadline)
        end
    end
  end
end
