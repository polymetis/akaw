defmodule Akaw.StreamingTest do
  use ExUnit.Case, async: true

  # `Req.Test`'s plug transport cannot produce a mid-body socket close, so
  # the `{:error, reason}` branch of `Akaw.Streaming.next_chunk/1` is only
  # reachable through a real socket. This raw listener sends a valid chunked
  # response header plus one chunk, then hangs up without the terminating
  # zero-length chunk — which is what a dropped CouchDB connection looks
  # like from the client side.
  defp hang_up_mid_body_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      _request = :gen_tcp.recv(socket, 0)

      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: application/json\r\n",
        "Transfer-Encoding: chunked\r\n\r\n",
        "10\r\n{\"seq\":\"1\"}\n\r\n"
      ])

      :gen_tcp.shutdown(socket, :read_write)
      :gen_tcp.close(listen)
    end)

    port
  end

  describe "chunks/4 transport failure" do
    test "a mid-body close raises %Akaw.Error{} carrying the exception, not an inspect string" do
      port = hang_up_mid_body_server()
      client = Akaw.new(base_url: "http://127.0.0.1:#{port}")

      error =
        assert_raise Akaw.Error, fn ->
          client
          |> Akaw.Streaming.chunks(:get, "/db/_changes", [])
          |> Enum.to_list()
        end

      assert error.error == "stream_transport_error"
      assert error.status == nil

      # `:reason` is Exception.message/1, which is stable across Finch
      # versions. Before this was fixed it was inspect/1 of the raw struct,
      # so it read "%Mint.TransportError{reason: :closed}" on Finch 0.21 and
      # "%Finch.TransportError{reason: :closed, source: ...}" on 0.23.
      assert error.reason == "socket closed"
      refute error.reason =~ "TransportError"

      # And the struct itself survives in :body, which is what Akaw.Error's
      # moduledoc promises for transport failures and what the non-streaming
      # path has always done.
      assert %{exception: exception} = error.body
      assert is_exception(exception)
    end
  end
end
