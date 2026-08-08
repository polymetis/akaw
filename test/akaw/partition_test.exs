defmodule Akaw.PartitionTest do
  use ExUnit.Case, async: true

  alias Akaw.Loopback

  setup do
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(test, %{
        method: conn.method,
        path: conn.request_path,
        query_string: conn.query_string,
        body: body
      })

      Loopback.json(conn, %{"rows" => []})
    end

    {:ok, client: Loopback.client(plug)}
  end

  test "info/3 → GET /{db}/_partition/{p}", %{client: client} do
    assert {:ok, _} = Akaw.Partition.info(client, "mydb", "tenant42")
    assert_receive %{method: "GET", path: "/mydb/_partition/tenant42"}
  end

  test "all_docs/4 → GET /{db}/_partition/{p}/_all_docs", %{client: client} do
    assert {:ok, _} =
             Akaw.Partition.all_docs(client, "mydb", "tenant42",
               include_docs: true,
               startkey: "user_"
             )

    assert_receive %{path: "/mydb/_partition/tenant42/_all_docs", query_string: qs}
    assert qs =~ "include_docs=true"
    decoded = URI.decode_query(qs)
    assert decoded["startkey"] == "\"user_\""
  end

  test "view/6 → GET /.../_partition/{p}/_design/{ddoc}/_view/{view}", %{client: client} do
    assert {:ok, _} = Akaw.Partition.view(client, "mydb", "t42", "by_email", "all")
    assert_receive %{path: "/mydb/_partition/t42/_design/by_email/_view/all"}
  end

  test "find/4 → POST /.../_partition/{p}/_find", %{client: client} do
    query = %{selector: %{tenant: "t42", active: true}}
    assert {:ok, _} = Akaw.Partition.find(client, "mydb", "t42", query)
    assert_receive %{method: "POST", path: "/mydb/_partition/t42/_find", body: body}
    assert JSON.decode!(body) == %{"selector" => %{"tenant" => "t42", "active" => true}}
  end

  test "explain/4 → POST /.../_partition/{p}/_explain", %{client: client} do
    assert {:ok, _} =
             Akaw.Partition.explain(client, "mydb", "t42", %{selector: %{a: 1}})

    assert_receive %{method: "POST", path: "/mydb/_partition/t42/_explain"}
  end

  describe "streaming variants" do
    # These three function bodies had zero test coverage — the one
    # genuinely untested feature the audit's coverage run surfaced.
    # ETS rather than send: the lazy streams drain the consuming
    # process's mailbox, so a message-based probe gets eaten — and the
    # plug runs in a Bandit connection-handler process, so Process.put wouldn't
    # reach the test either.
    defp partition_stream_plug(container, seen) do
      body =
        ~s({"total_rows":2,"offset":0,"#{container}":[\n) <>
          ~s({"id":"t:a","key":"t:a","value":1},\n) <>
          ~s({"id":"t:b","key":"t:b","value":2}\n]})

      fn conn ->
        {:ok, request_body, conn} = Plug.Conn.read_body(conn)

        :ets.insert(seen, {:akaw_partition_stream_req, %{
          method: conn.method,
          path: conn.request_path,
          query_string: conn.query_string,
          body: request_body
        }})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end
    end

    defp partition_stream_client(container, seen) do
      Loopback.client(partition_stream_plug(container, seen))
    end

    test "stream_all_docs/4 streams decoded rows from the partition path" do
      seen = :ets.new(:akaw_partition_stream_all_docs, [:public])

      rows =
        partition_stream_client("rows", seen)
        |> Akaw.Partition.stream_all_docs("mydb", "tenant42", startkey: "t:")
        |> Enum.to_list()

      assert [%{"id" => "t:a"}, %{"id" => "t:b"}] = rows

      [{_, request}] = :ets.lookup(seen, :akaw_partition_stream_req)
      assert request.method == "GET"
      assert request.path == "/mydb/_partition/tenant42/_all_docs"
      assert URI.decode_query(request.query_string)["startkey"] == ~s|"t:"|
    end

    test "stream_view/6 streams decoded rows from the partition view path" do
      seen = :ets.new(:akaw_partition_stream_view, [:public])

      rows =
        partition_stream_client("rows", seen)
        |> Akaw.Partition.stream_view("mydb", "tenant42", "d", "by_n")
        |> Enum.to_list()

      assert [%{"id" => "t:a"}, %{"id" => "t:b"}] = rows

      [{_, request}] = :ets.lookup(seen, :akaw_partition_stream_req)
      assert request.path == "/mydb/_partition/tenant42/_design/d/_view/by_n"
    end

    test "stream_find/4 POSTs the query and streams the docs container" do
      seen = :ets.new(:akaw_partition_stream_find, [:public])

      rows =
        partition_stream_client("docs", seen)
        |> Akaw.Partition.stream_find("mydb", "tenant42", %{selector: %{n: 1}})
        |> Enum.to_list()

      assert [%{"id" => "t:a"}, %{"id" => "t:b"}] = rows

      [{_, request}] = :ets.lookup(seen, :akaw_partition_stream_req)
      assert request.method == "POST"
      assert request.path == "/mydb/_partition/tenant42/_find"
      assert JSON.decode!(request.body) == %{"selector" => %{"n" => 1}}
    end
  end
end
