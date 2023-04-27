defmodule Support.TestingStorage do
  defstruct [:owner]
end

defimpl HLS.Storage.Driver, for: Support.TestingStorage do
  @impl true
  def ready?(_), do: true

  @impl true
  def get(_), do: raise("Not implemented")

  @impl true
  def get(_, _), do: raise("Not implemented")

  @impl true
  def put(%Support.TestingStorage{owner: pid}, uri, data, _opts) do
    send(pid, {:put, uri, data})
  end
end
