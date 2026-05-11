defmodule Akaw.Reshard do
  @moduledoc """
  Shard-rebalancing endpoints (`/_reshard/...`).

  Reshard jobs split shards as cluster topology changes. The endpoints are
  cluster-level (no `{db}` path) and require admin auth.

  See <https://docs.couchdb.org/en/latest/api/server/common.html#reshard>.
  """

  alias Akaw.{Client, Request}

  @doc "`GET /_reshard` — overall reshard state and counts."
  @spec summary(Client.t()) :: {:ok, map()} | {:error, term()}
  def summary(%Client{} = client) do
    Request.request(client, :get, "/_reshard")
  end

  @doc "`GET /_reshard/state` — global reshard state (`running` or `stopped`)."
  @spec state(Client.t()) :: {:ok, map()} | {:error, term()}
  def state(%Client{} = client) do
    Request.request(client, :get, "/_reshard/state")
  end

  @doc """
  `PUT /_reshard/state` — globally start or stop reshard jobs.

  `new_state` is `"running"` or `"stopped"`. Pass `reason: "..."` in opts
  to record why.
  """
  @spec put_state(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def put_state(%Client{} = client, new_state, opts \\ [])
      when new_state in ["running", "stopped"] do
    body = opts |> Map.new() |> Map.put(:state, new_state)
    Request.request(client, :put, "/_reshard/state", json: body)
  end

  @doc "`GET /_reshard/jobs` — list all reshard jobs."
  @spec jobs(Client.t()) :: {:ok, map()} | {:error, term()}
  def jobs(%Client{} = client) do
    Request.request(client, :get, "/_reshard/jobs")
  end

  @doc """
  `POST /_reshard/jobs` — create a reshard job.

  Body is the job spec (see CouchDB docs for shape — typically `:type`,
  `:db`, optional `:shard`, `:node`, `:range`).
  """
  @spec create_job(Client.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def create_job(%Client{} = client, body) when is_map(body) do
    Request.request(client, :post, "/_reshard/jobs", json: body)
  end

  @doc "`GET /_reshard/jobs/{jobid}` — info on one job."
  @spec job(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def job(%Client{} = client, job_id) when is_binary(job_id) do
    Request.request(client, :get, "/_reshard/jobs/#{encode(job_id)}")
  end

  @doc "`DELETE /_reshard/jobs/{jobid}` — stop and remove a job."
  @spec delete_job(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_job(%Client{} = client, job_id) when is_binary(job_id) do
    Request.request(client, :delete, "/_reshard/jobs/#{encode(job_id)}")
  end

  @doc "`GET /_reshard/jobs/{jobid}/state` — current state of one job."
  @spec job_state(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def job_state(%Client{} = client, job_id) when is_binary(job_id) do
    Request.request(client, :get, "/_reshard/jobs/#{encode(job_id)}/state")
  end

  @doc """
  `PUT /_reshard/jobs/{jobid}/state` — change one job's state.

  `new_state` is `"running"` or `"stopped"`. Pass `reason: "..."` to record
  why.
  """
  @spec put_job_state(Client.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def put_job_state(%Client{} = client, job_id, new_state, opts \\ [])
      when is_binary(job_id) and new_state in ["running", "stopped"] do
    body = opts |> Map.new() |> Map.put(:state, new_state)
    Request.request(client, :put, "/_reshard/jobs/#{encode(job_id)}/state", json: body)
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
