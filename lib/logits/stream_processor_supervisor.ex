defmodule LogIts.StreamProcessSupervisor do
  use Supervisor
  require Logger
  alias Elixir.Stream, as: S

  @name LogIts.StreamProcessSupervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: @name)
  end

  def start_container_watcher(%{"Id" => id} = info, handler) do
    # Logger.debug "Monitor:container: #{inspect info}"

    cmd = "GET /containers/#{id}/logs?stderr=1&stdout=1&timestamps=0&follow=1&since=#{DateTime.to_unix(DateTime.utc_now) - 1} HTTP/1.1\n"
    args = %{info: info, cmd: cmd, stream_type: :logs, stream_handler: handler}
    Supervisor.start_child(@name, [args])
  end

  def start_events_watcher(pid) do
    ts = DateTime.to_unix(DateTime.utc_now)
    cmd = "GET /events?since=#{ts} HTTP/1.1\n"
    args = %{id: ts, cmd: cmd, stream_type: :events, sink: pid}
    Supervisor.start_child(@name, [args])
  end

  def init(:ok) do
    children = [
      # LogIts.StreamProcessor,
      %{id: LogIts.StreamProcessor, start: {LogIts.StreamProcessor, :start_link, []}}
    ]

    opts = [strategy: :simple_one_for_one, name: StreamProcessSupervisor]
    # Supervisor.init(children, strategy: :simple_one_for_one)
    Supervisor.init(children, strategy: :simple_one_for_one)
  end
end
