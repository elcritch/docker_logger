defmodule LogIts.Application do
  use Application

  def start(_type, _args) do
    children = [
      LogIts.Monitor,
      LogIts.StreamProcessSupervisor,
      {LogIts.Spout.AwsCloud, []},
    ]

    opts = [strategy: :one_for_one, name: LogIts.Supervisor]
    Supervisor.start_link(children, opts)
  end

end
