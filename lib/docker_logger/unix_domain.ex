defmodule TcpServer do
  use GenServer

  @string_size_limit 20_000

  def start_link(%{id: id, cmd: cmd} = args) do
    GenServer.start_link(__MODULE__,args,[])
  end

  def init(args) do
    {:ok, socket} = :gen_tcp.connect({:local, "/var/run/docker.sock"}, 0, [{:active, false}, :binary])
    GenServer.cast self(), {:start}
    {:ok, %{socket: socket} |> Map.merge(args) }
  end

  def start_container_watcher(id) do
    cmd = "GET /containers/#{id}/logs?stderr=0&stdout=1&timestamps=0&follow=1&since=#{DateTime.to_unix(DateTime.utc_now) - 10} HTTP/1.1\n"
    start_link(%{id: id, cmd: cmd})
  end

  def handle_cast({:start}, %{socket: socket, id: id, cmd: cmd} = state) do
    # socket |> :gen_tcp.send("GET /events HTTP/1.1\n")
    # socket |> :gen_tcp.send("POST /containers/#{id}/attach?stream=1&stdout=0&stderr=1 HTTP/1.1\n")

    socket |> :gen_tcp.send(cmd)
    socket |> :gen_tcp.send("Host: localhost\r\n")
    socket |> :gen_tcp.send("Accept: */*\r\n")
    socket |> :gen_tcp.send("Connection: Upgrade\r\n")
    socket |> :gen_tcp.send("Upgrade: tcp\r\n")
    socket |> :gen_tcp.send("\n")

    # process headers
    resource =
      stream(socket)
      |> parse_http_headers
      |> Enum.to_list
      # |> Enum.each(&(IO.puts "header: #{&1}"))

    # process docker logs
    stream(socket)
      |> docker_log_parse
      # |> Stream.each(fn x -> IO.puts "logs:check: #{inspect x}" end)
      |> stream_to_lines
      |> parse_docker_logs
      |> Enum.each(&process_log/1)
      # |> Enum.each(fn x -> IO.puts "logs: #{inspect x}" end)

    {:noreply, state}
  end

  def stream(socket) do
    Stream.repeatedly(fn -> res = :gen_tcp.recv(socket,0); {:ok, msg} = res; msg end)
    |> Stream.flat_map(fn x -> :binary.bin_to_list(x); end)
    |> Stream.map(fn x -> <<x>> end)
  end

  def process_log(item) do
    IO.puts "logs: #{inspect item}"
  end

  def stream_to_lines(stream) do
    stream |> Stream.chunk_while({[],0},
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

  def docker_log_parse(stream) do
    stream |> Stream.chunk_while({:header, [], 0},
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
        IO.puts "after chunker: #{inspect x}"
        {:cont, x, :none}
      end)
  end

  def parse_http_headers(stream) do
    stream |> Stream.transform([], fn i, acc ->
          if i == "\n" && acc == ["\r", "\n", "\r"]  do
            {:halt, [i]}
          else
            {[i], [i] ++ Enum.take(acc, 2)}
          end
        end)
  end

  def parse_docker_logs(stream) do
    stream |> Stream.map(fn line ->
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

  def handle_info({:tcp,socket,packet},state) do
    # IO.inspect packet, label: "incoming packet"

    IO.puts "\n\n====\nincoming packet: #{packet }"
    IO.puts "incoming packet: raw: #{inspect String.split(packet,"\n") }"
    :inet.setopts(socket, active: :once)

    {:noreply,state}
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
