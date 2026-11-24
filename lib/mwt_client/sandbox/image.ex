defmodule MWTClient.Sandbox.Image do
  @moduledoc """
  The VM image, in three parts, built with podman and handed to
  microsandbox:

    1. **MWT's base** (`base/0`): Ubuntu, with what MWT itself runs in the
       VM. MWT keeps it; it changes with MWT, never with you.
    2. **Your layer** (`Settings.image_layer`): the VM's tools, yours to
       edit, starting from MWT's default (`default_layer/0`). No `FROM`:
       it comes after the base (`layer_problem/1`).
    3. **MWT's final layer** (`final_layer/0`): checks that what MWT runs
       is still there, points the VM at `/mnt/mwt` and `/cache`, and lists
       the checksum of every file, which the VM's image check reads
       (`MWTClient.Sandbox.ImageCheck`).

  What podman builds is the three in that order (`full/1`): the build page
  shows it, and each build keeps it.

  MWT's layers hold only pointers into `/mnt/mwt` and `/cache`, so nothing
  in the image belongs to one identity: the CA, the credential helper and
  the agents' instructions arrive when the VM is created. Updates to those
  files need no rebuild; changing the layers' startup wiring does.

  Each build gets a tag of its date and number (`2026-11-12.1`) under the
  image name from the settings. MWT keeps as many as the `vm_images`
  retention rule says, the current build and the two before it at first
  (`keep/3`, `MWTClient.Storage.Retention`).

  The build runs on this machine in a rootless podman container, which
  isolates it less than the VM does: install scripts in your layer run
  there. Keep what it installs to what you trust.
  """

  alias MWTClient.Sandbox.{Build, Msb}

  @default_name "mwt_agent_sdb_image"
  @kept 3

  @doc "The image name a new sandbox starts with."
  @spec default_name() :: String.t()
  def default_name, do: @default_name

  @doc "MWT's base: the first part of every build, MWT's own."
  @spec base() :: String.t()
  def base, do: File.read!(priv("mwt-base.Containerfile"))

  @doc "The layer a new sandbox starts with, and *Start from MWT's default* gives."
  @spec default_layer() :: String.t()
  def default_layer, do: File.read!(priv("your-layer.Containerfile"))

  @doc "MWT's final layer: the last part of every build, MWT's own."
  @spec final_layer() :: String.t()
  def final_layer, do: File.read!(priv("mwt-final-layer.Containerfile"))

  @your_layer "# ---- Your layer: yours to edit, on MWT's build page. ----"

  @doc """
  The three parts of what podman builds from `layer`, in order, each
  starting with a line that says whose it is: `:base` and `:final`, MWT's,
  and `:yours`.
  """
  @spec parts(String.t()) :: [{:base | :yours | :final, String.t()}]
  def parts(layer) do
    [
      base: String.trim(base()),
      yours: @your_layer <> "\n" <> String.trim(layer),
      final: String.trim(final_layer())
    ]
  end

  @doc "What podman builds from `layer`: its parts (`parts/1`), a blank line between them."
  @spec full(String.t()) :: String.t()
  def full(layer), do: Enum.map_join(parts(layer), "\n\n", &elem(&1, 1)) <> "\n"

  @doc """
  What keeps `layer` from being built, or nil. Your layer comes after
  MWT's base, so it has no `FROM`: one would start an image of its own,
  without what MWT runs in the VM.

      iex> MWTClient.Sandbox.Image.layer_problem("RUN apt-get install -y htop")
      nil
      iex> MWTClient.Sandbox.Image.layer_problem("FROM ubuntu:26.04\\nRUN true") =~ "FROM"
      true
  """
  @spec layer_problem(String.t()) :: String.t() | nil
  def layer_problem(layer) do
    if whole_containerfile?(layer),
      do:
        "Your layer comes after MWT's base, so it has no FROM line: remove it, " <>
          "or start from MWT's default."
  end

  @doc """
  Whether `text` is a whole Containerfile, with its own `FROM`: what a
  recipe was before MWT kept the base (2026-11-24).
  """
  @spec whole_containerfile?(String.t()) :: boolean()
  def whole_containerfile?(text), do: Regex.match?(~r/^\s*FROM\s+\S+/mi, text)

  @doc """
  Whether `name` can name an image: lowercase letters and digits, joined by
  single `.`, `_`, `__` or runs of `-`, as OCI references allow.
  """
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name),
    do: byte_size(name) <= 128 and Regex.match?(~r/^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*$/, name)

  @doc """
  The tag the next build of `name` gets on `date`: the date, then one more
  than the highest number that day among `builds`.

      iex> MWTClient.Sandbox.Image.next_tag("box", ~D[2026-11-12], [])
      "2026-11-12.1"
  """
  @spec next_tag(String.t(), Date.t(), [Build.t()]) :: String.t()
  def next_tag(name, date, builds) do
    day = Date.to_iso8601(date)

    highest =
      builds
      |> Enum.filter(&(&1.name == name))
      |> Enum.flat_map(fn build ->
        case String.split(build.tag, ".", parts: 2) do
          [^day, number] ->
            case Integer.parse(number) do
              {n, ""} -> [n]
              _ -> []
            end

          _ ->
            []
        end
      end)
      |> Enum.max(fn -> 0 end)

    "#{day}.#{highest + 1}"
  end

  @doc """
  Splits `builds` (newest first) into those kept and those to delete: the
  newest #{@kept}, plus any whose ref is in `protected` (the VM's), which is
  never deleted while in use.
  """
  @spec keep([Build.t()], [String.t()], pos_integer()) :: {[Build.t()], [Build.t()]}
  def keep(builds, protected, count \\ @kept) do
    {newest, older} =
      builds |> Enum.sort_by(& &1.built_at, {:desc, DateTime}) |> Enum.split(count)

    {still_used, removed} = Enum.split_with(older, &(&1.ref in protected))
    {newest ++ still_used, removed}
  end

  @doc "Writes the build context into `dir`, replacing what was there: `full`, what podman builds."
  @spec write_context(Path.t(), String.t()) :: :ok
  def write_context(dir, full) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "Containerfile"), full)
  end

  @doc """
  The shell script that builds `ref` from `dir` and loads it into
  microsandbox. It leaves `versions.txt` (what mise installed) and `size` in
  `dir`, read without running anything from the image. Paths are quoted, so
  spaces in a home folder are fine. It runs with `Msb.env/1`: the image is
  loaded by the confined msb (`MWT_MSB`, `Msb.confined/1`), allowed to read
  the archive and nothing else of this machine.

  `cache: false` builds every step again and pulls the base image afresh,
  for when a build may hold something damaged or stale: podman otherwise
  reuses every step whose text and parent haven't changed.
  """
  @spec build_script(Path.t(), String.t(), keyword()) :: String.t()
  def build_script(dir, ref, opts \\ []) do
    archive = Path.join(dir, "image.tar")
    q = &shell_quote/1

    cache =
      if Keyword.get(opts, :cache, true), do: "--pull=newer", else: "--pull=always --no-cache"

    """
    set -euo pipefail
    echo "==> podman build #{ref}#{if cache =~ "no-cache", do: " (without podman's cache)", else: ""}"
    podman build --format docker #{cache} --tag #{q.(ref)} --file #{q.(Path.join(dir, "Containerfile"))} #{q.(dir)}
    container=$(podman create #{q.(ref)})
    podman cp "$container:/etc/mwt/versions.txt" #{q.(Path.join(dir, "versions.txt"))} || true
    podman rm "$container" >/dev/null
    podman image inspect --format '{{.Size}}' #{q.(ref)} > #{q.(Path.join(dir, "size"))}
    echo "==> handing the image to microsandbox"
    rm -f #{q.(archive)}
    podman save --format docker-archive --output #{q.(archive)} #{q.(ref)}
    MWT_MSB_READ=#{q.(archive)} "$MWT_MSB" load --input #{q.(archive)} --tag #{q.(ref)}
    rm -f #{q.(archive)}
    echo "==> ready: #{ref}"
    """
  end

  @doc "Reads what a finished build left in `dir` into a `Build`."
  @spec read_build(Path.t(), map()) :: Build.t()
  def read_build(dir, %{name: name, tag: tag, layer: layer, built_at: built_at} = building) do
    versions =
      case File.read(Path.join(dir, "versions.txt")) do
        {:ok, text} -> String.slice(text, 0, 20_000)
        {:error, _} -> ""
      end

    size =
      with {:ok, text} <- File.read(Path.join(dir, "size")),
           {size, _} <- Integer.parse(String.trim(text)) do
        size
      else
        _ -> nil
      end

    %Build{
      ref: "#{name}:#{tag}",
      name: name,
      tag: tag,
      built_at: built_at,
      containerfile: building.containerfile,
      layer: layer,
      versions: versions,
      size: size
    }
  end

  @doc """
  Deletes a build's image from microsandbox and podman. Loading a podman
  archive also names it `localhost/<ref>` in microsandbox, so both names go.
  Failures are ignored.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(username, ref) do
    _ = Msb.run(username, ["image", "remove", ref, "localhost/" <> ref], 60)

    if podman?() do
      MWTClient.Executable.cmd("podman", ["rmi", "--ignore", ref], stderr_to_stdout: true)
    end

    :ok
  end

  @doc "Whether podman, which builds the image, is installed."
  @spec podman?() :: boolean()
  def podman?, do: MWTClient.Executable.find("podman") != nil

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp priv(name), do: Path.join([:code.priv_dir(:mwt_client), "sandbox", name])
end
