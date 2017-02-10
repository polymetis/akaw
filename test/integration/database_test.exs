defmodule Integration.DatabaseTest do
  use ExUnit.Case, async: false

  @create_db_name "created_db"
  @existing_db_name "existing_db"
  @integration_test_db "akaw"
  @integration_test_rep_db "akaw_rep"
  @existing_doc_id "akaw"
  @existing_doc %{"key" => "value", "_id" => @existing_doc_id}

  setup_all do
    # Delete old integration test db
    Akaw.delete_db(TestHelper.server, @create_db_name)
    Akaw.delete_db(TestHelper.server, @integration_test_db)
    Akaw.delete_db(TestHelper.server, @integration_test_rep_db)
    # Create integration test db
    Akaw.create_db(TestHelper.server, @existing_db_name)
    Akaw.create_db(TestHelper.server, @integration_test_db)
    {:ok, db} = Akaw.open_db(TestHelper.server, @integration_test_db)
    Akaw.save_doc(db, @existing_doc)
    :ok
  end

  setup do
    {:ok, db} = Akaw.open_db(TestHelper.server, @integration_test_db)
    {:ok, db: db, server: TestHelper.server}
  end

  test "db info has couchdb key", %{db: db} do
    {:ok, info} = Akaw.db_info(db)
    assert info["db_name"] == @integration_test_db
  end

  test "delete not existing database", %{server: server} do
    assert {:error, :not_found} == Akaw.delete_db(server, "not_existing")
  end

  test "delete existing database by name", %{server: server} do
    db_name = "some_db"
    Akaw.create_db(server, db_name)
    assert {:ok, :db_deleted} == Akaw.delete_db(server, db_name)
  end

  test "delete existing databasee", %{server: server} do
    db_name = "some_db_1"
    {:ok, db} = Akaw.create_db(server, db_name)
    assert {:ok, :db_deleted} == Akaw.delete_db(db)
  end

  test "create database", %{server: server} do
    assert {:ok, {:db, _, @create_db_name, _ }} = Akaw.create_db(server, @create_db_name)
  end

  test "database exists? true", %{server: server} do
    assert Akaw.db_exists?(server, @existing_db_name)
  end

  test "database exists? false", %{server: server} do
    refute Akaw.db_exists?(server, "not_existing")
  end

  # test "compact database", %{db: db} do
  #   {:db, server, db_name, _opts} = db
  #   assert Akaw.db_exists?(server, db_name)
  #   assert :ok == Akaw.compact(db)
  # end

  test "replicate database", %{server: server} do
    rep_obj = %{source: @integration_test_db, target: @integration_test_rep_db, create_target: true}
    {:ok, resp} = Akaw.replicate(server, rep_obj)
    assert Map.has_key?(resp, "history")
    assert Akaw.db_exists?(server, @integration_test_rep_db)
  end

  # test "replicate database continuous", %{server: server} do
  #   rep_obj = %{source: @integration_test_db, target: @integration_test_rep_db, create_target: true , continuous: true}
  #   {:ok, resp} = Akaw.replicate(server, rep_obj)
  #   assert Map.has_key?(resp, "Date")
  #   assert Akaw.db_exists?(server, @integration_test_rep_db)
  # end

end
