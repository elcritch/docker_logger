defmodule LogIts.Application do
  use Application

  def start(_type, _args) do
    children = [
      LogIts.Docker.Monitor,
      LogIts.StreamProcessSupervisor,
    ]

    opts = [strategy: :one_for_one, name: LogIts.Supervisor]
    Supervisor.start_link(children, opts)
  end

end
