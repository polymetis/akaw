defmodule AkawTest do
  use ExUnit.Case, async: true
  doctest Akaw

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
end
