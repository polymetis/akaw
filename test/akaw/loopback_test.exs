defmodule Akaw.LoopbackTest do
  use ExUnit.Case, async: true

  alias Akaw.Loopback

  # The seam's own guarantee: a broken stub must never read as a
  # plausible CouchDB response. Without the FunPlug rescue, a crashed
  # stub produced exactly the empty-500 shape real tests pin, with the
  # stacktrace lost to an unattributed handler crash report.
  test "a crashed stub answers 418 carrying the formatted exception" do
    plug = fn _conn -> raise "stub bug: fixture left the rails" end

    assert {:error, %Akaw.Error{status: 418} = error} =
             Akaw.Request.request(Loopback.client(plug), :get, "/")

    assert error.body =~ "stub bug: fixture left the rails"
    assert error.body =~ "loopback_test.exs"
  end

  test "a deliberately stubbed empty 500 is still a plain 500" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 500, "") end
    client = Loopback.client(plug, req_options: [retry: false])

    assert {:error, %Akaw.Error{status: 500, error: nil, reason: nil}} =
             Akaw.Request.request(client, :get, "/")
  end
end
