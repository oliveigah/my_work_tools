defmodule MWTClient.Sandbox.Seccomp do
  @moduledoc """
  The seccomp filter every process of a VM's bubble runs under
  (`MWTClient.Sandbox.Bubble`): the relay, `msb` and the VM's own process,
  where libkrun emulates its devices. A VM that broke out into that process
  is still refused, with EPERM, the calls a VMM never makes and kernel
  exploits reach for. That covers mounts and new namespaces, kernel modules
  and kexec, BPF, keyrings, io_uring, userfaultfd, perf events, ptrace,
  reading another process's memory, file handles, and the clock.

  It is a deny list, not an allow list. Nothing in msb, its libkrun or MWT's
  relay makes any of these calls (checked in their sources for 0.7.15:
  only the guest's own agent mounts or changes root, inside the VM, where
  this filter doesn't apply). `mix microsandbox.update` lists every line a
  new release of msb adds that makes one; libkrun, a dependency, it doesn't
  read. An allow list of what a VMM does would break with any msb update
  that makes a new call.

  Nor can anything in the bubble make a user namespace, where it would have
  capabilities again: `unshare` and `setns` are refused, `clone` is refused
  when its flags ask for one, and `clone3`, whose flags are in memory a
  filter can't read, is answered ENOSYS, on which glibc makes the thread or
  process with `clone` instead (as Docker's default profile does). bwrap's
  own `--disable-userns` can't be used: it runs the sandbox in a nested user
  namespace, where the relay's `CAP_NET_ADMIN` no longer reaches the
  network namespace it must add its route to.

  It is a classic BPF program, the form bwrap's `--seccomp FD` reads, as
  libseccomp's `seccomp_export_bpf` writes it. It checks the architecture
  first. A call made through another ABI (32-bit `int 0x80`, x32) is refused
  whatever it is, since its numbers differ and a deny list would miss them.
  """

  import Bitwise

  # x86_64 (asm/unistd_64.h) and arm64 (asm-generic/unistd.h) numbers. A
  # call one architecture lacks is left out of its table.
  @x86_64 %{
    acct: 163,
    add_key: 248,
    bpf: 321,
    chroot: 161,
    clock_adjtime: 305,
    clock_settime: 227,
    create_module: 174,
    delete_module: 176,
    finit_module: 313,
    fsconfig: 431,
    fsmount: 432,
    fsopen: 430,
    fspick: 433,
    get_kernel_syms: 177,
    init_module: 175,
    io_uring_enter: 426,
    io_uring_register: 427,
    io_uring_setup: 425,
    ioperm: 173,
    iopl: 172,
    kcmp: 312,
    kexec_file_load: 320,
    kexec_load: 246,
    keyctl: 250,
    lookup_dcookie: 212,
    mount: 165,
    mount_setattr: 442,
    move_mount: 429,
    name_to_handle_at: 303,
    nfsservctl: 180,
    open_by_handle_at: 304,
    open_tree: 428,
    perf_event_open: 298,
    pivot_root: 155,
    process_vm_readv: 310,
    process_vm_writev: 311,
    ptrace: 101,
    query_module: 178,
    quotactl: 179,
    quotactl_fd: 443,
    reboot: 169,
    request_key: 249,
    setns: 308,
    settimeofday: 164,
    swapoff: 168,
    swapon: 167,
    syslog: 103,
    sysfs: 139,
    _sysctl: 156,
    umount2: 166,
    unshare: 272,
    uselib: 134,
    userfaultfd: 323,
    ustat: 136,
    vhangup: 153
  }

  @aarch64 %{
    acct: 89,
    add_key: 217,
    bpf: 280,
    chroot: 51,
    clock_adjtime: 266,
    clock_settime: 112,
    delete_module: 106,
    finit_module: 273,
    fsconfig: 431,
    fsmount: 432,
    fsopen: 430,
    fspick: 433,
    init_module: 105,
    io_uring_enter: 426,
    io_uring_register: 427,
    io_uring_setup: 425,
    kcmp: 272,
    kexec_file_load: 294,
    kexec_load: 104,
    keyctl: 219,
    lookup_dcookie: 18,
    mount: 40,
    mount_setattr: 442,
    move_mount: 429,
    name_to_handle_at: 264,
    nfsservctl: 42,
    open_by_handle_at: 265,
    open_tree: 428,
    perf_event_open: 241,
    pivot_root: 41,
    process_vm_readv: 270,
    process_vm_writev: 271,
    ptrace: 117,
    quotactl: 60,
    quotactl_fd: 443,
    reboot: 142,
    request_key: 218,
    setns: 268,
    settimeofday: 170,
    swapoff: 225,
    swapon: 224,
    syslog: 116,
    umount2: 39,
    unshare: 97,
    userfaultfd: 282,
    vhangup: 58
  }

  @clone %{x86_64: 56, aarch64: 220}
  @clone3 435
  @clone_newuser 0x10000000

  # struct seccomp_data: the call's number, its architecture, then its
  # arguments, 8 bytes each (the low half first, on these little-endian
  # machines).
  @nr_offset 0
  @arch_offset 4
  @arg0_low 16
  @audit_arch %{x86_64: 0xC000003E, aarch64: 0xC00000B7}
  # x86_64's x32 ABI sets this bit in the call's number.
  @x32_bit 0x40000000

  @bpf_ld_w_abs 0x20
  @bpf_jeq_k 0x15
  @bpf_jge_k 0x35
  @bpf_jset_k 0x45
  @bpf_ret_k 0x06
  @ret_allow 0x7FFF0000
  @ret_eperm 0x00050000 ||| 1
  @ret_enosys 0x00050000 ||| 38

  @type arch :: :x86_64 | :aarch64

  @doc "This machine's architecture, as the filter knows it, or nil when it has none for it."
  @spec arch() :: arch() | nil
  def arch do
    case :erlang.system_info(:system_architecture) |> to_string() do
      "x86_64" <> _ -> :x86_64
      "aarch64" <> _ -> :aarch64
      _other -> nil
    end
  end

  @doc "The calls refused on `arch`, by name."
  @spec denied(arch()) :: [atom()]
  def denied(arch), do: arch |> table() |> Map.keys() |> Enum.sort()

  @doc """
  The filter for `arch` (this machine's unless given), as bwrap reads it, or
  nil for an architecture it has no table for.
  """
  @spec program(arch() | nil) :: binary() | nil
  def program(arch \\ arch())
  def program(nil), do: nil

  def program(arch) do
    abi =
      [
        load(@arch_offset),
        jump(@bpf_jeq_k, @audit_arch[arch], 1, 0),
        ret(@ret_eperm),
        load(@nr_offset)
      ] ++
        if arch == :x86_64,
          do: [jump(@bpf_jge_k, @x32_bit, 0, 1), ret(@ret_eperm)],
          else: []

    # clone3 answered ENOSYS; clone refused with CLONE_NEWUSER, allowed
    # otherwise.
    clones = [
      jump(@bpf_jeq_k, @clone3, 0, 1),
      ret(@ret_enosys),
      jump(@bpf_jeq_k, @clone[arch], 0, 4),
      load(@arg0_low),
      jump(@bpf_jset_k, @clone_newuser, 0, 1),
      ret(@ret_eperm),
      ret(@ret_allow)
    ]

    calls =
      arch
      |> table()
      |> Map.values()
      |> Enum.sort()
      |> Enum.flat_map(&[jump(@bpf_jeq_k, &1, 0, 1), ret(@ret_eperm)])

    IO.iodata_to_binary(abi ++ clones ++ calls ++ [ret(@ret_allow)])
  end

  @doc """
  What `program/1` returns for a call: `:allow`, `:eperm` or `:enosys`, by
  running the program on it (`arch`, `nr` and its first argument as the
  kernel passes them). For tests, and for reading the filter back.
  """
  @spec verdict(binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          :allow | :eperm | :enosys
  def verdict(program, audit_arch, nr, arg0 \\ 0) do
    instructions = for <<code::little-16, jt, jf, k::little-32 <- program>>, do: {code, jt, jf, k}
    data = %{@arch_offset => audit_arch, @nr_offset => nr, @arg0_low => arg0 &&& 0xFFFFFFFF}
    run(List.to_tuple(instructions), 0, 0, data)
  end

  @doc "The number of `clone` on `arch`."
  @spec clone(arch()) :: non_neg_integer()
  def clone(arch), do: Map.fetch!(@clone, arch)

  @doc "The audit architecture the kernel reports for `arch`."
  @spec audit_arch(arch()) :: non_neg_integer()
  def audit_arch(arch), do: Map.fetch!(@audit_arch, arch)

  defp run(program, pc, acc, data) do
    case elem(program, pc) do
      {@bpf_ld_w_abs, _, _, offset} ->
        run(program, pc + 1, Map.fetch!(data, offset), data)

      {@bpf_jeq_k, jt, jf, k} ->
        run(program, pc + 1 + if(acc == k, do: jt, else: jf), acc, data)

      {@bpf_jge_k, jt, jf, k} ->
        run(program, pc + 1 + if(acc >= k, do: jt, else: jf), acc, data)

      {@bpf_jset_k, jt, jf, k} ->
        run(program, pc + 1 + if((acc &&& k) != 0, do: jt, else: jf), acc, data)

      {@bpf_ret_k, _, _, @ret_allow} ->
        :allow

      {@bpf_ret_k, _, _, @ret_eperm} ->
        :eperm

      {@bpf_ret_k, _, _, @ret_enosys} ->
        :enosys
    end
  end

  defp table(:x86_64), do: @x86_64
  defp table(:aarch64), do: @aarch64

  defp load(offset), do: instruction(@bpf_ld_w_abs, 0, 0, offset)
  defp jump(code, k, jt, jf), do: instruction(code, jt, jf, k)
  defp ret(value), do: instruction(@bpf_ret_k, 0, 0, value)

  defp instruction(code, jt, jf, k), do: <<code::little-16, jt, jf, k::little-32>>
end
