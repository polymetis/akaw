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

    # Wait on the *job*, not on the clock.
    #
    # A `_replicator` doc is a request, not an action: CouchDB's scheduler
    # picks it up whenever it gets to it, and on a cold node that latency is
    # wildly variable. Measured against an idle local container: 1.0s, 4.4s,
    # 4.6s, 4.7s, 5.2s, 5.7s, 5.9s, 7.9s — and then 34.3s and 34.4s. CI hit
    # that tail and failed a 30s deadline with the job in state "running",
    # error_count 0, i.e. perfectly healthy and just not finished.
    #
    # (The ~34s cluster looks like the replicator's 30s default
    # `connection_timeout` being hit once and retried, rather than steady
    # slowness — but the fix does not depend on that being the cause.)
    #
    # So any fixed wall-clock number is the wrong instrument: short enough to
    # keep the suite quick is short enough to flake, and long enough to be
    # safe makes a genuinely broken replication take minutes to report. Poll
    # the job's own state instead — that distinguishes "slow" from "broken",
    # which is the distinction the test actually cares about.
    assert :ok = await_replication(client, repl_id, target, "doc1")

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

  # The real credentials must go INTO the replication document — that's
  # how CouchDB reaches the source — but they must never come OUT in
  # test output: CI logs are often world-readable, AKAW_TEST_PASS may be
  # a real admin password there, and these diagnostics fire precisely on
  # the flakes that get pasted into issues. Covers both the URL we print
  # ourselves and any credential-bearing URL CouchDB embeds in its own
  # error strings (its auth errors quote the session URL).
  defp redact_credentials(text) do
    String.replace(text, ~r{//([^/@:\s]+):[^@\s]+@}, "//\\1:[REDACTED]@")
  end

  # Poll until the replicated doc shows up, giving up early if the
  # replicator reports the job unhealthy rather than merely unfinished.
  # The generous ceiling is a backstop for a stuck job, not an expected
  # wait — the happy path normally returns in a few seconds.
  @replication_ceiling_ms 120_000
  @replication_poll_ms 200

  defp await_replication(client, repl_id, target_db, doc_id) do
    deadline = System.monotonic_time(:millisecond) + @replication_ceiling_ms
    poll_replication(client, repl_id, target_db, doc_id, deadline)
  end

  defp poll_replication(client, repl_id, target_db, doc_id, deadline) do
    cond do
      match?({:ok, _}, Akaw.Document.get(client, target_db, doc_id)) ->
        :ok

      unhealthy = replication_failure(client, repl_id) ->
        flunk(
          redact_credentials("""
          replication job is not healthy, so #{doc_id} is never arriving:
            #{inspect(unhealthy)}
            source/target URL given to CouchDB: #{build_authed_url(client, target_db)}
          """)
        )

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          redact_credentials("""
          replication did not deliver #{doc_id} within #{@replication_ceiling_ms}ms.
            scheduler: #{inspect(replication_state(client, repl_id))}
            source/target URL given to CouchDB: #{build_authed_url(client, target_db)}
          """)
        )

      true ->
        Process.sleep(@replication_poll_ms)
        poll_replication(client, repl_id, target_db, doc_id, deadline)
    end
  end

  # `crashing` / `failed` mean CouchDB has given up or is backing off, and
  # a climbing error_count means it is retrying against something broken —
  # an unreachable source/target reads exactly like this. Anything else
  # ("initializing", "pending", "running", "completed") is just progress.
  defp replication_failure(client, repl_id) do
    case Akaw.Replication.status(client, repl_id) do
      {:ok, %{"state" => state} = doc} when state in ["crashing", "failed", "error"] ->
        Map.take(doc, ["state", "error_count", "info"])

      {:ok, %{"error_count" => count} = doc} when is_integer(count) and count > 0 ->
        Map.take(doc, ["state", "error_count", "info"])

      _ ->
        nil
    end
  end

  defp replication_state(client, repl_id) do
    case Akaw.Replication.status(client, repl_id) do
      {:ok, doc} -> Map.take(doc, ["state", "error_count", "info", "last_updated"])
      other -> other
    end
  end
end
