# GUI-Lite Update Flow

This repo treats the converted Codex Desktop app as a local GUI shell over the Codex app-server. The preferred launch path is:

```bash
./run-codex-gui.sh
```

There is no native package install flow in this fork. Updating means downloading the latest upstream `Codex.dmg`, regenerating `codex-app/`, and launching it from this checkout.

## What Is Disabled

A normal Codex Desktop launch calls app-server methods such as:

```text
skills/list
plugin/list
```

Those calls, plus the desktop primary-runtime installer, recommended-skill helper, and external-agent import flow, can hydrate bundled system skills, marketplace plugin metadata, `vendor_imports`, and other bootstrap files under `~/.codex`. GUI-lite patches the desktop bundle so those methods return empty results without hitting app-server, so primary-runtime bundled skills/plugin marketplaces are not copied into Codex home, and so recommended-skill discovery/install paths cannot clone `openai/skills`. It also disables the app-server app/plugin/tool-search feature flags for the GUI process and keeps a proxy block as a defensive backstop.

The Codex CLI app-server can also try to install bundled system skills during startup even when no desktop `skills/list` request is sent. The wrapper blocks that by making the private runtime `skills` root non-writable while app-server starts. This causes the system-skill installer to fail harmlessly in the private runtime instead of creating `skills/.system`; the real `.codex` is not modified.

This is prevention, not cleanup. The launcher does not prune or delete anything from the real `.codex` directory.

## Codex Home Model

GUI-lite uses three homes:

```text
CODEX_GUI_SESSION_HOME   real Codex home, default ~/.codex
CODEX_HOME               private per-launch Electron home while the desktop process runs
app-server CODEX_HOME    private per-launch app-server home created by the CLI wrapper
```

On startup, `run-codex-gui.sh` copies the existing contents of `CODEX_GUI_SESSION_HOME` into a fresh private Electron home under:

```text
${XDG_STATE_HOME:-~/.local/state}/codex-gui/electron/
```

That prevents desktop-side `codex-home` calls from writing `vendor_imports`, ambient suggestion files, or other scratch data into the real `.codex`.

When the desktop starts `codex app-server`, `scripts/codex-gui-cli-wrapper.sh` creates a separate fresh private app-server runtime home under:

```text
${XDG_STATE_HOME:-~/.local/state}/codex-gui/runs/
```

Both private homes are seeded from the real session home so the GUI can see existing auth, config, custom skills, memories, and other user-managed Codex files at startup. Known generated bootstrap paths such as `skills/.system`, `.tmp/plugins`, plugin caches, and `vendor_imports` are excluded from the seed by default so old generated state does not affect the GUI agent. During the GUI session, new Electron and app-server writes go to private runtime homes, not directly to the real `.codex`.

On app-server exit, the wrapper copies only the desktop session database files back to `CODEX_GUI_SESSION_HOME`:

```text
state_5.sqlite*
```

On GUI exit, `run-codex-gui.sh` also copies only Electron global preference files back to `CODEX_GUI_SESSION_HOME`:

```text
.codex-global-state.json
.codex-global-state.json.bak
```

That file stores GUI preferences such as Appearance/theme settings. It is intentionally allowlisted separately from generated skill/plugin/vendor paths.

No generated skills/plugins/logs/memories are copied back automatically. No files are deleted automatically.

By default, `run-codex-gui.sh` snapshots the real `CODEX_GUI_SESSION_HOME` before launching and audits it again after exit. It prints a warning if anything outside the allowlist changed:

```text
state_5.sqlite*
.codex-global-state.json*
```

Set `CODEX_GUI_REAL_HOME_AUDIT=fail` to make unexpected real-home writes fail the launcher after exit, or `CODEX_GUI_REAL_HOME_AUDIT=0` to disable the audit for debugging. The audit is read-only except for temporary snapshot files under `${TMPDIR:-/tmp}`.

The private runtime may contain an empty `skills` directory used as the write blocker. It should not contain newly generated `skills/.system`, `.tmp/plugins`, plugin cache paths, or `vendor_imports`.

## Runtime Controls

Launch the local GUI:

```bash
./run-codex-gui.sh
```

Force X11 or pass other Electron flags:

```bash
./run-codex-gui.sh -- --ozone-platform=x11
```

Use a different real Codex home:

