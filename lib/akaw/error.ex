defmodule Akaw.Error do
  @moduledoc """
  HTTP error response from CouchDB.

  Returned as `{:error, %Akaw.Error{}}` for any non-2xx HTTP response.
  Transport-level failures (DNS, connection refused, timeouts) bypass this
  and surface as `{:error, exception}` with the raw Mint/Finch exception.

  ## Fields

    * `:status` — HTTP status code
    * `:error`  — CouchDB's `error` field, e.g. `"not_found"`
    * `:reason` — CouchDB's `reason` field, e.g. `"missing"`
    * `:body`   — raw decoded response body

  ## Examples

      iex> err = %Akaw.Error{status: 404, error: "not_found", reason: "missing"}
      iex> Exception.message(err)
      "CouchDB returned HTTP 404: not_found (missing)"

      iex> err = %Akaw.Error{status: 500}
      iex> Exception.message(err)
      "CouchDB returned HTTP 500: error (no reason given)"

      iex> try do
      ...>   raise %Akaw.Error{status: 409, error: "conflict", reason: "Document update conflict."}
      ...> rescue
      ...>   e in Akaw.Error -> e.status
      ...> end
      409
  """

  defexception [:status, :error, :reason, :body]

  @type t :: %__MODULE__{
          status: pos_integer() | nil,
          error: String.t() | nil,
          reason: String.t() | nil,
          body: term()
        }

  @impl true
  def message(%__MODULE__{status: status, error: error, reason: reason}) do
    "CouchDB returned HTTP #{status}: #{error || "error"} (#{reason || "no reason given"})"
  end
end
