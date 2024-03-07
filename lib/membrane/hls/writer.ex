defprotocol Membrane.HLS.Writer do
  @spec write(t(), URI.t(), binary(), Keyword.t()) :: :ok | {:error, any}
  def write(driver, uri, payload, opts \\ [])
end
