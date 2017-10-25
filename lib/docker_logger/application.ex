defmodule DockerLogger.Application do
  use Application

  def start(_type, _args) do
    children = [
      DockerLogger.Monitor,
      DockerLogger.StreamProcessSupervisor,
    ]

    opts = [strategy: :one_for_one, name: DockerLogger.Supervisor]
    Supervisor.start_link(children, opts)
  end

end
