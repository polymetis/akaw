defmodule Akaw do
  @moduledoc """
  Akaw — an Elixir client for [CouchDB](https://couchdb.apache.org/).

  Akaw is a thin wrapper around the CouchDB HTTP API built on
  [Req](https://hex.pm/packages/req) (which uses
  [Finch](https://hex.pm/packages/finch) underneath). Endpoints are exposed as
  plain functions that return `{:ok, decoded_map}` on success or
  `{:error, term}` on failure.

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

  Each `Akaw.Client` can target a specific Finch pool. By default Req uses
  its built-in pool. To use a custom pool — for example to raise `:size` or
  `:count` for high-concurrency workloads — start a Finch instance in your
  supervision tree and pass its name:

      children = [
        {Finch, name: MyApp.Finch, pools: %{default: [size: 50]}}
      ]

      client = Akaw.new(base_url: "http://localhost:5984", finch: MyApp.Finch)

  ## Notes & gotchas

    * **JSON with duplicate keys.** CouchDB happily stores documents with
      repeated keys (the JSON spec allows it). Akaw decodes responses through
      Req's standard JSON layer, which collapses duplicates to the last-seen
      value. If you need to preserve duplicates you'll need a custom decoder;
      this isn't supported today.

    * **Streaming.** Large responses — `_changes` with `feed=continuous`,
      `_all_docs` over giant databases, full views, large Mango finds,
      cluster-wide `_db_updates` — should be consumed via the dedicated
      `stream_*` functions:

        * `Akaw.Changes.stream/3` and `stream_post/4`
        * `Akaw.Documents.stream_all_docs/3` and `stream_design_docs/3`
        * `Akaw.View.stream/5` and `stream_post_keys/6`
        * `Akaw.Find.stream_find/3`
        * `Akaw.Server.stream_db_updates/2`
        * `Akaw.Partition.stream_all_docs/4`, `stream_view/6`, `stream_find/4`

      Reading any of these with the non-streaming variant loads the entire
      response into memory.

    * **Errors.** Every non-success path produces `{:error, %Akaw.Error{}}`.
      HTTP non-2xx fills `:status`, `:error`, `:reason`, `:body` from
      CouchDB. Transport failures (timeouts, DNS, refused) set
      `status: nil`, `error: "transport_error"`, and stash the underlying
      Mint/Finch exception in `body.exception` for the curious.
  """

  alias Akaw.Client

  @doc """
  Build a `%Akaw.Client{}` configured for a CouchDB instance.

  ## Options

    * `:base_url` (required) — base URL of the CouchDB instance,
      e.g. `"http://localhost:5984"`. Trailing slash is stripped.

    * `:auth` — authentication credentials. One of:

        * `nil` (default) — no auth
        * `{:basic, username, password}` — HTTP basic auth
        * `{:bearer, token}` — bearer token (JWT)

    * `:finch` — name of a custom Finch pool, e.g. `MyApp.Finch`. Defaults
      to Req's built-in pool.

    * `:headers` — list of `{name, value}` headers added to every request.

    * `:req_options` — keyword list of Req options merged into every request
      (e.g. `receive_timeout: 30_000`). Per-call options override these.

  ## Examples

      iex> client = Akaw.new(base_url: "http://localhost:5984")
      iex> client.base_url
      "http://localhost:5984"

      iex> Akaw.new(base_url: "http://x:5984/").base_url
      "http://x:5984"

      iex> client = Akaw.new(base_url: "http://x", auth: {:basic, "admin", "pw"})
      iex> client.auth
      {:basic, "admin", "pw"}

      iex> client = Akaw.new(base_url: "http://x", finch: MyApp.Finch)
      iex> client.finch
      MyApp.Finch

      iex> client = Akaw.new(base_url: "http://x", headers: [{"x-trace", "abc"}])
      iex> client.headers
      [{"x-trace", "abc"}]
  """
  @spec new(keyword()) :: Client.t()
  def new(opts) when is_list(opts) do
    base_url = opts |> Keyword.fetch!(:base_url) |> String.trim_trailing("/")

    %Client{
      base_url: base_url,
      auth: Keyword.get(opts, :auth),
      finch: Keyword.get(opts, :finch),
      headers: Keyword.get(opts, :headers, []),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end
end
