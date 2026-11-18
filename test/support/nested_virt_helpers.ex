defmodule MWTClient.NestedVirtHelpers do
  @moduledoc """
  A machine's CPU and KVM as `MWTClient.Sandbox.NestedVirt` reads them, in a
  folder of their own: `/proc/cpuinfo` and `/sys/module/*/parameters/nested`.
  Tests read one of these instead of the machine they run on, so they behave
  the same on yours and in a VM.
  """

  @doc """
  Writes a machine of `kind` under `root`, replacing what was there:

    * `:allowed` - an AMD CPU with SVM, `kvm_amd` loaded with nesting;
    * `:off` - the same CPU, `kvm_amd` loaded without it;
    * `:unavailable` - a CPU without SVM or VMX, as in a VM not given it.
  """
  @spec fake_host!(Path.t(), :allowed | :off | :unavailable) :: Path.t()
  def fake_host!(root, kind) do
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "proc"))

    flags = if kind == :unavailable, do: "fpu sse2 hypervisor", else: "fpu sse2 svm npt"
    File.write!(Path.join(root, "proc/cpuinfo"), "processor\t: 0\nflags\t\t: #{flags}\n")

    if kind in [:allowed, :off] do
      dir = Path.join(root, "sys/module/kvm_amd/parameters")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "nested"), if(kind == :allowed, do: "1\n", else: "0\n"))
    end

    root
  end
end
