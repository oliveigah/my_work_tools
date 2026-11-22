defmodule MWTClient.Sandbox.ConfineTest do
  @moduledoc """
  The arguments of a confined command's bubble (`MWTClient.Sandbox.Confine`),
  as `bubble_test.exs` checks the VM's: what it binds, how, and in which
  order. Running in one is `host_run_test.exs`'s, tagged `:bwrap`.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Confine

  doctest Confine

  @spec_ %{
    dir: "/home/me/site",
    writes: false,
    home: "/home/me",
    reads: ["/home/me/.local/bin", "/home/me/.local/share/mise/shims"],
    bwrap: "/usr/bin/bwrap",
    resolver: "/run/systemd/resolve",
    links: %{"/home/me/.local/bin" => "/home/me/opt/bin"}
  }

  defp pairs(words), do: Enum.chunk_every(words, 3, 1, :discard)

  test "namespaces of its own but the network, which a script may need" do
    words = Confine.words(@spec_)
    assert hd(words) == "/usr/bin/bwrap"

    for flag <-
          ~w(--unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup --die-with-parent),
        do: assert(flag in words)

    refute "--unshare-net" in words
    refute "--unshare-all" in words
    # A session of its own would take it out of the process group the
    # time limit kills.
    refute "--new-session" in words
    refute "--clearenv" in words
  end

  test "the system read-only, an empty home, and what it may read on top of it" do
    words = Confine.words(@spec_)
    assert ["--ro-bind", "/usr", "/usr"] in pairs(words)
    assert ["--ro-bind", "/etc", "/etc"] in pairs(words)
    assert ["--ro-bind-try", "/run/systemd/resolve", "/run/systemd/resolve"] in pairs(words)

    home = Enum.find_index(words, &(&1 == "/home/me"))
    assert Enum.at(words, home - 1) == "--tmpfs"

    for folder <- @spec_.reads ++ ["/home/me/opt/bin"] do
      at = Enum.find_index(words, &(&1 == folder))
      assert Enum.at(words, at - 1) == "--ro-bind-try"
      assert at > home, "#{folder} must be bound after the empty home"
    end

    # /run is replaced before the resolver's folder goes back in.
    run = Enum.find_index(pairs(words), &(&1 == ["--tmpfs", "/run", "--ro-bind-try"]))
    assert run
  end

  test "its folder read-only unless it may write there, and it starts there" do
    assert ["--ro-bind", "/home/me/site", "/home/me/site"] in pairs(Confine.words(@spec_))

    writes = Confine.words(%{@spec_ | writes: true})
    assert ["--bind", "/home/me/site", "/home/me/site"] in pairs(writes)
    assert Enum.take(writes, -3) == ["--chdir", "/home/me/site", "--"]
    assert ["--dir", "/mnt/mwt/tokens", "--bind"] in pairs(writes)
  end

  test "in your home folder itself, it runs in the empty one" do
    words = Confine.words(%{@spec_ | dir: "/home/me"})
    refute ["--ro-bind", "/home/me", "/home/me"] in pairs(words)
    refute ["--bind", "/home/me", "/home/me"] in pairs(words)
    assert Enum.take(words, -3) == ["--chdir", "/home/me", "--"]
  end

  test "the workspace: from-vm read-only, to-vm writable, before its own folder" do
    words = Confine.words(Map.put(@spec_, :workspace, "/home/me/mwt-vm"))
    from = ["--ro-bind-try", "/home/me/mwt-vm/from-vm", "/home/me/mwt-vm/from-vm"]
    to = ["--bind-try", "/home/me/mwt-vm/to-vm", "/home/me/mwt-vm/to-vm"]
    assert from in pairs(words)
    assert to in pairs(words)

    index = fn part -> Enum.find_index(pairs(words), &(&1 == part)) end
    assert index.(from) > index.(["--tmpfs", "/home/me", "--ro-bind-try"]) - 1
    assert index.(to) < index.(["--ro-bind", "/home/me/site", "/home/me/site"])

    refute Enum.any?(Confine.words(@spec_), &String.contains?(&1, "mwt-vm"))
  end

  test "no value travels in the arguments, which every account here can read" do
    words = Confine.words(@spec_)
    refute Enum.any?(words, &String.contains?(&1, "="))
    refute "--setenv" in words
  end
end
