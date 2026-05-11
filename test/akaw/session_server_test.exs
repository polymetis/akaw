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

  test "scheduled refresh fires after the configured interval" do
    {plug, counter} = counting_session_plug()
    # 100ms interval — plenty short for tests
    pid = start_server(plug, refresh_interval: 100)

    assert :counters.get(counter, 1) == 1
    Process.sleep(350)

    # By 350ms we should have had the initial login plus at least 2-3
    # scheduled refreshes (allowing for jitter).
    assert :counters.get(counter, 1) >= 3

    # Server is still alive and serving the latest client
    client = Akaw.SessionServer.client(pid)
    assert {"cookie", _} = List.keyfind(client.headers, "cookie", 0)
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
