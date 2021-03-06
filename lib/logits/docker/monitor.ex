defmodule LogIts.Docker.Monitor do
  use GenServer
  require Logger
  alias Elixir.Stream, as: S
  alias LogIts.StreamProcessSupervisor

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__,%{},name: __MODULE__)
  end

  def init(args) do
    GenServer.cast self(), :start
    GenServer.cast self(), :update_containers
    config = Application.get_env(:logits, :monitor)

    stream_handler = case config |> Keyword.get(:stream_handler) do
      {mod,fun} ->
        fn x -> apply(mod, fun, x) end
      handler when is_function(handler) ->
        handler
      handler when is_binary(handler) ->
        {func, _} = Code.eval_string(handler, [] )
        func
      nil = handler ->
        &default_handler/2
    end
    state =
      %{containers: %{}, pids: %{}, stream_handler: stream_handler}
      |> Map.merge(args)
    {:ok, state}
  end

  def handle_cast(:start, state) do
    res = LogIts.StreamProcessSupervisor.start_events_watcher(self())

    {:noreply, state}
  end

  def default_handler(stream, info) do
    IO.inspect stream, label: "stream:default_handler"
    # {:ok, awspid} = LogIts.Spout.AwsCloud.start_link()
    #
    # stream
    # |> LogIts.Spout.AwsCloud.process_log_stream(awspid)
    # |> LogIts.Spout.SysLog.process_log_stream
    stream
  end

  def handle_cast(:update_containers, %{containers: containers} = state) do
    ignorekeys = ["NetworkSettings","HostConfig","Mounts", "Labels"]

    # Logger.debug "Monitor:container:update_containers:"

    new_containers =
      Dockerex.Client.get("containers/json")
      # |> S.each(&( Logger.debug "new container: #{inspect &1}"))
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

    {:ok, pid} =
      StreamProcessSupervisor.start_container_watcher(container_info, state.stream_handler)

    Logger.info "Monitor:container:spawn:log_monitor: #{inspect pid} - container-id #{id}"
    {:noreply, %{ state | pids: Map.put(state.pids, id, pid)} }
  end

  def handle_cast({:event, raw_event }, state) when is_binary(raw_event) do
    event = Poison.decode!(raw_event)
    action = Map.get(event, "Action") || Map.get(event, "action") || raise "event missing action"
    id = Map.get(event, "ID") || Map.get(event, "Id")  || Map.get(event, "id")
    Logger.info "Monitor:handle:docker_event:: #{inspect action} -- #{inspect id}"

    case action do
      "start" ->
        GenServer.cast self(), :update_containers
        {:noreply, state}
      "die" ->
        id = id || raise "missing id"
        {pid, pids} = Map.pop(state.pids, id)
        Logger.debug "Killing: pid: #{inspect pid}, id: #{id}"
        state = %{ state | containers: Map.delete(state.containers, id) }
        state = %{ state | pids: pids }
        {:noreply, state }
      _ ->
        Logger.debug "Event: Unhandled action: #{inspect action}"
        {:noreply, state}
    end
  end

  def terminate(reason, state) do
    Logger.debug "Terminating monitor: reason: #{inspect reason} state: #{inspect state}"

    for {cid, pid} <- state.pids do
      Logger.debug "killing container logger: #{inspect pid} - #{inspect cid} "
      Process.exit(pid, :kill)
    end

    reason
  end

end
