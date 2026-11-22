defmodule MWTClientWeb.SandboxLive.ComponentsTest do
  use ExUnit.Case, async: true

  alias MWTClientWeb.SandboxLive.Components

  doctest Components

  test "a list cut in pages keeps the page within those there are" do
    assert Components.paged([], 3, 20) == {[], 1, 1}
    assert Components.paged(Enum.to_list(1..20), 2, 20) == {Enum.to_list(1..20), 1, 1}
    assert Components.paged(Enum.to_list(1..21), 0, 20) == {Enum.to_list(1..20), 1, 2}
    assert Components.paged(Enum.to_list(1..21), 2, 20) == {[21], 2, 2}
  end

  test "the page a pager asks for is a whole number, or nothing" do
    assert Components.page_asked("3") == 3
    assert Components.page_asked(3) == 3
    assert Components.page_asked("3a") == nil
    assert Components.page_asked(nil) == nil
  end
end
