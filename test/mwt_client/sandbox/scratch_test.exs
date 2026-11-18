defmodule MWTClient.Sandbox.ScratchTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Scratch

  test "a folder only you can open, under a name no one can guess, gone once done" do
    {first, second} =
      Scratch.with_dir("mwt-test", fn dir ->
        assert File.stat!(dir).access == :read_write
        assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
        assert Path.dirname(dir) == System.tmp_dir!()
        assert "mwt-test-" <> random = Path.basename(dir)
        assert byte_size(random) == 16

        other = Scratch.dir!("mwt-test")
        File.rm_rf!(other)
        {dir, other}
      end)

    refute first == second
    refute File.exists?(first)
  end
end
