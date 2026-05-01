# AGENTS.md

## Purpose

This repository adapts the official macOS Codex Desktop DMG to a local runnable Linux GUI. It intentionally avoids native package installs, updater services, system launchers, and automatic Codex CLI installation.

The current flow is:

1. `build-codex-gui.sh` extracts `Codex.dmg`.
2. It extracts and patches `app.asar`.
3. It rebuilds native Node modules for Linux.
4. It downloads a Linux Electron runtime.
5. It writes an internal Linux launcher into `codex-app/.codex-linux/start-internal.sh`.
6. `run-codex-gui.sh` launches the generated app with `scripts/codex-gui-cli-wrapper.sh` as `CODEX_CLI_PATH`.
7. The builder patches the desktop bundle so GUI skills/plugins list methods return empty results without hitting app-server.
8. `run-codex-gui.sh` seeds a private per-launch Electron `CODEX_HOME` from the real `.codex` so desktop-side `codex-home` calls do not write generated files into the real home.
9. `run-codex-gui.sh` copies `.codex-global-state.json*` GUI preference state back from the private Electron home after exit so Appearance/theme settings persist.
10. The wrapper seeds a private per-launch app-server home from the real `.codex`, disables GUI app/plugin/tool-search feature paths, blocks app-server system skill bootstrap, proxies app-server JSON-RPC as a backstop, and copies only `state_5.sqlite*` back to the real `.codex`.
11. `scripts/verify-gui-lite-safety.sh` must pass before a generated app is accepted or launched.

## Source Of Truth

- `build-codex-gui.sh`
  Main local builder and generated launcher template.
- `run-codex-gui.sh`
  Preferred launcher. Rebuilds or updates `codex-app/` when requested and starts GUI-lite mode.
- `scripts/codex-gui-cli-wrapper.sh`
  Wrapper used as `CODEX_CLI_PATH`. It passes normal CLI commands through and isolates `codex app-server` in a private runtime home.
- `scripts/verify-gui-lite-safety.sh`
  Static and runtime safety gate. It checks patch surfaces, verifies the safety stamp, and runs app-server against a temp Codex home to ensure forbidden skills/plugin bootstrap paths are not created.
- `scripts/codex-gui-appserver-proxy.mjs`
  Line-delimited JSON-RPC proxy that blocks GUI-triggered app-server methods such as `skills/list` and `plugin/list`.
- `scripts/patch-linux-window-ui.js`
  Repeatable app bundle patch for Linux window behavior.
- `scripts/patch-gui-lite-behavior.js`
  Repeatable app bundle patch that disables desktop skills/plugins list calls and primary-runtime bundled skills/plugin marketplace hydration.
- `scripts/install-deps.sh`
  Optional helper for host build dependencies.
- `docs/gui-lite-update-flow.md`
  Local launch, update, verification, and patching runbook.
- `docs/webview-server-evaluation.md`
  Decision record for the future local webview server model.
- `.npmrc`, `pnpm-workspace.yaml`, `.yarnrc.yml`
  Package-manager age gates. Keep npm/pnpm/Yarn registry installs restricted to packages older than seven days unless the user explicitly asks to bypass that protection.

## Generated Artifacts

- `Codex.dmg`
  Cached upstream DMG. Useful for repeat builds.
- `codex-app/`
  Generated Linux app directory. Treat this as build output unless intentionally testing launcher contents.
- `codex-app/.codex-linux/gui-lite-safety.env`
  Generated safety stamp written only after GUI-lite static checks and the temp-home app-server smoke test pass.
- `${XDG_STATE_HOME:-~/.local/state}/codex-gui/runs/`
  Private per-launch app-server homes seeded from the real `.codex`.
- `${XDG_STATE_HOME:-~/.local/state}/codex-gui/electron/`
  Private per-launch Electron homes seeded from the real `.codex`.
