# Codex Desktop Linux GUI

Run the upstream macOS Codex Desktop app as a local Linux Electron GUI.

This fork is intentionally local-only. It does not build native `.deb`, `.rpm`, or pacman packages, does not install a system launcher, and does not run an updater service. Updates are applied by regenerating `codex-app/` from the latest upstream `Codex.dmg`.

## What This Does

The build pipeline:

1. Extracts the upstream macOS `Codex.dmg`.
2. Extracts and patches `app.asar` for Linux window behavior.
3. Rebuilds native Node modules for Linux.
4. Downloads a Linux Electron runtime.
5. Writes an internal launcher at `codex-app/.codex-linux/start-internal.sh`.
6. Launches through `./run-codex-gui.sh`.

The launcher wraps only `codex app-server`. Normal Codex CLI commands pass through to your real CLI.

## Repository Layout

Tracked source is intentionally small:

- `build-codex-gui.sh`, `run-codex-gui.sh`, and `tests/scripts_smoke.sh`
- `scripts/` repeatable patching, launcher-wrapper, proxy, verification, and dependency helpers
- `docs/` local update and design notes

There is intentionally no project `Makefile` or repo-owned app icon asset. The shell scripts are the public workflow, and generated Linux window/notification icons are sourced from the upstream webview assets extracted from the DMG.

Generated artifacts are ignored and may be recreated:

- `Codex.dmg` cached upstream desktop image
- `codex-app/` generated runnable Linux Electron app
- `${XDG_STATE_HOME:-~/.local/state}/codex-gui/` private GUI runtime homes
- `~/.cache/codex-desktop/launcher.log`

The old native packaging, updater daemon, Rust build, Nix flake, and user-local install paths are intentionally removed from this fork.

## GUI-Lite Codex Home Behavior

Normal Codex Desktop can call app-server methods such as `skills/list` and `plugin/list`, which can hydrate bundled skills and marketplace plugin trees under `~/.codex`.

GUI-lite prevents that by:

- Giving Electron itself a fresh private `CODEX_HOME` seeded from your real `~/.codex`, so desktop-side `codex-home` calls cannot write generated scratch data into the real home.
- Copying your real `~/.codex` into a fresh private app-server home at startup, excluding known generated bootstrap paths such as `skills/.system`, `vendor_imports`, and plugin caches by default.
- Disabling app-server app/plugin/tool-search feature flags for the GUI process.
- Patching the desktop bundle so skills/plugins list methods return empty results without hitting app-server.
- Patching the desktop primary-runtime hydration hooks so bundled skills and plugin marketplaces are not copied into Codex home.
- Patching recommended-skill discovery/install helpers so they return empty or disabled responses instead of cloning `openai/skills` into `vendor_imports`.
- Blocking desktop app-server methods that trigger bundled skills/plugins as a proxy backstop.
- Locking the private runtime `skills` root while app-server starts so the CLI cannot create `skills/.system`.
- Copying `.codex-global-state.json*` GUI preference state, such as Appearance/theme settings, back from the private Electron home after the GUI exits.
- Copying only `state_5.sqlite*` session tracking files back to the real `.codex` after app-server exit.
- Never pruning or deleting files from the real `.codex`.
- Refusing fixed private Electron/app-server homes that point at or inside the real `.codex`, so runtime chmod/locking never targets the real Codex home.
- Refusing to launch unless `scripts/verify-gui-lite-safety.sh` confirms the app bundle is patched and the app-server wrapper does not create forbidden skills/plugin/vendor paths in a temp home.

This means existing auth, config, custom skills, memories, and other user-managed Codex files are available to the GUI at startup, while generated system skills/plugin caches/vendor imports are not imported into the GUI runtime and new desktop-created scratch data stays outside the real `.codex`.

See [docs/gui-lite-update-flow.md](docs/gui-lite-update-flow.md) for the full update and verification runbook.

## Requirements

You need:

- Node.js 20+
- `npm`, `npx`
- `python3`
- `7z` or `7zz`
- `curl`
- `unzip`
- GNU `make` build tool
- `g++`
- an existing compatible `codex` CLI in `PATH` or `CODEX_REAL_CLI_PATH`

This repo will not install or update `@openai/codex` automatically.

## Package Age Gate

Repository package-manager config rejects newly published npm-registry packages by default:

- `.npmrc` sets npm 11+ `min-release-age=7` days.
- `pnpm-workspace.yaml` sets pnpm 10.16+ `minimumReleaseAge: 10080` minutes.
- `.yarnrc.yml` sets Yarn 4.12+ `npmMinimalAgeGate: "7d"`.

`build-codex-gui.sh` also passes this repo's `.npmrc` to its own `npm install` calls, refuses to continue if npm does not resolve the age gate, and refreshes npm-sourced build caches that were not stamped under the current age-gated config.

