# Changelog

All notable changes to Akaw are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Requires Req `~> 0.7`** (was `~> 0.5`). This is a hard floor — Akaw now
  uses Req 0.7's `finch: [name: …]` option spelling, which raises on 0.5. If
  your application pins Req itself, it needs the same bump.

  Also moves to Finch 0.23, Mint 1.9.3, and Plug 1.20.3 (test-only).

- **`Akaw.new/1` lifts credentials out of `:base_url`.** Given
  `base_url: "http://admin:pw@host:5984"`, the credential is moved into
  `:auth` as `{:basic, "admin", "pw"}` and the stored `:base_url` becomes
  `"http://host:5984"`. An explicit `:auth` still wins.

  Req 0.5 discarded URL credentials entirely (CouchDB answered 401); Req 0.7
  honours them. Handling it in `Akaw.new/1` keeps the behaviour the same
  either way, and keeps the secret out of `inspect/1` output — `Akaw.Client`
  redacts `:auth` but deliberately prints `:base_url`.

- **Sending a request body with `method: :get` now raises `ArgumentError`**
  in `Akaw.DesignDoc.Shows`, `Lists`, `Rewrites`, and `Updates`.

  Req 0.7 silently rewrites a GET carrying a body into a POST. Against
  CouchDB that changes which handler runs: a `_rewrite` rule pinned to
  `"method": "GET"` stops matching and returns 404, and a `_show`/`_list`
  function branching on `req.method` takes the other branch without erroring.
  Rather than let the verb change under you, Akaw refuses the combination.

  Pass `method: :post`, or the string `method: "GET"` if you genuinely want a
  GET that carries a body — Akaw sends that verbatim.

- **Query parameters are one-value-per-key.** Req 0.7 deduplicates params,
  keeping the last occurrence, where Req 0.5 appended. A repeated key in a
  `:params` keyword list no longer produces two query parameters, and for
  `Akaw.DesignDoc.Rewrites`, `:params` now *overrides* same-named parameters
  already present in the rewrite path rather than appending to them.

- **Attachments with an archive content type are no longer auto-decoded.**
  Req used to silently expand `application/zip`, `application/gzip`
  (and `x-gzip`), `application/x-tar`, `application/x-tgz`, and
  `application/zstd` response bodies. `Akaw.Attachment.get/5` now returns the
  raw bytes for those, which is what its documentation always said it did.
  JSON attachments are still decoded.

- **All transport failures on streaming calls now carry
  `error: "stream_transport_error"`.** The tag used to depend on which
  phase and flavor failed: a connect failure opening a lazy `stream/N`,
  or any transport failure on a `reduce_while` call, was tagged plain
  `"transport_error"`, while a mid-stream failure on the lazy path said
  `"stream_transport_error"` — the same physical event reading
  differently across API flavors. Now it's one tag per API mode:
  streaming calls always say `"stream_transport_error"`, non-streaming
  calls say `"transport_error"` (or `"decode_error"`, above). If you
  matched `"transport_error"` from `reduce_while` results, update the
  pattern.

- **Streaming transport failures report a stable `:reason`.**
  `%Akaw.Error{error: "stream_transport_error"}` previously carried an
  `inspect/1` dump of the underlying exception struct in `:reason`, which
  changed shape with the Finch version. It is now `Exception.message/1`
  (e.g. `"socket closed"`), and the struct itself is available at
  `body.exception`, matching the non-streaming path.

- Akaw is now developed and tested against **Erlang/OTP 29.0.5** and
  **Elixir 1.20.3**.

  The supported floor is unchanged: `mix.exs` still declares
  `elixir: "~> 1.18"`, which is what Akaw actually needs (the native `JSON`
  module, introduced in Elixir 1.18). Nothing in the library requires 1.19 or
  1.20, and the full suite — including the integration tests against a real
  CouchDB — passes on both the old and the new toolchain.

- **`Akaw.SessionServer`'s default `:refresh_interval` is now 5 minutes**
  (was 30). CouchDB's `AuthSession` cookie expires 10 minutes after issuance
  by default (`[chttpd_auth] timeout`), and the server holds one cookie
  between refreshes — with a 30-minute cadence the held cookie was dead for
  20 of every 30 minutes on an all-default setup. Pass
  `refresh_interval: :timer.minutes(30)` explicitly if you had raised
  CouchDB's timeout and relied on the old cadence.

- **`Akaw.Session.refresh/3` treats a 200 without `Set-Cookie` as an
  error.** Refresh strips the old cookie before re-authenticating, so
  `create/3`'s lenient no-cookie fallback (return the client unchanged)
  handed back a client with no credentials at all — which
  `Akaw.SessionServer` then installed as its state while emitting success
  telemetry. Refresh now returns
  `{:error, %Akaw.Error{error: "no_auth_cookie"}}`; the `SessionServer`
  keeps its previous client on that path, and refuses to start at all if
  the initial login grants no cookie. `create/3`'s documented fallback is
  unchanged.

### Fixed

- **Quiet longpoll and continuous feeds no longer die at the transport's
  15-second receive timeout.** CouchDB legitimately holds a quiet feed
  open until `:timeout` (server default 60s) — or indefinitely with a
  heartbeat — while Finch's default `receive_timeout` is 15s, so
  `Akaw.Changes.get(client, db, feed: "longpoll")` on a quiet database
  *always* failed client-side (and, with retry, took ~67 seconds and four
  abandoned server-side connections to do it). Held-open feeds now
  default `:receive_timeout` to cover the server's window: `heartbeat * 2`
  for an integer heartbeat, 120s for a server-picked one, otherwise
  `:timeout` + 5s slack. This applies to every held-open entry point:
  `Akaw.Changes.get/3`/`post/4` with longpoll/continuous/eventsource
  feeds, the lazy `Changes.stream/3`/`stream_post/4`,
  `Akaw.Server.db_updates/2`/`stream_db_updates/2`, and the
  `reduce_while` continuous wrappers (which previously only derived from
  `:heartbeat`). The non-reduce entry points also now route
  `:receive_timeout` / `:pool_timeout` / `:connect_options` to the
  transport instead of the query string. An explicit `:receive_timeout`
  always wins — per call or per client `req_options`.

  Note on `_db_updates`: CouchDB's documentation describes its
  `:timeout` in seconds, but the implementation (verified empirically
  against CouchDB 3.5) takes milliseconds, same as `_changes` — a quiet
  `_db_updates` longpoll answers at the same 60s default window.

