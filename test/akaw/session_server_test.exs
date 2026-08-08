defmodule Akaw.SessionServerTest do
  use ExUnit.Case, async: true

  defp counting_session_plug do
    counter = :counters.new(1, [])

    plug = fn conn ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      conn
      |> Plug.Conn.put_resp_header("set-cookie", "AuthSession=tok_#{n}; Path=/")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"ok" => true, "name" => "admin", "roles" => ["_admin"]})
      )
    end

    {plug, counter}
  end

  # Same as `counting_session_plug/0`, but also tells `test_pid` about every
  # call, so a test can wait for the Nth refresh instead of sleeping and
  # hoping. The SessionServer runs the request itself, so the message comes
  # from its process — the test just receives.
  defp announcing_session_plug(test_pid) do
    {plug, counter} = counting_session_plug()

    announcing = fn conn ->
      conn = plug.(conn)
      send(test_pid, {:session_refresh, :counters.get(counter, 1)})
      conn
    end

    {announcing, counter}
  end

  defp start_server(plug, opts \\ []) do
    base_opts = [
      name: :"akaw_session_test_#{System.unique_integer([:positive])}",
      base_url: "http://x",
      username: "admin",
      password: "pw",
      client_opts: [req_options: [plug: plug]]
    ]

    {:ok, pid} = start_supervised({Akaw.SessionServer, Keyword.merge(base_opts, opts)})
    pid
  end

  test "default refresh_interval stays comfortably under CouchDB's default cookie lifetime" do
    # CouchDB's [chttpd_auth] timeout defaults to 600s: the AuthSession
    # cookie hard-expires 10 minutes after issuance, and Akaw never picks
    # up rotated cookies mid-flight (Akaw.Session's moduledoc: refresh is
    # explicit) — so this timer is the only thing keeping the held cookie
    # alive. If the default interval ever creeps past the lifetime, a
    # server on all-default config serves a dead cookie from cookie expiry
    # until the next refresh, every cycle.
    #
    # "Comfortably": half the lifetime, so one failed attempt (60s
    # backoff) still gets its retry in before the cookie dies.
    couch_default_cookie_lifetime = :timer.minutes(10)

    {plug, _} = counting_session_plug()

    # Deliberately not start_server/2: the default under test must come
    # from the library, not survive by way of the helper's base_opts.
    {:ok, pid} =
      start_supervised(
        {Akaw.SessionServer,
         name: :"akaw_session_default_interval_#{System.unique_integer([:positive])}",
         base_url: "http://x",
         username: "admin",
         password: "pw",
         client_opts: [req_options: [plug: plug]]}
      )

    assert :sys.get_state(pid).interval <= div(couch_default_cookie_lifetime, 2)
  end

  test "init authenticates and exposes the authed client" do
    {plug, counter} = counting_session_plug()
    pid = start_server(plug)

    # /_session called once during init
    assert :counters.get(counter, 1) == 1

    client = Akaw.SessionServer.client(pid)
    assert {"cookie", "AuthSession=tok_1"} in client.headers
    assert client.auth == nil
  end

  test "refresh/1 re-auths and rotates the cookie" do
    {plug, counter} = counting_session_plug()
    pid = start_server(plug)

    assert :ok = Akaw.SessionServer.refresh(pid)
    assert :counters.get(counter, 1) == 2

    client = Akaw.SessionServer.client(pid)
    assert {"cookie", "AuthSession=tok_2"} in client.headers
  end

  test "client/1 returns the latest authed client across multiple refreshes" do
    {plug, _} = counting_session_plug()
    pid = start_server(plug)

    Akaw.SessionServer.refresh(pid)
    Akaw.SessionServer.refresh(pid)
    Akaw.SessionServer.refresh(pid)

    client = Akaw.SessionServer.client(pid)
    assert {"cookie", "AuthSession=tok_4"} in client.headers
  end

  test "scheduled refresh keeps firing on the configured interval" do
    # Deliberately not `Process.sleep(n)` + "did enough refreshes happen by
    # now?". That asks the scheduler for a throughput guarantee it does not
    # give: under a loaded `mix test` the timer and the sleep both slip, and
    # the assertion fails while the behaviour under test is perfectly fine.
    #
    # What we actually care about is that refreshes keep arriving. So the
    # plug announces each one and we wait for them — `assert_receive` blocks
    # only as long as it needs to, and its timeout is a ceiling on failure
    # rather than a stopwatch on success.
    {plug, _counter} = announcing_session_plug(self())
    pid = start_server(plug, refresh_interval: 50)

    assert_receive {:session_refresh, 1}, 1_000
    assert_receive {:session_refresh, 2}, 1_000
    assert_receive {:session_refresh, 3}, 1_000

    # Still alive, and serving the cookie from the most recent refresh.
    client = Akaw.SessionServer.client(pid)
    assert {"cookie", _} = List.keyfind(client.headers, "cookie", 0)
  end

  describe "telemetry" do
    test "emits :ok event on successful refresh" do
      {plug, _} = counting_session_plug()
      test = self()
      handler_id = "akaw-test-ok-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:akaw, :session_server, :refresh, :ok],
        fn _event, measurements, metadata, _config ->
          send(test, {:telemetry_ok, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      pid = start_server(plug)
      assert :ok = Akaw.SessionServer.refresh(pid)

      assert_receive {:telemetry_ok, %{duration: duration}, %{name: _}}
      assert is_integer(duration) and duration >= 0
    end

    test "emits :error event + Logger.warning on failed refresh" do
      counter = :counters.new(1, [])
      test = self()
      handler_id = "akaw-test-err-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:akaw, :session_server, :refresh, :error],
        fn _event, measurements, metadata, _config ->
          send(test, {:telemetry_err, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        if n == 1 do
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "AuthSession=initial; Path=/")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            401,
            Jason.encode!(%{"error" => "unauthorized", "reason" => "denied"})
          )
        end
      end

      pid = start_server(plug)
      assert {:error, _} = Akaw.SessionServer.refresh(pid)

      assert_receive {:telemetry_err, %{duration: _}, %{name: _, error: %Akaw.Error{status: 401}}}
    end
  end

  test "refresh failure leaves the existing client in place" do
    counter = :counters.new(1, [])

    plug = fn conn ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      cond do
        n == 1 ->
          # Initial login: succeeds with a cookie
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "AuthSession=initial; Path=/")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))

        true ->
          # Subsequent refresh attempts: 401
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            401,
            Jason.encode!(%{"error" => "unauthorized", "reason" => "no"})
          )
      end
    end

    pid = start_server(plug)

    # Initial cookie is "initial"
    client_before = Akaw.SessionServer.client(pid)
    assert {"cookie", "AuthSession=initial"} in client_before.headers

    # Force a refresh — should fail
    assert {:error, %Akaw.Error{status: 401}} = Akaw.SessionServer.refresh(pid)

    # Existing client is preserved
    client_after = Akaw.SessionServer.client(pid)
    assert {"cookie", "AuthSession=initial"} in client_after.headers
  end

  test "a refresh answered without a Set-Cookie keeps the existing client" do
    counter = :counters.new(1, [])

    plug = fn conn ->
      :counters.add(counter, 1, 1)

      conn =
        if :counters.get(counter, 1) == 1 do
          Plug.Conn.put_resp_header(conn, "set-cookie", "AuthSession=initial; Path=/")
        else
          # A proxy eating Set-Cookie: 200, valid body, no cookie.
          conn
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
    end

    pid = start_server(plug)

    assert {:error, %Akaw.Error{error: "no_auth_cookie"}} = Akaw.SessionServer.refresh(pid)

    # The cookie-less client must not have been installed.
    client = Akaw.SessionServer.client(pid)
    assert {"cookie", "AuthSession=initial"} in client.headers
  end

  test "init refuses a session answer that grants no cookie" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
    end

    Process.flag(:trap_exit, true)

    assert {:error, %Akaw.Error{error: "no_auth_cookie"}} =
             Akaw.SessionServer.start_link(
               name: :"akaw_session_no_cookie_#{System.unique_integer([:positive])}",
               base_url: "http://x",
               username: "admin",
               password: "pw",
               client_opts: [req_options: [plug: plug]]
             )
  end

  test "accepts :password as a 0-arity function for deferred secret lookup" do
    {plug, counter} = counting_session_plug()

    pid =
      start_server(plug,
        password: fn ->
          :counters.add(counter, 1, 1_000_000)
          "pw"
        end
      )

    # The closure ran once during init
    assert :counters.get(counter, 1) == 1_000_001
    # The plug also incremented once (real login)
    assert :ok = Akaw.SessionServer.refresh(pid)
    # Closure ran again for the refresh
    assert :counters.get(counter, 1) == 2_000_002
  end

  test "a password_fn that raises at refresh time is a failed refresh, not a crash" do
    # The moduledoc sells password_fn for deferred secret lookup (Vault,
    # K8s reloader). If the secret store hiccups at refresh time, the
    # documented path is "existing client stays in place, retry on
    # backoff" — a crash here would loop through the supervisor, whose
    # restarts re-run the same raising function in init until the whole
    # tree gives up.
    calls = :counters.new(1, [])
    {plug, _} = counting_session_plug()

    pid =
      start_server(plug,
        password: fn ->
          :counters.add(calls, 1, 1)
          if :counters.get(calls, 1) == 1, do: "pw", else: raise("vault is down")
        end
      )

    assert {:error, %Akaw.Error{error: "refresh_exception", reason: "vault is down"}} =
             Akaw.SessionServer.refresh(pid)

    assert Process.alive?(pid)
    client = Akaw.SessionServer.client(pid)
    assert {"cookie", "AuthSession=tok_1"} in client.headers
  end

  test "a password_fn that exits at refresh time is a failed refresh, not a crash" do
    # A GenServer.call into a dead secret-store process exits rather than
    # raises — the graceful path has to absorb both.
    calls = :counters.new(1, [])
    {plug, _} = counting_session_plug()

    pid =
      start_server(plug,
        password: fn ->
          :counters.add(calls, 1, 1)
          if :counters.get(calls, 1) == 1, do: "pw", else: exit(:vault_timeout)
        end
      )

    assert {:error, %Akaw.Error{error: "refresh_exception", reason: "exit: :vault_timeout"}} =
             Akaw.SessionServer.refresh(pid)

    assert Process.alive?(pid)
    assert {"cookie", "AuthSession=tok_1"} in Akaw.SessionServer.client(pid).headers
  end

  test "the scheduled path absorbs a password_fn exception and retries on backoff" do
    # The crash-loop scenario is specifically the *scheduled* refresh
    # (handle_info) — pin that path end to end: the exception is absorbed,
    # the :error telemetry fires, and the backoff timer brings the next
    # attempt, which succeeds and rotates the cookie.
    test = self()
    handler_id = "akaw-test-recover-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:akaw, :session_server, :refresh, :error],
      fn _event, _measurements, metadata, _config ->
        send(test, {:telemetry_err, metadata.error})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    calls = :counters.new(1, [])
    {plug, _} = announcing_session_plug(test)

    pid =
      start_server(plug,
        refresh_interval: 50,
        password: fn ->
          :counters.add(calls, 1, 1)
          # Call 1: init. Call 2: first scheduled refresh — Vault blips.
          # Call 3+: recovered.
          if :counters.get(calls, 1) == 2, do: raise("vault blip"), else: "pw"
        end
      )

    # Init logged in (plug call 1); the first scheduled refresh raised
    # before reaching the plug and was absorbed...
    assert_receive {:telemetry_err, %Akaw.Error{error: "refresh_exception"}}, 1_000
    # ...and the backoff timer brought a successful retry (plug call 2).
    assert_receive {:session_refresh, 2}, 1_000

    assert {"cookie", "AuthSession=tok_2"} in Akaw.SessionServer.client(pid).headers
  end

  test "neither password nor live session cookie is visible in :sys.get_state output" do
    {plug, _} = counting_session_plug()
    pid = start_server(plug, password: "super-secret-password")

    state = :sys.get_state(pid)
    refute Map.has_key?(state, :password)
    assert is_function(state.password_fn, 0)

    rendered = inspect(state)
    refute rendered =~ "super-secret-password"

    # The AuthSession cookie is a live credential too. It necessarily
    # lives in state.client.headers, but the client's derived Inspect
    # (base_url and finch only) must keep it out of anything rendered —
    # crash reports, Logger dumps, observer.
    assert {"cookie", "AuthSession=tok_1"} in state.client.headers
    refute rendered =~ "tok_1"
    refute rendered =~ "AuthSession"
  end

  test "init failure prevents the server from starting" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "unauthorized", "reason" => "bad"}))
    end

    name = :"akaw_session_init_fail_#{System.unique_integer([:positive])}"

    Process.flag(:trap_exit, true)

    assert {:error, _} =
             Akaw.SessionServer.start_link(
               name: name,
               base_url: "http://x",
               username: "admin",
               password: "wrong",
               client_opts: [req_options: [plug: plug, retry: false]]
             )
  end
end