On Arch, the manual dependency set is:

```bash
sudo pacman -S --needed nodejs npm python p7zip curl unzip base-devel
```

The helper is still available if you want it:

```bash
bash scripts/install-deps.sh
```

## Quick Start

```bash
git clone <your-repo-url> codex-app-linux
cd codex-app-linux
./build-codex-gui.sh
./run-codex-gui.sh
```

Use your own DMG:

```bash
./build-codex-gui.sh /path/to/Codex.dmg
```

## Updating

Download the latest upstream DMG, rebuild `codex-app/`, and exit:

```bash
./run-codex-gui.sh --update-only
```

The rebuild prints explicit GUI-lite safety gates and writes a safety stamp only after static scans and a temp-home app-server smoke test pass. `./run-codex-gui.sh` checks that stamp again before every launch.

Rebuild from the cached `Codex.dmg`:

```bash
./run-codex-gui.sh --rebuild-only
```

Launch immediately after updating:

```bash
./run-codex-gui.sh --update
```

## Useful Environment Variables

- `CODEX_REAL_CLI_PATH=/path/to/codex` uses a specific real Codex CLI.
- `CODEX_GUI_SESSION_HOME=/path/to/.codex` changes the real Codex home used for startup seed and session DB sync.
- `CODEX_GUI_ELECTRON_HOME=/path/runtime` uses a fixed private Electron Codex home for debugging.
- `CODEX_GUI_ELECTRON_RUNTIME_PARENT=/path/runs` changes where private per-launch Electron homes are created.
- `CODEX_GUI_RUNTIME_PARENT=/path/runs` changes where private per-launch app-server homes are created.
- `CODEX_GUI_RUNTIME_HOME=/path/runtime` uses a fixed private app-server home for debugging.
- `CODEX_GUI_SYNC_GLOBAL_STATE=0` disables copying `.codex-global-state.json*` back from the private Electron home.
- `CODEX_GUI_BUILD_CACHE_DIR=/path/cache` changes the persistent builder cache for Electron zips, Node build tools, npm packages, and rebuilt native modules.
- `CODEX_GUI_LITE_MODE=0` bypasses the GUI-lite wrapper for comparison.
- `CODEX_GUI_BLOCK_SYSTEM_SKILL_BOOTSTRAP=0` disables the runtime skills-root lock for debugging only.
- `CODEX_GUI_SEED_GENERATED_BOOTSTRAP_PATHS=1` also copies generated bootstrap paths from the real `.codex` into the private runtime for debugging only.
- `CODEX_GUI_BLOCK_APP_SERVER_METHODS="skills/list plugin/list"` overrides the proxy block list.
- `CODEX_GUI_DEFAULT_DISABLE_FEATURES=""` clears the default GUI-lite feature disables. This can re-enable upstream marketplace hydration in the private runtime home.
- `CODEX_GUI_EXTRA_DISABLE_FEATURES="plugins memories"` adds optional `--disable` flags to `codex app-server`.

## Maintenance Commands

```bash
bash tests/scripts_smoke.sh
scripts/verify-gui-lite-safety.sh codex-app --require-stamp --runtime-smoke
rm -rf codex-app
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/codex-gui"
```

The runtime cleanup command removes only private GUI runtime homes under XDG state. It does not touch the real `.codex`.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Codex CLI not found` | Put a compatible `codex` binary in `PATH` or set `CODEX_REAL_CLI_PATH` |
| CLI version too old | Update your Codex CLI yourself, then rerun `./run-codex-gui.sh` |
| Safety stamp missing or changed | Run `./run-codex-gui.sh --rebuild-only`; do not launch a changed upstream app until verification passes |
| Blank window | Check `~/.cache/codex-desktop/launcher.log` and whether port `5175` is already in use |
| `ERR_CONNECTION_REFUSED` on `:5175` | Ensure `python3` works and port `5175` is free |
| GPU/Vulkan/Wayland errors | Try `./run-codex-gui.sh -- --ozone-platform=x11` or `./run-codex-gui.sh -- --disable-gpu` |
| Generated skills/plugins appear in real `.codex` | Confirm you launched through `./run-codex-gui.sh`; `codex-app/start.sh` should not exist |

## Validation

After changing launcher or update behavior:

```bash
bash tests/scripts_smoke.sh
scripts/verify-gui-lite-safety.sh codex-app --require-stamp --runtime-smoke
```

If you changed the generated launcher template, rebuild and inspect it:

```bash
./run-codex-gui.sh --rebuild-only
sed -n '1,160p' codex-app/.codex-linux/start-internal.sh
```

## Disclaimer

This is an unofficial community project. Codex Desktop is a product of OpenAI. This tool does not redistribute OpenAI software; it automates conversion from the upstream DMG.

## License

MIT
