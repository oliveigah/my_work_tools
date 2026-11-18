defmodule MWTClient.Sandbox.SeccompTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias MWTClient.Sandbox.Seccomp

  # A few calls every VMM makes, by architecture: read, write, mmap, ioctl
  # (KVM), clone, exit_group, mbind (msb's NUMA placement).
  @made %{
    x86_64: [0, 1, 9, 16, 56, 231, 237],
    aarch64: [63, 64, 222, 29, 220, 94, 235]
  }

  for arch <- [:x86_64, :aarch64] do
    describe "on #{arch}" do
      test "every listed call is refused, and what a VMM makes is allowed" do
        arch = unquote(arch)
        program = Seccomp.program(arch)
        audit = Seccomp.audit_arch(arch)

        # mount, unshare, setns and bpf are among the refused, on both.
        assert [:bpf, :mount, :setns, :unshare] -- Seccomp.denied(arch) == []

        numbers = %{
          x86_64: %{mount: 165, unshare: 272, setns: 308, bpf: 321, keyctl: 250},
          aarch64: %{mount: 40, unshare: 97, setns: 268, bpf: 280, keyctl: 219}
        }

        for {_name, nr} <- numbers[arch],
            do: assert(Seccomp.verdict(program, audit, nr) == :eperm)

        for nr <- @made[arch], do: assert(Seccomp.verdict(program, audit, nr) == :allow)
      end

      test "a call through another ABI is refused, whatever it is" do
        program = Seccomp.program(unquote(arch))

        # i386 (int 0x80 on x86_64) and arm (32-bit), with read's number.
        for other <- [0x40000003, 0x40000028] do
          assert Seccomp.verdict(program, other, 3) == :eperm
        end
      end
    end
  end

  for arch <- [:x86_64, :aarch64] do
    test "on #{arch}, no user namespace: clone asking for one is refused, clone3 sends glibc to clone" do
      arch = unquote(arch)
      program = Seccomp.program(arch)
      audit = Seccomp.audit_arch(arch)
      clone = Seccomp.clone(arch)

      # A thread (CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND |
      # CLONE_THREAD …), a fork (SIGCHLD), and one with CLONE_NEWUSER.
      assert Seccomp.verdict(program, audit, clone, 0x3D0F00) == :allow
      assert Seccomp.verdict(program, audit, clone, 17) == :allow
      assert Seccomp.verdict(program, audit, clone, 0x10000000 ||| 17) == :eperm
      assert Seccomp.verdict(program, audit, 435) == :enosys
    end
  end

  test "x86_64's x32 calls are refused: their numbers would miss the list" do
    program = Seccomp.program(:x86_64)
    audit = Seccomp.audit_arch(:x86_64)

    # mount and read, with x32's bit.
    assert Seccomp.verdict(program, audit, 0x40000000 + 165) == :eperm
    assert Seccomp.verdict(program, audit, 0x40000000 + 0) == :eperm
  end

  test "an architecture with no table gets no filter" do
    assert Seccomp.program(nil) == nil
  end
end
