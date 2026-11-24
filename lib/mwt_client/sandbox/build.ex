defmodule MWTClient.Sandbox.Build do
  @moduledoc """
  One built image: what went in and what came out.

  `ref` is what microsandbox knows it by, `name:tag`. `containerfile` is
  what podman built, kept as it was, MWT's parts included
  (`MWTClient.Sandbox.Image.full/1`), since rebuilding it later gives other
  versions: going back means using the build, not the recipe. `layer` is
  your layer it came from; nil for a build from before MWT kept the base
  (2026-11-24), whose `containerfile` was your whole recipe.
  """

  @enforce_keys [:ref, :name, :tag, :built_at]
  defstruct [:ref, :name, :tag, :built_at, :layer, containerfile: "", versions: "", size: nil]

  @type t :: %__MODULE__{
          ref: String.t(),
          name: String.t(),
          tag: String.t(),
          built_at: DateTime.t(),
          containerfile: String.t(),
          layer: String.t() | nil,
          versions: String.t(),
          size: non_neg_integer() | nil
        }
end
