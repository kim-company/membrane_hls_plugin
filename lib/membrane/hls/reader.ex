defprotocol Membrane.HLS.Reader do
  @spec read(t(), URI.t(), Keyword.t()) :: {:ok, binary()} | {:error, any}
  def read(driver, uri, opts \\ [])

  @spec exists?(t(), URI.t()) :: boolean()
  def exists?(driver, uri)
end
