defmodule Akaw.Client do
  @moduledoc """
  Configured CouchDB client.

  Build with `Akaw.new/1`, then pass the returned struct to functions in
  `Akaw.Server`, `Akaw.Database`, and friends.
  """

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
