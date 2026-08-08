defmodule Akaw.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # The default connection pool every client rides unless
      # `Akaw.new(finch: ...)` names another. Finch's stock shape — one
      # HTTP/1 pool of 50 connections per {scheme, host, port} — fits a
      # CouchDB client; callers with special needs (TLS options for a
      # self-signed CouchDB, proxies, bigger pools) start their own
      # named Finch and pass it per client.
      {Finch, name: Akaw.Finch}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Akaw.Supervisor)
  end
end
