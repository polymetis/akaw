defmodule Akaw.Client do
  @moduledoc """
  Configured CouchDB client.

  Build with `Akaw.new/1`, then pass the returned struct to functions in
  `Akaw.Server`, `Akaw.Database`, and friends.

  ## Inspect redaction

  This struct carries credentials, so its `Inspect` implementation is
  derived with `only: [:base_url, :finch]` — every other field is shown as
  `...`. Without this, a client sitting in process state (e.g. inside an
  `Akaw.SessionServer`) would print its secrets in a SASL crash report,
  `Logger` dump, or `inspect/2` call. The redacted fields all carry secrets:

    * `:auth` — basic-auth password or bearer token.
    * `:headers` — the `AuthSession` cookie after cookie login, or any
      `Authorization` header you set yourself.
    * `:req_options` — Req's own `:auth` option and any nested `:headers`.

  The allowlist fails closed: a field added to the struct later stays hidden
  until it's explicitly added to `:only`.
  """

  @derive {Inspect, only: [:base_url, :finch]}
  defstruct [
    :base_url,
    :auth,
    :finch,
    headers: [],
    req_options: []
  ]

  @type auth ::
          nil
          | {:basic, username :: String.t(), password :: String.t()}
          | {:bearer, token :: String.t()}

  @type t :: %__MODULE__{
          base_url: String.t(),
          auth: auth(),
          finch: atom() | nil,
          headers: list({String.t(), String.t()}),
          req_options: keyword()
        }
end
