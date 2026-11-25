defmodule MWTClient.Sandbox.FormFieldsTest do
  @moduledoc """
  The fields of each thing you add, which presets and proposals set: every
  one the builders read, and none of yours.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.FormFields

  doctest FormFields

  @things [
    :credential,
    :network,
    :credential_grant,
    :network_grant,
    :request_action,
    :command_action
  ]

  test "no thing has a field of yours" do
    for thing <- @things,
        do: assert(FormFields.of(thing) -- FormFields.yours() == FormFields.of(thing))
  end

  test "every field is checked as given, the first wrong one named" do
    assert FormFields.check(:credential_grant, %{"hosts" => "a.example", "start" => "on"}) ==
             {:error, "start is yours to set, as you review it."}

    assert FormFields.check(:command_action, %{"script" => "ls", "confined" => "false"}) ==
             {:error, "confined is yours to set, as you review it."}

    assert :ok = FormFields.check(:network_grant, %{"destinations" => "10.0.0.0/8:443"})
  end
end
