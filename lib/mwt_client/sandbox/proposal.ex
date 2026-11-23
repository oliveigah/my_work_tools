defmodule MWTClient.Sandbox.Proposal do
  @moduledoc """
  A grant an agent proposes with `mwt propose`, turned into the fields of
  the add form, so MWT checks it exactly as it checks what you type
  (`MWTClient.Sandbox.Server.Grants.build_grant/3`).

  What an agent may propose:

    * a **token grant** (`mwt propose token`): its hosts, the variables and
      headers its placeholder travels in, git, a command that mints a
      short-lived value and how long one is kept at most, a cloud
      metadata server for Google's client libraries (its project and
      account), a Google login file and the header its ID token travels
      in, the service accounts MWT signs JWTs as for it, or only for its
      subgrants;
      starting from one of the presets, when it names one. Never the value:
      you paste it as you review it;
    * a **network grant** (`mwt propose network`): its destinations, the
      DNS server for their names and the interface they are reached
      through;
    * a **subgrant** of a grant that takes them (`mwt propose GRANT`): a
      command subgrant of Ask to run commands, a request subgrant of a
      token grant.

  Never a start setting, an approval mode, a check or a value: those are
  yours. MWT saves what it proposes at once, off and disabled on startup,
  marked as proposed and to review (`MWTClient.Sandbox.Grant.to_review?/1`).

  Pure: what the agent sent, the grant it names and the preset it starts
  from go in; the form's fields come out.
  """

  alias MWTClient.Sandbox.Grant

  @types ["token", "network"]

  @doc """
  What `wanted`, the word after `mwt propose`, names: a new grant of a type
  (`token`, `network`), or the grant a subgrant goes under, by id or by
  name in any case.

      iex> MWTClient.Sandbox.Proposal.target("network", [])
      {:new, :network}
      iex> MWTClient.Sandbox.Proposal.target("nothing", [])
      {:error, :unknown_grant}
  """
  @spec target(String.t(), [Grant.t()]) ::
          {:new, :token | :network} | {:under, Grant.t()} | {:error, term()}
  def target(wanted, grants) do
    parent =
      Enum.find(grants, &(&1.id == wanted)) ||
        Enum.find(grants, &(String.downcase(&1.name) == String.downcase(wanted)))

    cond do
      wanted in @types -> {:new, String.to_existing_atom(wanted)}
      is_nil(parent) -> {:error, :unknown_grant}
      not Grant.takes_subgrants?(parent) -> {:error, {:no_subgrants, parent.name}}
      true -> {:under, parent}
    end
  end

  @doc """
  The add form's fields for what the agent proposes: `ask` is what it
  sent (`name`, `purpose`, and the fields of its kind), `preset` the
  preset it starts from, if any, whose fields it overrides.
  """
  @spec attrs({:new, :token | :network} | {:under, Grant.t()}, map(), map() | nil) :: map()
  def attrs({:new, :token}, ask, preset) do
    minted? = text(ask[:mint]) != ""
    # Naming either is asking for the server: one with no project is then
    # refused for it, rather than dropped.
    metadata? = text(ask[:metadata_project]) != "" or text(ask[:metadata_account]) != ""
    # A header for the ID token is asking for the login it comes from.
    login? = ask[:login_file] == true or text(ask[:id_token_header]) != ""

    preset_fields(preset)
    |> Map.merge(%{"kind" => "token", "preset" => preset && to_string(preset.id)})
    |> Map.merge(
      given(%{
        "name" => text(ask[:name]),
        "purpose" => text(ask[:purpose]),
        "hosts" => joined(ask[:hosts]),
        "env" => joined(ask[:env]),
        "file_env" => joined(ask[:file_env]),
        "carriers" => joined(ask[:carriers]),
        "git" => if(ask[:git] == true, do: "true", else: ""),
        "source" => if(minted?, do: "minted", else: ""),
        "mint" => text(ask[:mint]),
        "keep_minutes" => text(ask[:keep_minutes]),
        "signs_as" => joined(ask[:signs_as]),
        "present_metadata" => if(metadata?, do: "true", else: ""),
        "present_project" => text(ask[:metadata_project]),
        "present_email" => text(ask[:metadata_account]),
        "present_login" => if(login?, do: "true", else: ""),
        "present_id_header" => text(ask[:id_token_header]),
        "reach" => if(ask[:subgrants_only] == true, do: "subgrants", else: "")
      })
    )
    |> Map.put_new("prefix", "mwt_")
    |> Map.put_new("source", "stored")
    |> Map.put("fill", %{})
  end

  def attrs({:new, :network}, ask, preset) do
    preset_fields(preset)
    |> Map.merge(%{"kind" => "network", "preset" => preset && to_string(preset.id)})
    |> Map.merge(
      given(%{
        "name" => text(ask[:name]),
        "purpose" => text(ask[:purpose]),
        "destinations" => ask[:destinations] |> List.wrap() |> lines(),
        "resolver" => text(ask[:resolver]),
        "anchor" => text(ask[:anchor])
      })
    )
    |> Map.put("fill", %{})
  end

  def attrs({:under, %Grant{kind: :token} = parent}, ask, _preset) do
    headers = ask[:headers] |> List.wrap() |> lines()

    %{
      "kind" => "request",
      "parent" => parent.id,
      "name" => text(ask[:name]),
      "purpose" => text(ask[:purpose]),
      "method" =>
        if(text(ask[:method]) == "", do: "GET", else: String.upcase(text(ask[:method]))),
      "url" => text(ask[:url]),
      "headers" =>
        if(headers == "",
          do: parent.request_headers || MWTClient.Sandbox.SavedRequest.default_headers(nil),
          else: headers
        ),
      "body" => text(ask[:body]),
      "params" => ask[:params] |> List.wrap() |> lines()
    }
  end

  def attrs({:under, %Grant{}}, ask, _preset) do
    %{
      "kind" => "command",
      "preset" => "saved_command",
      "name" => text(ask[:name]),
      "purpose" => text(ask[:purpose]),
      "script" => ask[:script] |> text() |> String.replace("\r\n", "\n"),
      "dir" => text(ask[:dir]),
      "params" => ask[:params] |> List.wrap() |> lines(),
      # Confined, as a subgrant you add starts: nothing of your keys or
      # logins in reach until you choose otherwise as you review it.
      "confined" => "true"
    }
  end

  @doc """
  Who proposed it, as the grant keeps it (`Grant.proposal`): the agent, its
  thread, why, how long it asked for, and when; not reviewed yet. Its
  `revision` is new each time the agent proposes it, a changed one
  included: accepting names the revision the page showed, so one the agent
  changed between your reading and your click isn't accepted
  (`accepts?/2`).
  """
  @spec stamp(map(), DateTime.t()) :: Grant.proposal()
  def stamp(said, now) do
    %{
      agent: said.agent,
      thread: said.thread,
      reason: said.reason,
      minutes: said.minutes,
      at: now,
      reviewed_at: nil,
      revision: 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    }
  end

  @doc """
  Whether accepting from a page that showed `revision` accepts `proposal`
  as the agent last proposed it. A proposal saved before revisions has
  none, and a page showing it sends none.
  """
  @spec accepts?(Grant.proposal(), String.t() | nil) :: boolean()
  def accepts?(proposal, revision),
    do: to_string(Map.get(proposal, :revision)) == to_string(revision)

  @order [
    :kind,
    :name,
    :purpose,
    :hosts,
    :env,
    :carriers,
    :mint,
    :keep_minutes,
    :signs_as,
    :present_project,
    :present_email,
    :present_login,
    :present_id_header,
    :destinations,
    :resolver,
    :anchor,
    :script,
    :dir,
    :params,
    :method,
    :url,
    :headers,
    :body,
    :fill
  ]

  @doc """
  What the agent hears when its proposal is refused, from the form's
  errors by field: the first, with the option it comes from.
  """
  @spec refusal(%{atom() => String.t()}) :: String.t()
  def refusal(errors) do
    errors
    |> Enum.sort_by(fn {field, _} -> Enum.find_index(@order, &(&1 == field)) || 99 end)
    |> Enum.map_join(" ", fn {field, message} -> "#{option(field)}#{message}" end)
  end

  defp option(:name), do: "--name: "
  defp option(:purpose), do: "--for: "
  defp option(:hosts), do: "--host: "
  defp option(:env), do: "--env: "
  defp option(:carriers), do: "--carrier: "
  defp option(:mint), do: "--mint: "
  defp option(:keep_minutes), do: "--keep-minutes: "
  defp option(:signs_as), do: "--sign-as: "
  defp option(:present_project), do: "--metadata-project: "
  defp option(:present_email), do: "--metadata-account: "
  defp option(:present_login), do: "--login-file: "
  defp option(:present_id_header), do: "--id-token-header: "
  defp option(:destinations), do: "--destination: "
  defp option(:resolver), do: "--resolver: "
  defp option(:anchor), do: "--via: "
  defp option(:dir), do: "--dir: "
  defp option(:params), do: "--param: "
  defp option(:method), do: "--method: "
  defp option(:url), do: "--url: "
  defp option(:headers), do: "--header: "
  defp option(:body), do: "--data: "
  defp option(:fill), do: "--preset: "
  defp option(_field), do: ""

  # A preset's fields, as its form starts from them.
  defp preset_fields(nil), do: %{}
  defp preset_fields(%{fields: fields}), do: fields

  # Only what the agent gave overrides the preset.
  defp given(fields), do: Map.reject(fields, fn {_key, value} -> value == "" end)

  defp joined(values), do: values |> List.wrap() |> Enum.map(&text/1) |> Enum.join(", ")
  defp lines(values), do: values |> Enum.map(&text/1) |> Enum.join("\n")

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_other), do: ""
end
