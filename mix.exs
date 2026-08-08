defmodule Akaw.MixProject do
  use Mix.Project

  def project do
    [
      app: :akaw,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
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
      {:stream_data, "~> 1.0", only: :test}
    ]
  end
end
