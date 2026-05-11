defmodule Akaw.Error do
  @moduledoc """
  Error response from a CouchDB call.

  Every Akaw endpoint that returns `{:error, _}` wraps the failure in this
  struct so callers have a single shape to pattern-match on. Stream
  consumers see the same struct raised from inside enumeration.

  Three kinds of failure all funnel through `%Akaw.Error{}`:

    * **HTTP non-2xx** — `status` is the HTTP code, `error` and `reason`
      come from CouchDB's JSON body when present, `body` is the decoded
      response.

    * **Transport** (DNS, connection refused, timeout, …) — `status` is
      `nil`, `error` is `"transport_error"`, `reason` is the underlying
      exception's message, `body` is `%{exception: original_exception}`
      so you can re-examine the raw Mint/Finch error if needed.

    * **Stream failures** — `status` is `nil`, `error` is one of
      `"stream_idle_timeout"`, `"stream_transport_error"`,
      `"stream_format_error"`, `"stream_decode_error"`; `reason` carries
      diagnostic context.

  ## Fields

    * `:status` — HTTP status code, or `nil` for non-HTTP failures
    * `:error`  — short error tag, e.g. `"not_found"` or `"transport_error"`
    * `:reason` — human-readable message
    * `:body`   — raw decoded response body (HTTP errors) or
      `%{exception: e}` (transport errors)

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
  def message(%__MODULE__{status: nil, error: error, reason: reason}) do
    "Akaw #{error || "error"}: #{reason || "no reason given"}"
  end

  def message(%__MODULE__{status: status, error: error, reason: reason}) do
    "CouchDB returned HTTP #{status}: #{error || "error"} (#{reason || "no reason given"})"
  end

  @doc false
  # Used by Akaw.Request / Akaw.Streaming to convert raw transport
  # exceptions into the unified Akaw.Error shape. Public callers don't
  # need to invoke this directly.
  @spec wrap_transport(Exception.t() | term()) :: t()
  def wrap_transport(exception) when is_exception(exception) do
    %__MODULE__{
      status: nil,
      error: "transport_error",
      reason: Exception.message(exception),
      body: %{exception: exception}
    }
  end

  def wrap_transport(other) do
    %__MODULE__{
      status: nil,
      error: "transport_error",
      reason: inspect(other),
      body: %{exception: other}
    }
  end
end
