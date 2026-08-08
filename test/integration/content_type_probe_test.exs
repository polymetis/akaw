defmodule Akaw.Integration.ContentTypeProbeTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  import Akaw.IntegrationHelpers

  # The content-type probe: pins the empirical facts under the transport
  # swap's decode gate ("D3" in the design brief).
  #
  # The decode gate is content-type-based: a response is JSON-decoded
  # exactly when CouchDB says `application/json`. The safety of that
  # choice rests on facts this suite pins against a real CouchDB:
  #
  #   * Every JSON endpoint class answers `application/json` even when
  #     the request carries NO Accept header at all. (CouchDB 1.x
  #     famously answered `text/plain` to clients that didn't explicitly
  #     accept JSON — that habit is gone from the 3.x line, and this is
  #     the test that will notice if it ever comes back.)
  #   * Error bodies are JSON too, on the same terms.
  #   * The classes that must NOT be force-decoded declare themselves:
  #     attachments carry their stored type, `feed=eventsource` is
  #     `text/event-stream`, and design functions (_show/_list) set
  #     whatever type the function chose.
  #
  # Requests here are raw gen_tcp on purpose: the probe outlives any
  # HTTP-client swap, and no client library lets you send *no* Accept
  # header as precisely as writing the bytes yourself.

  @ddoc %{
    language: "javascript",
    views: %{
      by_n: %{map: "function(d) { if (d.n) emit(d.n, d.n); }"}
    },
    shows: %{
      echo: """
      function(doc, req) {
        var body = doc ? doc._id : 'no_doc';
        return { body: body, headers: { 'Content-Type': 'text/plain' } };
      }
      """
    },
    lists: %{
      ids: """
      function(head, req) {
        start({ headers: { "Content-Type": "text/plain" } });
        var row;
        while (row = getRow()) { send(row.id + "\\n"); }
      }
      """
    }
  }

  setup do
    client = client()
    db = setup_temp_db(client)
    {:ok, _} = Akaw.DesignDoc.put(client, db, "fns", @ddoc)
    {:ok, _} = Akaw.Document.put(client, db, "doc_1", %{n: 1})

    {:ok, %{"_rev" => rev}} = Akaw.Document.get(client, db, "doc_1")

    {:ok, _} =
      Akaw.Attachment.put(client, db, "doc_1", "note.txt", "plain text bytes",
        rev: rev,
        content_type: "text/plain"
      )

    {:ok, client: client, db: db}
  end

  describe "JSON endpoint classes answer application/json with no Accept header" do
    test "server metadata endpoints" do
      for path <- ["/", "/_all_dbs", "/_uuids", "/_up", "/_session"] do
        {status, headers} = raw_request("GET", path)
        assert {path, content_type(headers)} == {path, "application/json"}
        assert status in 200..299
      end
    end

    test "database and document reads", %{db: db} do
      for path <- [
            "/#{db}",
            "/#{db}/doc_1",
            "/#{db}/_all_docs",
            "/#{db}/_design/fns/_view/by_n"
          ] do
        {status, headers} = raw_request("GET", path)
        assert {path, content_type(headers)} == {path, "application/json"}
        assert status == 200
      end
    end

    test "every _changes feed mode except eventsource", %{db: db} do
      for feed <- ["normal", "longpoll", "continuous"] do
        {status, headers} =
          raw_request("GET", "/#{db}/_changes?feed=#{feed}&timeout=0")

        assert {feed, content_type(headers)} == {feed, "application/json"}
        assert status == 200
      end
    end

    test "_find answers JSON", %{db: db} do
      {status, headers} =
        raw_request("POST", "/#{db}/_find",
          body: ~s({"selector":{"n":{"$gt":0}}}),
          headers: ["content-type: application/json"]
        )

      assert status == 200
      assert content_type(headers) == "application/json"
    end

    test "error bodies are JSON on the same terms", %{db: db} do
      # Missing database and rev-less overwrite: the two everyday error
      # shapes (404 / 409). Status is config-independent for both.
      assert {404, missing_headers} =
               raw_request("GET", "/no_such_db_#{System.unique_integer([:positive])}")

      assert content_type(missing_headers) == "application/json"

      assert {409, conflict_headers} =
               raw_request("PUT", "/#{db}/doc_1",
                 body: ~s({"n":2}),
                 headers: ["content-type: application/json"]
               )

      assert content_type(conflict_headers) == "application/json"

      # Unauthenticated: don't pin the status (whether anonymous reads
      # are allowed is server config), pin that whatever comes back is
      # still JSON.
      {_status, anon_headers} = raw_request("GET", "/_all_dbs", auth: false)
      assert content_type(anon_headers) == "application/json"
    end
  end

  describe "classes the decode gate must leave alone declare themselves" do
    test "attachments carry their stored content-type", %{db: db} do
      assert {200, headers} = raw_request("GET", "/#{db}/doc_1/note.txt")
      assert content_type(headers) == "text/plain"
    end

    test "feed=eventsource is text/event-stream", %{db: db} do
      assert {200, headers} = raw_request("GET", "/#{db}/_changes?feed=eventsource&timeout=0")
      assert content_type(headers) == "text/event-stream"
    end

    test "design functions set their own content-type", %{db: db} do
      for path <- [
            "/#{db}/_design/fns/_show/echo/doc_1",
            "/#{db}/_design/fns/_list/ids/by_n"
          ] do
        assert {200, headers} = raw_request("GET", path)
        assert {path, content_type(headers)} == {path, "text/plain"}
      end
    end
  end

  describe "and the consumer-visible consequences through akaw" do
    test "JSON classes arrive decoded", %{client: client} do
      assert {:ok, %{"couchdb" => "Welcome"}} = Akaw.Server.info(client)
    end

    test "error bodies arrive decoded into the error struct", %{client: client} do
      assert {:error, %Akaw.Error{status: 404, error: "not_found", reason: reason}} =
               Akaw.Database.info(client, "no_such_db_#{System.unique_integer([:positive])}")

      assert is_binary(reason)
    end

    test "attachments arrive as raw bytes with their type in meta", %{client: client, db: db} do
      assert {:ok, "plain text bytes", %{content_type: "text/plain" <> _}} =
               Akaw.Attachment.get(client, db, "doc_1", "note.txt")
    end
  end

  # ---------------------------------------------------------------------
  # Raw HTTP/1.1 over gen_tcp: exactly the bytes we choose, nothing more.
  # ---------------------------------------------------------------------

  defp raw_request(method, path, opts \\ []) do
    %URI{host: host, port: port} =
      URI.parse(System.get_env("AKAW_TEST_URL", "http://localhost:5984"))

    body = Keyword.get(opts, :body, "")

    header_lines =
      [
        "host: #{host}:#{port}",
        "connection: close",
        auth_header(Keyword.get(opts, :auth, true)),
        if(body != "", do: "content-length: #{byte_size(body)}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.concat(Keyword.get(opts, :headers, []))

    request =
      "#{method} #{path} HTTP/1.1\r\n" <>
        Enum.join(header_lines, "\r\n") <> "\r\n\r\n" <> body

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5_000)

    :ok = :gen_tcp.send(socket, request)
    response = recv_until_closed(socket, [])
    :gen_tcp.close(socket)

    [head | _] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | raw_headers] = String.split(head, "\r\n")
    ["HTTP/1.1", status | _] = String.split(status_line, " ")

    headers =
      Map.new(raw_headers, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    {String.to_integer(status), headers}
  end

  defp auth_header(false), do: nil

  defp auth_header(true) do
    user = System.get_env("AKAW_TEST_USER", "admin")
    pass = System.get_env("AKAW_TEST_PASS", "password")
    "authorization: Basic " <> Base.encode64("#{user}:#{pass}")
  end

  defp recv_until_closed(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        recv_until_closed(socket, [acc | data])

      {:error, :closed} ->
        IO.iodata_to_binary(acc)

      {:error, reason} ->
        # Name the failure instead of dying in a clause error — when
        # this fires against some future CouchDB that stops honoring
        # `connection: close`, the bytes seen so far are the evidence.
        received = IO.iodata_to_binary(acc)

        flunk("""
        recv failed with #{inspect(reason)} before the server closed.
        #{byte_size(received)} bytes received: #{inspect(String.slice(received, 0, 300))}
        """)
    end
  end

  # Media type only — charset parameters are the server's business.
  defp content_type(headers) do
    headers
    |> Map.fetch!("content-type")
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
  end
end
