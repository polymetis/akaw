defmodule Akaw.SessionServer do
  @moduledoc """
  A `GenServer` that holds an authenticated `Akaw.Client` and refreshes
  its `AuthSession` cookie on a fixed interval.

  Use this when your application talks to CouchDB via cookie auth and you
  want refresh to "just happen" instead of writing your own scheduler.

  ## Usage

      children = [
        {Akaw.SessionServer,
          name: MyApp.Couch,
          base_url: "http://localhost:5984",
          username: "admin",
          password: System.fetch_env!("COUCHDB_PASSWORD")}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

      # In your code:
      client = Akaw.SessionServer.client(MyApp.Couch)
      {:ok, info} = Akaw.Server.info(client)

  ## Options

    * `:name` (required) — the name to register the GenServer under
    * `:base_url` (required) — passed through to `Akaw.new/1`
    * `:username` (required) — CouchDB user
    * `:password` (required) — CouchDB password as a binary, **or** a
      0-arity function that returns one. Either way the value is held
      inside a closure in process state so it doesn't appear in
      `:sys.get_state/1` output, SASL crash reports, or `inspect/2`
      dumps — the state shows `password_fn: #Function<...>`. Pass a
      function if you want to defer the secret lookup (Vault, K8s
      secret reloader, etc.) to refresh time rather than start time.
      If the function raises or exits during a *refresh* (the secret
      store hiccups), that's treated as a failed refresh — existing
      client kept, retry on backoff — not a crash. Only the initial
      lookup at start is let-it-crash.
    * `:refresh_interval` — milliseconds between refresh attempts
      (default 5 minutes). Keep this comfortably under CouchDB's
      `[chttpd_auth] timeout` (default 10 minutes): the `AuthSession`
      cookie hard-expires that long after issuance, and since Akaw
      doesn't capture rotated cookies from intervening responses
      (see `Akaw.Session`), this timer is the only thing keeping the
      held cookie alive.
    * `:client_opts` — extra opts forwarded to `Akaw.new/1`
      (e.g. `req_options: [retry: :transient]`, `finch: MyApp.Finch`).

  ## On failure

  If the initial login fails, the GenServer crashes — the supervisor
  decides whether to retry. A 200 that grants no `AuthSession` cookie
  counts as failure: this server exists to hold a cookie, so it refuses
  to start without one. Two CouchDB behaviors to keep in mind here
  (both verified live): a *booting* CouchDB rejects correct credentials
  with a 401 for a short window, so a refresh failing once during a
  server restart is expected and self-heals on the next tick; and a
  genuinely wrong password burns one of CouchDB's five
  failures-before-lockout per supervisor restart — after which even the
  corrected password is refused with 403 for ~5 minutes. If a *refresh* fails after a successful
  initial login, the existing client stays in place and we retry on a
  short backoff (60s or the configured interval, whichever is smaller).
  Callers continue to see the most recent good client.

  One caveat for laptops and suspendable VMs: the refresh timer counts
  monotonic time, which stands still while the host sleeps. After a
  suspend longer than the cookie lifetime, the server serves an expired
  cookie until the next scheduled refresh fires.

  ## Telemetry

  The server emits two `:telemetry` events per refresh attempt:

    * `[:akaw, :session_server, :refresh, :ok]` — successful refresh.
      Measurements: `%{duration: monotonic_ns}`.
      Metadata: `%{name: server_name}`.

    * `[:akaw, :session_server, :refresh, :error]` — failed refresh.
      Measurements: `%{duration: monotonic_ns}`.
      Metadata: `%{name: server_name, error: error_term}`.

  Failures also log a `Logger.warning` so the operator notices without
  a telemetry handler in place.
  """

  use GenServer
  require Logger

  alias Akaw.{Error, Session}

  @default_interval :timer.minutes(5)
  @retry_backoff :timer.seconds(60)

  @doc "Start a SessionServer under a supervisor. See moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Return the current authenticated `Akaw.Client`."
  @spec client(GenServer.server()) :: Akaw.Client.t()
  def client(server), do: GenServer.call(server, :client)

  @doc """
  Force an immediate refresh. Returns `:ok` on success or `{:error, term}`
  if the re-auth call fails — in the failure case the existing client
  stays in place.
  """
  @spec refresh(GenServer.server()) :: :ok | {:error, term()}
  def refresh(server), do: GenServer.call(server, :refresh)

  @impl true
  def init(opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    username = Keyword.fetch!(opts, :username)
    password_fn = to_password_fn(Keyword.fetch!(opts, :password))
    interval = Keyword.get(opts, :refresh_interval, @default_interval)
    client_opts = Keyword.get(opts, :client_opts, [])
    name = Keyword.get(opts, :name)

    base_client = Akaw.new([base_url: base_url] ++ client_opts)

    # Session.refresh/3 rather than create/3: refresh enforces that an
    # AuthSession cookie actually came back, which is this server's whole
    # reason to exist. On the cookie-less base_client the strip is a no-op,
    # so the request itself is identical.
    case Session.refresh(base_client, username, password_fn.()) do
      {:ok, authed, _body} ->
        schedule_refresh(interval)

        {:ok,
         %{
           client: authed,
           base_client: base_client,
           username: username,
           password_fn: password_fn,
           interval: interval,
           name: name
         }}

      {:error, error} ->
        {:stop, error}
    end
  end

  defp to_password_fn(fun) when is_function(fun, 0), do: fun
  defp to_password_fn(value) when is_binary(value), do: fn -> value end

  @impl true
  def handle_call(:client, _from, state) do
    {:reply, state.client, state}
  end

  def handle_call(:refresh, _from, state) do
    case do_refresh(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    case do_refresh(state) do
      {:ok, new_state} ->
        schedule_refresh(new_state.interval)
        {:noreply, new_state}

      {:error, _error} ->
        schedule_refresh(min(state.interval, @retry_backoff))
        {:noreply, state}
    end
  end

  defp do_refresh(state) do
    metadata = %{name: state.name}
    start = System.monotonic_time()

    case attempt_refresh(state) do
      {:ok, new_client, _body} ->
        :telemetry.execute(
          [:akaw, :session_server, :refresh, :ok],
          %{duration: System.monotonic_time() - start},
          metadata
        )

        {:ok, %{state | client: new_client}}

      {:error, error} = err ->
        :telemetry.execute(
          [:akaw, :session_server, :refresh, :error],
          %{duration: System.monotonic_time() - start},
          Map.put(metadata, :error, error)
        )

        Logger.warning(
          "Akaw.SessionServer refresh failed (name=#{inspect(state.name)}): " <>
            inspect(error)
        )

        err
    end
  end

  # A raise or exit escaping `password_fn` (a Vault hiccup, a timed-out
  # secret-store call) must not escape do_refresh: the moduledoc promises
  # that after a successful login a failed refresh keeps the existing
  # client and retries — and an escape here would crash-loop through the
  # supervisor, whose restarts re-run the same raising function in init.
  # Only init is let-it-crash.
  defp attempt_refresh(state) do
    Session.refresh(state.client, state.username, state.password_fn.())
  rescue
    exception ->
      {:error,
       %Error{
         error: "refresh_exception",
         reason: Exception.message(exception),
         body: %{exception: exception, stacktrace: __STACKTRACE__}
       }}
  catch
    kind, value ->
      {:error,
       %Error{
         error: "refresh_exception",
         reason: "#{kind}: #{inspect(value)}",
         body: %{exception: {kind, value}, stacktrace: __STACKTRACE__}
       }}
  end

  defp schedule_refresh(interval) do
    Process.send_after(self(), :refresh, interval)
  end
end
