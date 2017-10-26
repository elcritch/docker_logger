defmodule LogIts.Spout.AwsCloud do
  # use GenServer
  require Logger
  alias Elixir.Stream, as: S

  def process_log_stream(stream) do
    stream
    |> S.each(&( Logger.info "AwsCloud: #{inspect &1}" ))
  end
end
