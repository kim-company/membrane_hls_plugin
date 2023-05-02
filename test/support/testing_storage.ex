defmodule Support.TestingStorage do
  defstruct [:owner]
end

defimpl HLS.Storage, for: Support.TestingStorage do
  @impl true
  def exists?(_, _), do: true

  @impl true
  def read(_, _, _), do: raise("Not implemented")

  @impl true
  def write(%Support.TestingStorage{owner: pid}, uri, data, _opts) do
    send(pid, {:write, uri, data})
  end
end
