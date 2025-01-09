defmodule Membrane.HLS.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: Membrane.HLS.TrackerSupervisor},
      {Task.Supervisor, name: Membrane.HLS.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Membrane.HLS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
