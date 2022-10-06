defmodule HLS.Storage.HTTP do
  @behaviour HLS.Storage

  @enforce_keys [:url]
  defstruct @enforce_keys ++ [:client, follow_redirects?: false]

  def init(config = %__MODULE__{url: url}) do
    uri = URI.parse(url)
    base_url = "#{uri.scheme}://#{uri.authority}#{Path.dirname(uri.path)}"

    middleware =
      [
        {Tesla.Middleware.Retry,
         delay: 100,
         max_retries: 10,
         max_delay: 1_000,
         should_retry: fn
           {:ok, %{status: status}} when status >= 400 and status <= 500 -> true
           {:error, _} -> true
           {:ok, _} -> false
         end},
        {Tesla.Middleware.BaseUrl, base_url}
      ] ++
        if config.follow_redirects? do
          [Tesla.Middleware.FollowRedirects]
        else
          []
        end

    %__MODULE__{config | client: Tesla.client(middleware)}
  end

  def get(%__MODULE__{client: client, url: url}) do
    client
    |> Tesla.get(url)
    |> handle_response()
  end

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

  defp handle_response({:ok, %Tesla.Env{body: body, status: 200}}), do: {:ok, body}
  defp handle_response({:ok, %Tesla.Env{status: status}}), do: {:error, {:status, status}}
  defp handle_response(err = {:error, _reason}), do: err
end
