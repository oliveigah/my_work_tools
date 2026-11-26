defmodule MWTClient.ProcessGuard do
  @moduledoc """
  Keeps other programs running as you out of MWT's memory. When MWT
  starts, before any identity unlocks, it marks its own process not
  dumpable (`prctl(PR_SET_DUMPABLE, 0)`, as `ssh-agent` does), with a NIF
  of its own (`c_src/process_guard.c`).

  From then on no process of yours can trace MWT, or read its memory, its
  environment or its open files through `/proc`, whatever
  `kernel.yama.ptrace_scope` allows, and MWT leaves no core dump. What that
  keeps: the unlocked identities' keys, the credentials, and what the
  databases hold in memory. Root still reads everything.

  It covers this process only. What MWT starts is dumpable again once it
  `exec`s (msb and the relay in the VM's bubble, host commands, git), and
  so is `erl_child_setup`, which the BEAM starts before any of MWT's code
  runs and which starts them; none of them holds a key. MWT's files on
  disk, the VM's sockets and its bubble are other matters
  (`MWTClient.Sandbox.Peer`, `docs/architecture.md`).
  """

  @on_load :load

  @doc false
  def load do
    :mwt_client
    |> :code.priv_dir()
    |> Path.join("process_guard")
    |> String.to_charlist()
    |> :erlang.load_nif(0)
  end

  @doc "Marks this process not dumpable. MWT does it once, as it starts."
  @spec start() :: :ok | {:error, integer() | :unsupported}
  def start, do: guard_nif()

  @doc "Whether this process is dumpable: true until `start/0` ran."
  @spec dumpable?() :: boolean()
  def dumpable? do
    case dumpable_nif() do
      0 -> false
      value when is_integer(value) -> true
    end
  end

  @doc false
  def guard_nif, do: :erlang.nif_error(:not_loaded)

  @doc false
  def dumpable_nif, do: :erlang.nif_error(:not_loaded)
end
