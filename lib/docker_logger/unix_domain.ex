defmodule TcpServer do
  use GenServer

  @string_size_limit 20_000

  def start_link(%{id: id} = args) do
    GenServer.start_link(__MODULE__,args,[])
  end

  def init(args) do

    IO.puts "starting connection..."
    {:ok, socket} = :gen_tcp.connect({:local, "/var/run/docker.sock"}, 0, [{:active, false}, :binary])

    GenServer.cast self(), {:start}

    {:ok, %{socket: socket} |> Map.merge(args) }
  end

  def handle_cast({:start}, %{socket: socket, id: id} = state) do

    # socket |> :gen_tcp.send("GET /events HTTP/1.1\n")
    # socket |> :gen_tcp.send("POST /containers/#{id}/attach?stream=1&stdout=0&stderr=1 HTTP/1.1\n")
    socket |> :gen_tcp.send("GET /containers/#{id}/logs?stderr=0&stdout=1&timestamps=0&follow=1&since=#{DateTime.to_unix(DateTime.utc_now) - 10} HTTP/1.1\n")

    socket |> :gen_tcp.send("Host: localhost\r\n")
    socket |> :gen_tcp.send("Accept: */*\r\n")
    socket |> :gen_tcp.send("Connection: Upgrade\r\n")
    socket |> :gen_tcp.send("Upgrade: tcp\r\n")
    socket |> :gen_tcp.send("\n")

    resource =
      Stream.repeatedly(fn -> res = :gen_tcp.recv(socket,0); {:ok, msg} = res; msg end)
      |> Stream.flat_map(fn x -> :binary.bin_to_list(x); end)
      |> Stream.map(fn x -> <<x>> end)
      |> Stream.chunk_while({[],0},
          fn i, {acc, count} ->
            next = [ acc, i ]
            if (i == "\n" && List.last(acc) == "\r") do
              # turn list of bin's into single line
              {:cont, to_string(if List.last(acc) == "\r", do: List.first(acc), else: acc), {[], 0} }
            else
              {:cont, {next, count+1} }
            end
          end,
          fn({acc, count}) -> {:cont, to_string(acc)} end)

    resource
      |> Stream.take_while(fn x -> !Regex.match?(~r/^(\r\n){0,1}$/, x) end)
      |> Enum.map(&(IO.puts("http headers: #{inspect &1}")))

    resource
      |> docker_out_chunker
      # |> Stream.chunk_every(2,3)
      # |> Stream.flat_map(fn x -> Enum.slice(x,-2..-1) end)
      |> Enum.map(&(IO.puts("logs: #{String.length(&1) |> Integer.to_string(16)}: #{inspect &1}")))

    # process_log_stream(resource)

    {:noreply, state}
  end

  def docker_out_chunker(enum) do
    Stream.chunk_while enum, {:http, []},
      fn ln, {tag, acc} ->
        cond do
          :http == acc && (ln == "\n" && List.last(acc) == "\r") ->
            IO.puts
            {:cont, :header}
          :header == acc && Regex.match?(~r/^[0-9a-fA-F]{1,3}$|/, ln) ->
            {count, rem} = Integer.parse(ln |> String.upcase,16)
            IO.puts "chunk header: #{count}"
            {:cont, :line}
          :header == acc ->
            raise "error:header expected:ln: #{inspect ln} acc: #{inspect acc}"
          :line == acc ->
            {:cont, ln, :last}
          :last == acc ->
            {:cont, :header}
          true ->
            raise "error::ln: #{inspect ln} acc: #{inspect acc}"
        end
      end,
      fn x ->
        IO.puts "after chunker: #{inspect x}"
        {:cont, x, :none}
      end
  end

  def process_log_stream(resource) do
    resource
      |> Stream.chunk_while([], fn x -> end, fn x -> end)
      # |> Stream.reject(fn ln -> Regex.match?(~r/^\d{1,3}$|^$/, ln) end)
      |> Stream.map(&parse_docker_logs/1)
      |> Enum.map(&(IO.puts("log: #{&1 |> inspect }")))
  end

  def parse_docker_logs(line) do
    case line do
      # deplex stdin, stdout, stderr
      <<0, 0, 0, 0, n :: size(32), rest :: binary >> -> {:stdin, rest}
      <<1, 0, 0, 0, n :: size(32), rest :: binary >> -> {:stdout, rest}
      <<2, 0, 0, 0, n :: size(32), rest :: binary >> -> {:stderr, rest}
      # tty output
      other -> {:stdout, other}
    end
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
