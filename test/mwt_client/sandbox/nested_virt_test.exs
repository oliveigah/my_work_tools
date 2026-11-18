defmodule MWTClient.Sandbox.NestedVirtTest do
  # Not async: the tests about refusing point MWT at another machine for a
  # while, through the application env.
  use ExUnit.Case, async: false

  alias MWTClient.NestedVirtHelpers
  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Msb, NestedVirt, Server, Settings}
  alias MWTClient.Vault.Store

  setup do
    root = Path.join(System.tmp_dir!(), "nested-virt-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  describe "what this machine allows" do
    test "an AMD CPU whose KVM was loaded with nesting allows it", %{root: root} do
      assert root |> NestedVirtHelpers.fake_host!(:allowed) |> NestedVirt.host() == :allowed
    end

    test "nesting off in the module is off, with the module to turn it on in", %{root: root} do
      assert root |> NestedVirtHelpers.fake_host!(:off) |> NestedVirt.host() == {:off, "kvm_amd"}
      assert NestedVirt.enable_line("kvm_amd") == "options kvm_amd nested=1"
    end

    test "Intel's module says Y, and a module that isn't loaded is off", %{root: root} do
      NestedVirtHelpers.fake_host!(root, :unavailable)
      File.write!(Path.join(root, "proc/cpuinfo"), "flags\t\t: fpu vmx ept\n")

      assert NestedVirt.host(root) == {:off, "kvm_intel"}

      dir = Path.join(root, "sys/module/kvm_intel/parameters")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "nested"), "Y\n")

      assert NestedVirt.host(root) == :allowed
    end

    test "a CPU without virtualization can't give it, whatever the modules say", %{root: root} do
      # Inside a VM not given it: KVM is built in and says yes, the CPU has
      # neither SVM nor VMX.
      NestedVirtHelpers.fake_host!(root, :unavailable)
      dir = Path.join(root, "sys/module/kvm_amd/parameters")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "nested"), "1\n")

      assert NestedVirt.host(root) == :unavailable
      assert NestedVirt.host(Path.join(root, "nowhere")) == :unavailable
    end
  end

  describe "the setting" do
    test "is off unless turned on, and takes only on or off" do
      assert %Settings{}.nested_virt == false
      assert {:ok, %{nested_virt: true}} = Settings.cast(%Settings{}, %{"nested_virt" => "true"})
      assert {:ok, %{nested_virt: false}} = Settings.cast(%Settings{}, %{"nested_virt" => false})

      assert {:error, %{nested_virt: _}} =
               Settings.cast(%Settings{}, %{"nested_virt" => "yes please"})
    end

    test "on, the VM is created with --nested-virt; off, without" do
      vm = %{
        name: "test",
        image: "box:1",
        shell: "/bin/bash",
        cpus: 4,
        memory_gib: 8,
        disk_gib: 64,
        env: []
      }

      refute "--nested-virt" in Msb.create_args(vm)
      refute "--nested-virt" in Msb.create_args(Map.put(vm, :nested_virt, false))
      assert "--nested-virt" in Msb.create_args(Map.put(vm, :nested_virt, true))
    end
  end

  describe "the VM" do
    setup do
      context = MWTClient.VaultHelpers.unlocked_identity("nested")
      pid = GenServer.whereis(Store.via(Server, context.username))

      # A VM made from today's settings before this one existed: its spec has
      # no word about nesting.
      :sys.replace_state(pid, fn state ->
        spec = %{
          name: state.vm.name,
          image: "box:1",
          shell: "/bin/bash",
          cpus: state.settings.cpus,
          memory_gib: state.settings.memory_gib,
          disk_gib: state.settings.disk_gib,
          mounts: :none
        }

        %{
          state
          | vm: %{state.vm | exists?: true},
            image: %{state.image | tag: "box:1", loaded?: true},
            created_spec: :erlang.phash2(spec)
        }
      end)

      context
    end

    test "made before the setting existed, it isn't stale; turning it on or off is", %{
      username: username
    } do
      refute Sandbox.snapshot(username).vm.stale?

      assert {:ok, _} = Sandbox.update_settings(username, %{"nested_virt" => "true"})
      assert Sandbox.snapshot(username).vm.stale?

      assert {:ok, _} = Sandbox.update_settings(username, %{"nested_virt" => "false"})
      refute Sandbox.snapshot(username).vm.stale?
    end

    test "the pages hear what this machine allows", %{username: username} do
      assert Sandbox.snapshot(username).tools.nested_virt == :allowed
    end

    test "on where this machine doesn't allow it, creating is refused before anything", %{
      username: username,
      root: root
    } do
      saved = Application.get_env(:mwt_client, NestedVirt)
      on_exit(fn -> Application.put_env(:mwt_client, NestedVirt, saved) end)
      Application.put_env(:mwt_client, NestedVirt, root: NestedVirtHelpers.fake_host!(root, :off))

      assert {:ok, _} = Sandbox.update_settings(username, %{"nested_virt" => "true"})

      assert Sandbox.recreate_vm(username) == {:error, {:no_nested_virt, {:off, "kvm_amd"}}}
      assert Sandbox.snapshot(username).vm.busy == nil
    end
  end
end
