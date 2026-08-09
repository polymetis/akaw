defmodule Akaw do
  @moduledoc """
  Akaw — an Elixir client for [CouchDB](https://couchdb.apache.org/).

  Akaw is a thin wrapper around the CouchDB HTTP API, speaking directly
  through [Finch](https://hex.pm/packages/finch) with the OTP-native
  `JSON` module — between your call and the socket sit exactly one HTTP
  client and one parser. Endpoints are exposed as plain functions that
  return `{:ok, decoded_map}` on success or `{:error, term}` on failure.

  ## Quick start

      client = Akaw.new(base_url: "http://localhost:5984",
                        auth: {:basic, "admin", "password"})

      {:ok, info} = Akaw.Server.info(client)
      {:ok, _}    = Akaw.Database.create(client, "mydb")
      {:ok, doc}  = Akaw.Document.get(client, "mydb", "user_42")

  ## Module map

  Endpoints are grouped by the CouchDB API section they belong to:

  | Module                    | CouchDB endpoints                                                                                                                         |
  | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
  | `Akaw.Server`             | `/`, `/_all_dbs`, `/_dbs_info`, `/_uuids`, `/_replicate`, `/_db_updates`, `/_membership`, `/_active_tasks`, `/_up`, `/_search_analyze`, `/_nouveau_analyze` |
  | `Akaw.Session`            | `/_session` (+ `refresh/3` for re-auth)                                                                                                   |
  | `Akaw.SessionServer`      | GenServer wrapper that holds an authed client and refreshes its cookie on a timer                                                         |
  | `Akaw.Database`           | `/{db}` (HEAD/GET/PUT/DELETE/POST), `/_compact[/{ddoc}]`, `/_view_cleanup`, `/_ensure_full_commit`, `/_revs_limit`                        |
  | `Akaw.Document`           | `/{db}/{docid}` (HEAD/GET/PUT/DELETE/COPY)                                                                                                |
  | `Akaw.Documents`          | `/{db}/_all_docs`, `/_bulk_get`, `/_bulk_docs`, `/_design_docs`                                                                           |
  | `Akaw.Attachment`         | `/{db}/{docid}/{attname}`                                                                                                                 |
  | `Akaw.DesignDoc`          | `/{db}/_design/{ddoc}` + `/_info`                                                                                                         |
  | `Akaw.View`               | `/{db}/_design/{ddoc}/_view/{view}` (+ `/queries`)                                                                                        |
  | `Akaw.Find`               | `/{db}/_find`, `/_index`, `/_explain`                                                                                                     |
  | `Akaw.Changes`            | `/{db}/_changes` (with `stream/3` for `feed=continuous`)                                                                                  |
  | `Akaw.Replication`        | replication docs in `/_replicator`, `/_scheduler/docs[/_replicator/{id}]`, `/_scheduler/jobs`                                             |
  | `Akaw.Partition`          | `/{db}/_partition/{partition}/...`                                                                                                        |
  | `Akaw.LocalDoc`           | `/{db}/_local/{docid}`, `/{db}/_local_docs`                                                                                               |
  | `Akaw.Security`           | `/{db}/_security`                                                                                                                         |
  | `Akaw.Purge`              | `/{db}/_purge`, `/_purged_infos`, `/_purged_infos_limit`                                                                                  |
  | `Akaw.Node`               | `/_node/{node}`, `/_stats`, `/_system`, `/_prometheus`, `/_smoosh/status`, `/_versions`, `/_restart`                                      |
  | `Akaw.Config`             | `/_node/{node}/_config[/section[/key]]`, `/_reload`                                                                                       |
  | `Akaw.Cluster`            | `/_cluster_setup`                                                                                                                         |
  | `Akaw.Reshard`            | `/_reshard`, `/_reshard/state`, `/_reshard/jobs[/{jobid}[/state]]`                                                                        |
  | `Akaw.DesignDoc.Shows`    | `/{db}/_design/{ddoc}/_show/{func}[/{docid}]`                                                                                             |
  | `Akaw.DesignDoc.Lists`    | `/{db}/_design/{ddoc}/_list/{func}/{view}` (cross-ddoc views supported)                                                                   |
  | `Akaw.DesignDoc.Updates`  | `/{db}/_design/{ddoc}/_update/{func}[/{docid}]`                                                                                           |
  | `Akaw.DesignDoc.Rewrites` | `/{db}/_design/{ddoc}/_rewrite/{path}`                                                                                                    |
  | `Akaw.Search`             | `/{db}/_design/{ddoc}/_search[_info]/{index}` (Clouseau plugin)                                                                           |
  | `Akaw.Nouveau`            | `/{db}/_design/{ddoc}/_nouveau[_info]/{index}` (Nouveau plugin)                                                                           |

  ## Connection pooling

  Akaw is an OTP application: it boots one Finch instance named
  `Akaw.Finch` (one HTTP/1 pool of 50 connections per CouchDB host),
  and every client uses it unless told otherwise. To use a custom pool
  — bigger sizes for high-concurrency workloads, TLS options for a
  self-signed CouchDB, a proxy — start your own Finch in your
  supervision tree and pass its name:

      children = [
        {Finch, name: MyApp.Finch, pools: %{default: [size: 50]}}
      ]

      client = Akaw.new(base_url: "http://localhost:5984", finch: MyApp.Finch)

  ## Notes & gotchas

    * **JSON with duplicate keys.** CouchDB happily stores documents with
      repeated keys (the JSON spec allows it). Decoding collapses
      duplicates to the **first**-seen value (verified empirically
      against the OTP-native `JSON` module). If you need to preserve
      duplicates you'll need a custom decoder; this isn't supported
      today.

    * **Streaming.** Large responses — `_changes` with `feed=continuous`,
      `_all_docs` over giant databases, full views, large Mango finds,
      cluster-wide `_db_updates` — should be consumed via one of the
      streaming flavors:

      *Lazy `Enumerable.t()` (ergonomic, mailbox-bound):*

        * `Akaw.Changes.stream/3` and `stream_post/4`
        * `Akaw.Documents.stream_all_docs/3` and `stream_design_docs/3`
        * `Akaw.View.stream/5` and `stream_post_keys/6`
        * `Akaw.Find.stream_find/3`
        * `Akaw.Server.stream_db_updates/2`
        * `Akaw.Partition.stream_all_docs/4`, `stream_view/6`, `stream_find/4`

      *Synchronous callback (real TCP backpressure, safe from a GenServer
      or LiveView):*

        * `Akaw.Changes.reduce_while/5` and `reduce_while_post/6`
        * `Akaw.Documents.reduce_while_all_docs/5` and
          `reduce_while_design_docs/5`
        * `Akaw.View.reduce_while/7` and `reduce_while_post_keys/8`
        * `Akaw.Find.reduce_while/6`
        * `Akaw.Server.reduce_while_db_updates/4`
        * `Akaw.Partition.reduce_while_all_docs/6`,
          `reduce_while_view/8`, `reduce_while_find/7`

      The lazy variants deliver response parts as messages into the
      calling process's mailbox with no backpressure (consumed with a
      selective `receive` — unrelated messages are left alone); prefer
      a `Task` or the callback variants for anything long-lived. The
      callback variants run the reducer inline inside
      `Finch.stream_while`, so no messages are involved and blocking in
      the reducer stalls CouchDB at the socket. Reading any of these
      with the non-streaming variant loads the entire response into
      memory.

      *Callback contract.* Every `reduce_while*` function takes
      `(acc, reducer, opts)`. The reducer is `(item, acc) -> {:cont, acc}
      | {:halt, acc}`; the function returns `{:ok, final_acc} |
      {:error, %Akaw.Error{}}`.

      *Per-call transport escape hatches.* The flat `opts` keyword can
      include any of these transport-level options inline, in addition
      to CouchDB query params:

        * `:receive_timeout` — Finch's between-chunk timeout in ms
        * `:pool_timeout` — Finch wait time to acquire a pool worker

      Connection-level options (TLS for self-signed CouchDB, proxies)
      are configured on a named Finch pool, not per call — see
      "Connection pooling" below.

      Streaming and feed requests never retry — a per-call `retry:`
      raises `ArgumentError`, and a client-level
      `req_options: [retry: ...]` is overridden on those paths. Resume
      interrupted walks from a checkpoint you own instead; see
      "Interrupted walks" in the `reduce_while` docs.

      Anything else flows through to the endpoint as a query param —
      except on the Mango `reduce_while` variants, where the query
      lives in the POSTed body and non-transport opts are ignored
      (see `Akaw.Find.reduce_while/6`).
      For held-open feeds (longpoll/continuous/eventsource), `:receive_timeout`
      auto-defaults to cover CouchDB's legitimate quiet window —
      `heartbeat * 2` for an integer `:heartbeat`, 120s for a
      server-picked one, otherwise the feed's `:timeout` (server
      default 60s) plus slack. An explicit `:receive_timeout` — per
      call or per client — always wins.

    * **Errors.** Every non-success path produces `{:error, %Akaw.Error{}}`.
      HTTP non-2xx fills `:status`, `:error`, `:reason`, `:body` from
      CouchDB. Transport failures (timeouts, DNS, refused) set
      `status: nil` and stash the underlying Mint/Finch exception in
      `body.exception` for the curious — tagged `"transport_error"` on
      plain requests and `"stream_transport_error"` on the streaming
      APIs. See `Akaw.Error` for the full inventory of shapes.
  """

  alias Akaw.Client

  @doc """
  Build a `%Akaw.Client{}` configured for a CouchDB instance.

  ## Options

    * `:base_url` (required) — base URL of the CouchDB instance,
      e.g. `"http://localhost:5984"`. Trailing slash is stripped.

      Credentials embedded in the URL (`"http://admin:pw@localhost:5984"`)
      are lifted out into `:auth` as `{:basic, user, password}`, so the
      secret ends up in the field `Akaw.Client`'s `Inspect` implementation
      redacts rather than in the one it prints. An explicit `:auth` option
      takes precedence.

    * `:auth` — authentication credentials. One of:

        * `nil` (default) — no auth
        * `{:basic, username, password}` — HTTP basic auth
        * `{:bearer, token}` — bearer token (JWT)

    * `:finch` — name of a custom Finch pool, e.g. `MyApp.Finch`, or a
      keyword list, e.g. `[name: MyApp.Finch, pool_tag: :bulk]`.
      Defaults to `Akaw.Finch`, the pool the Akaw application boots —
      see "Connection pooling".

    * `:headers` — list of `{name, value}` headers added to every request.

    * `:req_options` — a *narrow, named* set of client-level options merged
      into every request; per-call options override these. Allowed keys:
      `:receive_timeout`, `:pool_timeout`, `:retry` (atoms only —
      `false` disables the keep-alive-race retry; `:safe_transient` /
      `:transient` both mean the default policy; plain requests only,
      streaming and feed paths never retry),
      `:compressed`, and `:headers`. Anything
      else raises `ArgumentError` — this is deliberately not an
      arbitrary passthrough to the underlying HTTP client, so the
      client contract survives a transport change. Connection-level
      options (TLS for self-signed CouchDB, proxies) belong on a named
      Finch pool passed via `:finch` — see "Connection pooling". For
      test stubbing, point `:base_url` at a loopback listener serving
      your stub — see "Testing against Akaw" in the README.

  ## Examples

      iex> client = Akaw.new(base_url: "http://localhost:5984")
      iex> client.base_url
      "http://localhost:5984"

      iex> Akaw.new(base_url: "http://x:5984/").base_url
      "http://x:5984"

      iex> client = Akaw.new(base_url: "http://x", auth: {:basic, "admin", "pw"})
      iex> client.auth
      {:basic, "admin", "pw"}

      iex> client = Akaw.new(base_url: "http://admin:pw@x:5984")
      iex> {client.base_url, client.auth}
      {"http://x:5984", {:basic, "admin", "pw"}}

      iex> client = Akaw.new(base_url: "http://ignored:me@x", auth: {:bearer, "tok"})
      iex> {client.base_url, client.auth}
      {"http://x", {:bearer, "tok"}}

      iex> client = Akaw.new(base_url: "http://x", finch: MyApp.Finch)
      iex> client.finch
      MyApp.Finch

      iex> client = Akaw.new(base_url: "http://x", headers: [{"x-trace", "abc"}])
      iex> client.headers
      [{"x-trace", "abc"}]
  """
  @spec new(keyword()) :: Client.t()
  def new(opts) when is_list(opts) do
    {base_url, url_auth} =
      opts |> Keyword.fetch!(:base_url) |> String.trim_trailing("/") |> split_userinfo()

    %Client{
      base_url: base_url,
      auth: validate_auth!(Keyword.get(opts, :auth) || url_auth),
      finch: opts |> Keyword.get(:finch) |> validate_finch!(),
      headers: Keyword.get(opts, :headers, []),
      req_options: opts |> Keyword.get(:req_options, []) |> validate_req_options!()
    }
  end

  # The keyword form takes exactly the keys the request layer forwards.
  # Silently dropping the rest would let `finch: [name: X, pool_size:
  # 100]` run on default sizing until saturation teaches the user
  # otherwise — the failure arrives days later, pointing nowhere.
  defp validate_finch!(nil), do: nil
  defp validate_finch!(name) when is_atom(name), do: name

  defp validate_finch!(options) when is_list(options) do
    case Keyword.keys(options) -- [:name, :pool_tag] do
      [] ->
        options

      unknown ->
        raise ArgumentError, """
        unknown key(s) in :finch: #{inspect(Enum.uniq(unknown))}

        The keyword form takes exactly :name and :pool_tag. Pool sizing, \
        TLS, and proxy settings are configured on the named Finch pool \
        itself:

            {Finch, name: MyApp.CouchPool, pools: %{default: [size: 100]}}

            Akaw.new(base_url: url, finch: MyApp.CouchPool)
        """
    end
  end

  defp validate_finch!(other) do
    raise ArgumentError,
          ":finch takes a pool name (atom) or a keyword list " <>
            "[name: ..., pool_tag: ...] — got #{inspect(other)}"
  end

  # A control character in a credential (the classic: a trailing newline
  # from an env var or file read) must fail HERE, loudly and redacted.
  # Let through, a bearer token would be rejected by the transport's
  # header validation — whose diagnostic echoes the full header value
  # into the error struct and from there into logs — and a basic
  # credential would just encode to garbage and 401 forever, silently.
  defp validate_auth!({:basic, user, pass} = auth) when is_binary(user) and is_binary(pass) do
    reject_control_characters!(user, "basic-auth username")
    reject_control_characters!(pass, "basic-auth password")
    auth
  end

  defp validate_auth!({:bearer, token} = auth) when is_binary(token) do
    reject_control_characters!(token, "bearer token")
    auth
  end

  defp validate_auth!(other), do: other

  defp reject_control_characters!(value, label) do
    if value =~ ~r/[\x00-\x1F\x7F]/ do
      raise ArgumentError,
            "the #{label} contains control characters (a trailing newline from " <>
              "an env var or file read?) — value not shown. Trim it before Akaw.new/1."
    end
  end

  # The named allowlist for client-level request options. Deliberately
  # narrow: an arbitrary passthrough to the HTTP client would weld the
  # public contract to that client's option surface — the exact coupling
  # the transport-neutrality work exists to prevent.
  @allowed_req_options [
    :receive_timeout,
    :pool_timeout,
    :retry,
    :compressed,
    :headers
  ]

  defp validate_req_options!(req_options) when is_list(req_options) do
    validate_retry_value!(Keyword.get(req_options, :retry))

    case Keyword.keys(req_options) -- @allowed_req_options do
      [] ->
        req_options

      unknown ->
        raise ArgumentError, """
        unknown key(s) in :req_options: #{inspect(Enum.uniq(unknown))}

        :req_options is a narrow, named allowlist — #{inspect(@allowed_req_options)} \
        — not an arbitrary passthrough to the underlying HTTP client.

        If you were passing :connect_options (custom TLS for a self-signed \
        CouchDB, proxy settings): connection options are configured on a \
        named Finch pool instead —

            children = [
              {Finch,
               name: MyApp.CouchPool,
               pools: %{default: [conn_opts: [transport_opts: [cacertfile: "..."]]]}}
            ]

            Akaw.new(base_url: url, finch: MyApp.CouchPool)

        If you were passing :plug (test stubbing): serve the stub from a \
        real loopback listener and point :base_url at it — Bandit on \
        port 0 gives each test its own URL. See "Testing against Akaw" \
        in the README.
        """
    end
  end

  # The :retry KEY is allowed; its value domain is contract too. Atoms
  # only: a function-valued policy would program the caller directly
  # against the transport's request/response types — the exact coupling
  # this contract exists to contain (and the Req-era transport actually
  # accepted one).
  defp validate_retry_value!(value) when value in [nil, false, :safe_transient, :transient] do
    :ok
  end

  defp validate_retry_value!(other) do
    raise ArgumentError,
          "req_options[:retry] takes false, :safe_transient, or :transient — " <>
            "got #{inspect(other)}. Function-valued retry policies program " <>
            "against the underlying HTTP client's request/response types, " <>
            "which the client contract deliberately does not expose."
  end

  # Credentials embedded in the URL (`http://admin:pw@host:5984`) are
  # lifted into `:auth` at construction time, for two load-bearing
  # reasons. First, Finch silently discards URL userinfo — without the
  # lift the credential would simply never reach CouchDB (the Req-era
  # transports flip-flopped on this; now it's akaw's own guarantee).
  # Second, a credential inside `:base_url` collides with
  # `Akaw.Client`'s Inspect derivation, which deliberately prints
  # `:base_url` in the clear and redacts `:auth` — the lift lands the
  # secret in the redacted field. An explicit `:auth` option still wins.
  defp split_userinfo(base_url) do
    case URI.parse(base_url) do
      %URI{userinfo: nil} ->
        {base_url, nil}

      %URI{userinfo: userinfo} = uri ->
        {user, pass} =
          case String.split(userinfo, ":", parts: 2) do
            [user, pass] -> {user, pass}
            [user] -> {user, ""}
          end

        {URI.to_string(%{uri | userinfo: nil}), {:basic, URI.decode(user), URI.decode(pass)}}
    end
  end
end
