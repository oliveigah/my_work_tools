defmodule MWTClient.Sandbox.NestedVirt do
  @moduledoc """
  Whether this machine lets the VM run VMs of its own: nested virtualization.

  Off unless you turn it on in the VM's settings (`MWTClient.Sandbox.Settings`,
  `nested_virt`). On, microsandbox creates the VM with `--nested-virt`: the VM
  sees the CPU's virtualization (AMD's SVM, Intel's VMX) and its kernel's KVM
  gives it `/dev/kvm`, so microsandbox, QEMU or an Android emulator run inside
  it. MWT itself needs that to test what starts a real VM.

  The cost is exposure. With it on, every process in the VM, all of them root,
  reaches this machine's KVM code that emulates the CPU's virtualization for
  a guest's own hypervisor. Several published guest-to-host escapes were in
  that code. It applies when the VM is created, so turning it on or off takes
  a recreate.

  microsandbox refuses `--nested-virt` when this machine's KVM doesn't offer
  it, so the settings say first: `host/1` reads what KVM was loaded with.
  """

  @type host :: :allowed | {:off, module :: String.t()} | :unavailable

  @doc """
  What this machine allows:

    * `:allowed`: its CPU has hardware virtualization and the KVM module for
      it was loaded with `nested=1`;
    * `{:off, module}`: KVM is there but `module` (`kvm_amd` or `kvm_intel`)
      was loaded without nesting, or isn't loaded;
    * `:unavailable`: the CPU offers no hardware virtualization here, as
      inside a VM that wasn't given it.

  `root` is where `/proc` and `/sys` are read from: `/` unless the
  application env says otherwise, for tests.
  """
  @spec host(Path.t()) :: host()
  def host(root \\ Keyword.get(Application.get_env(:mwt_client, __MODULE__, []), :root, "/")) do
    case module(cpu_flags(root)) do
      nil ->
        :unavailable

      module ->
        # AMD's module says 1, Intel's says Y.
        case File.read(Path.join([root, "sys/module", module, "parameters/nested"])) do
          {:ok, value} -> if String.trim(value) in ["1", "Y"], do: :allowed, else: {:off, module}
          {:error, _not_loaded} -> {:off, module}
        end
    end
  end

  @doc """
  The line that turns nesting on for good on this machine, for `{:off, module}`:
  a file in `/etc/modprobe.d`, read the next time the module loads.
  """
  @spec enable_line(String.t()) :: String.t()
  def enable_line(module), do: "options #{module} nested=1"

  defp module(flags) do
    cond do
      "svm" in flags -> "kvm_amd"
      "vmx" in flags -> "kvm_intel"
      true -> nil
    end
  end

  # Every CPU lists the same flags; the first line is enough.
  defp cpu_flags(root) do
    case File.read(Path.join(root, "proc/cpuinfo")) do
      {:ok, text} ->
        case Regex.run(~r/^flags\s*:(.*)$/m, text) do
          [_line, flags] -> String.split(flags)
          nil -> []
        end

      {:error, _reason} ->
        []
    end
  end
end
