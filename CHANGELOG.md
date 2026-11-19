# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-19

### Added

- Full-screen Home Assistant dashboard plugin for KOReader, opened from Tools > More tools or a gesture.
- Config-built card with sections: `header`, `weather_now`, `chart`, `daily`, `values`, `buttons`, `footer`.
- Current weather with icon, temperature (optionally from a separate sensor), humidity, wind with
  direction and pressure.
- Hourly chart with temperature line, precipitation bars, night shading and sunrise/sunset captions from `sun.sun`.
- Daily forecast with high, low, computed "feels like" (wind chill, heat index) and precipitation.
- Values grid with attributes, units and state-to-text maps.
- Buttons that call Home Assistant services, with confirmation dialogs, live state captions and icons,
  inverted style, and state-dependent actions.
- Original garage and gate icons.
- Battery and Wi-Fi indicators, Refresh and Close buttons, swipe down to close.
- Automatic refresh with a periodic full e-ink flash, refresh after wake-up, status footer with the last
  update or error, last good data kept on errors.
- Configuration and network errors are shown on screen; a network error stops the rest of the refresh.
- English (default) and Polish UI with a string table (`homedash_i18n.lua`) and per-string overrides.
- Mock Home Assistant server replaying real captured responses, and dev tooling: `scripts/dev.sh`
  (emulator, headless screenshots for three screen profiles, English and Polish), `scripts/test.sh`
  (busted), `scripts/check_mock.sh`, `scripts/capture_ha.sh`.
- `scripts/package.sh` (release zip) and `scripts/deploy.sh` (SSH deploy with md5 verification).
- Documentation, GitHub issue and pull request templates, CI (mock check and unit tests).
