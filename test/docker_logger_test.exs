defmodule DockerLoggerTest do
  use ExUnit.Case
  doctest DockerLogger

  test "greets the world" do
    assert DockerLogger.hello() == :world
  end
end
