defmodule Akaw.SessionTest do
  use ExUnit.Case, async: true

  defp recording_client(reply_fn) do
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(test, %{
        method: conn.method,
        path: conn.request_path,
        body: body,
        req_headers: conn.req_headers
      })

      reply_fn.(conn)
    end

    Akaw.new(base_url: "http://couch.example", req_options: [plug: plug])
  end

  describe "create/3" do
    test "POSTs name+password and captures AuthSession cookie" do
      reply = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "AuthSession=tok123; Path=/; Version=1")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"ok" => true, "name" => "admin", "roles" => ["_admin"]})
        )
      end

      client = recording_client(reply)

      assert {:ok, %Akaw.Client{} = authed, body} =
               Akaw.Session.create(client, "admin", "secret")

      assert_receive %{method: "POST", path: "/_session", body: posted}
      assert Jason.decode!(posted) == %{"name" => "admin", "password" => "secret"}

      assert body == %{"ok" => true, "name" => "admin", "roles" => ["_admin"]}
      assert {"cookie", "AuthSession=tok123"} in authed.headers
      assert authed.auth == nil
    end

    test "strips any prior :auth on the request and clears it on the returned client" do
      test = self()

      plug = fn conn ->
        send(test, {:auth, Plug.Conn.get_req_header(conn, "authorization")})

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "AuthSession=tok; Path=/")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end

      client =
        Akaw.new(
          base_url: "http://x",
          auth: {:basic, "admin", "pw"},
          req_options: [plug: plug]
        )

      assert {:ok, authed, _} = Akaw.Session.create(client, "admin", "pw")
      assert authed.auth == nil
      assert_receive {:auth, []}
    end

    test "returns the original client unchanged if no Set-Cookie header" do
      reply = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end

      client = recording_client(reply)
      assert {:ok, returned, _} = Akaw.Session.create(client, "admin", "pw")
      assert returned == client
    end

    test "replaces any existing cookie header rather than duplicating" do
      reply = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "AuthSession=NEW; Path=/")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end

      client =
        Akaw.new(
          base_url: "http://x",
          headers: [{"cookie", "AuthSession=OLD"}],
          req_options: [plug: fn conn -> reply.(conn) end]
        )

      assert {:ok, authed, _} = Akaw.Session.create(client, "u", "p")
      cookies = for {"cookie", v} <- authed.headers, do: v
      assert cookies == ["AuthSession=NEW"]
    end

    test "propagates HTTP errors as %Akaw.Error{}" do
      reply = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{
            "error" => "unauthorized",
            "reason" => "Name or password is incorrect."
          })
        )
      end

      client = recording_client(reply)

      assert {:error, %Akaw.Error{status: 401, error: "unauthorized"}} =
               Akaw.Session.create(client, "admin", "wrong")
    end
  end

  describe "info/1" do
    test "GET /_session" do
      test = self()

      plug = fn conn ->
        send(test, {:method, conn.method, :path, conn.request_path})

        Req.Test.json(conn, %{
          "ok" => true,
          "userCtx" => %{"name" => "admin", "roles" => ["_admin"]}
        })
      end

      client = Akaw.new(base_url: "http://x", req_options: [plug: plug])

      assert {:ok, %{"userCtx" => %{"name" => "admin"}}} = Akaw.Session.info(client)
      assert_receive {:method, "GET", :path, "/_session"}
    end
  end

  describe "delete/1" do
    test "DELETE /_session" do
      test = self()

      plug = fn conn ->
        send(test, {:method, conn.method, :path, conn.request_path})
        Req.Test.json(conn, %{"ok" => true})
      end

      client = Akaw.new(base_url: "http://x", req_options: [plug: plug])

      assert {:ok, %{"ok" => true}} = Akaw.Session.delete(client)
      assert_receive {:method, "DELETE", :path, "/_session"}
    end
  end

  describe "refresh/3" do
    test "re-auths and replaces the cookie on the returned client" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "AuthSession=tok_#{n}; Path=/")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "name" => "admin"}))
      end

      base = Akaw.new(base_url: "http://x", req_options: [plug: plug])

      {:ok, c1, _} = Akaw.Session.create(base, "admin", "pw")
      assert {"cookie", "AuthSession=tok_1"} in c1.headers

      {:ok, c2, _} = Akaw.Session.refresh(c1, "admin", "pw")
      assert {"cookie", "AuthSession=tok_2"} in c2.headers

      # Old cookie isn't sitting alongside the new one
      cookies = for {"cookie", v} <- c2.headers, do: v
      assert cookies == ["AuthSession=tok_2"]
    end

    test "strips any prior cookie before re-auth so we don't send the old AuthSession" do
      test = self()

      plug = fn conn ->
        send(test, {:cookies, Plug.Conn.get_req_header(conn, "cookie")})

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "AuthSession=NEW; Path=/")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end

      stale =
        Akaw.new(
          base_url: "http://x",
          headers: [{"cookie", "AuthSession=STALE"}],
          req_options: [plug: plug]
        )

      assert {:ok, _, _} = Akaw.Session.refresh(stale, "admin", "pw")

      # Refresh request must not include the stale cookie header
      assert_receive {:cookies, []}
    end
  end
end
