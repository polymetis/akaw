defmodule Akaw.ReshardTest do
  use ExUnit.Case, async: true

  setup do
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(test, %{
        method: conn.method,
        path: conn.request_path,
        body: body
      })

      Req.Test.json(conn, %{"ok" => true})
    end

    {:ok, client: Akaw.new(base_url: "http://x", req_options: [plug: plug])}
  end

  test "summary/1 → GET /_reshard", %{client: client} do
    assert {:ok, _} = Akaw.Reshard.summary(client)
    assert_receive %{method: "GET", path: "/_reshard"}
  end

  test "state/1 → GET /_reshard/state", %{client: client} do
    assert {:ok, _} = Akaw.Reshard.state(client)
    assert_receive %{method: "GET", path: "/_reshard/state"}
  end

  test "put_state/3 → PUT /_reshard/state with state body", %{client: client} do
    assert {:ok, _} = Akaw.Reshard.put_state(client, "stopped", reason: "maintenance")
    assert_receive %{method: "PUT", path: "/_reshard/state", body: body}
    decoded = Jason.decode!(body)
    assert decoded["state"] == "stopped"
    assert decoded["reason"] == "maintenance"
  end

  test "jobs/1 → GET /_reshard/jobs", %{client: client} do
    assert {:ok, _} = Akaw.Reshard.jobs(client)
    assert_receive %{method: "GET", path: "/_reshard/jobs"}
  end

  test "create_job/2 → POST /_reshard/jobs with body", %{client: client} do
    job = %{type: "split", db: "users"}
    assert {:ok, _} = Akaw.Reshard.create_job(client, job)
    assert_receive %{method: "POST", path: "/_reshard/jobs", body: body}
    assert Jason.decode!(body) == %{"type" => "split", "db" => "users"}
  end

  test "job/2 → GET /_reshard/jobs/{id}", %{client: client} do
    assert {:ok, _} = Akaw.Reshard.job(client, "abc-123")
    assert_receive %{method: "GET", path: "/_reshard/jobs/abc-123"}
  end

  test "delete_job/2 → DELETE /_reshard/jobs/{id}", %{client: client} do
    assert {:ok, _} = Akaw.Reshard.delete_job(client, "abc-123")
    assert_receive %{method: "DELETE", path: "/_reshard/jobs/abc-123"}
  end

  test "job_state/2 → GET /_reshard/jobs/{id}/state", %{client: client} do
    assert {:ok, _} = Akaw.Reshard.job_state(client, "abc-123")
    assert_receive %{method: "GET", path: "/_reshard/jobs/abc-123/state"}
  end

  test "put_job_state/4 → PUT /_reshard/jobs/{id}/state", %{client: client} do
    assert {:ok, _} =
             Akaw.Reshard.put_job_state(client, "abc-123", "stopped", reason: "user-requested")

    assert_receive %{method: "PUT", path: "/_reshard/jobs/abc-123/state", body: body}
    decoded = Jason.decode!(body)
    assert decoded["state"] == "stopped"
    assert decoded["reason"] == "user-requested"
  end
end
