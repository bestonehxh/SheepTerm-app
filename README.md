<p align="center">
  <img src=".github/icon.png?v=3" width="128" alt="SheepTerm app icon">
</p>

# 🐑 SheepTerm

**A native macOS terminal client built for network engineers — SSH, Serial, and local shell in one window.**

SheepTerm is written in SwiftUI + AppKit (Swift 6) and designed around the daily workflow of
configuring switches, routers, firewalls, and access points: legacy-cipher SSH to old gear,
serial consoles over USB adapters, syntax-highlighted device output, and safe multi-line
config pasting.

## ⬇️ Download

[![Download SheepTerm for macOS](https://img.shields.io/badge/Download-SheepTerm_3.0_%281%29_for_macOS-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/bestonehxh/SheepTerm/releases/latest)

**[Get the latest release →](https://github.com/bestonehxh/SheepTerm/releases/latest)** — download `SheepTerm-3.0-1.zip`, unzip, and drag **SheepTerm.app** into `Applications`.

> The build is unsigned (not notarized), so macOS will warn on first launch —
> right-click the app and choose **Open**, or run
> `xattr -dr com.apple.quarantine /Applications/SheepTerm.app`
>
> Requires macOS 26.4 (Tahoe) or later, Apple Silicon.

## Features

### Connections
- **SSH** via bundled libssh 0.12 — works with both modern ciphers and the legacy
  algorithms old Cisco / Aruba / HPE gear still speaks; SSH agent forwarding supported
- **Serial console** over USB serial adapters (configurable baud rate)
- **Local shell** tabs alongside your remote sessions
- **Quick Connect (⌘K)** — type `admin@10.0.0.1`, `admin@sw01:2222`, or an IPv6 literal and go
- Ask-before-quit when live SSH/serial sessions would be lost (local shells don't nag)

### Host management
- Sidebar with **host groups**, search, and recent connections
- **Import / Export groups** as `.sheepterm` files to share with teammates —
  credentials are always stripped from exported files by design
- **Backup / Restore** the whole configuration as a single `.sheeptermbackup` file —
  passwords are never written to the file; they live only in the macOS Keychain
- Careful merge-on-import: no silent overwrites, per-host conflict resolution

### Terminal
- **Syntax highlighting for network device output** — colors are injected into the
  incoming stream as truecolor SGR, so the actual text is untouched: copy and session
  logs stay clean. Rules are customizable, and a backpressure guard keeps huge
  `show tech` dumps from lagging the app
- **Safe Multi-line Paste** — pasting 2+ lines into an SSH/serial session shows a
  read-only preview first, with the option to send line-by-line at a chosen pacing
  delay (great for config blocks on slow control planes)
- **Search in scrollback** (⌘F / ⌘G), clear scrollback (⌘L)
- **Session logging** to `~/Documents/SheepTerm Logs/`
- 6 terminal themes: SheepTerm, Dracula, Nord, One Dark, Solarized, Gruvbox
- Full UTF-8 handling (Thai, CJK, emoji, box-drawing) — shortcuts keep working on
  non-Latin keyboard layouts

### Security
- Passwords are stored **only in the macOS Keychain** — never in config files,
  backups, or exports

## Requirements

- macOS 26.4 (Tahoe) or later, Apple Silicon
- To build: Xcode 26+ and Homebrew `libssh`

## Building

```bash
brew install libssh
xcodebuild -project SheepTerm.xcodeproj -scheme SheepTerm -configuration Release build
```

The app is built at
`~/Library/Developer/Xcode/DerivedData/SheepTerm-*/Build/Products/Release/SheepTerm.app`.

## The Sheep family 🐑

SheepTerm is one of six small native macOS apps that share the same sheep icon set:

|  | App | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepDrop/main/.github/icon.png?v=3" width="44" alt=""> | [SheepDrop](https://github.com/bestonehxh/SheepDrop) | SFTP / SCP / FTP / TFTP file transfer — client and built-in server |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTerm/main/.github/icon.png?v=3" width="44" alt=""> | [SheepTerm](https://github.com/bestonehxh/SheepTerm) | SSH / Serial / local-shell terminal for network engineers |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTap/main/.github/icon.png?v=3" width="44" alt=""> | [SheepTap](https://github.com/bestonehxh/SheepTap) | Menu-bar viewer for your Mac's network interfaces with click-to-copy |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepPing/main/.github/icon.png?v=3" width="44" alt=""> | [SheepPing](https://github.com/bestonehxh/SheepPing) | Continuous multi-host ping monitor with per-host logs and CSV export |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepText/main/.github/icon.png?v=3" width="44" alt=""> | [SheepText](https://github.com/bestonehxh/SheepText) | Fast text editor with tree-sitter highlighting and a JavaScript plugin system |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepArt/main/.github/icon.png?v=3" width="44" alt=""> | [SheepArt](https://github.com/bestonehxh/SheepArt) | Screenshot annotation — draw, crop, layers, one-key background removal |

## Acknowledgements

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) — terminal emulation engine
- [libssh](https://www.libssh.org) (LGPL-2.1) — SSH transport, bundled as a dynamic library

## License

[MIT](LICENSE) © 2026 bestonehxh
