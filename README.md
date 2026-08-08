# Grok Usage

<p align="center">
  <img src="docs/screenshots/menubar.png" alt="Grok Usage in the macOS menu bar" width="720" />
</p>

<p align="center">
  <strong>Weekly Grok usage at a glance</strong> — plan, pool %, and time until reset in your Mac menu bar.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6" />
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT" />
</p>

Unofficial menu bar utility for [Grok](https://grok.com) / [Grok Build](https://x.ai/build). Reads the same local login as the Grok CLI (`~/.grok/auth.json`) and fetches **billing metadata only** — no chat or model calls.

---

## Screenshots

**Menu bar**

![Grok Usage in the menu bar](docs/screenshots/menubar.png)

**Detail panel**

<p align="center">
  <img src="docs/screenshots/popover-dark.png" alt="Detail panel (dark)" width="220" />
  &nbsp;&nbsp;
  <img src="docs/screenshots/popover-light.png" alt="Detail panel (light)" width="220" />
</p>

### Menu bar

```
✦  20% 4d
```

| Piece | Meaning |
|-------|---------|
| **Grok mark** | Template icon (adapts to light/dark menu bar) |
| **Usage** | Weekly pool percent used |
| **Countdown** | Days until reset when ≥ 24h remain; otherwise hours |

### Click for details

- **Plan** (e.g. SuperGrok Heavy) and total **% used**
- **Weekly reset** date/time (no year) and countdown in **days + hours**
- **Usage split** by product — Chat, Build, Imagine, Voice, API
- **Quit**

---

## Requirements

- **macOS 14** or later  
- **[Grok Build](https://x.ai/build)** installed and signed in at least once  

```bash
grok login   # only if ~/.grok/auth.json is missing
```

---

## Install

### Build from source

```bash
git clone https://github.com/rlimberger/grokbar.git
cd macos-grok-usage-bar
bash build.sh
open "build/Grok Usage.app"
```

Optional install:

```bash
cp -R "build/Grok Usage.app" /Applications/
```

Ad-hoc signed builds: first open via **right-click → Open** if Gatekeeper warns.

Xcode (or Xcode-beta) must be available for the Swift toolchain / SDK.

---

## Privacy

| Action | Detail |
|--------|--------|
| **Read** | `~/.grok/auth.json` (shared with Grok Build) |
| **Write** | May refresh OIDC tokens in that file |
| **Network** | `auth.x.ai` (token refresh), `cli-chat-proxy.grok.com` (billing metadata) |
| **Not sent** | Chats, code, project files |

No inference / completions — only usage and subscription metadata.

---

## How it works

1. Load OIDC credentials from `~/.grok/auth.json` (same file as `grok`).
2. Refresh the access token when near expiry (`auth.x.ai/oauth2/token`).
3. Fetch billing metadata:
   - `GET …/v1/billing?format=credits` — weekly pool %, product split, reset window  
   - `GET …/v1/billing` — monthly included allowance (plan heuristics)
4. Cache the last good snapshot under Application Support.
5. Background refresh about **every 20 minutes** while the Mac is awake; open-panel fetch only if data is older than **15 minutes**. Menu bar countdown ticks locally every minute.

Plan names are **best-effort** (OIDC `tier` claim + monthly included pool). xAI does not always return a stable plan string on this endpoint.

---

## Project layout

```
Sources/                 AppKit status item + SwiftUI panel + networking
Resources/               Info.plist, Grok template icons
docs/screenshots/        README images
build.sh                 → build/Grok Usage.app
```

---

## License

[MIT](LICENSE)

Not affiliated with xAI. Grok and related marks are property of their owners.
