defmodule AkawTest do
  use ExUnit.Case, async: true

  doctest Akaw
  doctest Akaw.Error
  doctest Akaw.Params

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

    test "hides auth passed through req_options" do
      client = Akaw.new(base_url: "http://x", req_options: [auth: {:bearer, "token-in-opts"}])
      refute inspect(client) =~ "token-in-opts"
    end

    test "still shows base_url and finch for debugging" do
      client = Akaw.new(base_url: "http://localhost:5984", finch: MyApp.Finch)
      dump = inspect(client)

      assert dump =~ "http://localhost:5984"
      assert dump =~ "MyApp.Finch"
    end
  end
end
