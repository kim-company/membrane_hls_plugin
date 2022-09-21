defmodule HLS.Storage do
  alias HLS.Playlist
  alias HLS.Playlist.Master
  alias HLS.Playlist.Media

  @type config_t :: struct
  @type state_t :: any

  @type content_t :: String.t() | binary()
  @type ok_t :: {:ok, content_t}
  @type error_t :: {:error, any}
  @type callback_result_t :: ok_t | error_t

  @doc """
  Generates the loader state based on the configuration struct.
  """
  @callback init(config_t) :: state_t

  @callback get(state_t) :: callback_result_t
  @callback get(state_t, URI.t()) :: callback_result_t

  @opaque t :: %__MODULE__{adapter: module, state: any}
  defstruct [:adapter, :state]

  @spec new(config_t) :: t
  def new(%adapter{} = config) do
    %__MODULE__{
      adapter: adapter,
      state: adapter.init(config)
    }
  end

  def new(url = "http" <> _rest) do
    new(%HLS.Storage.HTTP{url: url})
  end

  def new(path) when is_binary(path) do
    new(%HLS.Storage.FS{location: path})
  end

  @spec get_master_playlist(t) :: {:ok, Master.t()} | error_t()
  def get_master_playlist(storage) do
    with {:ok, content} <- storage.adapter.get(storage.state) do
      {:ok, Playlist.unmarshal(content, Master)}
    end
  end

  @spec get_master_playlist!(t) :: Master.t()
  def get_master_playlist!(storage) do
    {:ok, playlist} = get_master_playlist(storage)
    playlist
  end

  @spec get_media_playlist(t, URI.t()) :: {:ok, Media.t()} | error_t()
  def get_media_playlist(storage, uri) do
    with {:ok, content} <- storage.adapter.get(storage.state, uri) do
      {:ok, Playlist.unmarshal(content, Media)}
    end
  end

  @spec get_media_playlist!(t, URI.t()) :: Media.t()
  def get_media_playlist!(storage, uri) do
    {:ok, playlist} = get_media_playlist(storage, uri)
    playlist
  end

  @spec get_segment(t, URI.t()) :: callback_result_t()
  def get_segment(storage, uri), do: storage.adapter.get(storage.state, uri)

  @spec get_segment!(t, URI.t()) :: content_t()
  def get_segment!(storage, uri) do
    {:ok, content} = storage.adapter.get(storage.state, uri)
    content
  end
end
