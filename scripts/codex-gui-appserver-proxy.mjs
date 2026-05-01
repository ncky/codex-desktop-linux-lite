#!/usr/bin/env node
import { spawn } from "node:child_process";
import readline from "node:readline";

const realCodex = process.env.CODEX_REAL_CLI_PATH;
if (!realCodex) {
  console.error("Codex GUI app-server proxy requires CODEX_REAL_CLI_PATH.");
  process.exit(1);
}

const blockedMethods = new Set(
  (process.env.CODEX_GUI_BLOCK_APP_SERVER_METHODS ?? "skills/list plugin/list")
    .split(/[\s,]+/)
    .map((value) => value.trim())
    .filter(Boolean),
);
const traceProxy = process.env.CODEX_GUI_PROXY_TRACE === "1";
let parseMissCount = 0;

const emptyResults = new Map([
  ["skills/list", { data: [] }],
  ["plugin/list", { featuredPluginIds: [], marketplaces: [], remoteSyncError: null }],
]);

const child = spawn(realCodex, process.argv.slice(2), {
  env: process.env,
  stdio: ["pipe", "pipe", "pipe"],
});

child.stderr.pipe(process.stderr);

const serverOutput = readline.createInterface({
  input: child.stdout,
  crlfDelay: Number.POSITIVE_INFINITY,
});

serverOutput.on("line", (line) => {
  process.stdout.write(`${line}\n`);
});

const clientInput = readline.createInterface({
  input: process.stdin,
  crlfDelay: Number.POSITIVE_INFINITY,
});

function writeResponse(request, result) {
  if (request.id == null) {
    return;
  }

  process.stdout.write(
    `${JSON.stringify({
      jsonrpc: request.jsonrpc ?? "2.0",
      id: request.id,
      result,
    })}\n`,
  );
}

clientInput.on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    if (traceProxy && parseMissCount < 20) {
      parseMissCount += 1;
      console.error(`[codex-gui] proxy parse miss: ${line.slice(0, 240)}`);
    }
    child.stdin.write(`${line}\n`);
    return;
  }

  if (traceProxy) {
    console.error(`[codex-gui] proxy message: ${JSON.stringify(message).slice(0, 500)}`);
  }

  if (message && blockedMethods.has(message.method)) {
    writeResponse(message, emptyResults.get(message.method) ?? null);
    console.error(`[codex-gui] blocked app-server method: ${message.method}`);
    return;
  }

  child.stdin.write(`${line}\n`);
});

clientInput.on("close", () => {
  child.stdin.end();
});

child.on("error", (error) => {
  console.error(`[codex-gui] failed to start real codex CLI: ${error.message}`);
  process.exit(1);
});

child.on("exit", (code, signal) => {
  if (signal) {
    const signalExitCodes = { SIGHUP: 129, SIGINT: 130, SIGTERM: 143 };
    process.exit(signalExitCodes[signal] ?? 1);
  }
  process.exit(code ?? 0);
});

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    if (!child.killed) {
      child.kill(signal);
    }
  });
}
