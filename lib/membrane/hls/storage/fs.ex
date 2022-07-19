defmodule Membrane.HLS.Storage.FS do
  @behaviour Membrane.HLS.Storage

  @enforce_keys [:location]
  defstruct @enforce_keys ++ [:dirname, :basename, :manifest_ext]

  @impl true
  def init(config = %__MODULE__{location: location}) do
    basename = Path.basename(location)
    dirname = Path.dirname(location)
    ext = Path.extname(basename)
    %__MODULE__{config | basename: basename, dirname: dirname, manifest_ext: ext}
  end

  @impl true
  def get(%__MODULE__{dirname: dir, basename: manifest}), do: load([dir, manifest])

  @impl true
  def get(%__MODULE__{dirname: dir}, %URI{path: rel}), do: load([dir, rel])

  defp load(path) when is_list(path) do
    path
    |> Path.join()
    |> load()
  end

  defp load(path) when is_binary(path) do
    File.read(path)
  end
end
