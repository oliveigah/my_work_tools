defmodule MWTClient.Sandbox.LayerVersions do
  @moduledoc """
  Your layer of the VM's image (`MWTClient.Sandbox.Settings.image_layer`)
  as saved, and what it held before each save, so a change you regret is
  undone by restoring a version, as a note's is: the same versions
  (`MWTClient.Versions`), of the kind `"image_layers"`, one item, kept by
  the `image_layer_versions` retention rule.

  Every save keeps the layer it replaced. Notes keep one per 10 minutes of
  your editing because they save as you type; the layer saves only when
  you say so, so each `change/5` opens the versions afresh, and the rule
  always keeps. A save that changes nothing keeps nothing.

  Before 2026-11-24 the recipe was a whole Containerfile, its `FROM`
  included; since then MWT keeps the base. `upgrade/3` keeps such a recipe
  as a version, replaced by MWT (`:mwt`), and starts you on MWT's default
  layer, which the build page says until you save (`upgraded?/2`).

  Called from the sandbox's process, the only one that changes settings.
  """

  alias MWTClient.Sandbox.{Image, Settings}
  alias MWTClient.Versions
  alias MWTClient.Versions.Version

  @kind "image_layers"
  @item "layer"

  @doc "The versions kept of your layer, the newest first."
  @spec list(String.t()) :: [Version.t()]
  def list(username), do: username |> Versions.open(@kind) |> Versions.list(@item)

  @doc "The version numbered `number` of your layer."
  @spec fetch(String.t(), integer()) :: {:ok, Version.t()} | :error
  def fetch(username, number),
    do: username |> Versions.open(@kind) |> Versions.fetch(@item, number)

  @doc "The text a version of your layer held."
  @spec text(Version.t()) :: String.t()
  def text(%Version{content: %{text: text}}) when is_binary(text), do: text
  def text(%Version{}), do: ""

  @doc """
  `after` once its layer is saved: when the layer changed from `before`'s,
  `before`'s is kept as a version, made `by` someone, `how` (`:edit`, or
  `:restore` of an earlier one), and `after` gets the next number and
  `now` as when it was saved.
  """
  @spec change(String.t(), Settings.t(), Settings.t(), Versions.by(), :edit | :restore) ::
          Settings.t()
  def change(username, %Settings{} = before, %Settings{} = settings, by, how) do
    if before.image_layer == settings.image_layer do
      %{settings | image_layer_version: before.image_layer_version}
    else
      username
      |> Versions.open(@kind)
      |> Versions.changed(@item, kept(before), by, how)

      %{
        settings
        | image_layer_version: before.image_layer_version + 1,
          image_layer_saved_at: DateTime.utc_now()
      }
    end
  end

  @doc """
  The settings, with a recipe from before MWT kept the base (`old`, a
  whole Containerfile) kept as a version and replaced by MWT's default
  layer. Settings without one stay as they are.
  """
  @spec upgrade(String.t(), Settings.t(), String.t() | nil) :: Settings.t()
  def upgrade(username, %Settings{} = settings, old) when is_binary(old) do
    if Image.whole_containerfile?(old) do
      change(username, %{settings | image_layer: old}, settings, :mwt, :edit)
    else
      settings
    end
  end

  def upgrade(_username, %Settings{} = settings, _old), do: settings

  @doc """
  Whether your layer is still the default MWT started you on when it took
  your whole Containerfile (`upgrade/3`): the newest version is that one,
  and nothing was saved since.
  """
  @spec upgraded?(Settings.t(), [Version.t()]) :: boolean()
  def upgraded?(%Settings{} = settings, [%Version{replaced_by: :mwt} = newest | _older]),
    do: settings.image_layer_version == newest.version + 1

  def upgraded?(%Settings{}, _versions), do: false

  defp kept(%Settings{} = settings) do
    %{
      version: settings.image_layer_version,
      content: %{text: settings.image_layer},
      saved_at: settings.image_layer_saved_at || DateTime.utc_now()
    }
  end
end
