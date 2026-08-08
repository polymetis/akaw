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

  The stub plug runs in a Bandit acceptor process, not the test process.
  To observe the request from the test, close over the test pid and
  message it (`test = self()` before the plug, `send(test, ...)` inside,
  `assert_receive` after) — an `assert` directly inside the plug would
  fail the acceptor, not the test.

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
    @behaviour Plug

    @impl true
    def init(fun) when is_function(fun, 1), do: fun

    @impl true
    def call(conn, fun), do: fun.(conn)
  end

  @doc """
  Serve `plug_fun` from a fresh loopback listener; returns its base URL.
  """
  def url(plug_fun) when is_function(plug_fun, 1) do
    server =
      start_supervised!(
        {Bandit, plug: {FunPlug, plug_fun}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
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
  """
  def client(plug_fun, extra \\ []) do
    Akaw.new([base_url: url(plug_fun)] ++ extra)
  end

  @doc """
  Send `data` as a JSON response. Like `Req.Test.json/2`: respects a
  status already set with `Plug.Conn.put_status/2`, defaults to 200.
  """
  def json(%Plug.Conn{} = conn, data) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(conn.status || 200, JSON.encode_to_iodata!(data))
  end

  @doc """
  A base URL whose connections are refused — a loopback port that was
  bound and then closed, which is what a down CouchDB looks like from
  the client side. Replaces `Req.Test.transport_error(conn, :econnrefused)`
  with the real thing.

  The OS could in principle hand the port to another process between the
  close and the connect; ephemeral allocation walks the port range, so a
  just-released port isn't re-offered until the range wraps.
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
    Akaw.new([base_url: refused_url()] ++ extra)
  end
end
