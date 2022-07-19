defmodule Membrane.HLS.Source do
  use Membrane.Source

  def_output_pad(:output, [
    mode: :pull,
    caps: :any,
  ])

  def_options([
    storage: [spec: HLS.Storage.t(), description: "HLS.Storage instance pointing to the target HLS playlist"],
    target: [spec: HLS.AlternativeRendition.t() | HLS.VariantStream.t(), description: "Stream to be followed"],
  ])

  @impl true
  def handle_init(options) do
    {:ok, %{storage: options.storage, target: options.target}}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    {{:ok, [caps: {:output, :any}]}, state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, state) do
    {{:ok, [{:end_of_stream, :output}]}, state}
  end
end
