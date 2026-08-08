defmodule Akaw.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/polymetis/akaw"

  def project do
    [
      app: :akaw,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "Akaw",
      description: "An Elixir client for the CouchDB HTTP API.",
      source_url: @source_url,
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # 0.7 is a hard floor, not a preference: Akaw.Request translates
      # `:finch` / `:pool_timeout` into Req 0.7's `finch: [name: …]`
      # spelling, which raises on 0.5.
      {:req, "~> 0.7"},
      {:plug, "~> 1.0", only: :test},
      {:stream_data, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      # Mirrors the module map in Akaw's @moduledoc: the CouchDB API is big
      # and flat, so grouping by API section is the only way the sidebar
      # stays navigable.
      groups_for_modules: [
        Core: [Akaw, Akaw.Client, Akaw.Error],
        "Databases & documents": [
          Akaw.Database,
          Akaw.Document,
          Akaw.Documents,
          Akaw.Attachment,
          Akaw.LocalDoc
        ],
        Querying: [Akaw.View, Akaw.Find, Akaw.Changes, Akaw.Search, Akaw.Nouveau],
        "Design documents": [
          Akaw.DesignDoc,
          Akaw.DesignDoc.Shows,
          Akaw.DesignDoc.Lists,
          Akaw.DesignDoc.Updates,
          Akaw.DesignDoc.Rewrites
        ],
        "Partitioned databases": [Akaw.Partition],
        Authentication: [Akaw.Session, Akaw.SessionServer, Akaw.Security],
        "Server & cluster administration": [
          Akaw.Server,
          Akaw.Node,
          Akaw.Config,
          Akaw.Cluster,
          Akaw.Reshard,
          Akaw.Replication,
          Akaw.Purge
        ]
      ]
    ]
  end
end
