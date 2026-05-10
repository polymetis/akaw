defmodule Akaw.Session do
  @moduledoc """
  Session endpoints (`/_session`) — cookie-based authentication.

  CouchDB supports several authentication mechanisms; this module wraps the
  cookie flow:

    1. `create/3` posts credentials and returns a *new* client carrying the
       `AuthSession` cookie.
    2. The returned client is used for subsequent requests; CouchDB
       refreshes the cookie automatically on each request.
    3. `delete/1` invalidates the session.

  Other auth styles don't go through `/_session`:

    * **Basic auth** — pass `auth: {:basic, user, pass}` to `Akaw.new/1`.
    * **JWT bearer** — pass `auth: {:bearer, token}` to `Akaw.new/1`.

  See <https://docs.couchdb.org/en/latest/api/server/authn.html>.
  """

  alias Akaw.{Client, Request}

  @auth_session_re ~r/AuthSession=([^;]+)/

  @doc """
  `POST /_session` — start a new cookie-auth session.

  Returns `{:ok, authed_client, body}` where `authed_client` is a copy of
  `client` with the `AuthSession` cookie installed (and any prior `:auth`
  cleared, since the cookie replaces it). The response `body` mirrors the
  CouchDB shape: `%{"ok" => true, "name" => ..., "roles" => [...]}`.

  If CouchDB returns 200 but doesn't include a `Set-Cookie` header (rare —
  custom proxies may strip it), the original client is returned unchanged.
  """
  @spec create(Client.t(), String.t(), String.t()) ::
          {:ok, Client.t(), map()} | {:error, term()}
  def create(%Client{} = client, name, password)
      when is_binary(name) and is_binary(password) do
    request_client = %Client{client | auth: nil}

    case Request.request(request_client, :post, "/_session",
           json: %{name: name, password: password},
           return: :response
         ) do
      {:ok, %Req.Response{body: body} = resp} ->
        case extract_auth_session(resp) do
          nil -> {:ok, client, body}
          cookie -> {:ok, with_cookie(client, cookie), body}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  `GET /_session` — current session info.

  Returns the authenticated user (if any), their roles, and the auth handler
  CouchDB used to identify them.

  ## Example

      Akaw.Session.info(authed_client)
      #=> {:ok, %{
      #     "ok" => true,
      #     "userCtx" => %{"name" => "admin", "roles" => ["_admin"]},
      #     "info" => %{"authentication_handlers" => ["cookie", "default"], ...}
      #   }}
  """
  @spec info(Client.t()) :: {:ok, map()} | {:error, term()}
  def info(%Client{} = client), do: Request.request(client, :get, "/_session")

  @doc """
  `DELETE /_session` — invalidate the current session cookie.
  """
  @spec delete(Client.t()) :: {:ok, map()} | {:error, term()}
  def delete(%Client{} = client), do: Request.request(client, :delete, "/_session")

  defp extract_auth_session(%Req.Response{} = resp) do
    resp
    |> Req.Response.get_header("set-cookie")
    |> Enum.find_value(fn cookie ->
      case Regex.run(@auth_session_re, cookie) do
        [_, value] -> value
        _ -> nil
      end
    end)
  end

  defp with_cookie(%Client{} = client, cookie_value) do
    cookie_header = {"cookie", "AuthSession=#{cookie_value}"}

    new_headers =
      client.headers
      |> Enum.reject(fn {name, _} -> String.downcase(name) == "cookie" end)
      |> List.insert_at(0, cookie_header)

    %Client{client | auth: nil, headers: new_headers}
  end
end
