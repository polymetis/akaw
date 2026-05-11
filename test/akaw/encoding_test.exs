defmodule Akaw.EncodingTest do
  use ExUnit.Case, async: true

  # Verifies how Akaw composes URL paths from db / doc id / attachment /
  # design-doc segments. Most modules share the same private encoder
  # (`URI.encode(s, &URI.char_unreserved?/1)`) plus special-cased prefix
  # handling for `_design/` and `_local/`.

  defp recording_client do
    test = self()

    plug = fn conn ->
      send(test, conn.request_path)
      Req.Test.json(conn, %{})
    end

    Akaw.new(base_url: "http://x", req_options: [plug: plug, retry: false])
  end

  describe "doc id encoding" do
    test "alphanumerics and unreserved chars pass through" do
      Akaw.Document.get(recording_client(), "db", "user_42-v1.0~final")
      assert_receive "/db/user_42-v1.0~final"
    end

    test "/ is percent-encoded to %2F" do
      Akaw.Document.get(recording_client(), "db", "weird/path")
      assert_receive "/db/weird%2Fpath"
    end

    test "Unicode (Japanese) is UTF-8 percent-encoded" do
      Akaw.Document.get(recording_client(), "db", "日本語")
      assert_receive "/db/%E6%97%A5%E6%9C%AC%E8%AA%9E"
    end

    test "emoji is percent-encoded" do
      Akaw.Document.get(recording_client(), "db", "🎉")
      assert_receive "/db/%F0%9F%8E%89"
    end

    test "spaces become %20 (not +)" do
      Akaw.Document.get(recording_client(), "db", "doc with spaces")
      assert_receive "/db/doc%20with%20spaces"
    end

    test ":, %, &, =, ?, # are encoded" do
      Akaw.Document.get(recording_client(), "db", "k=v&q?x#y%z:p")
      assert_receive "/db/k%3Dv%26q%3Fx%23y%25z%3Ap"
    end

    test "_design/ prefix is preserved verbatim" do
      Akaw.Document.get(recording_client(), "db", "_design/myddoc")
      assert_receive "/db/_design/myddoc"
    end

    test "suffix after _design/ is encoded" do
      Akaw.Document.get(recording_client(), "db", "_design/with/slash")
      assert_receive "/db/_design/with%2Fslash"
    end

    test "_local/ prefix is preserved verbatim" do
      Akaw.Document.get(recording_client(), "db", "_local/checkpoint")
      assert_receive "/db/_local/checkpoint"
    end

    test "suffix after _local/ is encoded" do
      Akaw.Document.get(recording_client(), "db", "_local/x with space")
      assert_receive "/db/_local/x%20with%20space"
    end
  end

  describe "db name encoding" do
    test "lowercase + digits + - _ pass through" do
      Akaw.Database.info(recording_client(), "users-db_v2")
      assert_receive "/users-db_v2"
    end

    test "$, (, ), + are encoded (RFC 3986 strict — stricter than CouchDB allows)" do
      # CouchDB itself accepts $()+/-_ etc. unencoded in db names, but
      # Akaw uses URI.char_unreserved? for safety. The encoded form
      # roundtrips through CouchDB's URL decoder; document the behavior.
      Akaw.Database.info(recording_client(), "weird$db(name)+v2")
      assert_receive "/weird%24db%28name%29%2Bv2"
    end
  end

  describe "attachment name encoding" do
    test "filename with dots is preserved" do
      Akaw.Attachment.head(recording_client(), "db", "doc", "report.v2.final.pdf")
      assert_receive "/db/doc/report.v2.final.pdf"
    end

    test "filename with spaces is encoded" do
      Akaw.Attachment.head(recording_client(), "db", "doc", "my photo.jpg")
      assert_receive "/db/doc/my%20photo.jpg"
    end

    test "filename with slashes is encoded" do
      Akaw.Attachment.head(recording_client(), "db", "doc", "subdir/file.txt")
      assert_receive "/db/doc/subdir%2Ffile.txt"
    end

    test "Unicode in filename" do
      Akaw.Attachment.head(recording_client(), "db", "doc", "写真.png")
      assert_receive "/db/doc/%E5%86%99%E7%9C%9F.png"
    end

    test "preserves _design/ in the doc id" do
      Akaw.Attachment.head(recording_client(), "db", "_design/myddoc", "logo.png")
      assert_receive "/db/_design/myddoc/logo.png"
    end
  end

  describe "view path encoding" do
    test "ddoc and view names are encoded" do
      client = recording_client()
      Akaw.View.get(client, "db", "my ddoc", "by/name")
      assert_receive "/db/_design/my%20ddoc/_view/by%2Fname"
    end
  end

  describe "design doc path encoding" do
    test "ddoc name with special chars" do
      Akaw.DesignDoc.info(recording_client(), "db", "my ddoc")
      assert_receive "/db/_design/my%20ddoc/_info"
    end
  end

  describe "partition path encoding" do
    test "partition id with special chars" do
      Akaw.Partition.info(recording_client(), "db", "tenant 1")
      assert_receive "/db/_partition/tenant%201"
    end
  end

  describe "scheduler path encoding" do
    test "replication id with special chars" do
      Akaw.Replication.status(recording_client(), "my repl_1")
      assert_receive "/_scheduler/docs/_replicator/my%20repl_1"
    end
  end
end
