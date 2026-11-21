# N. Diagrams: groups and order

Read [README.md](README.md) first: it holds what every step shares. None
of the sandbox's decisions apply here.

## What it makes possible

- In the diagram editor you can put what is selected in front of or
  behind the rest:
  - bring forward, send backward, bring to front, send to back;
  - from a menu on the right click, or with `Ctrl+]` and `Ctrl+[`, `Shift`
    for all the way.

  Several selected elements keep their order among themselves. Today the
  only way is `update_diagram` through MCP, rewriting the whole list.
- You can group what belongs together, a box and its label or a legend:
  - `Ctrl+G` groups, `Ctrl+Shift+G` ungroups, or the right-click menu;
  - a click on a member selects the group, and a double-click goes inside
    it to pick one;
  - moving, resizing, deleting, duplicating and restyling act on all its
    members;
  - groups nest, and arrows bound to a member stay bound.
- Agents drawing diagrams through MWT's tools can group too: a `group` on
  each member, a list for nested groups. `mwt://guides/diagrams` tells
  them how.
- The order is the elements' order, so versions, the diff and MWT's tools
  see it with no new field.

## Where it sits

A filler, for a slot with nothing to take. Nothing in the sandbox depends
on it, and it depends on nothing there. Its three steps go in order: the
menu holds the order actions, and groups are made from it.

## Read

- `docs/todo.md`, "Diagrams: groups, and bringing to front or sending to
  back".
- `docs/mcp.md`, and the diagram guide in `lib/mwt_client/mcp/guides.ex`.
- Code:
  - `assets/js/diagram_editor.js`: `renderScene`, the `contextmenu`
    handler in `mounted`, `pointerDown`;
  - `assets/js/diagram_geometry.js`;
  - `lib/mwt_client_web/live/diagrams_live.ex`;
  - the element schema in `lib/mwt_client/mcp/catalogue.ex`.
- Tests: `diagram_geometry.test.mjs`, `diagrams_live_test.exs`,
  `test/mwt_client/diagrams/`, `test/mwt_client/mcp/schema_test.exs`.
- To see it running: the run-mwt skill. Don't run a dev server against
  `~/.mwt_client`.

Edit JavaScript in the style it has; don't reformat it.

## N1: stacking order (S/M)

Task: `diagram-stacking-order`.

- The four actions on the selection, with their shortcuts.
- Several selected elements keep their order among themselves.
- Saved as the elements' order.
- Tests for the reordering, in the geometry module's style if it is pure,
  and a LiveView test that a saved order survives.

## N2: a menu on the right click (M)

Task: `diagram-context-menu`. After N1.

- A right click that doesn't move opens MWT's menu at the pointer: one
  released within a few pixels of where it was pressed. A right drag
  still moves around the canvas, and the browser's own menu stays off.
- On an element that isn't selected, the right click selects it first.
  On empty canvas, the menu offers what applies there: paste, select all.
- The menu lists:
  - the order actions;
  - duplicate, copy, paste and delete;
  - each action's shortcut beside it.
- Actions that don't apply are greyed out, not hidden.
- `Escape` or a click elsewhere closes it, and the arrow keys move through
  it.

## N3: groups (M)

Task: `diagram-groups`. After N2.

- Group and ungroup, from the menu and with their shortcuts.
- Selecting, going inside a group, and every action on a group, as above.
- A group moves in the stacking order as one block, its members kept next
  to each other.
- Groups nest, and arrows bound to a member stay bound.
- `group` on each member in the element schema MWT's tools check, with
  `schema_test.exs` covering it.
- The diagram guide explains it, so an agent groups what belongs
  together.
- Remove the todo's diagram section.

**Done when:** each step has its tests, `mix precommit` passes, and you
tried it in the running app with the run-mwt skill.
