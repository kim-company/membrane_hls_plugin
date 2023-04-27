defmodule Membrane.HLS.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_hls_plugin,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Membrane.HLS.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:membrane_core, "~> 0.11.0"},
      {:membrane_file_plugin, "~> 0.13.2", only: :test},
      {:kim_hls, github: "kim-company/kim_hls"},
      {:kim_q, github: "kim-company/kim_q"}
    ]
  end
end
