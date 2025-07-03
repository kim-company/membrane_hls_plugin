defmodule Membrane.HLS.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_hls_plugin,
      version: "1.1.1",
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/kim-company/membrane_hls_plugin",
      name: "Membrane HLS Plugin",
      description: description(),
      package: package(),
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
      {:kim_hls, "~> 2.1"},
      {:membrane_core, "~> 1.0"},
      {:membrane_file_plugin, "~> 0.17"},
      {:membrane_mp4_plugin, "~> 0.35"},
      {:membrane_aac_plugin, "~> 0.18"},
      {:membrane_h26x_plugin, "~> 0.10"},
      {:membrane_text_format, "~> 1.0"},
      {:membrane_webvtt_plugin, "~> 1.0"},
      {:membrane_mpeg_ts_plugin, "~> 1.3"},
      {:membrane_flv_plugin, "~> 0.13", only: :test},
      {:membrane_nalu_plugin, "~> 0.1", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      maintainers: ["KIM Keep In Mind"],
      files: ~w(lib mix.exs README.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/kim-company/membrane_hls_plugin"}
    ]
  end

  defp description do
    """
    Adaptive live streaming (HLS) plugin for the Membrane Framework.
    """
  end
end
