defmodule HLS.Storage.HTTP do
  @behaviour HLS.Storage

  @enforce_keys [:url]
  defstruct @enforce_keys ++ [:client]

  @impl true
  def init(config = %__MODULE__{url: url}) do
    uri = URI.parse(url)
    base_url = "#{uri.scheme}://#{uri.host}#{Path.dirname(uri.path)}"
    middleware = [
      {Tesla.Middleware.BaseUrl, base_url}
    ]

    %__MODULE__{config | client: Tesla.client(middleware)}
  end

  @impl true
  def get(%__MODULE__{url: url}) do
    url
    |> Tesla.get()
    |> handle_response()
  end

  @impl true
  def get(%__MODULE__{client: client}, uri) do
    client
    |> Tesla.get(uri.path, query: decode_query(uri.query))
    |> handle_response()
  end

  defp decode_query(nil), do: []
  defp decode_query(raw) when is_binary(raw) do
    raw
    |> URI.decode_query()
    |> Enum.into([])
  end

  defp handle_response({:ok, %Tesla.Env{body: body}}), do: {:ok, body}
  defp handle_response(err = {:error, _reason}), do: err
end
