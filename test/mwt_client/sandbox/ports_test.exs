defmodule MWTClient.Sandbox.PortsTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Ports

  doctest Ports

  # What `mwt ports --watch` sent from a real VM (the watcher's own test run):
  # ss lines with their trailing spaces, then the folders.
  @report """
  LISTEN 0      4096       127.0.0.1:4101       0.0.0.0:*    users:(("beam.smp",pid=3889,fd=21))  \nLISTEN 0      5          127.0.0.1:4123       0.0.0.0:*    users:(("python3",pid=17520,fd=3))  \nLISTEN 0      128          0.0.0.0:22         0.0.0.0:*    users:(("sshd",pid=88,fd=3))        \nLISTEN 0      511            [::1]:5173          [::]:*    users:(("node",pid=901,fd=19))      \nLISTEN 0      4096               *:4369             *:*    users:(("epmd",pid=77,fd=3))        \nLISTEN 0      4096       127.0.0.1:4101       0.0.0.0:*    users:(("beam.smp",pid=3889,fd=22))  \ncwd 3889 /work/mwt_client.wt/slot-1\ncwd 17520 /tmp/fakech\ncwd 901 /work/web.wt/slot-2/assets
  """

  describe "a report from the VM" do
    test "is one listener per port, with its process, pid and folder" do
      assert [
               %{port: 22, process: "sshd", pid: 88, cwd: nil, binds: ["0.0.0.0"]},
               %{port: 4101, process: "beam.smp", pid: 3889, cwd: "/work/mwt_client.wt/slot-1"},
               %{port: 4123, process: "python3", cwd: "/tmp/fakech"},
               %{port: 4369, process: "epmd", binds: ["*"]},
               %{port: 5173, process: "node", binds: ["::1"], cwd: "/work/web.wt/slot-2/assets"}
             ] = Ports.parse(@report)
    end

    test "is read only as far as it makes sense, and only so far" do
      assert Ports.parse("") == []

      assert Ports.parse("LISTEN 0 1 127.0.0.1:99999 0.0.0.0:*\nLISTEN 0 1 nonsense\nhello") ==
               []

      # A folder line for a process that holds no port changes nothing.
      assert [%{cwd: nil}] = Ports.parse("LISTEN 0 1 127.0.0.1:4000 0.0.0.0:*\ncwd 1 /etc")

      lines = for port <- 2000..2999, do: "LISTEN 0 1 127.0.0.1:#{port} 0.0.0.0:*"
      assert length(Ports.parse(Enum.join(lines, "\n"))) == Ports.max_listeners()
    end
  end

  describe "the plan" do
    test "forwards to loopback in the VM, ::1 for a server only there" do
      plan =
        Ports.plan(
          Ports.parse(@report) ++
            [%{port: 4150, binds: ["::1"], process: "node", pid: 1, cwd: nil}]
        )

      assert %{port: 4101, target: "127.0.0.1", status: :pending} = find(plan, 4101)
      assert %{port: 4150, target: "::1", status: :pending} = find(plan, 4150)
    end

    test "is only the range: everything else stays in the VM, unlisted" do
      assert Ports.range() == 4100..4199
      assert Ports.range_text() == "4100 to 4199"

      assert [4101, 4123] = @report |> Ports.parse() |> Ports.plan() |> Enum.map(& &1.port)

      edges =
        for port <- [1024, 4000, 4099, 4100, 4199, 4200, 4369, 33_053],
            do: %{port: port, binds: ["0.0.0.0"], process: "x", pid: nil, cwd: nil}

      assert [4100, 4199] = edges |> Ports.plan() |> Enum.map(& &1.port)
    end

    test "says the same range as the VM's watcher and the agents' instructions" do
      %{first: first, last: last} = Ports.range()
      cli = File.read!(Path.join([:code.priv_dir(:mwt_client), "sandbox", "mwt-cli"]))
      assert cli =~ "ss -ltnpH '( sport >= :#{first} and sport <= :#{last} )'"
      assert cli =~ "a port from #{Ports.range_text()}"
      assert MWTClient.Sandbox.Instructions.text() =~ "on a port from #{Ports.range_text()}"
    end
  end

  test "a server's slot comes from its folder" do
    assert Ports.slot("/work/mwt_client.wt/slot-1") == {"mwt_client", "slot-1"}
    assert Ports.slot("/work/mwt_client.wt/slot-12/lib") == {"mwt_client", "slot-12"}
    assert Ports.slot("/work/mwt_client.wt/slot-1x") == nil
    assert Ports.slot("/work/mwt_client") == nil
    assert Ports.slot(nil) == nil
  end

  test "each identity's VM has an address of its own, on loopback" do
    a = Ports.address("one")
    assert a == Ports.address("one")
    assert a != Ports.address("two")
    assert {:ok, {127, 77, _, last}} = :inet.parse_address(String.to_charlist(a))
    assert last in 1..254
    assert Ports.url(a, 4000) == "http://#{a}:4000"
  end

  defp find(plan, port), do: Enum.find(plan, &(&1.port == port))
end
