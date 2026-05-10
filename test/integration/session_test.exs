defmodule Akaw.Integration.SessionTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  import Akaw.IntegrationHelpers

  setup do
    {:ok, client: client()}
  end

  test "create/3 returns an authed client and session info", %{client: client} do
    user = System.get_env("AKAW_TEST_USER", "admin")
    pass = System.get_env("AKAW_TEST_PASS", "password")

    assert {:ok, %Akaw.Client{} = authed, body} = Akaw.Session.create(client, user, pass)
    assert body["ok"] == true
    assert body["name"] == user

    # Cookie installed, prior basic auth dropped
    assert authed.auth == nil
    cookies = for {"cookie", v} <- authed.headers, do: v
    assert Enum.any?(cookies, &String.starts_with?(&1, "AuthSession="))
  end

  test "info/1 reports the authenticated user", %{client: client} do
    user = System.get_env("AKAW_TEST_USER", "admin")
    pass = System.get_env("AKAW_TEST_PASS", "password")

    {:ok, authed, _} = Akaw.Session.create(client, user, pass)

    assert {:ok, %{"userCtx" => ctx}} = Akaw.Session.info(authed)
    assert ctx["name"] == user
    assert "_admin" in ctx["roles"]
  end

  test "delete/1 invalidates the session", %{client: client} do
    user = System.get_env("AKAW_TEST_USER", "admin")
    pass = System.get_env("AKAW_TEST_PASS", "password")

    {:ok, authed, _} = Akaw.Session.create(client, user, pass)
    assert {:ok, %{"ok" => true}} = Akaw.Session.delete(authed)
  end

  test "create/3 with bad password returns 401", %{client: client} do
    user = System.get_env("AKAW_TEST_USER", "admin")

    assert {:error, %Akaw.Error{status: 401, error: "unauthorized"}} =
             Akaw.Session.create(client, user, "definitely-not-the-password")
  end
end
