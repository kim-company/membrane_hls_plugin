defmodule Membrane.HLS.Sink.SegmentWriter do
  use GenServer

  alias HLS.Storage
  require Membrane.Logger

  @supervisor Membrane.HLS.TaskSupervisor
  @default_max_attempts 3
  @default_timeout_ms 2_000

  def start_link(opts) do
    opts = Keyword.validate!(opts, [:writer, max_attempts: @default_max_attempts])
    GenServer.start_link(__MODULE__, opts)
  end

  def write(server, request) do
    GenServer.cast(server, {:write, request})
  end

  @impl true
  def handle_cast({:write, request}, state) do
    {:noreply, start_upload_task(state, request)}
  end

  @impl true
  def handle_info({ref, response}, state) when is_reference(ref) do
    case response do
      :ok ->
        # No need to continue to monitor
        Process.demonitor(ref, [:flush])
        {_, state} = pop_in(state, [:tasks, ref])
        {:noreply, state}

      {:error, reason} ->
        %{request: %{uri: uri}, attempt: attempt} = get_in(state, [:tasks, ref])

        Membrane.Logger.warn(
          "Request attempt #{inspect(attempt)} to #{inspect(uri)} failed with reason: #{reason}"
        )

        # We'll handle the restart in the DOWN message
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        state = %{max_attempts: max}
      ) do
    {%{request: request = %{uri: uri}, attempt: attempt}, state} = pop_in(state, [:tasks, ref])

    Membrane.Logger.warn(
      "Task #{inspect(ref)} with request to #{inspect(uri)} exited with reason: #{inspect(reason)}"
    )

    if attempt == max do
      {:stop,
       {:too_many_retries,
        "Reached max retry attempts on request #{inspect(request)}: last error was: #{inspect(reason)}"},
       state}
    else
      {:noreply, start_upload_task(state, request, attempt + 1)}
    end
  end

  @impl true
  def init(args) do
    {:ok,
     %{
       writer: Keyword.fetch!(args, :writer),
       max_attempts: Keyword.fetch!(args, :max_attempts),
       tasks: %{}
     }}
  end

  defp start_upload_task(
         state = %{writer: writer},
         request = %{uri: uri, payload: payload},
         attempt \\ 1
       ) do
    task =
      Task.Supervisor.async_nolink(
        @supervisor,
        fn ->
          Storage.write(writer, uri, payload)
        end,
        shutdown: @default_timeout_ms
      )

    put_in(state, [:tasks, task.ref], %{request: request, attempt: attempt})
  end
end
