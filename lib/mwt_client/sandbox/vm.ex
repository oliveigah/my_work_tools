defmodule MWTClient.Sandbox.VM do
  @moduledoc """
  The VM's state as the control panel shows it.

  `exists?` says whether microsandbox has the VM at all; a VM is only
  created once its image is built. `stale?` is set when settings changed after
  the VM was created, so it runs with the old ones until it is recreated.
  `error` is the last thing `msb` refused, in its own words.

  `record` is which VM this is: the id MWT gave it when it created it, when
  that was, and the image it was made from. The boot script writes the same
  into the VM (`/etc/mwt-vm`), and `mwt vm` in there compares the two, so
  a connection to any other VM says so. A VM made before MWT kept records
  gets one at its next start, with no `created_at`.
  """

  defstruct name: "agentbox",
            status: :stopped,
            started_at: nil,
            exists?: false,
            stale?: false,
            busy: nil,
            error: nil,
            msb: nil,
            record: nil,
            reclaimed: nil

  @type status :: :stopped | :starting | :running | :stopping | :crashed

  @type t :: %__MODULE__{
          name: String.t(),
          status: status(),
          started_at: DateTime.t() | nil,
          exists?: boolean(),
          stale?: boolean(),
          busy: String.t() | nil,
          error: String.t() | nil,
          msb: String.t() | nil,
          record: record() | nil,
          reclaimed: [{atom(), %{before: non_neg_integer(), after: non_neg_integer()}}] | nil
        }

  @type record :: %{id: String.t(), created_at: DateTime.t() | nil, image: String.t() | nil}
end
