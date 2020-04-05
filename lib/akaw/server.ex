defmodule Akaw.Server do

alias Akaw.Conn
alias Mojito.Response

@moduledoc """
This module's role is to interact and define with Couchdb's
Server functions.

https://docs.couchdb.org/en/stable/api/server/index.html
"""
  def info(%Conn{url: url}) do
    case Mojito.request(:get, url) do
      {:ok, %Response{body: body}} -> Jason.decode!(body)
      {_, error}                   -> {:error, error}
    end
  end

  def active_tasks(%Conn{basic_auth: nil}) do
    {:error, "Authentication is required for get stats on active tasks"}
  end

  def active_tasks(%Conn{url: url, basic_auth: {username, password}}) do
    auth = Mojito.Headers.auth_header(username, password)
    case Mojito.request(:get, url, [auth]) do
      {:ok, %Response{body: body}} -> Jason.decode!(body)
      {_, error}                   -> {:error, error}
    end

  end
end
