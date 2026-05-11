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
          password: System.fetch_env!("COUCHDB_PASSWORD"),
          refresh_interval: :timer.minutes(5)}
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
    * `:refresh_interval` — milliseconds between refresh attempts
      (default 30 minutes, well within CouchDB's default 10-minute
      `[chttpd_auth] timeout` × auto-renewal window).
    * `:client_opts` — extra opts forwarded to `Akaw.new/1`
      (e.g. `req_options: [retry: :transient]`, `finch: MyApp.Finch`).

  ## On failure

  If the initial login fails, the GenServer crashes — the supervisor
  decides whether to retry. If a *refresh* fails after a successful
  initial login, the existing client stays in place and we retry on a
  short backoff (60s or the configured interval, whichever is smaller).
  Callers continue to see the most recent good client.

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

  alias Akaw.Session

  @default_interval :timer.minutes(30)
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

    case Session.create(base_client, username, password_fn.()) do
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

    case Session.refresh(state.client, state.username, state.password_fn.()) do
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

  defp schedule_refresh(interval) do
    Process.send_after(self(), :refresh, interval)
  end
end
