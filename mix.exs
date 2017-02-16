defmodule Akaw.Mixfile do
  use Mix.Project

  def project() do
    [app: :akaw,
     version: "0.7.0",
     elixir: "~> 1.3",
     package: package,
     description: description,
     deps: deps]
  end

  def application() do
    [applications: [:logger, :couchbeam]]
  end

  defp deps() do
    [
      {:couchbeam, "~> 1.4"},
      {:ex_doc, "~> 0.11", only: :dev},
      {:earmark, ">= 0.0.0"},
      {:hackney, "~> 1.6.3"}, 
      {:jsx, "~> 2.8.1"}
    ]
  end

  defp description() do
    """
    CouchDB client, wrapping couchbeam erlang client.
    """
  end

  defp package() do
    [
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md),
      maintainers: ["Thomas Ringling"],
      licenses: ["Unlicense"],
      links: %{"GitHub" => "https://github.com/ringling/akaw"}
   ]
  end
end