```bash
CODEX_GUI_SESSION_HOME=/path/to/.codex ./run-codex-gui.sh
```

Use a fixed private runtime home for debugging:

```bash
CODEX_GUI_RUNTIME_HOME=/tmp/codex-gui-runtime ./run-codex-gui.sh
```

Use a fixed private Electron home for debugging:

```bash
CODEX_GUI_ELECTRON_HOME=/tmp/codex-gui-electron ./run-codex-gui.sh
```

Bypass GUI-lite proxying for comparison:

```bash
CODEX_GUI_LITE_MODE=0 ./run-codex-gui.sh
```

Disable the system-skill bootstrap lock for debugging only:

```bash
CODEX_GUI_BLOCK_SYSTEM_SKILL_BOOTSTRAP=0 ./run-codex-gui.sh
```

Fail if the real Codex home changes outside the state/preference allowlist:

```bash
CODEX_GUI_REAL_HOME_AUDIT=fail ./run-codex-gui.sh
```

Copy generated bootstrap paths from the real `.codex` into the private homes for debugging only:

```bash
CODEX_GUI_SEED_GENERATED_BOOTSTRAP_PATHS=1 ./run-codex-gui.sh
```

Block additional app-server methods:

```bash
CODEX_GUI_BLOCK_APP_SERVER_METHODS="skills/list plugin/list some/method" ./run-codex-gui.sh
```

Disable extra Codex feature flags for the GUI app-server:

```bash
CODEX_GUI_EXTRA_DISABLE_FEATURES="plugins memories" ./run-codex-gui.sh
```

Clear the default GUI-lite feature disables for debugging:

```bash
CODEX_GUI_DEFAULT_DISABLE_FEATURES="" ./run-codex-gui.sh
```

That can re-enable upstream marketplace hydration inside private runtime homes. It still should not write those files into the real `CODEX_GUI_SESSION_HOME`.

Fixed debug homes set with `CODEX_GUI_ELECTRON_HOME`, `CODEX_GUI_ELECTRON_RUNTIME_PARENT`, `CODEX_GUI_RUNTIME_HOME`, or `CODEX_GUI_RUNTIME_PARENT` must be outside `CODEX_GUI_SESSION_HOME`. The launcher and wrapper reject paths inside the real Codex home before creating directories or applying private runtime chmod/skills locking.

## Updating The Desktop App

Fetch the latest upstream `Codex.dmg`, regenerate `codex-app/`, and exit without launching:

```bash
./run-codex-gui.sh --update-only
```

The build is accepted only after `scripts/verify-gui-lite-safety.sh` prints all safety gates, runs an app-server wrapper smoke test in a temp Codex home, and writes `codex-app/.codex-linux/gui-lite-safety.env`. Normal launch requires that stamp to still match `app.asar`, `codex-app/.codex-linux/start-internal.sh`, and the copied webview content.

Rebuild from the cached `Codex.dmg` without downloading:

```bash
./run-codex-gui.sh --rebuild-only
```

Builder dependency downloads are cached under:

```text
.cache/codex-gui-build/
```

That cache contains the Electron Linux zip, npm package cache, Node build tools, and rebuilt native modules keyed by Electron/module versions. Same-version `--rebuild-only` runs should reuse it instead of redownloading Electron or rerunning a full native module rebuild. Set `CODEX_GUI_BUILD_CACHE_DIR=/path/cache` to move the cache.

Builder npm installs are age-gated by this repo's package-manager config. `.npmrc` sets npm 11+ `min-release-age=7`, and `build-codex-gui.sh` passes that file to its own npm calls through `--userconfig`. The builder also stamps npm-sourced Node-tool and native-module caches with the current age-gate config and refreshes caches that were created before the gate was active. Pnpm and Yarn guard files are present for any future package-manager use:

```text
pnpm-workspace.yaml  minimumReleaseAge: 10080
.yarnrc.yml          npmMinimalAgeGate: "7d"
```

Do not bypass this during routine updates. If npm reports that no eligible package version exists, wait for the package to age past the seven-day gate or explicitly document why the gate is being disabled.

Launch immediately after updating:

```bash
./run-codex-gui.sh --update
```

## Update Checklist For Agents

Use this checklist whenever updating to a new upstream Codex Desktop DMG.

1. Inspect local changes:

```bash
git status --short
```

2. Check upstream DMG metadata:

