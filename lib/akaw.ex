defmodule Akaw do

  @moduledoc """
  Wrapper around the [couchbeam](https://github.com/benoitc/couchbeam/) erlang couchdb client
  """

  alias Akaw.Mapper

  @doc """
  Returns a server connection

  ## Examples

      Akaw.server_connection("url")
      #=> {:server, "url", []}

      Akaw.server_connection(@couchdb_url, [{:basic_auth, {"username", "password"}}])
      #=> {:server, "url", [{:basic_auth, {"username", "password"}}]}
  """
  def server_connection, do: server_connection("http://localhost:5984")
  def server_connection(url, options \\ []) do
    :couchbeam.server_connection(url, options)
  end

  @doc """
  Returns basic info about server

  ## Examples
      Akaw.server_info(server)
      #=> %{"couchdb" => "Welcome", "uuid" => "c1cdba4b7d7a963b9ca7c5445684679f", "vendor" => {[{"version", "1.5.0-1"}, {"name", "Homebrew"}]}, "version" => "1.5.0"}
  """
  def server_info(server) do
    :couchbeam.server_info(server)
    |> map_response
  end

  @doc """
  Replicates a database from source to target

  ## Examples

  `create_target` param, target db is created if not already present

  `continuous` param, replication runs continuously until server restart

      Akaw.replicate(server, %{source: "sourcedb", target: "targetdb", create_target: true})
      #=> {:ok, %{"history" => [...], "ok" => true, "replication_id_version" => 3, "session_id" => "b3457b342b2eb31ea0f85e77bac03a66", "source_last_seq" => 16}}

      Akaw.replicate(server, %{source: "https://user:pass@sourcedb", target: "targetdb", create_target: true})
      #=> {:ok, resp}

      Akaw.replicate(server, %{source: "https://user:pass@sourcedb", target: "http://user:pass@targetdb", create_target: true})
      #=> {:ok, resp}

      Akaw.replicate(server, %{source: "https://user:pass@sourcedb", target: "http://user:pass@targetdb", create_target: true, continuous: true})
      #=> #=> {:ok, %{"Cache-Control" => "must-revalidate", "Content-Length" => "84", "Content-Type" => "application/json", "Date" => "Mon, 09 Feb 2015 16:24:19 GMT", "Server" => "CouchDB/1.5.0 (Erlang OTP/R16B03)"}}

  """
  def replicate(server, rep_obj) do
    :couchbeam.replicate(server, {rep_obj |> Map.to_list})
    |> map_response
  end

  @doc """
  Returns a list of all databases

  ## Examples

      Akaw.all_dbs(server)
      #=> {:ok, ["_replicator", "_users", "some_db", ...]}
  """
  def all_dbs(server) do
    :couchbeam.all_dbs(server)
  end

  @doc """
  Returns a single server generated uuid

  ## Examples
      Akaw.uuid(server)
      #=> "267732468d85b6fd22504aeaa4dc68e3"
  """
  def uuid(server) do
    [uuid] = :couchbeam.get_uuid(server)
    uuid
  end

  @doc """
  Returns a total of `number` server generated uuids

  ## Examples
      Akaw.uuids(server, 3)
      #=> ["267732468d85b6fd22504aeaa4fb8ac9", "267732468d85b6fd22504aeaa4fb8065", "267732468d85b6fd22504aeaa4fb7ca7"]
  """
  def uuids(server, number) do
    :couchbeam.get_uuids(server, number)
  end

  @doc """
  Opens a database

  If credentials were passed during server_connection, they will be passed on to open_db.
  They will however be overwritten by the credentials applied to open_db

  ## Examples
      Akaw.open_db(server, "akaw")
      #=> {:ok, {:db, server, "akaw", []}}

      Akaw.open_db(server, "akaw", [{:basic_auth, {"username", "password"}}])
      #=> {:ok, {:db, server, "akaw", [{:basic_auth, {"username", "password"}}]}}
  """
  def open_db(server, db_name, options \\ []) do
    :couchbeam.open_db(server, db_name, options)
  end

  @doc """
  Creates a database. The database must NOT exist

  ## Examples
      Akaw.create_db(server, "akaw")
      #=> {:db, server, "akaw", [basic_auth: {"username", "password"}]}}
      Akaw.create_db(server, "akaw")
      #=> {:error, :db_exists}
  """
  def create_db(server, db_name, options \\ []) do
    :couchbeam.create_db(server, db_name, options)
  end

  @doc """
  Deletes a database. The database must exist

  ## Examples
      {:ok, db} = Akaw.open_db(server, "akaw")
      #=> {:ok, {:db, server, "akaw", []}}
      Akaw.delete_db(db)
      #=> {:ok, :db_deleted}
      Akaw.delete_db(db)
      #=> {:error, :not_found}
  """
  def delete_db(db) do
    case :couchbeam.delete_db(db) |> map_response do
      {:ok, %{"ok" => true}} -> {:ok, :db_deleted}
      response -> response
    end
  end

  @doc """
  Deletes a database. The database must exist

  ## Examples
      Akaw.delete_db(server, "akaw")
      #=> {:ok, :db_deleted}
      Akaw.delete_db(server, "akaw")
      #=> {:error, :not_found}
  """
  def delete_db(server, db_name) do
    case :couchbeam.delete_db(server, db_name) |> map_response do
      {:ok, %{"ok" => true}} -> {:ok, :db_deleted}
      response -> response
    end
  end

  @doc """
  Returns database info.

  ## Examples
      {:ok, db} = Akaw.open_db(server, "akaw")
      Akaw.db_info(db)
      #=> %{"committed_update_seq" => 0, "compact_running" => false, "data_size" => 227,
          "db_name" => "akaw", "disk_format_version" => 6, "disk_size" => 306,
          "doc_count" => 1, "doc_del_count" => 0,
          "instance_start_time" => "1423503379138489", "purge_seq" => 0,
          "update_seq" => 1}
  """
  def db_info(db) do
    :couchbeam.db_info(db) |> map_response
  end

  @doc """
  Compacts a database.

  ## Examples
      {:ok, db} = Akaw.open_db(server, "akaw")
      Akaw.compact(db)
      #=> :ok
  """
  def compact(db) do
    :couchbeam.compact(db)
  end

  @doc """
  Checks if database exist.

  ## Examples
      Akaw.db_exists?(server, "akaw")
      #=> true
  """
  def db_exists?(server, db_name) do
    :couchbeam.db_exists(server, db_name)
  end

  @doc """
  Save and update a document

  Update a document, by using an existing document id

  ## Examples
      Akaw.save_doc(db, %{"key" => "value"}) # Couch auto creates id
      #=> %{"_id" => "c1cdba4b7d7a963b9ca7c5445684679f", "_rev" => "1-59414e77c768bc202142ac82c2f129de", "key" => "value"}

      Akaw.save_doc(db, %{"_id" => "FIRST_ID", "key" => "value"}) # User defined id
      #=> %{"_id" => "FIRST_ID", "_rev" => "1-59414e77c768bc202142ac82c2f129de", "key" => "value"}
  """
  def save_doc(db, doc) do
    :couchbeam.save_doc(db, {Mapper.map_to_list(doc)})
    |> map_response
  end

  @doc """
  Returns true if document exists

  ## Examples

      Akaw.doc_exists?(db, "EXISTING_DOC_ID")
      #=> true

      Akaw.doc_exists?(db, "NONE_EXISTING_DOC_ID")
      #=> false

  """
  def doc_exists?(db, doc_id) do
    :couchbeam.doc_exists(db, doc_id)
  end

  @doc """
  Put an attachment to document

  ## Examples
      attachment = %{ name: "image.png", data: "....", content_type: "image/png" }
      Akaw.put_attachment(db, %{id: id}, attachment) # latest revision
      #=> {:ok, %{"id" => "18c359e463c37525e0ff484dcc0003b7", "rev" => "3-ebe18f0e4f4c3c717a9e9291bc2465b3"}}

      doc_id = "18c359e463c37525e0ff484dcc0003b7"
      revision = "1-59414e77c768bc202142ac82c2f129de"
      content_type = Akaw.MIME.type("txt") # => "text/plain"
      attachment = %{ name: "file.txt", data: "SOME DATA - HERE IT'S TEXT", content_type: content_type }
      Akaw.put_attachment(db, %{id: doc_id, rev: revision}, attachment)
      #=> {:ok, %{"id" => "18c359e463c37525e0ff484dcc0003b7", "rev" => "3-ebe18f0e4f4c3c717a9e9291bc2465b3"}}
  """
  def put_attachment(db, %{id: id, rev: rev}, attachment) do
    _put_attachment(db, id, attachment, [{:rev, rev}, {:content_type, attachment.content_type}])
  end
  def put_attachment(db, %{id: id}, attachment) do
    {:ok, rev} = lookup_doc_rev(db, id)
    _put_attachment(db, id, attachment, [{:rev, rev}, {:content_type, attachment.content_type}])
  end
  defp _put_attachment(db, doc_id, attachment, options) do
    :couchbeam.put_attachment(db, doc_id, attachment.name, attachment.data, options)
    |> map_response
  end

  @doc """
  Fetch attachment from document

  ## Examples
      doc_id = "18c359e463c37525e0ff484dcc0003b7"
      attachment_name = "file.txt"
      Akaw.fetch_attachment(db, doc_id, attachment_name)
      #=> {:ok, "SOME DATA - HERE IT'S TEXT"}

  """
  def fetch_attachment(db, doc_id, attachment_name) do
    :couchbeam.fetch_attachment(db, doc_id, attachment_name)
  end

  @doc """
  Delete attachment from document

  This method is idempotent, and will increment the document revision, even though the attachment isn't present(e.g. already deleted)

  ## Examples
      attachment_name = "file.txt"

      Akaw.delete_attachment(db, %{id: "18c359e463c37525e0ff484dcc0003b7"}, attachment_name)
      #=> {:ok, %{"id" => "18c359e463c37525e0ff484dcc0003b7", "rev" => "4-ebe18f0e4f4c3c717a9e9291bc2465b3"}}

      Akaw.delete_attachment(db, %{id: "18c359e463c37525e0ff484dcc0003b7", rev: "3-ebe18f0e4f4c3c717a9e9291bc2465b3"}, attachment_name)
      #=> {:ok, %{"id" => "18c359e463c37525e0ff484dcc0003b7", "rev" => "4-ebe18f0e4f4c3c717a9e9291bc2465b3"}}
  """
  def delete_attachment(db, %{id: id, rev: rev}, attachment_name) do
    :couchbeam.delete_attachment(db, id, attachment_name, [{:rev, rev}])
    |> map_response
  end
  def delete_attachment(db, %{id: id}, attachment_name) do
    {:ok, rev} = lookup_doc_rev(db, id)
    delete_attachment(db, %{id: id, rev: rev}, attachment_name)
  end

  @doc """
  Retreives document as map, by id with or without revision

  ## Examples
      Akaw.open_doc(db, %{id: id})
      #=> {:ok, %{"_id" => id, "_rev" => rev, ...}}

      Akaw.open_doc(db, %{id: id, rev: revision})
      #=> {:ok, %{"_id" => id, "_rev" => rev, ...}}
  """
  def open_doc(db, %{_id: id}) do
    :couchbeam.open_doc(db, id) |> map_open_resp
  end
  def open_doc(db, %{_id: id, _rev: rev}) do
    :couchbeam.open_doc(db, id, [{:rev, rev}]) |> map_open_resp
  end

  defp map_open_resp({:error, err}), do: {:error, err}
  defp map_open_resp({:ok, resp}),   do: resp |> Mapper.list_to_map

  @doc """
  Returns current document revision

  ## Examples
      Akaw.lookup_doc_rev(db, "18c359e463c37525e0ff484dcc0003b7")
      #=> {:ok, "1-59414e77c768bc202142ac82c2f129de"}
  """
  def lookup_doc_rev(db, id) do
    :couchbeam.lookup_doc_rev(db, id) |> map_response
  end

  @doc """
  Delete a document

  ## Examples
      Akaw.delete_doc(db, %{id: "18c359e463c37525e0ff484dcc0003b7", rev: "1-59414e77c768bc202142ac82c2f129de"})
      #=> %{"id" => "18c359e463c37525e0ff484dcc0003b7", "ok" => true, "rev" => "2-9b2e3bcc3752a3a952a3570b2ed4d27e"}
  """
  def delete_doc(db, %{_id: id, _rev: rev}) do
    doc = {[{"_id", id}, {"_rev", rev}]}
    :couchbeam.delete_doc(db, doc, [])
    |> map_response
  end

  @doc """
  Returns all documents in a database

  ## Examples

      Akaw.all(db)
      #=> [
            %{
              "doc" => %{"_id" => "doc_id_1", "_rev" => "...", "foo" => "bar"},
              "id" => "doc_id_1",
              "key" => "doc_id_1",
              "value" => %{"rev" => "..."}
            },
            %{"doc" => %{"_id" => "doc_id_2", ...
          ]

  """
  def all(db, options \\ [:include_docs]) do
    {:ok, resp } = :couchbeam_view.all(db, options)
    resp |> Mapper.list_to_map
  end

  @doc """
  Follow database changes

  ## Examples

      def changes_fun(stream_ref) do
        receive do
          {stream_ref, {:done, last_seq}} ->
            Logger.info "Stopped at seq: \#{inspect last_seq}"
            :ok
          {stream_ref, {:change, change}} ->
            Logger.info "Change: \#{inspect change}"
            changes_fun(stream_ref)
          {stream_ref, error}->
            Log.error "\#{inspect error}"
          msg ->
            Logger.warn "\#{inspect msg}"
        end
      end

      Akaw.follow(db, [:continuous, :heartbeat])
      #=> {:ok, <stream_ref>}
      changes_fun(<stream_ref>)

  """
  def follow(db, options \\ []) do
    :couchbeam_changes.follow(db, options)
  end

  def follow_once(db, options \\ []) do
    :couchbeam_changes.follow_once(db, options)
  end

  @doc """
  Fetch view

  options group

  ## Examples
  {:ok, res} = Akaw.fetch_view(db, {"lists","company_users_by_income"},[:group])
  """
  def fetch_view(db, {design_name, view_name}, options \\ []) do
    :couchbeam_view.fetch(db, {design_name, view_name}, options)
  end

  def fetch_view_values(db, {design_name, view_name}, options \\ []) do
    {:ok, result } = :couchbeam_view.fetch(db, {design_name, view_name}, options)
    result |> Enum.map(&Akaw.map_response(&1))
  end

  def fetch_view_docs(db, {design_name, view_name}, options \\ []) do
    {:ok, result } = :couchbeam_view.fetch(db, {design_name, view_name}, [:include_docs | options])
    result |> Enum.map(&Akaw.map_response(&1))
  end

  def map_response({[{"id", id}, {"key", key}, {"value", {json}}]}), do: {[{"id", id}, {"key", key}, {"value", Akaw.Mapper.list_to_map(json)}]}
  def map_response({[{"id", id}, {"key", key}, {"value", {json}}, {"doc", {document}}]}), do: {[{"id", id}, {"key", key}, {"value", Akaw.Mapper.list_to_map(json)}, {"doc", Akaw.Mapper.list_to_map(document)}]}
  def map_response({[{"id", id}, {"key", key}, {"value", :null}]}), do: {[{"id", id}, {"key", key}, {"value", :null}]}
  def map_response({[{"id", id}, {"key", key}, {"value", :null}, {"doc", {document}}]}), do: {[{"id", id}, {"key", key}, {"value", :null}, {"doc", Akaw.Mapper.list_to_map(document)}]}

  def map_response({:ok, [{list}]}) when is_list(list), do: {:ok, Enum.into(list, %{})}
  def map_response({:ok, _status_code, resp, _ref}), do: {:ok, Enum.into(resp, %{})}
  def map_response({:ok, {response}}), do: {:ok, response |> Akaw.Mapper.list_to_map()}
  def map_response({:error, response}), do: {:error, response}
  def map_response(response), do: {:ok, response}

end
