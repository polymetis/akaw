defmodule Akaw.IntegrationHelpers do
  @moduledoc """
  Shared helpers for `@tag :integration` tests that hit a real CouchDB.

  By default targets `http://localhost:5984` with `admin:password`. Override
  via env vars:

    * `AKAW_TEST_URL` — base URL
    * `AKAW_TEST_USER` — admin username
    * `AKAW_TEST_PASS` — admin password

  One constraint on `AKAW_TEST_URL`: the replication tests hand it to
  CouchDB as a replication source/target, and replication runs
  *server-side* — so the URL must be reachable from inside CouchDB
  itself, not just from the test host. A container published on a
  remapped host port (say `-p 15984:5984`, `AKAW_TEST_URL=http://localhost:15984`)
  passes everything except replication, which dies with `econnrefused`:
  inside the container, localhost:15984 doesn't exist. Publish on
  `5984:5984` (as CI does) and the URL resolves on both sides.

  Run integration tests with:

      mix test --include integration
  """

  @doc "Build a client targeting the configured CouchDB instance."
  def client(extra_opts \\ []) do
    base = [
      base_url: System.get_env("AKAW_TEST_URL", "http://localhost:5984"),
      auth:
        {:basic, System.get_env("AKAW_TEST_USER", "admin"),
         System.get_env("AKAW_TEST_PASS", "password")}
    ]

    Akaw.new(Keyword.merge(base, extra_opts))
  end

  @doc "Generate a unique db name (`{prefix}_{random hex}`) for test isolation."
  def unique_db_name(prefix \\ "akaw_test") do
    suffix = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    "#{prefix}_#{suffix}"
  end

  @doc """
  Create the database, register an `on_exit` to delete it. Returns the name.

  Pass options through to `Akaw.Database.create/3` (e.g. `partitioned: true`).
  """
  def setup_temp_db(client, opts \\ []) do
    db = unique_db_name()
    {:ok, _} = Akaw.Database.create(client, db, opts)
    ExUnit.Callbacks.on_exit(fn -> Akaw.Database.delete(client, db) end)
    db
  end

  @doc """
  Create the named database if it doesn't exist; otherwise no-op.

  Use for shared system dbs (`_users`, `_replicator`) that we don't want to
  delete after each test.
  """
  def ensure_db(client, name) do
    case Akaw.Database.create(client, name) do
      {:ok, _} -> :ok
      {:error, %Akaw.Error{status: 412}} -> :ok
      other -> other
    end
  end

  @doc "Ensure CouchDB's system databases exist (no-op if already there)."
  def ensure_system_dbs(client) do
    Enum.each(["_users", "_replicator", "_global_changes"], &ensure_db(client, &1))
    :ok
  end

  @doc """
  Sync point for live-arrival `_changes` tests: writes sentinel docs until
  the continuous feed sends one back (the consumer must `send` the calling
  process `:feed_open` when it sees a `"sentinel" <> _` id), or gives up.

  A single pre-written sentinel is NOT enough: the feed runs
  `since: "now"`, so a sentinel written before the connection is
  established falls outside the window and is never delivered — no
  timeout fixes a message that is never coming. (Observed on a GitHub
  runner.) Each attempt writes a fresh doc id so every write is a new
  change the feed can deliver.
  """
  def write_sentinels_until_feed_open(client, db, attempts \\ 100) do
    Enum.reduce_while(1..attempts, {:error, :never_opened}, fn i, _acc ->
      {:ok, _} = Akaw.Document.put(client, db, "sentinel_#{i}", %{})

      receive do
        :feed_open -> {:halt, :ok}
      after
        200 -> {:cont, {:error, :never_opened}}
      end
    end)
  end
end
