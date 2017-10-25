defmodule DockerLogger.Monitor do
  use GenServer
  alias Elixir.Stream, as: S

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
