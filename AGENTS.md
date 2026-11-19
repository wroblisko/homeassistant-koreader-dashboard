# AGENTS.md

Guidance for AI coding tools (and humans) working in this repository.

## Project

`homedash.koplugin` is a KOReader plugin: a full-screen Home Assistant dashboard for touch e-ink devices
(Kindle first). It draws weather, a forecast chart, values and service buttons natively and talks to Home
Assistant over its REST API. It is configured by a Lua file the user puts on the device. MIT licensed.

## Repository map

```
homedash.koplugin/   the plugin: main, homedash_{view,model,data,ha,icons,util,i18n}.lua, config.example.lua, icons/
spec/                busted specs + spec/fixtures/ha (captured Home Assistant responses)
scripts/             dev.sh test.sh mock_ha.py check_mock.sh capture_ha.sh package.sh deploy.sh
dev/                 dev configs (mock pl/en, real example)
docs/                configuration.md development.md ha-api.md images/
out/                 generated screenshots and logs (git-ignored)
```

## Commands

Run from the repo root. Put GNU tools first on `PATH` (macOS), without Homebrew `binutils`:

```bash
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/findutils/libexec/gnubin:/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/opt/gnu-getopt/bin:/opt/homebrew/opt/util-linux/bin:/opt/homebrew/bin:$PATH"
unset HOMEDASH_HA_URL

bash scripts/test.sh            # unit tests (busted)
bash scripts/check_mock.sh      # mock server == captured HA responses
bash scripts/dev.sh shots       # headless screenshots in out/ (Polish config)
bash scripts/dev.sh shots en    # English: out/en-*.png
bash scripts/dev.sh run         # emulator window against the mock
```

Needs a KOReader emulator build in `$KOREADER_SRC` (default `../koreader-src`, a sibling of this repo) for
`dev.sh`. `test.sh` and `check_mock.sh` do not. Details: [docs/development.md](docs/development.md).

## Updating the user's device (over Wi-Fi)

An agent can update a device directly once the user has set up SSH once:

