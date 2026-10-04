# appitize

[English](README.md) | [中文](README_zh.md)

Turn any website into a standalone, proxy-aware macOS app.

`appitize.sh` is an interactive shell script that generates a real `.app`
bundle for a URL. Double-clicking the app opens that site in Google Chrome
(app mode) through a proxy of your choice, using a dedicated Chrome profile —
so it behaves like a native desktop app and keeps its own login/cookies,
completely isolated from your everyday Chrome.

The app name and icon are read from the target site automatically. Because
sites behind Cloudflare reject plain `curl` requests, the lookup is performed
by a **real Chrome instance** (launched offscreen and driven over the DevTools
protocol), which executes the JS challenge and works where `curl` gets a 403.
A plain HTTP scrape is kept only as a fallback.

## Features

- Interactive: asks for proxy, URL and (optional) app name.
- Auto-fetches the **app name** from `og:site_name` or the page `<title>`.
- Auto-fetches and converts the **icon** (including through Cloudflare) into a
  proper `.icns`.
- **Proxy support**: `--proxy-server` plus an auto-detected proxy bypass list.
- **Auto LAN detection**: reads the IPv4 address + netmask of the physical
  interface and adds the local CIDR (e.g. `192.168.0.0/24`) to the bypass list.
- **Isolated profile**: each app gets its own Chrome user-data directory.
- **No keychain popups**: generated apps and the offscreen lookup use a mock
  keychain, so Chrome never asks for "Chrome Safe Storage".
- Installs to `/Applications` (falls back to `~/Applications` if not writable).
- Only depends on tools that ship with macOS (plus Google Chrome).

## Requirements

- macOS 12+
- [Google Chrome](https://www.google.com/chrome/)
- Xcode Command Line Tools (`swiftc`): `xcode-select --install`
- `python3` (system Python is fine — only the standard library is used)
- A running local proxy (e.g. `http://localhost:1080`); the script does not
  start one for you.

## Usage

```bash
chmod +x appitize.sh
./appitize.sh
```

Example session:

```
==> New proxy web app

Proxy address [http://localhost:1080]:
    detected LAN: 192.168.0.0/24
Proxy bypass list [localhost;127.0.0.1;::1;192.168.0.0/24]:

URL: www.chatgpt.com

==> Opening https://www.chatgpt.com in Chrome to read its name and icon ...
    icon: https://chatgpt.com/unauth-mweb/apple-touch-icon.png

App name [ChatGPT]:

==> Creating ChatGPT.app
...
==> Launching...
```

Bare hosts are accepted (`www.chatgpt.com` → `https://www.chatgpt.com`).

## Prompts

| Prompt | Default | Notes |
| --- | --- | --- |
| Proxy address | `http://localhost:1080` | Leave empty to build an app with no proxy. |
| Proxy bypass list | `localhost;127.0.0.1;::1;<LAN CIDR>` | `;`-separated. The LAN CIDR is auto-detected. |
| URL | — | Required. Scheme is added if missing. |
| App name | auto | `og:site_name` → shortened `<title>` → domain label. Press Enter to accept. |

## How it works

1. Ask for the proxy settings, then the URL.
2. Launch an offscreen real Chrome (through the proxy) and drive it over CDP to
   read the page title, `og:site_name` and the best icon; download the icon
   bytes from inside the page so the browser's session/cookies apply.
   Falls back to a plain `curl` scrape if Chrome/`python3` are unavailable.
3. Ask for the app name, using the auto-detected value as the default.
4. Build the `.app`:
   - compile a small Swift `launcher` (`swiftc`) that re-execs Chrome,
   - convert the icon to `.icns` (`sips` + `iconutil`),
   - write `Info.plist`.

## Generated bundle

```
/Applications/<App Name>.app/
  Contents/
    Info.plist          # CFBundleExecutable=launcher, CFBundleIconFile=AppIcon
    MacOS/launcher      # compiled Swift launcher
    Resources/AppIcon.icns
```

The launcher runs Chrome with:

```
--user-data-dir=~/Library/Application Support/Chrome-<slug>
--use-mock-keychain
--password-store=basic
--proxy-server=<proxy>
--proxy-bypass-list=<bypass>
--app=<url>
```

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `BROWSER_WAIT` | `30` | Seconds to wait for the offscreen Chrome to render the page. |

## Notes & troubleshooting

- **The proxy must already be running.** The script never starts a proxy.
- **Cloudflare**: the actual app runs in Chrome, so it loads normally. Only the
  metadata lookup needs the real Chrome trick; if it still fails, the app is
  created without an icon and the name falls back to the domain label.
- **First launch / Gatekeeper**: the generated launcher is unsigned. If macOS
  blocks it, right-click the app → Open, or allow it in System Settings.
- **Keychain popup**: handled via `--use-mock-keychain`; if you ever see
  "Where is the Chrome keychain", click **Cancel** (never "Reset to Defaults").

## License

[MIT](LICENSE) © 2026 Jie Cui
