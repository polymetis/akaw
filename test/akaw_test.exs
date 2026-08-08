defmodule AkawTest do
  use ExUnit.Case, async: true

  doctest Akaw
  doctest Akaw.Error
  doctest Akaw.Params
  doctest Akaw.Path
  doctest Akaw.Response

  describe "new/1" do
    test "builds a client with sensible defaults" do
      client = Akaw.new(base_url: "http://localhost:5984")

      assert %Akaw.Client{
               base_url: "http://localhost:5984",
               auth: nil,
               finch: nil,
               headers: [],
               req_options: []
             } = client
    end

    test "trims trailing slash from base_url" do
      assert Akaw.new(base_url: "http://x:5984/").base_url == "http://x:5984"
    end

    test "captures auth, headers, finch pool, and req_options" do
      client =
        Akaw.new(
          base_url: "http://x",
          auth: {:basic, "u", "p"},
          finch: MyApp.Finch,
          headers: [{"x-foo", "1"}],
          req_options: [receive_timeout: 30_000]
        )

      assert client.auth == {:basic, "u", "p"}
      assert client.finch == MyApp.Finch
      assert client.headers == [{"x-foo", "1"}]
      assert client.req_options == [receive_timeout: 30_000]
    end

    test "raises if base_url is missing" do
      assert_raise KeyError, fn -> Akaw.new([]) end
    end
  end

  describe "Inspect redaction" do
    test "hides basic-auth credentials" do
      client = Akaw.new(base_url: "http://x", auth: {:basic, "admin", "hunter2"})
      dump = inspect(client)

      refute dump =~ "admin"
      refute dump =~ "hunter2"
    end

    test "hides a bearer token" do
      client = Akaw.new(base_url: "http://x", auth: {:bearer, "jwt-secret-token"})
      refute inspect(client) =~ "jwt-secret-token"
    end

    test "hides an AuthSession cookie carried in headers" do
      # Cookie login clears :auth and stores the credential in :headers, so a
      # redaction that only covered :auth would leak this — the exact client an
      # Akaw.SessionServer holds in its state.
      client =
        Akaw.new(base_url: "http://x", headers: [{"cookie", "AuthSession=s3cr3t-cookie"}])

      refute inspect(client) =~ "s3cr3t-cookie"
    end

    test "auth can no longer be smuggled through req_options at all" do
      # This used to pin that a secret passed via req_options was at
      # least redacted from inspect output. The narrowed allowlist
      # supersedes redaction with prevention: the key is rejected at
      # construction, so the secret never enters through that door.
      assert_raise ArgumentError, ~r/unknown key\(s\) in :req_options.*:auth/s, fn ->
        Akaw.new(base_url: "http://x", req_options: [auth: {:bearer, "token-in-opts"}])
      end
    end

    test "hides credentials embedded in base_url" do
      # Req 0.7 honours URL userinfo as Basic auth, which would otherwise make
      # :base_url a secret — and :base_url is the one field this Inspect
      # implementation deliberately prints. Akaw.new/1 lifts it into :auth so
      # the redaction still holds.
      client = Akaw.new(base_url: "http://admin:hunter2@localhost:5984")
      dump = inspect(client)

      refute dump =~ "hunter2"
      refute dump =~ "admin"
      assert dump =~ "http://localhost:5984"
    end

    test "still shows base_url and finch for debugging" do
      client = Akaw.new(base_url: "http://localhost:5984", finch: MyApp.Finch)
      dump = inspect(client)

      assert dump =~ "http://localhost:5984"
      assert dump =~ "MyApp.Finch"
    end
  end

  describe "new/1 req_options validation" do
    test "req_options rejects unknown keys with the named allowlist" do
      error =
        assert_raise ArgumentError, fn ->
          Akaw.new(base_url: "http://x", req_options: [connect_options: [timeout: 500]])
        end

      # The connect_options rejection must teach the replacement: a
      # named Finch pool carrying the connection options.
      assert error.message =~ "Finch"
      assert error.message =~ "transport_opts"
    end

    test "req_options accepts the full named allowlist" do
      client =
        Akaw.new(
          base_url: "http://x",
          req_options: [
            receive_timeout: 30_000,
            pool_timeout: 500,
            retry: false,
            compressed: false,
            headers: [{"x-extra", "1"}]
          ]
        )

      # Every allowed key must survive validation intact — a validator
      # refactor that silently drops allowed keys would otherwise pass.
      assert Keyword.keys(client.req_options) |> Enum.sort() ==
               Enum.sort([
                 :receive_timeout,
                 :pool_timeout,
                 :retry,
                 :compressed,
                 :headers
               ])

      assert Keyword.get(client.req_options, :receive_timeout) == 30_000
    end

    test "req_options rejects :plug and teaches the loopback seam" do
      # The unit suite's own migration off req_options: [plug:] closed
      # the contract behind it — the option existed for the old test
      # seam and dies with it.
      error =
        assert_raise ArgumentError, fn ->
          Akaw.new(
            base_url: "http://x",
            req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end]
          )
        end

      assert error.message =~ "loopback"
      assert error.message =~ "Testing against Akaw"
    end

    test "req_options rejects a function-valued :retry" do
      # Req accepts retry: fn %Req.Request{}, %Req.Response{} -> ... end
      # — a caller programming directly against the transport types the
      # narrowed contract exists to contain. Atoms only.
      error =
        assert_raise ArgumentError, fn ->
          Akaw.new(base_url: "http://x", req_options: [retry: fn _, _ -> false end])
        end

      assert error.message =~ ":safe_transient"
    end
  end
end