- **A fully minified response now raises the promised
  `stream_format_error` instead of silently streaming zero items.** The
  item streamer's documented defense against minifying proxies only fired
  for garbage *inside* a row array whose opener sat on its own line. The
  common minification case — the whole body collapsed onto one line —
  never entered the array at all, so `stream_all_docs/3` and the
  `reduce_while` variants completed cleanly with zero rows from a 200
  that contained data. Rows inlined with their array opener (`[{`) now
  raise the documented diagnostic from the seek state. A legitimately
  empty inline array (`"rows":[]`) still streams zero items.

- **A 2xx response with a corrupt JSON body is now a `"decode_error"`,
  not a `"transport_error"`.** Req reports JSON decode failures through
  the same error channel as network failures, and Akaw wrapped them all
  with the tag its own docs define as "DNS, connection refused, timeout" —
  so a caller following the documented branch-on-`body.exception` retry
  pattern would loop forever against a permanently corrupt endpoint
  (a proxy truncating responses, say). Non-streaming decode failures now
  carry `error: "decode_error"` with the codec exception in
  `body.exception`, mirroring the streaming path's existing
  `"stream_decode_error"`.

- **Streaming requests no longer inherit Req's automatic retry.** Req's
  default `retry: :safe_transient` re-runs the whole request after a
  transient failure (a 5xx, a dropped connection, a receive timeout). On
  the streaming paths — `stream/N`, `reduce_while/N`, and friends — the
  rows consumed before the failure had already been delivered, and the
  retried attempt reset the internal accumulator and delivered them all
  again: a mid-feed disconnect during `reduce_while_all_docs` over a
  million rows silently re-ran the reducer from row one with the
  accumulator wiped, and a node restart mid-`_changes` re-delivered
  already-processed changes. Streaming requests now pin `retry: false`;
  `{:ok, final_acc}` means every row was delivered exactly once. An
  explicit `:retry` (per call or per client `req_options`) is respected
  for reducers that prefer restart-from-scratch over failing.
  Non-streaming requests keep Req's default retry.

- **A `password_fn` that raises or exits during a scheduled refresh no
  longer crash-loops `Akaw.SessionServer`.** The `:password` option is
  documented for deferred secret lookup (Vault, K8s secret reloaders) —
  but an exception at refresh time killed the GenServer, and the
  supervisor's restart re-ran the same failing function in `init/1`,
  looping until `max_restarts` took the tree down. A transient secret-store
  blip now takes the documented graceful path instead: the existing client
  stays in place, the `:error` telemetry event fires (with
  `%Akaw.Error{error: "refresh_exception"}`), and the refresh retries on
  the usual backoff. The initial lookup at start remains let-it-crash.

- **Responses are compressed again.** Req 0.6.1 made decompression opt-in, so
  Akaw silently stopped negotiating gzip. Measured against CouchDB 3.5.1 on
  the same request: 129 bytes with gzip versus 17,600 without. This only
  affected attachments — CouchDB does not compress its JSON API responses —
  but it was pure loss there. Pass `compressed: false` per client or per call
  if you want the old opt-in behaviour.

- **`Akaw.Document.delete/5` and `Akaw.Attachment.delete/6` no longer let a
  stray `rev:` in `opts` override the positional `rev` argument.** Under Req
  0.7's param deduplication the last occurrence won, which could turn a valid
  delete into a 409 conflict. The positional argument is now authoritative.

- **A named Finch pool no longer emits a deprecation warning on every
  request.** `Akaw.new(finch: MyApp.Finch)` and the `:pool_timeout` escape
  hatch keep their flat spelling; Akaw translates them to Req 0.7's
  `finch: [...]` form internally. This also removes roughly 0.3 ms of
  `IO.warn` overhead per warning per request.

  The one exception is `:pool_timeout` combined with `:connect_options`,
  where Req raises if `:finch` is set at all — the flat spelling and its
  warning stand there.

### Added

- Akaw is released under the **MIT license**, and carries the Hex package
  metadata needed to publish it.

- A real README, and API documentation via `ex_doc` (`mix docs`), with the
  modules grouped by CouchDB API section.

- `:finch` now also accepts a keyword list of Finch options, e.g.
  `Akaw.new(finch: [name: MyApp.Finch, pool_tag: :bulk])`. A bare pool name
  still works.

### Notes for consumers

- **`%Akaw.Error{}`'s `:reason` is display-only for transport errors.** For
  TLS failures in particular, `:reason` carries a string generated by Erlang's
  `:ssl` application that embeds an internal source-code line number, and that
  string changes between OTP releases:

  ```
  OTP 28: "TLS client: In state wait_cert_cr at ssl_handshake.erl:2201 generated CLIENT ALERT: ..."
  OTP 29: "TLS client: In state wait_cert_cr at ssl_handshake.erl:2250 generated CLIENT ALERT: ..."
  ```

  If you branch on transport failures, match on `body.exception` — a
  `%Req.TransportError{reason: …}` — rather than on the `:reason` string.
