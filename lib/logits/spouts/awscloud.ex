defmodule LogIts.Spout.AwsCloud do
  # use GenServer
  require Logger
  alias Elixir.Stream, as: S
  alias LogIts.Spout.AwsCloud

  use ExActor.GenServer

  @logGroupName "logits2"
  @logStreamName "test1"
  @logInterval 5_000
  @logLimit 20_000

  defstart start_link(args \\ []) do
    access_key_id = System.get_env("AWS_ACCESS_KEY_ID")
    secret_access_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    region = System.get_env("AWS_REGION") || "us-west-2"

    client = %AWS.Client{access_key_id: access_key_id,
                         secret_access_key: secret_access_key,
                         region: region,
                         endpoint: "amazonaws.com"}

    Process.send_after(self(), :push_logs, @logInterval)
    AwsCloud.setup(self())

    initial_state(%{client: client, logs: [], seq_token: nil})
  end

  defcast setup(), state: %{client: client} = state do
    {:ok, result, _resp} = AWS.Logs.describe_log_streams(client, %{
        "descending": false,
        "limit": 50,
        "logGroupName": @logGroupName,
        "logStreamNamePrefix": @logStreamName,
      })

    Logger.debug "AWS.Logs:setup: result: -- #{inspect result}"
    seq_toke_map = for {log_stream, [log_info | _other ]} <- result, into: %{} do
      logStreamName = Map.get log_info, "logStreamName"
      uploadSequenceToken = Map.get log_info, "uploadSequenceToken"
      {logStreamName, uploadSequenceToken}
    end

    seq_token = Map.get seq_toke_map, @logStreamName
    Logger.debug "AWS.Logs:setup: seq_token: #{seq_token} -- #{inspect seq_toke_map}"
    new_state( %{ state | seq_token: seq_token} )
  end

  defcast logitem(item), state: %{client: client, seq_token: seq_token} = state do
    item = %{
       "message": "#{inspect item}",
       "timestamp": DateTime.to_unix(DateTime.utc_now) * 1000
    }

    if length(state.logs) > @logLimit do
      new_state( %{ state | logs: state.logs } )
    else
      new_state( %{ state | logs: state.logs ++ [item]} )
    end
  end

  defhandleinfo :push_logs, state: %{logs: []} = state do
    Logger.debug "AwsCloud:push_logs:skipping"
    new_state( state )
  end

  defhandleinfo :push_logs, state: %{client: client, seq_token: seq_token, logs: logs} = state do
    Logger.debug "AwsCloud: #{inspect logs} - seq_token: #{inspect seq_token}"
    Process.send_after(self(), :push_logs, @logInterval)

    log_args = %{
       "logEvents": logs,
       "logGroupName": @logGroupName,
       "logStreamName": @logStreamName,
       "sequenceToken": seq_token
    }

    {:ok, result, _resp} = AWS.Logs.put_log_events(client, log_args)
    Logger.debug "#{__MODULE__}: put_log_events:: #{inspect result }"
    nextSequenceToken = Map.get result, "nextSequenceToken"
    state = %{ state | seq_token: nextSequenceToken}
    state = %{ state | logs: []}
    new_state(state)
  end

  defcast stop, do: stop_server(:normal)

  def process_log_stream(stream, pid) do
    stream
    |> S.each(&( AwsCloud.logitem(pid, &1) ))
  end


end
