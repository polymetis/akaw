defmodule Akaw.RequestTest do
  use ExUnit.Case, async: true

  alias Akaw.Loopback
  alias Akaw.Request

  defp client_with(plug, extra \\ []) do
    Loopback.client(plug, [req_options: [retry: false]] ++ extra)
  end

  describe "URL composition" do
    test "joins base_url and path verbatim" do
      test = self()

      plug = fn conn ->
        send(test, {:url, conn.request_path})
        Loopback.json(conn, %{})
      end

      assert {:ok, _} = Request.request(client_with(plug), :get, "/_all_dbs")
      assert_receive {:url, "/_all_dbs"}
    end

    test "forwards :params as the query string" do
      test = self()

      plug = fn conn ->
        send(test, {:qs, conn.query_string})
        Loopback.json(conn, %{})
      end

      assert {:ok, _} =
               Request.request(client_with(plug), :get, "/_uuids", params: [count: 5])

      assert_receive {:qs, "count=5"}
    end
  end

  describe "auth" do
    test "{:basic, user, pass} sets Authorization: Basic" do
      test = self()
      expected = "Basic " <> Base.encode64("user:pw")

      plug = fn conn ->
        send(test, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Loopback.json(conn, %{})
      end

      client = client_with(plug, auth: {:basic, "user", "pw"})
      assert {:ok, _} = Request.request(client, :get, "/")
      assert_receive {:auth, [^expected]}
    end

    test "{:bearer, token} sets Authorization: Bearer" do
      test = self()

      plug = fn conn ->
        send(test, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Loopback.json(conn, %{})
      end

      client = client_with(plug, auth: {:bearer, "abc.def.ghi"})
      assert {:ok, _} = Request.request(client, :get, "/")
      assert_receive {:auth, ["Bearer abc.def.ghi"]}
    end
  end

  describe "error handling" do
    test "non-2xx with CouchDB error body returns %Akaw.Error{}" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          JSON.encode!(%{"error" => "not_found", "reason" => "missing"})
        )
      end

      assert {:error, %Akaw.Error{} = err} =
               Request.request(client_with(plug), :get, "/_nope")

      assert err.status == 404
      assert err.error == "not_found"
      assert err.reason == "missing"
      assert err.body == %{"error" => "not_found", "reason" => "missing"}
    end

    test "non-2xx without an error/reason body still wraps as %Akaw.Error{}" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end

      assert {:error, %Akaw.Error{status: 500, error: nil, reason: nil}} =
               Request.request(client_with(plug), :get, "/")
    end

    test "Akaw.Error implements Exception.message/1" do
      err = %Akaw.Error{status: 404, error: "not_found", reason: "missing"}
      assert Exception.message(err) =~ "404"
      assert Exception.message(err) =~ "not_found"
      assert Exception.message(err) =~ "missing"
    end

    test "requests negotiate compression and decode a gzipped response body" do
      test = self()

      plug = fn conn ->
        send(test, {:accept_encoding, Plug.Conn.get_req_header(conn, "accept-encoding")})

        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, :zlib.gzip(~s({"ok":true})))
      end

      assert {:ok, %{"ok" => true}} = Request.request(client_with(plug), :get, "/")

      # Req 0.6.1 made this opt-in; Akaw.Request opts back in, so CouchDB
      # still gets asked for gzip and the body still arrives decoded rather
      # than as a raw compressed binary.
      assert_receive {:accept_encoding, [encodings]}
      assert encodings =~ "gzip"
    end

    test "a corrupt gzip body on a 2xx is a decode_error" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "definitely not gzip")
      end

      assert {:error, %Akaw.Error{status: nil, error: "decode_error", reason: reason}} =
               Request.request(client_with(plug), :get, "/")

      assert reason =~ "failed to inflate"
    end

    test "a corrupt gzip body on a 5xx keeps its status — the status is the signal" do
      # A proxy answering 502 with a broken gzip body: collapsing this
      # into a status-less decode_error would hide the 5xx from exactly
      # the callers branching on it.
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.send_resp(502, "")
      end

      assert {:error, %Akaw.Error{status: 502}} =
               Request.request(client_with(plug), :get, "/")
    end

    test "content codings are case-insensitive comma-lists; x-gzip counts" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "X-Gzip, identity")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, :zlib.gzip(~s({"ok":true})))
      end

      assert {:ok, %{"ok" => true}} = Request.request(client_with(plug), :get, "/")
    end

    test "an encoding akaw can't undo comes back raw and undecoded" do
      # Encoded bytes must never reach the JSON parser; the caller gets
      # the bytes and the intact content-encoding header to deal with.
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "br")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "brotli-bytes-untouched")
      end

      assert {:ok, response} =
               Request.request(client_with(plug), :get, "/", return: :response)

      assert response.body == "brotli-bytes-untouched"
      assert {"content-encoding", "br"} in response.headers
    end

    test "inflation drops the headers describing the compressed bytes" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, :zlib.gzip(~s({"ok":true})))
      end

      assert {:ok, response} =
               Request.request(client_with(plug), :get, "/", return: :response)

      header_names = for {name, _} <- response.headers, do: String.downcase(name)
      refute "content-encoding" in header_names
      refute "content-length" in header_names
    end

    test "a caller can still turn compression off per call" do
      test = self()

      plug = fn conn ->
        send(test, {:accept_encoding, Plug.Conn.get_req_header(conn, "accept-encoding")})
        Loopback.json(conn, %{})
      end

      assert {:ok, _} = Request.request(client_with(plug), :get, "/", compressed: false)
      assert_receive {:accept_encoding, []}
    end

    test "compressed: false strips even an explicit accept-encoding header" do
      # Its one load-bearing use is the streaming paths' unconditional
      # pin: chunk parsers must never see gzip bytes, including via a
      # client-level literal header.
      test = self()

      plug = fn conn ->
        send(test, {:accept_encoding, Plug.Conn.get_req_header(conn, "accept-encoding")})
        Loopback.json(conn, %{})
      end

      client = client_with(plug, headers: [{"accept-encoding", "gzip"}])
      assert {:ok, _} = Request.request(client, :get, "/", compressed: false)
      assert_receive {:accept_encoding, []}
    end

    test "streaming paths shed a client-level accept-encoding header" do
      seen = :ets.new(:akaw_stream_accept_encoding, [:public])

      plug = fn conn ->
        :ets.insert(seen, {:accept_encoding, Plug.Conn.get_req_header(conn, "accept-encoding")})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"total_rows":0,"offset":0,"rows":[\n]}))
      end

      client = Loopback.client(plug, headers: [{"accept-encoding", "gzip"}])

      assert {:ok, 0} =
               Akaw.Documents.reduce_while_all_docs(client, "db", 0, fn _, n -> {:cont, n + 1} end)

      assert [{:accept_encoding, []}] = :ets.lookup(seen, :accept_encoding)
    end

    test "prepared/4 forwards the transport escape hatches as Finch request options" do
      client = Akaw.new(base_url: "http://x")

      {_request, _pool, finch_opts, _retry} =
        Request.prepared(client, :get, "/", pool_timeout: 5_000, receive_timeout: 30_000)

      assert finch_opts[:pool_timeout] == 5_000
      assert finch_opts[:receive_timeout] == 30_000
    end

    test "prepared/4 forwards the keyword finch form: pool name and pool_tag" do
      # Finch silently falls back to the :default pool config for an
      # unknown tag, so the integration suite alone can't catch a
      # dropped tag — this pins the forwarding exactly.
      client = Akaw.new(base_url: "http://x", finch: [name: SomePool, pool_tag: :bulk])

      {request, pool, _finch_opts, _retry} = Request.prepared(client, :get, "/", [])

      assert pool == SomePool
      assert request.pool_tag == :bulk
    end

    test "an unknown request option raises with the inventory" do
      client = Akaw.new(base_url: "http://x")

      error =
        assert_raise ArgumentError, fn ->
          Request.request(client, :get, "/", follow_redirects: true)
        end

      assert error.message =~ "unknown request option(s): [:follow_redirects]"
      assert error.message =~ "closed surface"
    end

    test "a per-call function-valued :retry raises instead of silently meaning enabled" do
      client = Akaw.new(base_url: "http://x")

      error =
        assert_raise ArgumentError, fn ->
          Request.request(client, :get, "/", retry: fn _, _ -> false end)
        end

      assert error.message =~ ":safe_transient"
    end

    test "a 503 surfaces immediately — status codes are never retried" do
      # Deliberate narrowing from the Req era (which retried
      # 408/429/500/502/503/504 with backoff): akaw's own policy retries
      # exactly one failure class — the pooled keep-alive race below.
      # The full status-classification port is a pre-Hex item.
      calls = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(calls, 1, 1)
        Plug.Conn.send_resp(conn, 503, "unavailable")
      end

      assert {:error, %Akaw.Error{status: 503}} =
               Request.request(Loopback.client(plug), :get, "/")

      assert :counters.get(calls, 1) == 1
    end

    test "the keep-alive race is retried once, loudly, for idempotent methods" do
      # A server hanging up after reading the request without answering
      # is what a pooled connection closed mid-request looks like —
      # CouchDB's own keep-alive timeout guarantees this race in normal
      # operation. GET retries once; the retry logs at :warning so the
      # policy is observable, never silent.
      port = close_first_then_serve()
      client = Akaw.new(base_url: "http://127.0.0.1:#{port}", finch: start_test_finch())

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{"ok" => true}} = Request.request(client, :get, "/")
        end)

      assert log =~ "retrying GET"
      assert log =~ "keep-alive race"
    end

    test "the keep-alive race is NOT retried for non-idempotent methods" do
      port = close_first_then_serve()
      client = Akaw.new(base_url: "http://127.0.0.1:#{port}", finch: start_test_finch())

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %Akaw.Error{error: "transport_error"} = err} =
                   Request.request(client, :post, "/db", json: %{a: 1})

          assert Exception.message(err.body.exception) =~ "closed"
        end)

      refute log =~ "retrying"
      # Process-scoped, capture-independent proof: no second connection.
      assert_received {:accepted, 1}
      refute_received {:accepted, 2}
    end

    test "pool exhaustion is {:error, pool_timeout}, not a raise — plain and reduce paths" do
      # A size-1 pool, one connection parked in a slow request, and a
      # 50ms checkout budget for the second: Finch reports this by
      # RAISING, which would break the {:error, %Akaw.Error{}} contract
      # at exactly the moment callers most need it. This also pins the
      # message guard against real Finch — if a Finch bump rewords the
      # exhaustion raise, this test fails before the misclassification
      # ships.
      test_pid = self()

      plug = fn conn ->
        send(test_pid, :occupied)
        Process.sleep(2_000)
        Loopback.json(conn, %{})
      end

      pool = :"akaw_saturation_test_finch_#{System.unique_integer([:positive])}"

      start_supervised!({Finch, name: pool, pools: %{default: [size: 1, count: 1]}},
        id: make_ref()
      )

      client = Akaw.new(base_url: Loopback.url(plug), finch: pool)

      occupant = Task.async(fn -> Request.request(client, :get, "/slow") end)
      assert_receive :occupied, 2_000

      assert {:error, %Akaw.Error{error: "pool_timeout", status: nil} = plain_error} =
               Request.request(client, :get, "/", pool_timeout: 50)

      assert plain_error.reason =~ "unable to provide a connection"

      assert {:error, %Akaw.Error{error: "pool_timeout"}} =
               Akaw.Documents.reduce_while_all_docs(
                 client,
                 "db",
                 [],
                 fn row, acc -> {:cont, [row | acc]} end,
                 pool_timeout: 50
               )

      Task.await(occupant, 5_000)
    end

    test "a reducer's own RuntimeError propagates — never misread as pool exhaustion" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"total_rows":1,"offset":0,"rows":[\n{"id":"a"}\n]}))
      end

      client = Loopback.client(plug)

      assert_raise RuntimeError, "reducer bug", fn ->
        Akaw.Documents.reduce_while_all_docs(client, "db", [], fn _row, _acc ->
          raise "reducer bug"
        end)
      end
    end

    test "retry: false disables even the keep-alive-race retry" do
      port = close_first_then_serve()

      client =
        Akaw.new(
          base_url: "http://127.0.0.1:#{port}",
          finch: start_test_finch(),
          req_options: [retry: false]
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %Akaw.Error{error: "transport_error"}} =
                   Request.request(client, :get, "/")
        end)

      refute log =~ "retrying"
      assert_received {:accepted, 1}
      refute_received {:accepted, 2}
    end

    test "json: bodies carry content-type and accept, encoded by the native JSON module" do
      # akaw translates json: to a native-encoded body itself rather
      # than letting Req's Jason-backed encode_body step run — mirroring
      # Req's header behavior (both put-new) so the wire shape is
      # unchanged.
      test = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(test, %{
          content_type: Plug.Conn.get_req_header(conn, "content-type"),
          accept: Plug.Conn.get_req_header(conn, "accept"),
          body: body
        })

        Loopback.json(conn, %{"ok" => true})
      end

      assert {:ok, _} =
               Request.request(client_with(plug), :post, "/db", json: %{a: 1, b: [true, nil]})

      assert_receive %{
        content_type: ["application/json"],
        accept: ["application/json"],
        body: body
      }

      assert JSON.decode!(body) == %{"a" => 1, "b" => [true, nil]}
    end

    test "a caller-supplied content-type is not clobbered by the json translation" do
      test = self()

      plug = fn conn ->
        send(test, {:content_type, Plug.Conn.get_req_header(conn, "content-type")})
        Loopback.json(conn, %{"ok" => true})
      end

      assert {:ok, _} =
               Request.request(client_with(plug), :post, "/db",
                 json: %{a: 1},
                 headers: [{"content-type", "application/json; charset=utf-8"}]
               )

      assert_receive {:content_type, ["application/json; charset=utf-8"]}
    end

    @tag :capture_log
    test "a response slower than :receive_timeout is a transport_error carrying the timeout" do
      # The old seam could only fabricate this class; over a real socket
      # the genuine article is a stub that oversleeps. Pinned ahead of
      # the transport swap: timeouts must keep surfacing through the
      # error channel, never raise.
      plug = fn conn ->
        Process.sleep(500)
        Loopback.json(conn, %{})
      end

      client = Loopback.client(plug, req_options: [retry: false])

      assert {:error, %Akaw.Error{} = err} =
               Request.request(client, :get, "/", receive_timeout: 50)

      assert err.status == nil
      assert err.error == "transport_error"
      assert Exception.message(err.body.exception) =~ "timeout"
    end

    test "transport exceptions are wrapped into %Akaw.Error{status: nil}" do
      client = Loopback.refused_client(req_options: [retry: false])

      assert {:error, %Akaw.Error{} = err} = Request.request(client, :get, "/")
      assert err.status == nil
      assert err.error == "transport_error"
      assert err.reason =~ "connection refused" or err.reason =~ "econnrefused"
      assert is_struct(err.body.exception)
    end

    test "a 200 with a corrupt JSON body is a decode_error, not a transport_error" do
      # A proxy truncating the response mid-body. Tagging this
      # "transport_error" sent the documented retry-on-transport pattern
      # into a loop against a permanently corrupt endpoint.
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s|{"total_rows": 3, "rows": [{"id|)
      end

      assert {:error, %Akaw.Error{} = err} =
               Request.request(client_with(plug), :get, "/db/_all_docs")

      assert err.status == nil
      assert err.error == "decode_error"
      assert %JSON.DecodeError{} = err.body.exception
    end

    test "Akaw.Error.message/1 for transport errors shows 'Akaw transport_error: ...'" do
      err = %Akaw.Error{
        status: nil,
        error: "transport_error",
        reason: "connection refused"
      }

      msg = Exception.message(err)
      assert msg =~ "transport_error"
      assert msg =~ "connection refused"
      refute msg =~ "CouchDB returned HTTP"
    end
  end

  describe "headers" do
    test "client headers are sent with every request" do
      test = self()

      plug = fn conn ->
        send(test, {:headers, conn.req_headers})
        Loopback.json(conn, %{})
      end

      client = client_with(plug, headers: [{"x-couch-feature", "akaw"}])
      assert {:ok, _} = Request.request(client, :get, "/")
      assert_receive {:headers, headers}
      assert {"x-couch-feature", "akaw"} in headers
    end

    test "per-call headers are concatenated with client headers" do
      test = self()

      plug = fn conn ->
        send(test, {:headers, conn.req_headers})
        Loopback.json(conn, %{})
      end

      client = client_with(plug, headers: [{"x-from-client", "yes"}])

      assert {:ok, _} =
               Request.request(client, :get, "/", headers: [{"x-from-call", "also"}])

      assert_receive {:headers, headers}
      assert {"x-from-client", "yes"} in headers
      assert {"x-from-call", "also"} in headers
    end

    test "per-call header overrides client header with the same name" do
      test = self()

      plug = fn conn ->
        send(test, {:headers, conn.req_headers})
        Loopback.json(conn, %{})
      end

      client = client_with(plug, headers: [{"cookie", "AuthSession=OLD"}])

      assert {:ok, _} =
               Request.request(client, :get, "/", headers: [{"cookie", "AuthSession=NEW"}])

      assert_receive {:headers, headers}
      cookies = for {"cookie", v} <- headers, do: v
      assert cookies == ["AuthSession=NEW"]
    end
  end

  # A raw listener whose first connection reads the request and hangs up
  # without answering — %Mint.TransportError{reason: :closed}, the exact
  # shape of the pooled keep-alive race — and whose second connection
  # serves a real 200. A stub plug can't produce this: a cooperative
  # server always answers what it accepts.
  #
  # Sends {:accepted, n} to the test per connection: the no-retry tests
  # refute_receive {:accepted, 2}, which is process-scoped proof no
  # second attempt happened — unlike log refutes, which capture_log
  # shares across the whole async suite. Both accepts case-match so the
  # tests that legitimately never open a second connection tear the
  # fixture down quietly when the listen socket closes with the test.
  defp close_first_then_serve do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    test = self()

    spawn_link(fn ->
      case :gen_tcp.accept(listen) do
        {:ok, first} ->
          send(test, {:accepted, 1})
          _request = :gen_tcp.recv(first, 0, 5_000)
          :gen_tcp.close(first)

          case :gen_tcp.accept(listen) do
            {:ok, second} ->
              send(test, {:accepted, 2})
              _request = :gen_tcp.recv(second, 0, 5_000)
              body = ~s({"ok":true})

              :gen_tcp.send(second, [
                "HTTP/1.1 200 OK\r\n",
                "content-type: application/json\r\n",
                "content-length: #{byte_size(body)}\r\n\r\n",
                body
              ])

              :gen_tcp.close(second)
              :gen_tcp.close(listen)

            {:error, _closed} ->
              :ok
          end

        {:error, _closed} ->
          :ok
      end
    end)

    port
  end

  # The raw fixture bypasses Loopback.client, so it also needs its own
  # per-test pool (same reasoning as the seam's: the shared pool never
  # retires entries for dead ports).
  defp start_test_finch do
    name = :"akaw_request_test_finch_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: name}, id: make_ref())
    name
  end
end
