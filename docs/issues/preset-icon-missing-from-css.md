# A preset's icon shows as an empty box

- Found: 2026-11-23, MWT 0.3.0
- Kind: bug
- Status: open

## What happens

Every grant made from the `google-login` preset shows an empty icon on the
grants page. Grants from the other presets show theirs.

## Why

The heroicons plugin makes a `hero-NAME` class only for the names Tailwind
finds in the files it scans, and `assets/css/app.css` scans `assets/css`,
`assets/js`, `lib/mwt_client_web` and `lib/mwt_client`. Presets are JSON
files under `priv/sandbox/presets/` (since 2026-11-17), which isn't scanned.
`hero-cloud` (google) and `hero-cube` (hex) render only because code in
`lib/` happens to use them too; `hero-identification`, the icon of
`google-login` (added 2026-11-22), appears nowhere else, so its class is
never built.

A preset of the user's, in the identity's folder, can't be scanned at
build time at all: any icon it names that MWT's own code doesn't use shows
empty too.

## Possible fixes

- Scan the presets: `@source "../../priv/sandbox/presets";` in `app.css`.
  That covers MWT's presets, not the user's.
- Accept only icons the CSS has: a list of the icons a grant may take, used
  by the preset loader and the add form, with the type's icon when one is
  missing.
- Render grant icons as inline SVG from the heroicons files instead of CSS
  classes, so any name works.

## Worse than an empty box (found 2026-11-24)

`<.icon>` (`core_components.ex`) has clauses only for `git-branch`,
`diagram` and `hero-*`. A preset of yours whose icon is any other name
(`"icon": "rocket"`) raises `FunctionClauseError` on every page that draws
a grant made from it: the grants page, the overview, the approvals.

The fix proposed then: one list of the icons a grant may take, in
`lib/mwt_client` so Tailwind builds every class on it, with the type's icon
for a name not on it, in the preset loader and in `Presets.icon/1` (which
covers grants already saved with `hero-identification`).
