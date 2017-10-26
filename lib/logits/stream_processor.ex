defmodule LogIts.StreamProcessor do
  use GenServer
  require Logger
  alias Elixir.Stream, as: S

  # Include docker specific pieces
  alias LogIts.Docker.Processor, as: Processor

  @string_size_limit 20_000

  def start_link(args) do
    Logger.debug "StreamProcessor: #{inspect args}"
    GenServer.start_link(__MODULE__,args,[])
  end

  def init(args) do
    Logger.debug "StreamProcessor: #{inspect args}"
    {:ok, socket} = :gen_tcp.connect({:local, "/var/run/docker.sock"}, 0, [{:active, false}, :binary])
    GenServer.cast self(), :start
    GenServer.cast self(), args.stream_type
    {:ok, %{socket: socket} |> Map.merge(args) }
  end

  def handle_cast(:start, %{socket: socket, cmd: cmd} = state) do
    Processor.process_http_protocol(state)
    {:noreply, state}
  end

  def handle_cast(:logs, %{socket: socket, info: info, stream_handler: stream_handler} = state) do
    Processor.create_log_stream(state)
    |> stream_handler.(info)
    |> Processor.start()

    {:stop, :normal, state}
  end

  def handle_cast(:events, %{socket: socket, id: id, sink: sink} = state) do
    Processor.process_event_stream(state)
    {:stop, :normal, state}
  end

  def handle_info({:tcp_closed,socket},state) do
    IO.inspect "Socket has been closed"
    {:noreply,state}
  end

  def handle_info({:tcp_error,socket,reason},state) do
    IO.inspect socket,label: "connection closed: #{reason}"
    {:noreply,state}
  end

end
