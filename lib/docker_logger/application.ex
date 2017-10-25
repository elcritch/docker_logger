alias Elixir.Stream, as: S

defmodule DockerLogger.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      # Starts a worker by calling: DockerLogger.Worker.start_link(arg)
      DockerLogger.Monitor,
      DockerLogger.StreamProcessSupervisor,
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DockerLogger.Supervisor]
    Supervisor.start_link(children, opts)
  end

end

defmodule DockerLogger.Monitor do
  use GenServer

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__,%{},name: __MODULE__)
  end

  def init(args) do
    GenServer.cast self(), :start
    GenServer.cast self(), :update_containers
    {:ok, %{containers: %{}} |> Map.merge(args) }
  end

  def handle_cast(:start, state) do
    self()
    |> DockerLogger.StreamProcessSupervisor.start_events_watcher()

    {:noreply, state}
  end

  def handle_cast(:update_containers, %{containers: containers} = state) do
    ignorekeys = ["NetworkSettings","HostConfig","Mounts", "Labels"]

    IO.puts "Monitor:container:update_containers:"

    new_containers =
      Dockerex.Client.get("containers/json")
      |> S.each(&( IO.puts "new container: #{inspect &1}"))
      |> S.filter(&( Regex.match?(~r/running|start/, Map.fetch!(&1, "State"))))
      |> S.map(&( &1 |> Map.drop(ignorekeys) ))
      |> S.map(&( {Map.fetch!(&1, "Id"), &1} ))
      |> S.reject(fn ({id,map}) -> containers |> Map.has_key?(id) end)
      |> Enum.into(%{})

    new_containers
      |> Map.values
      |> Enum.map(&(GenServer.cast self(), {:process, &1}))

    {:noreply, %{ state | containers: Map.merge(containers,new_containers)} }
  end

  def handle_cast({:process, container_info}, state) do

    IO.puts "Monitor:container:res: #{inspect container_info}"
    container_info
    |> DockerLogger.StreamProcessSupervisor.start_container_watcher()

    {:noreply, state}
  end

  def handle_cast({:event, %{"Action" => action} = event }, state) do
    IO.puts "Monitor:event:: #{inspect event }"
    case action do
      "start" ->
        GenServer.cast self(), :update_containers
        {:noreply, state}
      "die" ->
        id = Map.fetch!(event, "ID", nil) || Map.fetch!(event, "Id")
        {:noreply, %{ state | containers: Map.delete(state.containers, id) } }
      _ ->
        {:noreply, state}
    end
  end
end

defmodule DockerLogger.StreamProcessSupervisor do
  use Supervisor

  @name DockerLogger.StreamProcessSupervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: @name)
  end

  def start_container_watcher(%{"Id" => id} = info) do
    IO.puts "Monitor:container: #{inspect info}"

    cmd = "GET /containers/#{id}/logs?stderr=1&stdout=1&timestamps=0&follow=1&since=#{DateTime.to_unix(DateTime.utc_now) - 1} HTTP/1.1\n"
    args = %{info: info, cmd: cmd, stream_handler: :logs}
    Supervisor.start_child(@name, [args])
  end

  def start_events_watcher(pid) do
    ts = DateTime.to_unix(DateTime.utc_now)
    cmd = "GET /events?since=#{ts} HTTP/1.1\n"
    args = %{id: ts, cmd: cmd, stream_handler: :events, sink: pid}
    Supervisor.start_child(@name, [args])
  end

  def init(:ok) do
    children = [
      # DockerLogger.StreamProcessor,
      %{id: DockerLogger.StreamProcessor, start: {DockerLogger.StreamProcessor, :start_link, []}}
    ]

    opts = [strategy: :simple_one_for_one, name: StreamProcessSupervisor]
    # Supervisor.init(children, strategy: :simple_one_for_one)
    Supervisor.init(children, strategy: :simple_one_for_one)
  end
end
