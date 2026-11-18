defmodule MWTClientWeb.SandboxLive.Servers do
  @moduledoc """
  The servers running in the VM, open on this machine at the VM's address
  (`MWTClient.Sandbox.Ports`, kept by `MWTClient.Sandbox.Server.Forwarding`):
  a card for the overview, each server with a way to open it and to kill
  it (`MWTClient.Sandbox.stop_server/2`), and a short list per worktree
  slot for the Projects page.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components

  alias MWTClient.Sandbox.Ports

  attr :ports, :map, required: true, doc: "the snapshot's `ports`"

  @doc "Every server in the VM, with where it opens here, or why it doesn't."
  def overview_card(assigns) do
    # What opens here first, what doesn't after it, each by port.
    assigns =
      assigns
      |> assign(:range, Ports.range())
      |> assign(
        :entries,
        Enum.sort_by(assigns.ports.ports, &{match?({:skipped, _}, &1.status), &1.port})
      )

    ~H"""
    <.card id="overview-servers" title="Servers in the VM" body_class="">
      <:help>
        A server an agent starts in the VM on a port from {Ports.range_text()} opens on this machine by itself, at the VM's own address here and the same port, so it never collides with yours. Agents are told to use that range for what you are to open. Every other port stays in the VM and isn't listed, so language servers, test runs and other tools don't clutter this. What a server shows in your browser comes from the VM: treat it like any website.
      </:help>
      <:actions>
        <span
          id="servers-address"
          class="font-mono text-[11px] text-faint"
          title={"Ports #{Ports.range_text()} of the VM open at this address"}
        >
          {@ports.address}<span id="servers-range" class="text-faint/70">:{@range.first}–{@range.last}</span>
        </span>
      </:actions>
      <p
        :if={status_words(@ports)}
        id="servers-status"
        class={[
          "flex items-start gap-1.5 px-4 py-2.5 text-[11px] leading-4",
          if(match?({:error, _}, @ports.status), do: "text-bad", else: "text-muted")
        ]}
      >
        <.icon
          name={
            if match?({:error, _}, @ports.status),
              do: "hero-exclamation-triangle-micro",
              else: "hero-information-circle-micro"
          }
          class="mt-px size-3.5 shrink-0"
        />
        {status_words(@ports)}
      </p>
      <ul :if={@entries != []} id="servers" class="divide-y divide-line-soft">
        <.row :for={entry <- @entries} entry={entry} address={@ports.address} id_prefix="server" />
      </ul>
    </.card>
    """
  end

  attr :ports, :map, required: true
  attr :project, :string, required: true
  attr :slot, :string, required: true

  @doc "The servers one worktree slot runs, as links; nothing when it runs none."
  def slot_list(assigns) do
    assigns =
      assign(
        assigns,
        :entries,
        Enum.filter(assigns.ports.ports, &in_slot?(&1.cwd, assigns.project, assigns.slot))
      )

    ~H"""
    <ul
      :if={@entries != []}
      id={"slot-servers-#{@slot}"}
      class="mt-1.5 flex flex-wrap items-center gap-1.5"
    >
      <li
        :for={entry <- @entries}
        id={"slot-server-#{@slot}-#{entry.port}"}
        class="inline-flex items-center"
      >
        <a
          :if={entry.status == :forwarded}
          href={Ports.url(@ports.address, entry.port)}
          target="_blank"
          rel="noopener noreferrer"
          title={"Open #{Ports.url(@ports.address, entry.port)}"}
          class="inline-flex items-center gap-1 rounded-md border border-ok/30 bg-ok-soft/30 px-1.5 py-0.5 font-mono text-[10px] text-ok-strong transition-colors hover:border-ok/60 hover:bg-ok-soft/60"
        >
          <.icon name="hero-globe-alt-micro" class="size-3" /> :{entry.port}
        </a>
        <span
          :if={entry.status != :forwarded}
          title={reason(entry.status)}
          class="inline-flex items-center gap-1 rounded-md border border-line px-1.5 py-0.5 font-mono text-[10px] text-faint"
        >
          :{entry.port}
        </span>
      </li>
    </ul>
    """
  end

  attr :entry, :map, required: true
  attr :address, :string, required: true
  attr :id_prefix, :string, required: true

  defp row(assigns) do
    assigns = assign(assigns, :slot, Ports.slot(assigns.entry.cwd))

    ~H"""
    <li
      id={"#{@id_prefix}-#{@entry.port}"}
      class="group/server flex items-center gap-3 px-4 py-2.5 transition-colors hover:bg-hover/30"
    >
      <span class={[
        "flex h-7 min-w-14 shrink-0 items-center justify-center rounded-md border px-1.5 font-mono text-xs tabular-nums",
        if(@entry.status == :forwarded,
          do: "border-ok/35 bg-ok-soft/40 text-ok-strong",
          else: "border-line bg-deep text-faint"
        )
      ]}>
        {@entry.port}
      </span>
      <div class="min-w-0 flex-1">
        <p class="truncate text-xs font-medium text-ink">
          {@entry.process || "a process"}
          <span :if={@slot} class="font-normal text-muted">
            · {elem(@slot, 1)} of {elem(@slot, 0)}
          </span>
        </p>
        <p :if={@entry.status != :forwarded} class="truncate text-[11px] text-faint">
          {reason(@entry.status)}
        </p>
        <p
          :if={@entry.status == :forwarded}
          class="truncate font-mono text-[10px] text-faint"
          title={@entry.cwd}
        >
          {@entry.cwd}
        </p>
      </div>
      <a
        :if={@entry.status == :forwarded}
        id={"#{@id_prefix}-open-#{@entry.port}"}
        href={Ports.url(@address, @entry.port)}
        target="_blank"
        rel="noopener noreferrer"
        class="inline-flex shrink-0 items-center gap-1 rounded-md border border-line px-2 py-1 text-[11px] font-medium text-ink transition-all hover:border-accent/60 hover:text-accent active:scale-[0.98]"
      >
        Open <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" />
      </a>
      <button
        type="button"
        id={"#{@id_prefix}-kill-#{@entry.port}"}
        phx-click="stop_server"
        phx-value-port={@entry.port}
        data-confirm={"Kill #{@entry.process || "the process"} on port #{@entry.port} in the VM? It gets SIGTERM, as kill sends it."}
        title={"Kill #{@entry.process || "the process"} listening on port #{@entry.port} in the VM"}
        class="inline-flex shrink-0 cursor-pointer items-center gap-1 rounded-md border border-line px-2 py-1 text-[11px] font-medium text-muted transition-all hover:border-bad/50 hover:bg-bad-soft/30 hover:text-bad active:scale-[0.98] phx-click-loading:pointer-events-none phx-click-loading:opacity-50"
      >
        <.icon name="hero-stop-micro" class="size-3.5" /> Kill
      </button>
    </li>
    """
  end

  defp reason({:skipped, reason}), do: reason
  defp reason(:pending), do: "Starting…"
  defp reason(:forwarded), do: "Open on this machine"

  @doc false
  def status_words(%{status: :off}), do: "The VM isn't running."
  def status_words(%{status: :connecting}), do: "Connecting to the VM…"

  def status_words(%{status: :waiting}),
    do: "Connected. Waiting for the VM to say what listens in it."

  def status_words(%{status: {:error, message}}), do: message

  def status_words(%{status: :on, ports: []}),
    do: "Nothing listens on ports #{Ports.range_text()} in the VM yet."

  def status_words(_ports), do: nil

  # slot-0 is the clone itself, /work/NAME: a server in it (or a folder
  # in it) runs there.
  defp in_slot?(cwd, project, "slot-0") when is_binary(cwd) do
    clone = "/work/" <> project
    cwd == clone or String.starts_with?(cwd, clone <> "/")
  end

  defp in_slot?(cwd, project, slot), do: Ports.slot(cwd) == {project, slot}
end