1. **User, once:** put the agent machine's public key in `koreader/settings/SSH/authorized_keys` on the
   device (copy over USB with KOReader closed, or via KOReader's file manager).
2. **User, each time:** in KOReader open Tools → SSH server → Start (enable "Login without password" so
   the key is used) and tell the agent the device IP. Default port 2222, user `root`.
3. **Agent:**
   ```bash
   KINDLE_HOST=<ip> bash scripts/deploy.sh      # copies homedash.koplugin, verifies md5 of every file
   ```
   then ask the user to restart KOReader (Menu → Exit → Restart KOReader). `deploy.sh` never touches
   `koreader/settings/` (the user's `homedash_config.lua` and token file).
4. **Debugging on the device:** `ssh -p 2222 root@<ip> 'grep homedash /mnt/us/koreader/crash.log | tail -50'`.
   Read the config only if the user asks, and never print the token file.

Kindle quirks: old busybox (no `md5sum -c`), the clock/time zone can be wrong (use `locale.utc_offset_min`),
and the device does not mount as a USB drive while KOReader is running.

## Golden rules

1. **Never call a real Home Assistant service from an automated run.** Use the mock (`dev.sh` does) and
   `HOMEDASH_ACTIONS=off` wherever a real backend is involved. Never run `dev.sh ... real` unasked.
2. **Never commit or print tokens**, private addresses or user ids. Tokens live in files outside the repo.
3. Internal modules are named `homedash_*`; generic names collide with KOReader's module path.
4. Pure logic belongs in `homedash_model.lua` / `homedash_util.lua` / `homedash_data.lua` / `homedash_i18n.lua`
   with busted specs; `homedash_view.lua` only lays out and draws.
5. All UI sizes come from `Screen:scaleBySize()` or screen fractions. Check all three profiles.
6. **Verify UI by looking at the screenshots** (open the PNGs in `out/`). A correct pixel size is not a
   correct layout. Check for overlaps and clipped text, also in English where strings are longer.
7. Do not `pkill` emulators; the user may have one open. `dev.sh` kills only what it started.
8. The mock must stay byte-identical to the captures. If you change a fixture, change the matching raw
   capture identically and run `scripts/check_mock.sh`.
9. User-visible text goes through `homedash_i18n.lua` (`en` and `pl`); never hard-code words in the view or
   model. Config labels are user data and are not translated.

## Pitfalls (learned the hard way)

- Always pass a start directory to the emulator (`out/home`); with none, KOReader lists `$HOME`, which can
  block on macOS and scheduled code never runs.
- Headless screenshots need `SDL_VIDEO_DRIVER=offscreen` so the framebuffer is the exact device size.
- On a Retina Mac a window renders at 2x: use `-W <w> -H <h> -D <2*dpi>` (`HOMEDASH_REAL_PIXELS=1`), not a
  halved size.
- Homebrew `binutils` on `PATH` breaks the KOReader build (`not 8-byte aligned`).
- busted must run from the repo root with `--lpath='./homedash.koplugin/?.lua'` (and a JSON module:
  KOReader's `common/` or `luarocks install dkjson`). `scripts/test.sh` does this.
- Network calls block the UI thread. Keep timeouts short and stop the refresh after the first network error.
- Kindle Touch is 600x800 @ 167 dpi, touch only: no D-pad support is needed.
- Restart KOReader after changing `main.lua` on a device.

## How to add things

**A section type.** (1) Add it to `SECTION_TYPES` and the validation in `homedash_model.lua`. (2) Make
`Data.entity_ids` / `Data.forecast_queries` in `homedash_data.lua` return what it needs. (3) Add a widget
and a `kind == "<type>"` branch in `Dashboard:_sectionWidget` in `homedash_view.lua`, plus a minimum
height and weight in `_buildDashboard`. (4) Specs in `spec/`, an entry in `config.example.lua` and
`docs/configuration.md`, a screenshot check.

**An icon.** Button icons are SVGs in `homedash.koplugin/icons/` (line art, black on transparent, drawn on
a square viewBox; the name is the file name without `.svg`). Weather and status glyphs are code points of
`fonts/nerdfonts/symbols.ttf` mapped in `homedash_icons.lua`.

**A string.** Add the key to both `en` and `pl` in `homedash_i18n.lua` (a spec checks they match), use
`self.tr.t("key", ...)` in the view or take a translator argument in the model, and document it in
`docs/configuration.md`. **A language:** add `STRINGS`, `DECIMAL` and `DAYS` entries.

## KOReader API pointers

Paths inside the KOReader checkout (`$KOREADER_SRC`):

- `frontend/ui/uimanager.lua` (`show`, `setDirty`, `scheduleIn`, `unschedule`), `frontend/ui/widget/`
  (widgets), `frontend/ui/font.lua`, `frontend/device/screen.lua` (`scaleBySize`, `getSize`, `getDPI`, `shot`).
- `frontend/dispatcher.lua` (gesture actions), `frontend/pluginloader.lua`, `plugins/*.koplugin/` (examples;
  `plugins/keepalive.koplugin`, `plugins/SSH.koplugin`).
- `frontend/ui/network/manager.lua`, `frontend/socketutil.lua` (timeouts for `socket.http`).
- Fonts: `koreader-emulator-*/koreader/fonts/nerdfonts/symbols.ttf`.

## E-ink UI rules

Black, white and a few greys only. No animation. Prefer partial refresh (`"ui"`) and a full flash every
N refreshes to clear ghosting. Big touch targets, high contrast, no thin grey text. Avoid redraws that
change nothing. Everything must stay readable at 167 dpi and at 300 dpi.

## Definition of done

- `bash scripts/test.sh` and `bash scripts/check_mock.sh` pass.
- `bash scripts/dev.sh shots` (and `shots en` if text changed) pass, and you looked at the PNGs.
- New strings are in both languages; config changes are in `config.example.lua` and `docs/configuration.md`.
- `CHANGELOG.md` has an entry under "Unreleased" for user-visible changes.
- No secrets, private hosts or personal paths in the diff.
