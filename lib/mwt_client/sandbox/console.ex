defmodule MWTClient.Sandbox.Console do
  @moduledoc """
  The VM console: a command you type, run in the VM as an agent there runs
  one, so you see what the VM would see. It goes into the running VM
  (`MWTClient.Sandbox.Guest`'s `run`, `msb exec`), as the user agents run
  as, in `/work`, in a login shell, its errors with its output, as a
  terminal shows them; with a credential, under `mwt exec CREDENTIAL`, as
  an agent runs one with it. What it reaches goes through MWT as any agent's
  request does: the grants decide, and the activity log records it.

  It is a command of yours: nothing asks you about it. What it prints is
  the VM's to decide, so it is taken as text, at most `max_output/0` bytes
  of it, and the command is stopped after its time (`seconds`, at most
  `max_seconds/0`). One runs at a time, from the page that started it.
  """

  @max_output 256 * 1024
  @max_seconds 300
  @max_command 16 * 1024

  @typedoc """
  What a run gave: the folder it started in (nil for `/work`) and the one
  its shell ended in (nil when unknown), its exit status (nil when it
  didn't end by itself), its
  output with its errors, whether that was cut at `max_output/0`, whether
  its time ran out, and when it started and ended.
  """
  @type result :: %{
          command: String.t(),
          credential: String.t() | nil,
          dir: String.t() | nil,
          cwd: String.t() | nil,
          status: non_neg_integer() | nil,
          output: String.t(),
          cut: boolean(),
          timed_out: boolean(),
          started_at: DateTime.t(),
          finished_at: DateTime.t()
        }

  @doc "The most output a run keeps, in bytes."
  def max_output, do: @max_output

  @doc "The longest a run may take, in seconds."
  def max_seconds, do: @max_seconds

  @doc """
  Runs `command` in `guest`, under `credential` when one is named, for at
  most `seconds`: `{:ok, result}`, or why it didn't run.
  """
  @spec run(map(), String.t(), String.t() | nil, pos_integer(), String.t() | nil) ::
          {:ok, result()} | {:error, String.t()}
  def run(guest, command, credential, seconds \\ 60, dir \\ nil) do
    with {:ok, command} <- command(command),
         {:ok, credential} <- credential(credential),
         {:ok, dir} <- dir(dir) do
      seconds = seconds |> max(1) |> min(@max_seconds)
      started_at = DateTime.utc_now()

      base = %{
        command: command,
        credential: credential,
        dir: dir,
        cwd: nil,
        status: nil,
        output: "",
        cut: false,
        timed_out: false,
        started_at: started_at
      }

      result =
        case guest.run.(["bash", "-lc", script(command, credential, dir)], seconds, @max_output) do
          {:ok, output, status} ->
            {output, cwd} = ended_in(output)
            %{base | status: status, output: shown(output), cwd: cwd}

          {:error, {:too_long, head}} ->
            %{base | output: shown(head), cut: true}

          {:error, :timeout} ->
            %{base | timed_out: true}

          {:error, message} when is_binary(message) ->
            {:error, message}

          {:error, other} ->
            {:error, inspect(other)}
        end

      case result do
        {:error, message} -> {:error, message}
        result -> {:ok, Map.put(result, :finished_at, DateTime.utc_now())}
      end
    end
  end

  # The folder the shell ended in, which the script prints last after a
  # mark of its own (`script/3`), taken off what the command printed. Nil
  # when it isn't there: the command replaced the shell, or was cut.
  defp ended_in(output) do
    case Regex.run(~r/\x1e([^\x1e\n]*)\z/, output, return: :index) do
      [{at, _length}, {path_at, path_length}] ->
        {binary_part(output, 0, at), binary_part(output, path_at, path_length)}

      nil ->
        {output, nil}
    end
  end

  @doc """
  What the VM printed, as a terminal shows it: a line a carriage return
  went back over keeps what was written last (a progress bar shows where
  it ended), colours stay (`ESC[…m`, which `MWTClientWeb.Ansi` draws),
  other escapes go, and anything else that doesn't show is written out
  (`MWTClient.Sandbox.Shown`).

      iex> MWTClient.Sandbox.Console.shown("10%\\r50%\\r100%\\n\\e[32mok\\e[0m \\e[2Kdone\\e]0;title\\a")
      "100%\\n\\e[32mok\\e[0m done"
  """
  @spec shown(String.t()) :: String.t()
  def shown(output) do
    output
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> line |> String.split("\r") |> List.last() end)
    # Window titles and the like (OSC), then every escape but colours.
    |> String.replace(~r/\e\][^\a\e]*(\a|\e\\\\)/, "")
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-ln-~]/, "")
    |> String.split(~r/(\e\[[0-9;]*m)/, include_captures: true)
    |> Enum.map_join(fn piece ->
      if piece =~ ~r/\A\e\[[0-9;]*m\z/, do: piece, else: MWTClient.Sandbox.Shown.text(piece)
    end)
  end

  @doc """
  A run, in a line for the activity log: the command, who it spoke as, how
  it ended. Never its output.

      iex> MWTClient.Sandbox.Console.summary(%{command: "gh repo view o/r", credential: "github",
      ...>   status: 0, timed_out: false, cut: false})
      "You ran in the VM, as github: gh repo view o/r (exit 0)"
      iex> MWTClient.Sandbox.Console.summary(%{command: "sleep 99", credential: nil,
      ...>   status: nil, timed_out: false, cut: false, stopped: true})
      "You ran in the VM: sleep 99 (stopped from MWT)"
  """
  @spec summary(map()) :: String.t()
  def summary(result) do
    as = if result.credential, do: ", as #{result.credential}", else: ""

    ending =
      cond do
        Map.get(result, :stopped, false) -> "stopped from MWT"
        result.timed_out -> "stopped: out of time"
        result.cut -> "stopped: too much output"
        true -> "exit #{result.status}"
      end

    command = result.command |> String.replace(~r/\s+/, " ") |> String.slice(0, 160)
    "You ran in the VM#{as}: #{command} (#{ending})"
  end

  @doc """
  An HTTP request as the command that sends it: `curl -sS -i`, its method,
  each header, its body and its URL, each quoted. With a credential,
  its `Authorization` (or what its service expects, `request_headers`)
  is taken from the credential's token file, unless a header you give
  already says it.

      iex> MWTClient.Sandbox.Console.http_command(%{"method" => "GET",
      ...>   "url" => "https://api.github.com/user", "headers" => "", "body" => ""},
      ...>   %{id: "github", request_headers: "Authorization: Bearer {token}\\nAccept: application/json"})
      ~s{curl -sS -i -X GET -H "Authorization: Bearer $(cat /mnt/mwt/tokens/github)" -H 'Accept: application/json' 'https://api.github.com/user'}
  """
  @spec http_command(map(), map() | nil) :: String.t()
  def http_command(request, credential) do
    method =
      request["method"]
      |> to_string()
      |> String.upcase()
      |> then(&if(&1 == "", do: "GET", else: &1))

    given = lines(request["headers"])

    named =
      MapSet.new(given, fn line ->
        line |> String.split(":", parts: 2) |> hd() |> String.downcase() |> String.trim()
      end)

    from_credential =
      case credential do
        nil ->
          []

        %{id: id} = credential ->
          (Map.get(credential, :request_headers) || "Authorization: Bearer {token}")
          |> lines()
          |> Enum.reject(fn line ->
            MapSet.member?(
              named,
              line |> String.split(":", parts: 2) |> hd() |> String.downcase() |> String.trim()
            )
          end)
          |> Enum.map(fn line ->
            if String.contains?(line, "{token}"),
              do:
                ~s(-H ") <>
                  String.replace(line, "{token}", "$(cat /mnt/mwt/tokens/#{id})") <> ~s("),
              else: "-H " <> shell_quote(line)
          end)
      end

    body = request["body"] |> to_string()

    (["curl -sS -i -X #{shell_quote_word(method)}"] ++
       from_credential ++
       Enum.map(given, &("-H " <> shell_quote(&1))) ++
       if(String.trim(body) == "", do: [], else: ["--data-binary " <> shell_quote(body)]) ++
       [shell_quote(String.trim(to_string(request["url"])))])
    |> Enum.join(" ")
  end

  defp lines(text),
    do:
      text
      |> to_string()
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  # A method is a word: one that isn't is quoted as any value.
  defp shell_quote_word(word),
    do: if(word =~ ~r/\A[A-Z]+\z/, do: word, else: shell_quote(word))

  @doc """
  The script that runs `command` in the VM: in `dir`, or `/work` (home
  when there is neither), its errors with its output, under `mwt exec
  CREDENTIAL` when one is named. As the shell ends it prints the folder
  it is in after a mark (`\\x1e`), for a terminal to start the next
  command there (`run/5`).

      iex> alias MWTClient.Sandbox.Console
      iex> Console.script("gh repo view o/r", "github") |> String.split("\\n", trim: true)
      ["cd /work 2>/dev/null || cd", "exec 2>&1", ~S(trap 'printf "\\036%s" "$PWD"' EXIT),
       "mwt exec 'github' -- bash -c 'gh repo view o/r'"]
      iex> Console.script("ls", nil, "/work/klife") |> String.split("\\n", trim: true) |> hd()
      "cd -- '/work/klife' 2>/dev/null || cd /work 2>/dev/null || cd"
  """
  @spec script(String.t(), String.t() | nil, String.t() | nil) :: String.t()
  def script(command, credential, dir \\ nil) do
    start =
      case dir do
        nil -> "cd /work 2>/dev/null || cd"
        dir -> "cd -- #{shell_quote(dir)} 2>/dev/null || cd /work 2>/dev/null || cd"
      end

    run =
      case credential do
        nil -> command
        credential -> "mwt exec #{shell_quote(credential)} -- bash -c #{shell_quote(command)}"
      end

    "#{start}\nexec 2>&1\ntrap 'printf \"\\036%s\" \"$PWD\"' EXIT\n#{run}\n"
  end

  defp shell_quote(text), do: "'" <> String.replace(text, "'", ~S('\'')) <> "'"

  defp command(command) do
    command = command |> to_string() |> String.replace("\r\n", "\n") |> String.trim()

    cond do
      command == "" -> {:error, "Type a command."}
      byte_size(command) > @max_command -> {:error, "That command is over 16 KiB."}
      true -> {:ok, command}
    end
  end

  # A folder to start in: none, or an absolute path of one line.
  defp dir(nil), do: {:ok, nil}
  defp dir(""), do: {:ok, nil}

  defp dir(dir) when is_binary(dir) do
    if String.starts_with?(dir, "/") and not String.contains?(dir, ["\n", "\r", <<0>>]) and
         byte_size(dir) <= 4096,
       do: {:ok, dir},
       else: {:error, "That folder can't be started in."}
  end

  # A credential's id, as `mwt exec` takes it: none, or one made as ids are.
  defp credential(nil), do: {:ok, nil}
  defp credential(""), do: {:ok, nil}

  defp credential(id) when is_binary(id) do
    if id =~ ~r/\A[a-z0-9][a-z0-9_.-]{0,80}\z/,
      do: {:ok, id},
      else: {:error, "No credential is called that."}
  end
end
