defprotocol Membrane.HLS.Storage do
  @spec get(Membrane.HLS.Storage.t(), URI.t()) :: {:ok, binary()} | {:error, any()}
  def get(storage, uri)

  @spec list(Membrane.HLS.Storage.t(), URI.t()) :: {:ok, [URI.t()]} | {:error, any()}
  def list(storage, uri)

  @spec store(Membrane.HLS.Storage.t(), URI.t(), binary()) :: :ok | {:error, any()}
  def store(storage, uri, binary)
end

defmodule Membrane.HLS.Storage.S3 do
  defstruct [:req]

  def new(opts) do
    opts =
      Keyword.validate!(opts, [
        :access_key_id,
        :secret_access_key,
        :region,
        endpoint_url: nil
      ])

    %__MODULE__{req: ReqS3.attach(Req.new(), aws_sigv4: opts)}
  end

  defimpl Membrane.HLS.Storage do
    def get(storage, uri) do
      Req.get(storage.req, uri)
    end

    def list(storage, uri) do
      # TODO: Pagination
      Req.get(storage.req, uri)
    end

    def store(storage, uri, binary) do
      Req.put(storage.req, url: uri, body: binary)
    end
  end
end
