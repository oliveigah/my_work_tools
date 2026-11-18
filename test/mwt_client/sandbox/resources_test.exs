defmodule MWTClient.Sandbox.ResourcesTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Resources, Settings}

  @gib 1024 * 1024 * 1024

  defp machine(cores, memory_gib), do: %{cores: cores, memory: round(memory_gib * @gib)}

  describe "suggested/1" do
    test "gives the VM all but an eighth of the cores and a fifth of the memory" do
      # A 32 GB laptop shows about 30.5 GiB.
      assert %{cpus: 14, memory_gib: 24} == Resources.suggested(machine(16, 30.5))
      assert %{cpus: 7, memory_gib: 25} == Resources.suggested(machine(8, 32))
      assert %{cpus: 10, memory_gib: 12} == Resources.suggested(machine(12, 16))
    end

    test "keeps at least a core and 4 GiB for this machine, and at most 16 GiB" do
      assert %{cpus: 3, memory_gib: 3} == Resources.suggested(machine(4, 7.6))
      assert %{cpus: 56, memory_gib: 240} == Resources.suggested(machine(64, 256))
    end

    test "never suggests less than one of each, nor more than the most" do
      assert %{cpus: 1, memory_gib: 1} == Resources.suggested(machine(1, 2))
      assert %{cpus: 1, memory_gib: 1} == Resources.suggested(machine(2, 0.5))

      for cores <- 1..96, memory <- [1, 2, 4, 6, 8, 12, 16, 24, 31.2, 64, 128, 1024] do
        host = machine(cores, memory)
        suggested = Resources.suggested(host)
        most = Resources.most(host)
        assert suggested.cpus >= 1 and suggested.cpus <= most.cpus
        assert suggested.memory_gib >= 1 and suggested.memory_gib <= most.memory_gib
      end
    end

    test "falls back to 8 GiB where this machine's memory can't be read" do
      assert %{cpus: 14, memory_gib: 8} == Resources.suggested(%{cores: 16, memory: nil})
    end
  end

  describe "most/1" do
    test "is every core, and the memory less an eighth of it, from 2 to 8 GiB" do
      assert %{cpus: 16, memory_gib: 26} == Resources.most(machine(16, 30.5))
      assert %{cpus: 4, memory_gib: 5} == Resources.most(machine(4, 7.6))
      assert %{cpus: 64, memory_gib: 248} == Resources.most(machine(64, 256))
      assert %{cpus: 64, memory_gib: 504} == Resources.most(machine(128, 512))
    end

    test "is what microsandbox takes where memory can't be read" do
      assert %{cpus: 8, memory_gib: 512} == Resources.most(%{cores: 8, memory: nil})
    end
  end

  test "left/2 says what this machine keeps" do
    assert %{cores: 2, memory_gib: 6.5} ==
             Resources.left(machine(16, 30.5), %{cpus: 14, memory_gib: 24})
  end

  test "this machine reads as a machine" do
    host = Resources.host()
    assert host.cores >= 1
    assert is_nil(host.memory) or host.memory > 0
  end

  test "settings refuse more CPUs or memory than this machine can give" do
    most = %{cpus: 16, memory_gib: 26}

    assert {:ok, %{cpus: 16, memory_gib: 26}} =
             Settings.cast(%Settings{}, %{"cpus" => "16", "memory_gib" => "26"}, most)

    assert {:error, errors} =
             Settings.cast(%Settings{}, %{"cpus" => "17", "memory_gib" => "27"}, most)

    assert errors.cpus == "Enter a whole number from 1 to 16."
    assert errors.memory_gib == "Enter a whole number from 1 to 26."
  end
end
