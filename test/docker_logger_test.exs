defmodule LogItsTest do
  use ExUnit.Case
  doctest LogIts

  test "greets the world" do
    assert LogIts.hello() == :world
  end
end