```bash
curl -L --head --max-time 60 https://persistent.oaistatic.com/codex-app-prod/Codex.dmg
```

3. Download and rebuild the local app:

```bash
./run-codex-gui.sh --update-only
```

Do not run the GUI if this command does not print `GUI-lite safety verification passed`.

4. Run syntax and smoke checks:

```bash
bash -n build-codex-gui.sh run-codex-gui.sh scripts/codex-gui-cli-wrapper.sh scripts/verify-gui-lite-safety.sh
node --check scripts/codex-gui-appserver-proxy.mjs
bash tests/scripts_smoke.sh
```

5. Re-run the safety verifier against the generated app:

```bash
scripts/verify-gui-lite-safety.sh codex-app --require-stamp --runtime-smoke
```

Expected output includes:

```text
Gate 3/8: checking desktop bundle no longer directly hydrates skills/plugins
Gate 7/8 passed: runtime smoke seeded custom state without creating skills/.system, plugin caches, or vendor_imports
GUI-lite safety verification passed
```

6. Verify GUI-lite with an isolated real Codex home if the launcher or wrapper changed:

```bash
tmp="$(mktemp -d)"
mkdir -p "$tmp/home" "$tmp/cache" "$tmp/state" "$tmp/session-home"
env \
  HOME="$tmp/home" \
  XDG_CACHE_HOME="$tmp/cache" \
  XDG_STATE_HOME="$tmp/state" \
  CODEX_GUI_SESSION_HOME="$tmp/session-home" \
  timeout --signal=TERM --kill-after=5 25 ./run-codex-gui.sh
find "$tmp/session-home" -maxdepth 5 \( -type f -o -type d \) | sort
find "$tmp/state/codex-gui" -maxdepth 6 \( -type f -o -type d \) | sort
```

Expected real session-home contents after the timeout are limited to:

```text
state_5.sqlite*
```

The private runtime homes may contain app-server and desktop scratch files, but they should not contain newly hydrated `skills/.system`, `.tmp/plugins`, plugin cache, or `vendor_imports` paths from desktop hydration/import flows.

7. If the private runtime home contains new unwanted paths, first check whether a default feature disable stopped applying. If the creation is triggered by a request method, block that method in `scripts/codex-gui-appserver-proxy.mjs` or through `CODEX_GUI_BLOCK_APP_SERVER_METHODS`.

8. If the app fails to start after an upstream update, inspect:

```bash
~/.cache/codex-desktop/launcher.log
```

Common update breakpoints:

- The desktop bundle now requires a newer Codex CLI. `build-codex-gui.sh` detects the minimum app-server version; this fork does not install or update the CLI automatically.
- The desktop bundle added new app-server calls that hydrate local state. Add those methods to the proxy block list instead of deleting files after the fact.
- The desktop bundle added new direct `codex-home` writers. Keep Electron under the private `CODEX_HOME` and patch the writer if it affects agent behavior inside the private runtime.
- The app-server protocol changed from line-delimited JSON-RPC. Update `scripts/codex-gui-appserver-proxy.mjs` before launching against the real `.codex`.
- The Codex CLI changed its startup bootstrap behavior. Keep `scripts/codex-gui-cli-wrapper.sh` and `scripts/verify-gui-lite-safety.sh` aligned so the temp-home smoke test fails before a real launch can happen.

## Patch Boundaries

Keep update-resistant behavior outside the extracted app whenever possible:

- Prefer `run-codex-gui.sh` for orchestration.
- Prefer `scripts/codex-gui-cli-wrapper.sh` for Codex home isolation and state sync.
- Prefer `scripts/patch-gui-lite-behavior.js` for stopping desktop hydration calls before app-server sees them.
- Prefer `scripts/codex-gui-appserver-proxy.mjs` as a defensive backstop for app-server hydration methods still sent over stdio.
- Keep Linux runtime patching in `build-codex-gui.sh` and `scripts/patch-linux-window-ui.js`.
- Do not manually edit `codex-app/.codex-linux/start-internal.sh`; regenerate it through `build-codex-gui.sh`.
- Do not add a top-level `codex-app/start.sh`; `./run-codex-gui.sh` is the only supported entrypoint.
- Do not manually edit extracted `app.asar` output; make repeatable patches in scripts.

Only patch the desktop bundle itself when there is no app-server flag, environment variable, proxy-level workaround, or launcher-level workaround.
