defmodule LogIts.Docker.Processor do
  use GenServer
  require Logger
  alias Elixir.Stream, as: S

  @string_size_limit 20_000

  def start(stream) do
    stream |> Enum.each(fn x -> end)
  end

  def process_http_protocol(%{socket: socket, cmd: cmd} = state) do
    socket |> :gen_tcp.send(cmd)
    socket |> :gen_tcp.send("Host: localhost\r\n")
    socket |> :gen_tcp.send("Accept: */*\r\n")
    socket |> :gen_tcp.send("Connection: Upgrade\r\n")
    socket |> :gen_tcp.send("Upgrade: tcp\r\n")
    socket |> :gen_tcp.send("\r\n")

    # process headers
    create_stream(socket)
    |> parse_http_headers
    |> Enum.to_list
  end

  def create_log_stream(%{socket: socket, info: info} = state) do
    # process docker logs
    create_stream(socket)
    |> docker_log_stream_parser
    |> stream_to_lines
    |> parse_docker_log_item
    # |> Enum.each( log_handler )
  end

  def process_event_stream(%{socket: socket, id: id, sink: sink} = state) do
    # process events
    create_stream(socket)
    |> stream_to_lines
    |> S.chunk_every(3)
    |> S.map(&(Enum.at(&1,1)))
    |> Enum.each(fn event -> GenServer.cast(sink, {:event, event}) end)
  end

  def create_stream(socket) do
    S.repeatedly(fn -> res = :gen_tcp.recv(socket,0); {:ok, msg} = res; msg end)
    |> S.flat_map(fn x -> :binary.bin_to_list(x); end)
    |> S.map(fn x -> <<x>> end)
  end

  def stream_to_lines(stream) do
    stream |> S.chunk_while({[],0},
        fn i, {acc, count} ->
          if i == "\n" do
            # turn list of bin's into single line
            {:cont, to_string(if List.last(acc) == "\r", do: List.first(acc), else: acc), {[], 0} }
          else
            {:cont, {[acc,i], count+1}}
          end
        end,
        fn({acc, count}) -> {:cont, to_string(acc)} end)
  end

  def docker_log_stream_parser(stream) do
    stream |> S.chunk_while({:header, [], 0},
      fn i, {tag, acc, count} ->
        cond do
          :header == tag && (i == "\n") && List.last(acc) == "\r" ->
            {num, rem} = to_string(acc) |> String.upcase |> Integer.parse(16)
            {:cont, {:line,[],num}}
          :header == tag && count < 10 ->
            {:cont, {:header, acc ++ [i], count + 1}}
          :line == tag && count > 0 ->
            {:cont, i, {:line,[],count-1}}
          :line == tag && count <= -1  ->
            {:cont, {:header,[],0}}
          :line == tag && count <= 1 ->
            {:cont, {:line,[],count-1}}
          true ->
            raise "error::ln: #{i} acc: #{inspect acc}, tag: #{inspect tag}, count: #{count}"
        end
      end,
      fn x ->
        Logger.debug "after chunker: #{inspect x}"
        {:cont, x, :none}
      end)
  end

  def parse_http_headers(stream) do
    stream |> S.transform([], fn i, acc ->
          if i == "\n" && acc == ["\r", "\n", "\r"]  do
            {:halt, [i]}
          else
            {[i], [i] ++ Enum.take(acc, 2)}
          end
        end)
  end

  def parse_docker_log_item(stream) do
    stream |> S.map(fn line ->
        case line do
          # deplex stdin, stdout, stderr
          <<0, 0, 0, 0, n :: size(32), rest :: binary >> -> {:stdin, rest}
          <<1, 0, 0, 0, n :: size(32), rest :: binary >> -> {:stdout, rest}
          <<2, 0, 0, 0, n :: size(32), rest :: binary >> -> {:stderr, rest}
          # tty output
          other -> {:tty, other}
        end
    end)
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
