# Contributing

Issues and pull requests are welcome. For a bug report, include your device, firmware, KOReader and
Home Assistant versions, your config (without the token) and the relevant part of `koreader/crash.log`;
the issue templates ask for these.

Before opening a pull request:

1. Run `bash scripts/test.sh` and `bash scripts/check_mock.sh`.
2. For any UI change run `bash scripts/dev.sh shots` (and `bash scripts/dev.sh shots en`) and attach the
   screenshots to the pull request. Look at them first: no overlaps, text fits, also with longer English
   strings and on all three profiles.
3. Keep user-visible text in `homedash.koplugin/homedash_i18n.lua` (both `en` and `pl`).
4. Keep the config reference current: `homedash.koplugin/config.example.lua` and `docs/configuration.md`.
5. Add or update specs for logic in the model, data, util or i18n modules.
6. Tests and scripts must never call a real Home Assistant. Do not commit tokens, private addresses or
   Home Assistant user ids; `dev/config.real.lua` and `*.token` are git-ignored for that reason.
7. Add a line under "Unreleased" in `CHANGELOG.md`.

Setup, the emulator and the mock server: [docs/development.md](docs/development.md). If you use an AI
coding tool, [AGENTS.md](AGENTS.md) / [CLAUDE.md](CLAUDE.md) describe the project rules for it.

By contributing you agree that your work is licensed under the [MIT License](LICENSE).
