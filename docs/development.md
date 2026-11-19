# Development

Everything here runs on your computer; nothing needs a Kindle or a real Home Assistant. The plugin is
developed in KOReader's desktop emulator against a mock Home Assistant that replays real captured
responses.

## Repository layout

| Path | What |
| --- | --- |
| `homedash.koplugin/` | The plugin (what you copy to a device). |
| `homedash.koplugin/config.example.lua` | Commented configuration template. |
| `spec/` | busted unit tests and `spec/fixtures/ha/` (captured Home Assistant responses). |
| `scripts/` | `dev.sh`, `test.sh`, `mock_ha.py`, `check_mock.sh`, `capture_ha.sh`, `package.sh`, `deploy.sh`. |
| `dev/` | Dev configs: `config.mock.lua` (Polish), `config.mock.en.lua` (English), `config.real.example.lua`. |
| `docs/` | This file, [configuration.md](configuration.md), [ha-api.md](ha-api.md), screenshots in `images/`. |

## Architecture

All internal modules are prefixed `homedash_` because `require` uses KOReader's global module path and
generic names would collide with KOReader's own.

| Module | Role |
| --- | --- |
| `main.lua` | Plugin entry: menu item, gesture action (`homedash_show`), opens the dashboard. |
| `homedash_view.lua` | The full-screen widget: layout by screen fractions, drawing, taps, refresh timers, dev hooks. |
| `homedash_model.lua` | Pure logic: time, forecast windows, night intervals, feels-like, value and button texts, config validation and defaults. |
| `homedash_data.lua` | Which entities and forecasts to fetch and when; keeps the last good data and the last error. |
| `homedash_ha.lua` | Home Assistant REST client (`socket.http`, JSON, error mapping, short timeouts). |
| `homedash_icons.lua` | Weather condition and status glyphs from KOReader's `symbols.ttf`. |
| `homedash_util.lua` | Small pure helpers (clamp, temperature text, the actions-off switch). |
| `homedash_i18n.lua` | String tables (`en`, `pl`), weekday names, decimal marks, lookup with fallback. |

Model, data, util, icons and i18n use no KOReader modules, so busted tests them directly.

## KOReader emulator on macOS

