defmodule Membrane.HLS.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_hls_plugin,
      version: "0.1.0",
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
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
      {:membrane_core, "~> 1.0"},
      {:membrane_file_plugin, "~> 0.17"},
      {:membrane_mp4_plugin, "~> 0.35"},
      {:membrane_aac_plugin, "~> 0.18"},
      {:membrane_h26x_plugin, "~> 0.10"},
      {:kim_q, "~> 1.0"},
      {:kim_hls, github: "kim-company/kim_hls"},
      {:membrane_text_format, github: "kim-company/membrane_text_format"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
