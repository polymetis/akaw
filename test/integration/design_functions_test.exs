defmodule Akaw.Integration.DesignFunctionsTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  import Akaw.IntegrationHelpers

  # Design doc with one of each: a view, a show function, a list function,
  # an update function, and a rewrites table. JavaScript is what stock
  # CouchDB ships; quickjs is the active engine on 3.5.
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
    },
    updates: %{
      increment_n: """
      function(doc, req) {
        if (!doc) {
          return [null, { code: 404, body: 'no doc' }];
        }
        doc.n = (doc.n || 0) + 1;
        return [doc, { body: 'incremented' }];
      }
      """
    },
    rewrites: [
      %{from: "echoer", to: "_show/echo"}
    ]
  }

  setup do
    client = client()
    db = setup_temp_db(client)
    {:ok, _} = Akaw.DesignDoc.put(client, db, "fns", @ddoc)

    {:ok, _} = Akaw.Document.put(client, db, "doc_1", %{n: 1})
    {:ok, _} = Akaw.Document.put(client, db, "doc_2", %{n: 2})

    {:ok, client: client, db: db}
  end

  describe "Akaw.DesignDoc.Shows.call/5" do
    test "without doc — returns the no_doc literal", %{client: client, db: db} do
      assert {:ok, "no_doc"} = Akaw.DesignDoc.Shows.call(client, db, "fns", "echo")
    end

    test "with :doc_id — returns the doc's id", %{client: client, db: db} do
      assert {:ok, "doc_1"} =
               Akaw.DesignDoc.Shows.call(client, db, "fns", "echo", doc_id: "doc_1")
    end
  end

  describe "Akaw.DesignDoc.Lists.call/6" do
    test "transforms view rows", %{client: client, db: db} do
      assert {:ok, body} = Akaw.DesignDoc.Lists.call(client, db, "fns", "ids", "by_n")
      # body is plain text — one id per line
      ids = body |> String.split("\n", trim: true) |> Enum.sort()
      assert ids == ["doc_1", "doc_2"]
    end
  end

  describe "Akaw.DesignDoc.Updates.call/5" do
    test "without doc — returns 404 body from the update fn", %{client: client, db: db} do
      assert {:error, %Akaw.Error{status: 404}} =
               Akaw.DesignDoc.Updates.call(client, db, "fns", "increment_n")
    end

    test "with :doc_id — increments doc.n and persists it",
         %{client: client, db: db} do
      assert {:ok, "incremented"} =
               Akaw.DesignDoc.Updates.call(client, db, "fns", "increment_n", doc_id: "doc_1")

      assert {:ok, %{"n" => 2}} = Akaw.Document.get(client, db, "doc_1")
    end
  end

  describe "Akaw.DesignDoc.Rewrites.call/5" do
    # CouchDB 3.5 disables rewrites by default for security; integration
    # tagged tests skip on that to avoid noise. If you want to enable, set
    # `[chttpd] enable_xframe_options = true` and the per-ddoc allowlist.
    @tag :skip
    test "rewrites/echoer hits _show/echo", %{client: client, db: db} do
      assert {:ok, "no_doc"} = Akaw.DesignDoc.Rewrites.call(client, db, "fns", "echoer")
    end
  end
end