Clone and build KOReader next to this repo (the scripts default to `../koreader-src`, a sibling of this repo;
override with `KOREADER_SRC`). Follow KOReader's
[macOS build notes](https://github.com/koreader/koreader/blob/master/doc/Building.md) and install GNU
tools with Homebrew. Put them on `PATH` **but not Homebrew `binutils`**: its `ar`/`ranlib` produce
archives Apple's `ld` rejects (`64-bit mach-o member not 8-byte aligned`).

```bash
export PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:$(brew --prefix)/opt/findutils/libexec/gnubin:$(brew --prefix)/opt/make/libexec/gnubin:$(brew --prefix)/opt/gnu-getopt/bin:$(brew --prefix)/opt/util-linux/bin:$PATH"
cd "$KOREADER_SRC" && ./kodev build
```

If `binutils` was on `PATH` during an earlier build, the bad tools are cached in CMake: delete
`base/build/<triplet>` and rebuild.

The emulator ends up in `koreader-emulator-<triplet>/koreader`. `scripts/dev.sh` symlinks
`homedash.koplugin` into its `plugins/` directory and runs `./kodev run --no-build`.

## Running: `scripts/dev.sh`

```bash
bash scripts/dev.sh mock                  # foreground mock, outdoor temperature drifts
bash scripts/dev.sh run                   # window, profile kindle (600x800 @ 167)
bash scripts/dev.sh run legacy-paperwhite # 758x1024 @ 212
bash scripts/dev.sh run kindle-paperwhite # 1072x1448 @ 300
HOMEDASH_REAL_PIXELS=1 bash scripts/dev.sh run   # Retina Mac, see below
bash scripts/dev.sh shots                 # headless PNGs in out/ (Polish config)
bash scripts/dev.sh shots en              # same, English config, files out/en-*.png
```

`run` and `shots` start the mock on `HOMEDASH_MOCK_PORT` (default 18123), wait until it answers, and stop
it on exit. They export `HOMEDASH_HA_URL` and, unless `HOMEDASH_CONFIG` is set,
`HOMEDASH_CONFIG=dev/config.mock.lua`. If `HOMEDASH_HA_URL` is already set no mock is started. The mock log
is `out/mock_ha.log`.

Always pass a start directory to the emulator (the script uses `out/home`, created if needed); otherwise
KOReader's file browser opens `$HOME` and listing it can block on macOS.

**Retina.** SDL renders the window at 2x, so `-s kindle` gives KOReader a 1200x1600 screen and everything
looks half-size. `HOMEDASH_REAL_PIXELS=1` passes `-W`/`-H` at the device size and `-D` at twice the
device DPI, so the layout matches the device:

| Profile | Device | `-W` x `-H` | `-D` | KOReader sees |
| --- | --- | --- | --- | --- |
| `kindle` | 600x800 @ 167 | 600x800 | 334 | 1200x1600 @ 334 |
| `legacy-paperwhite` | 758x1024 @ 212 | 758x1024 | 424 | 1516x2048 @ 424 |
| `kindle-paperwhite` | 1072x1448 @ 300 | 1072x1448 | 600 | 2144x2896 @ 600 |

### Headless screenshots

`shots` runs each profile with `SDL_VIDEO_DRIVER=offscreen` (the PNG has the exact device size), opens the
dashboard automatically, saves a screenshot and quits. With the mock it also writes:

| File | Scenario |
| --- | --- |
| `out/<profile>.png` | three profiles, fresh fixtures |
| `out/kindle-error.png` | mock answers 401 |
| `out/kindle-unavailable.png` | entities `unavailable` |
| `out/kindle-action.png` | garage button pressed (`HOMEDASH_AUTOACTION=garage`) |
| `out/kindle-action-all.png` | "open all" pressed |

`shots en` writes the same set as `out/en-*.png`. The script checks each PNG's pixel size (macOS `sips`)
and the mock's recorded service calls for the action shots, and exits non-zero on any failure. Always
**open the PNGs and look at them**: a correct size does not mean a correct layout. The README images in
`docs/images/` are copies of `out/en-kindle.png`, `out/en-kindle-action.png`,
`out/en-kindle-paperwhite.png` and `out/kindle.png`.

Only the process tree started by the script is killed on a timeout (`HOMEDASH_SHOT_TIMEOUT`, default 60
seconds per shot). Never `pkill` the emulator: it would close any emulator window you have open.

## Dev environment variables

All of these are ignored when unset; leave them unset on a device.

| Variable | Effect |
| --- | --- |
| `HOMEDASH_AUTOOPEN=1` | Open the dashboard about a second after KOReader starts. |
| `HOMEDASH_SCREENSHOT=/abs/path.png` | Save a PNG once the dashboard has data (about 2 s after it shows, about 8 s with `AUTOACTION`). |
| `HOMEDASH_EXIT_AFTER_SHOT=1` | Quit KOReader after the screenshot. |
| `HOMEDASH_AUTOACTION=<button id>` | About a second after opening, run that button without the confirm dialog. Only against the mock. |
| `HOMEDASH_ACTIONS=off` | Safety switch: every button tap shows the "actions disabled" notice and never calls Home Assistant (`AUTOACTION` is ignored). |
| `HOMEDASH_CONFIG=/abs/path.lua` | Use this config instead of `koreader/settings/homedash_config.lua`. |
| `HOMEDASH_HA_URL` | Home Assistant URL used by the dev configs. When set before `dev.sh`, no mock is started. |
| `HOMEDASH_TOKEN_FILE` | Token file read by `dev/config.real.lua` (default `~/.homedash-token`). |
| `HOMEDASH_HOME_DIR` | Start directory for `run` and `shots` (default `out/home`). |
| `HOMEDASH_REAL_PIXELS=1` | `run` only: Retina sizing, see above. |
| `HOMEDASH_MOCK_PORT`, `HOMEDASH_SHOT_TIMEOUT` | Mock port (18123) and per-shot limit (60 s). |
| `KOREADER_SRC` | KOReader checkout (default `../koreader-src`, a sibling of this repo). |

## Mock server

`scripts/mock_ha.py` (Python standard library only) replays the captured Home Assistant responses
byte for byte: status lines, headers, compact JSON, error texts. See [ha-api.md](ha-api.md).

```bash
python3 scripts/mock_ha.py                 # http://127.0.0.1:8123, token "mock-token"
python3 scripts/mock_ha.py --live          # outdoor temperature drifts every 60 s
python3 scripts/mock_ha.py --no-shift      # forecast datetimes exactly as captured
bash scripts/check_mock.sh                 # mock == captured responses (must stay green)
```

Forecast datetimes are shifted so the hourly forecast starts at the next full hour. Service calls change
state (switches, covers, climate set-point) and `spec/fixtures/ha/mock_rules.json` adds timed effects,
for example `script.otworz_garaz` turns `binary_sensor.brama_garazowa` on after 4 seconds.

Test-only endpoints (no auth):

| Endpoint | Meaning |
| --- | --- |
| `GET /__mock/calls` | Service calls received so far. |
| `POST /__mock/reset` | Reload fixtures, clear calls and scenario. |
| `POST /__mock/state` | `{"entity_id","state","attributes"?}` sets a state. |
| `POST /__mock/scenario` | `{"delay_s":N,"force_401":bool,"unavailable":bool}`. |

## Capturing your own fixtures

`scripts/capture_ha.sh` records real responses into `spec/fixtures/ha/` with read-only calls
(`GET /api/states/*`, `weather.get_forecasts`, and requests rejected before they do anything):

```bash
HA_URL=http://192.168.1.10:8123 HA_TOKEN=... HA_WEATHER=weather.home bash scripts/capture_ha.sh sun.sun sensor.outdoor_temperature
bash scripts/check_mock.sh
```

The shipped fixtures were captured from a real installation, so entity names are realistic (Polish
friendly names). Review any new capture before committing it: `context.user_id` values identify Home
Assistant users and should be replaced with a dummy 32-hex string (the same value in the state fixture
and any raw capture). The mock must stay byte-identical to the captures, so change both or neither.

## Running against your own Home Assistant

The dashboard can run in the emulator against a real Home Assistant.

1. In Home Assistant create a dedicated user (Settings > People > Users > Add): leave "Administrator"
   off and turn on "Can only log in from the local network".
2. Log in as that user: profile > Security > Long-lived access tokens > Create token. Copy it once.
3. Save it where only you can read it:

   ```sh
   printf '%s\n' 'PASTE_TOKEN_HERE' > ~/.homedash-token
   chmod 600 ~/.homedash-token
   ```

4. `cp dev/config.real.example.lua dev/config.real.lua` and edit the entity ids. `dev/config.real.lua` is
   git-ignored.

```sh
export HOMEDASH_HA_URL=http://192.168.1.10:8123
bash scripts/dev.sh shots real             # out/real-<profile>.png, buttons disabled
bash scripts/dev.sh run real [profile]     # interactive window
bash scripts/dev.sh shots real refused     # out/real-refused.png (connection refused)
bash scripts/dev.sh shots real timeout     # out/real-timeout.png (unreachable host, 192.0.2.1)
```

`shots real` always sets `HOMEDASH_ACTIONS=off`. `run real` leaves actions on: confirming a dialog really
calls your Home Assistant (it opens the garage). Use `HOMEDASH_ACTIONS=off bash scripts/dev.sh run real`
to look around safely.

## Unit tests

```bash
bash scripts/test.sh              # busted over spec/
bash scripts/test.sh spec/i18n_spec.lua
```

The specs `require("homedash_model")` and friends, so busted runs from the repo root with
`--lpath='./homedash.koplugin/?.lua'`. `test.sh` uses KOReader's own busted install when a build exists
(`$KOREADER_SRC/base/build/<triplet>/spec/rocks/bin/busted`, with the emulator's `common/` directory on the
path for `json.lua`). Without a KOReader build it falls back to `busted` on `PATH`; install it with
`luarocks install busted dkjson` (LuaJIT or Lua 5.1). This is what CI does
([.github/workflows/ci.yml](../.github/workflows/ci.yml)). Specs never touch the network.

## Packaging

```bash
bash scripts/package.sh           # dist/homedash.koplugin-<version>.zip
```

The version comes from `homedash.koplugin/_meta.lua`. The zip has a single top-level `homedash.koplugin/`
folder; unzip it into `koreader/plugins/`. `dist/` is git-ignored.

## Deploying to a device over SSH

On the device start KOReader's SSH server (Tools > SSH server; default port 2222) and add your public
key to `koreader/settings/SSH/authorized_keys`. Then:

```bash
KINDLE_HOST=192.168.1.50 bash scripts/deploy.sh          # port 2222, /mnt/us/koreader
KINDLE_HOST=192.168.1.50 KINDLE_PORT=2222 KOREADER_DIR=/mnt/us/koreader bash scripts/deploy.sh
DRY_RUN=1 KINDLE_HOST=192.168.1.50 bash scripts/deploy.sh # list files and checksums only
```

It replaces `koreader/plugins/homedash.koplugin` with tar piped through ssh and then compares the md5 of
every file on the device. It never touches `koreader/settings/`, so your config and token stay.
Restart KOReader to load the new code. The device-side log is `koreader/crash.log`.

## Coding rules

- Sizes come from `Screen:scaleBySize()` or screen fractions, never fixed pixels; check all three profiles.
- Config problems and network errors are shown on screen; never crash on bad input.
- Network calls block the UI thread: keep timeouts short and stop a refresh after the first network error.
- Put logic in the pure modules and test it; keep `homedash_view.lua` to layout and drawing.
- User-visible text goes through `homedash_i18n.lua` (both `en` and `pl`).
