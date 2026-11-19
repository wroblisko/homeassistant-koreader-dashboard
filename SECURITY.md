# Security

## Handling the token

homedash needs a Home Assistant long-lived access token on the device.

- Create it for a **dedicated non-admin user** that may only log in from the local network.
- Home Assistant tokens have no scopes: whoever has the token can call every service that user may call.
  Keep the user's permissions as small as you can and use `confirm` on buttons that open doors.
- Store the token in its own file (for example `koreader/settings/homedash.token`) and read it from the
  config, so you can share or paste the config without the secret.
- Anyone with access to the device's storage (USB, KOReader's SSH server) can read the token. Revoke it in
  Home Assistant (profile > Security) if a device is lost.
- Plain HTTP on the LAN is not encrypted. Use HTTPS if you can.
- Never put tokens in issues, pull requests or screenshots. `*.token` and `dev/config.real.lua` are
  git-ignored; check `git diff` before you commit.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private vulnerability reporting
("Security" tab > "Report a vulnerability") on this repository. Include what you found, how to reproduce
it and the version. You will get an answer as soon as the maintainers can; fixes are released as a patch
version and noted in the changelog.

If a token was exposed (for example committed by mistake), revoke it in Home Assistant first.