- `.cache/codex-gui-build/`
  Persistent local builder cache for Node build tools, npm package cache, rebuilt native modules, and Electron Linux zip downloads. Override with `CODEX_GUI_BUILD_CACHE_DIR`.
- `~/.cache/codex-desktop/launcher.log`
  Generated launcher log.
- `~/.local/state/codex-desktop/app.pid`
  Electron launcher PID file.

Do not assume `codex-app/` is pristine. If behavior differs from `build-codex-gui.sh`, prefer updating `build-codex-gui.sh` and regenerating the app.

## Removed Legacy Surfaces

The upstream repository's native package builders, user-local installer, Rust updater service, Nix flake, old package artifacts, and Cargo build outputs are intentionally absent. Do not recreate `packaging/`, `contrib/user-local-install/`, `updater/`, `dist/`, `target/`, `flake.nix`, or package build scripts unless the user explicitly asks to restore those flows.

## Important Behavior

- No automatic Codex CLI installation:
  `run-codex-gui.sh` and the generated internal launcher fail clearly if a compatible `codex` binary is missing or too old. They must not run `npm install -g`.
- No native package install flow:
  This fork removed `.deb`, `.rpm`, pacman, and `codex-update-manager` support.
- GUI-lite app-server isolation:
  Local runs should use `./run-codex-gui.sh`. There must not be a top-level `codex-app/start.sh`. The launcher sets a private `CODEX_HOME` for Electron, and the wrapper sets a separate private `CODEX_HOME` for `codex app-server`, both seeded from `CODEX_GUI_SESSION_HOME` which defaults to `~/.codex`. The seed excludes known generated bootstrap paths such as `skills/.system`, `.tmp/plugins`, plugin caches, and `vendor_imports` by default while preserving user-managed files such as auth, config, custom skills, and memories.
- System skill bootstrap block:
  The Codex CLI app-server may try to install bundled system skills on startup. The wrapper makes the private runtime `skills` root non-writable while app-server starts so `skills/.system` is not created. This happens only in the private runtime and does not delete or modify the real `.codex`.
- No pruning of real `.codex`:
  The GUI must not delete files from the real `.codex`. The wrapper copies only `state_5.sqlite*` back from the private runtime home.
- No real-home vendor imports:
  Desktop-side `codex-home` calls must resolve to the private Electron `CODEX_HOME`, not the real `.codex`, so `vendor_imports` and other generated desktop scratch paths stay outside the real home.
- GUI preference persistence:
  `run-codex-gui.sh` copies only `.codex-global-state.json*` back from the private Electron home so Appearance/theme settings and other GUI global preferences persist across launches. Fixed private Electron/app-server homes must be outside the real `.codex`; the scripts reject paths inside `CODEX_GUI_SESSION_HOME` before runtime chmod/locking.
- Safety gate:
  `run-codex-gui.sh` must call `scripts/verify-gui-lite-safety.sh --require-stamp --runtime-smoke` before launching Electron. If upstream changes move the patch surface, update the patch and verifier instead of bypassing the gate.
- GUI method blocking:
  `scripts/patch-gui-lite-behavior.js` replaces desktop `listSkills`, `listPlugins`, and recommended-skill methods with empty or disabled responses and no-ops primary-runtime hydration hooks. `scripts/codex-gui-appserver-proxy.mjs` also blocks `skills/list` and `plugin/list` as a backstop.
- Default feature disables:
  `scripts/codex-gui-cli-wrapper.sh` disables app/plugin/tool-search-related feature flags for GUI app-server runs by default. Clearing `CODEX_GUI_DEFAULT_DISABLE_FEATURES` can re-enable upstream marketplace hydration in the private runtime home.
- Existing user state:
  Auth, config, custom skills, memories, and other existing Codex files are copied into the private Electron and app-server runtime homes on startup so the GUI can read them.
- DMG extraction:
  `7z` can return a non-zero status for the `/Applications` symlink inside the DMG. Continue if a `.app` bundle was extracted successfully.
