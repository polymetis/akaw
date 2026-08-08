defmodule Akaw.Response do
  @moduledoc """
  A transport-neutral HTTP response: status, headers, decoded body.

  Returned by the internal request layer when an endpoint needs response
  metadata alongside the body — the session cookie out of `Set-Cookie`,
  an attachment's content type and ETag. Everything outside the request
  layer programs against this struct, never against the underlying HTTP
  client's response type, so the transport can change without the rest
  of the library noticing.

  Headers are a flat list of `{name, value}` pairs with lowercase names;
  a header sent multiple times appears once per value.
  """

  defstruct [:status, :body, headers: []]

  @typedoc "A response: HTTP status, flat lowercase header pairs, decoded body."
  @type t :: %__MODULE__{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: term()
        }

  @doc """
  All values for a header, matched case-insensitively.

      iex> resp = %Akaw.Response{status: 200, headers: [{"set-cookie", "a=1"}, {"set-cookie", "b=2"}]}
      iex> Akaw.Response.get_header(resp, "Set-Cookie")
      ["a=1", "b=2"]

      iex> Akaw.Response.get_header(%Akaw.Response{status: 200}, "etag")
      []
  """
  @spec get_header(t(), String.t()) :: [String.t()]
  def get_header(%__MODULE__{headers: headers}, name) when is_binary(name) do
    wanted = String.downcase(name)
    for {header_name, value} <- headers, String.downcase(header_name) == wanted, do: value
  end
end
