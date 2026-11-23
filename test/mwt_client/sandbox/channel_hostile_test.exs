defmodule MWTClient.Sandbox.ChannelHostileTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Channel, Server}
  alias MWTClient.Vault.Store

  @source Path.expand("../../../lib/mwt_client/sandbox/channel.ex", __DIR__)

  @huge String.duplicate("a", 20_000)
  @hidden <<0, 27, "[2J", 0x202E::utf8, 0x200B::utf8, "\r\n">>

  # What a field may hold once `Channel.read/1` has taken an ask's line.
  @kinds [
    nil,
    0,
    -1,
    4_611_686_018_427_387_904,
    true,
    "",
    @huge,
    @hidden,
    "../../../../etc/passwd",
    "/",
    [],
    List.duplicate(@hidden, 40),
    [@huge],
    [1, nil, %{}],
    %{"a" => @hidden},
    %{"nested" => %{"deep" => [1, 2]}}
  ]

  setup do
    share = Path.join(System.tmp_dir!(), "hostile-share-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(share, "project"))
    on_exit(fn -> MWTClient.TestFolders.remove!(share) end)
    identity = MWTClient.VaultHelpers.unlocked_identity("hostile-channel")
    {:ok, _} = MWTClient.Sandbox.add_share(identity.username, share)

    {:ok, _token} =
      MWTClient.Sandbox.create_grant(identity.username, %{
        "kind" => "token",
        "name" => "API",
        "purpose" => "An API",
        "hosts" => "api.example.com",
        "env" => "API_TOKEN",
        "value" => "real-value-of-the-api"
      })

    Map.put(identity, :share, share)
  end

  # An ask of each shape the `mwt` command sends, as it sends it: each
  # reaches as far into MWT as a well-formed one goes.
  defp bases(share) do
    dir = Path.join(share, "project")
    me = %{"agent" => "claude", "thread" => "a task", "thread_id" => "thread-1", "folder" => dir}
    head = String.duplicate("a", 40)

    [
      {"grants", %{}},
      {"host", %{}},
      {"why", %{"target" => "api.example.com:443"}},
      {"ports", %{"report" => "tcp 0.0.0.0:4100\n"}},
      {"sync", %{"path" => share}},
      {"project", Map.put(me, "cwd", dir)},
      {"worktree",
       Map.merge(me, %{"action" => "new", "cwd" => dir, "name" => "t", "from" => "main"})},
      {"worktree", Map.merge(me, %{"action" => "free", "cwd" => dir})},
      {"handoff",
       Map.merge(me, %{"stage" => "prepare", "cwd" => dir, "title" => "t", "onto" => "main"})},
      {"handoff", Map.merge(me, %{"stage" => "withdraw", "cwd" => dir, "reason" => "r"})},
      {"handoff",
       Map.merge(me, %{
         "cwd" => dir,
         "head" => head,
         "title" => "t",
         "body" => "b",
         "onto" => "main"
       })},
      {"handoffs", %{"cwd" => dir}},
      {"call",
       Map.merge(me, %{
         "grant" => "x",
         "values" => %{"A" => "b"},
         "timeout" => 10,
         "reason" => "r"
       })},
      {"run",
       Map.merge(me, %{
         "grant" => "commands",
         "script" => "echo a",
         "dir" => dir,
         "timeout" => 10,
         "reason" => "r"
       })},
      {"request",
       Map.merge(me, %{"grant" => "internet", "need" => "", "reason" => "r", "minutes" => 10})},
      {"request", Map.merge(me, %{"need" => "a database", "reason" => "r", "minutes" => 10})},
      {"propose",
       Map.merge(me, %{
         "grant" => "commands",
         "name" => "x",
         "for" => "y",
         "script" => ~s(echo "$A"),
         "params" => ["A:word:a"],
         "dir" => dir,
         "reason" => "r"
       })},
      {"propose",
       Map.merge(me, %{
         "grant" => "token",
         "name" => "API two",
         "for" => "y",
         "hosts" => ["api.example.com"],
         "env" => ["API_TWO"],
         "mint" => "echo v",
         "reason" => "r"
       })},
      {"propose",
       Map.merge(me, %{
         "grant" => "network",
         "name" => "DB",
         "for" => "y",
         "destinations" => ["10.0.0.5:5432"],
         "resolver" => "10.0.0.1",
         "reason" => "r"
       })},
      {"propose",
       Map.merge(me, %{
         "grant" => "api",
         "name" => "get",
         "for" => "y",
         "method" => "GET",
         "url" => "https://api.example.com/x/$A",
         "params" => ["A:word:a"],
         "reason" => "r"
       })},
      {"wait", %{"id" => "run-1"}},
      {"wait", %{"id" => "ask-1"}},
      {"vm", %{"id" => "abc"}}
    ]
  end

  test "its commands are those `reply/3` answers" do
    replied =
      ~r/^  defp reply\("([a-z]+)"/m
      |> Regex.scan(File.read!(@source), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert Enum.sort(replied) == Enum.sort(Channel.commands())
  end

  # A failure of the server would put each grant back in its start setting
  # if nothing kept them (`MWTClient.Sandbox.UnlockState`), and loses what
  # waits for you: no ask may make it fail.
  test "no command, whatever its fields hold, makes the sandbox's server fail",
       %{username: username} = context do
    server = Store.whereis(Server, username)

    bases = bases(context.share)

    assert bases |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(Channel.commands())

    asks =
      for {command, base} <- bases,
          field <- Map.keys(base),
          kind <- [:missing | @kinds],
          do: {command, {field, kind}, line(command, corrupt(base, field, kind), 0)}

    asks = asks ++ for({command, base} <- bases, do: {command, :as_sent, line(command, base, 0)})

    waits =
      for {command, base} <- bases,
          wait <- [-1, 4_611_686_018_427_387_904, "60", @hidden],
          do: {command, {"wait", wait}, line(command, base, wait)}

    failed =
      (asks ++ waits)
      |> Task.async_stream(&answered(&1, username),
        max_concurrency: 32,
        timeout: 1_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(asks ++ waits)
      |> Enum.flat_map(fn
        {{:ok, :answered}, _case} -> []
        # Still waiting for you, as an ask that waits does: not a failure.
        {{:exit, :timeout}, _case} -> []
        {{:ok, failure}, {command, how, _line}} -> [{command, short(how), failure}]
      end)

    assert failed == []
    assert Store.whereis(Server, username) == server
    assert Process.alive?(server)
  end

  defp corrupt(base, field, :missing), do: Map.delete(base, field)
  defp corrupt(base, field, kind), do: Map.put(base, field, kind)

  defp line(command, fields, wait),
    do: fields |> Map.merge(%{"command" => command, "wait" => wait}) |> Jason.encode!()

  defp answered({command, _kind, line}, username) do
    case Channel.read(line) do
      %{} = ask ->
        _ = Channel.answer(command, ask, username)
        :answered

      :unreadable ->
        {:unreadable, line}
    end
  rescue
    error -> {:raised, Exception.format_banner(:error, error, __STACKTRACE__)}
  catch
    :exit, reason -> {:exit, reason |> inspect() |> String.slice(0, 300)}
  end

  defp short({field, kind}), do: {field, short(kind)}
  defp short(kind) when is_binary(kind), do: String.slice(kind, 0, 20)
  defp short(kind) when is_list(kind), do: {:list, length(kind)}
  defp short(kind), do: kind
end