- Launcher and `nvm`:
  GUI launchers often do not inherit the user's shell `PATH`. `run-codex-gui.sh` and the generated internal launcher search common `nvm` and local binary paths.
- Launcher logging:
  Generated launcher logs go to `~/.cache/codex-desktop/launcher.log`.
- Webview server:
  The launcher starts `python3 -m http.server 5175` from `content/webview/`, waits for the socket, then launches Electron.
- Build cache:
  `build-codex-gui.sh` must reuse `.cache/codex-gui-build/` for same-version rebuilds. Do not reintroduce unconditional `npx --yes asar`, fresh uncached native rebuilds, or unconditional Electron zip downloads.
- Package age gate:
  Builder npm installs must use this repo's `.npmrc` through `CODEX_GUI_NPMRC_PATH`/`--userconfig`, and routine update flows must not bypass the seven-day npm-registry age gate. Npm-sourced build caches must carry the `.codex-gui-npm-age-gate` stamp for the current config. For npm this is `min-release-age=7`; for pnpm it is `minimumReleaseAge: 10080`; for Yarn it is `npmMinimalAgeGate: "7d"`.
- Wayland/GPU compatibility:
  The generated launcher enables `--ozone-platform-hint=auto`, `--disable-gpu-sandbox`, `--disable-gpu-compositing`, and `--enable-features=WaylandWindowDecorations` by default.

## How To Rebuild

Regenerate from cached or downloaded DMG:

```bash
./build-codex-gui.sh
```

Regenerate from a specific DMG:

```bash
./build-codex-gui.sh ./Codex.dmg
```

Download the latest upstream DMG, regenerate `codex-app/`, and exit:

```bash
./run-codex-gui.sh --update-only
```

Rebuild from cached `Codex.dmg`:

```bash
./run-codex-gui.sh --rebuild-only
```

Launch local GUI-lite mode:

```bash
./run-codex-gui.sh
```

## Runtime Expectations

- `node`, `npm`, `npx`, `python3`, `7z` or `7zz`, `curl`, `unzip`, GNU `make`, and `g++` are required for `build-codex-gui.sh`.
- Node.js 20+ is required.
- A compatible `codex` binary must already exist in `PATH` or be supplied through `CODEX_REAL_CLI_PATH`.
- The launcher must not bootstrap or update `@openai/codex` automatically.

## Preferred Validation After Changes

After editing launcher, wrapper, proxy, or builder logic, validate:

```bash
bash -n build-codex-gui.sh
bash -n run-codex-gui.sh
bash -n scripts/codex-gui-cli-wrapper.sh
bash -n scripts/verify-gui-lite-safety.sh
node --check scripts/codex-gui-appserver-proxy.mjs
bash tests/scripts_smoke.sh
scripts/verify-gui-lite-safety.sh codex-app --require-stamp --runtime-smoke
```

If launcher behavior changed, regenerate and inspect:

```bash
./run-codex-gui.sh --rebuild-only
sed -n '1,160p' codex-app/.codex-linux/start-internal.sh
```

If GUI-lite behavior changed, validate with an isolated `CODEX_GUI_SESSION_HOME`; see `docs/gui-lite-update-flow.md` for the exact command and expected file list.

## Editing Guidance

- Prefer changing `build-codex-gui.sh` over manually patching the generated internal launcher.
- Prefer `run-codex-gui.sh` for orchestration.
- Prefer `scripts/codex-gui-cli-wrapper.sh` for Codex home isolation and session DB sync.
- Prefer `scripts/verify-gui-lite-safety.sh` for hard launch/update gates when upstream patch surfaces change.
- Prefer `scripts/patch-gui-lite-behavior.js` for stopping desktop hydration calls before they reach app-server.
- Prefer `scripts/codex-gui-appserver-proxy.mjs` as a defensive backstop for any hydration calls still sent over stdio.
- Do not add cleanup that deletes from the real `.codex`.
- Do not reintroduce package builders, updater services, or automatic CLI installation unless the user explicitly asks for that reversal.
