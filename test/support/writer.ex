defmodule Support.Writer do
  defstruct [:agent]

  def new(opts \\ []) do
    fail = Keyword.get(opts, :fail, false)
    {:ok, pid} = Agent.start_link(fn -> %{acc: [], fail: fail} end)
    %__MODULE__{agent: pid}
  end

  def history(%__MODULE__{agent: pid}) do
    Agent.get(pid, fn %{acc: acc} -> Enum.reverse(acc) end)
  end
end

defimpl HLS.FS.Writer, for: Support.Writer do
  @impl true
  def write(%Support.Writer{agent: pid}, uri, binary, _opts) do
    Agent.update(pid, fn state = %{acc: acc} ->
      %{state | acc: [{uri, binary} | acc]}
    end)

    if Agent.get(pid, fn %{fail: fail} -> fail end) do
      {:error, "I was supposed to fail"}
    else
      :ok
    end
  end
end
