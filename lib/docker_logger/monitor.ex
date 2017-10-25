defmodule DockerLogger.Monitor do
  use GenServer
  alias Elixir.Stream, as: S

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__,%{},name: __MODULE__)
  end

  def init(args) do
    GenServer.cast self(), :start
    GenServer.cast self(), :update_containers
    {:ok, %{containers: %{}, pids: %{}} |> Map.merge(args) }
  end

  def handle_cast(:start, state) do
    DockerLogger.StreamProcessSupervisor.start_events_watcher(self())
    {:noreply, state}
  end

  def handle_cast(:update_containers, %{containers: containers} = state) do
    ignorekeys = ["NetworkSettings","HostConfig","Mounts", "Labels"]

    # IO.puts "Monitor:container:update_containers:"

    new_containers =
      Dockerex.Client.get("containers/json")
      # |> S.each(&( IO.puts "new container: #{inspect &1}"))
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

  def handle_cast({:process, %{ "Id" => id } = container_info}, state) do
    {:ok, pid} = container_info
      |> DockerLogger.StreamProcessSupervisor.start_container_watcher()

    IO.puts "Monitor:container:spawn: id: #{inspect pid} - #{id}"
    {:noreply, %{ state | pids: Map.put(state.pids, id, pid)} }
  end

  def handle_cast({:event, raw_event }, state) when is_binary(raw_event) do
    event = Poison.decode!(raw_event)
    IO.puts "\nMonitor:event:: #{inspect event }"

    case Map.get(event, "Action", :error) do
      "start" ->
        GenServer.cast self(), :update_containers
        {:noreply, state}
      "die" ->
        id = Map.get(event, "ID") || Map.get(event, "Id")  || Map.get(event, "id") || raise "missing id"
        {pid, pids} = Map.pop(state.pids, id)
        IO.puts "Killing: pid: #{inspect pid}, id: #{id}"
        state = %{ state | containers: Map.delete(state.containers, id) }
        state = %{ state | pids: pids }
        {:noreply, state }
      _ ->
        {:noreply, state}
    end
  end

  def terminate(reason, state) do
    IO.puts "Terminating monitor: reason: #{inspect reason} state: #{inspect state}"

    for {cid, pid} <- state.pids do
      IO.puts "killing container logger: #{inspect pid} - #{inspect cid} "
      Process.exit(pid, :kill)
    end

    reason
  end

end
