# TinyWin

An ultra-lightweight, zero-bloat, security-hardened native macOS runner for Windows apps and games on Apple Silicon.

## Why TinyWin?
- **No bloated Windows VM**: Runs x86/x64 Windows binaries natively as macOS windows using Apple **Rosetta 2** + shared **Wine 11 WoW64** + **DXMT** (DirectX 10/11 → Apple Metal).
- **Zero idle overhead**: Native SwiftUI + AppKit binary (~1–2 MB), no background daemons, auto-reaps `wineserver` on exit (`0% CPU`, `0 B RAM` when idle).
- **Instant APFS Copy-on-Write Bottles**: Creating a new isolated bottle clones a bloat-stripped template (no Mono/Gecko auto-downloads) in < 0.2s using ~0 extra disk bytes.
- **Native macOS `.app` Wrappers**: Export any Windows `.exe` as a ~40 KB standalone `.app` bundle (with its extracted Windows icon converted to `.icns`) so it launches from Spotlight, Finder, or Dock like a native Mac app.
- **Hardened Security by Default**:
  - Removes Wine's default `Z:\ → /` host root mapping.
  - Replaces Wine's macOS `Desktop`/`Documents`/`Downloads` symlinks with isolated bottle directories.
  - Wraps Windows processes in a **macOS Seatbelt (`sandbox-exec`)** profile that blocks host writes and blocks reading `$HOME` secrets (`~/.ssh`, `~/.aws`, `~/Library/Keychains`, `~/Documents`, etc.).
  - Optional **Offline Mode** blocks all IP networking per bottle while keeping local Unix sockets working.

## Quick Start

```bash
# 1. Build TinyWin.app + tinywin CLI
make app

# 2. Check system readiness (Rosetta 2, Metal GPU, Seatbelt)
.build/release/tinywin doctor

# 3. Install the shared lean runtime (Wine 11 + DXMT Metal)
.build/release/tinywin setup

# 4. Create an isolated bottle (instant APFS CoW)
.build/release/tinywin create Apps --preset app
.build/release/tinywin create Games --preset game

# 5. Run a Windows .exe or .msi
.build/release/tinywin run Apps /path/to/app.exe

# 6. Export as a native macOS .app
.build/release/tinywin wrap Apps /path/to/app.exe --name "My App"

# Or open the native GUI:
open dist/TinyWin.app
```
