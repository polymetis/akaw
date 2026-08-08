defmodule Akaw.Loopback do
  @moduledoc """
  Real-socket test seam: serves a stub plug from a Bandit listener bound
  to a fresh loopback port, so unit tests exercise the production
  transport end to end — pool checkout, real HTTP framing, real sockets —
  instead of short-circuiting into an in-process adapter.

  ## Usage

      test "info" do
        plug = fn conn -> Akaw.Loopback.json(conn, %{"ok" => true}) end
        client = Akaw.Loopback.client(plug)

        assert {:ok, %{"ok" => true}} = Akaw.Server.info(client)
      end

  Every `url/1` / `client/2` call binds its own OS-assigned port
  (`port: 0`), so `async: true` suites can't collide, and the listener is
  supervised by the test that started it — torn down when the test exits.
  `client/2` also starts a per-test Finch pool that dies with the test;
  see `client/2` for why that matters.

  The stub plug runs in a Bandit connection-handler process, not the
  test process. To observe the request from the test, close over the
  test pid and message it (`test = self()` before the plug,
  `send(test, ...)` inside, `assert_receive` after) — an `assert`
  directly inside the plug would fail the handler, not the test. A stub
  that *crashes* answers 418 with the formatted exception (see
  `FunPlug`), so a broken stub reads as a broken stub, never as a
  plausible CouchDB response — with one gap: once a chunked stub has
  sent its first chunk, a later bug can only surface as a mid-stream
  close, indistinguishable from the transport failures streaming tests
  pin on purpose.

  ## Assertion discipline: content, not chunk counts

  Chunked bodies arrive with one collector call per chunk *frame* — but
  that is a floor, not an exact count: a frame larger than a socket
  buffer can be split into several deliveries. Assert on reassembled
  content (lines, items, whole bodies), never on how many pieces the
  transport happened to deliver.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 2]

  defmodule FunPlug do
    @moduledoc false
    # Bandit mounts a module plug; this one closes the gap to the
    # anonymous-function plugs the test suite is written in.
    #
    # call/2 rescues stub bugs and answers 418 with the formatted
    # exception. Without this, a crashed stub is byte-identical to a
    # deliberately stubbed empty 500 — a shape real tests pin — and the
    # stacktrace lands in an unattributed handler crash report instead
    # of the failing test's diff. The status must be in Plug's
    # reason-phrase table for Bandit to send it (599 raises there);
    # 418 is registered, CouchDB never emits it, and Req never retries
    # it — no assertion can be satisfied by a broken stub.
    @behaviour Plug

    @impl true
    def init(fun) when is_function(fun, 1), do: fun

    @impl true
    def call(conn, fun) do
      fun.(conn)
    rescue
      exception ->
        Plug.Conn.send_resp(
          conn,
          418,
          Exception.format(:error, exception, __STACKTRACE__)
        )
    end
  end

  @doc """
  Serve `plug_fun` from a fresh loopback listener; returns its base URL.
  """
  def url(plug_fun) when is_function(plug_fun, 1) do
    # num_acceptors: a test listener serves exactly one client; the
    # default 100 acceptors are ~300 idle processes per listener, ~400
    # listeners per suite run.
    bandit_options = [
      plug: {FunPlug, plug_fun},
      ip: {127, 0, 0, 1},
      port: 0,
      startup_log: false,
      thousand_island_options: [num_acceptors: 2]
    ]

    server =
      start_supervised!(
        {Bandit, bandit_options},
        # A test may mount several servers; the default child id (Bandit)
        # would collide on the second one.
        id: make_ref()
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  @doc """
  An `Akaw.Client` pointed at a fresh listener serving `plug_fun`.
  `extra` is passed through to `Akaw.new/1` (`:auth`, `:headers`,
  `:req_options`, ...).

  The client rides a per-test Finch pool that dies with the test. The
  application-wide `Akaw.Finch` keys pools by `{scheme, host, port}` and
  never retires them — against a unique port per test it would
  accumulate one dead pool and one CLOSE_WAIT fd per test for the rest
  of the run, an EMFILE with a long fuse.
  """
  def client(plug_fun, extra \\ []) do
    Akaw.new([base_url: url(plug_fun), finch: start_finch()] ++ extra)
  end

  @doc """
  Send `data` as a JSON response. Respects a status already set with
  `Plug.Conn.put_status/2`, defaults to 200. Always sets the
  content-type, clobbering any already there.
  """
  def json(%Plug.Conn{} = conn, data) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(conn.status || 200, JSON.encode_to_iodata!(data))
  end

  @doc """
  A base URL whose connections are refused — a loopback port that was
  bound and then closed, which is what a down CouchDB looks like from
  the client side: a genuine `:econnrefused`, not a fabricated one.

  The OS could in principle re-issue the port to another process in the
  few milliseconds between the close and the connect, but ephemeral
  allocation rotates through the range, so a just-released port isn't
  re-offered until the range wraps. The residual failure modes are loud
  ones (a wrong response body, a self-connect parse error) — never a
  false green.
  """
  def refused_url do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    "http://127.0.0.1:#{port}"
  end

  @doc """
  An `Akaw.Client` whose every request fails with `:econnrefused`.
  """
  def refused_client(extra \\ []) do
    Akaw.new([base_url: refused_url(), finch: start_finch()] ++ extra)
  end

  # Unique-atom names are required by Finch (it's a registered process);
  # ~400 per suite run is far from any atom-table concern.
  defp start_finch do
    name = :"akaw_loopback_finch_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: name}, id: make_ref())
    name
  end
end
