defmodule AkawTest do
  use ExUnit.Case
  doctest Akaw

  test "greets the world" do
    assert Akaw.hello() == :world
  end
end
