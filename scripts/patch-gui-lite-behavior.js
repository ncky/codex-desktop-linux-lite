#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");

const extractedDir = process.argv[2];
if (!extractedDir) {
  console.error("Usage: patch-gui-lite-behavior.js <extracted-asar-dir>");
  process.exit(1);
}

const buildDir = path.join(extractedDir, ".vite", "build");
if (!fs.existsSync(buildDir)) {
  console.error(`Vite build directory not found: ${buildDir}`);
  process.exit(1);
}

const webviewDir = path.join(extractedDir, "webview");

const patches = [
  {
    name: "listSkills",
    pattern: /async listSkills\([^)]*\)\{(?:(?!\}async listPlugins).)*\}(?=async listPlugins)/gs,
    replacement: "async listSkills(e){return{data:[]}}",
  },
  {
    name: "listPlugins",
    pattern: /async listPlugins\([^)]*\)\{(?:(?!\}async readConfig).)*\}(?=async readConfig)/gs,
    replacement: "async listPlugins(e){return{featuredPluginIds:[],marketplaces:[],remoteSyncError:null}}",
  },
  {
    name: "primaryRuntimeSkillsReload",
    pattern: /function sp\([^)]*\)\{(?:(?!\}async function cp).)*\}(?=async function cp)/gs,
    replacement: "function sp(e){}",
  },
  {
    name: "primaryRuntimePluginMarketplaceSync",
    pattern: /async function cp\([^)]*\)\{(?:(?!\}async function lp).)*\}(?=async function lp)/gs,
    replacement: "async function cp(e,t){}",
  },
  {
    name: "primaryRuntimeBundledSkillsSync",
    pattern: /async function lp\([^)]*\)\{(?:(?!\}async function up).)*\}(?=async function up)/gs,
    replacement: "async function lp(e,t){}",
  },
  {
    name: "bundledPluginsMarketplaceSync",
    pattern: /async function Lr\([^)]*\)\{(?:(?!\}async function Rr).)*\}(?=async function Rr)/gs,
    replacement: "async function Lr(e){}",
  },
  {
    name: "webviewSkillsList",
    pattern: /async function [A-Za-z_$][\w$]*\([^)]*\)\{(?:(?!\}async function).)*Skills\/list request(?:(?!\}async function).)*\}(?=async function)/gs,
    replacement: (match) => {
      const name = /^async function ([A-Za-z_$][\w$]*)/.exec(match)?.[1] ?? "listSkillsForHost";
      return `async function ${name}(e,t,n,r,i){return{data:[]}}`;
    },
  },
  {
    name: "webviewPluginListHelper",
    pattern: /function [A-Za-z_$][\w$]*\(e,t\)\{return e\.sendRequest\(`plugin\/list`,t\)\}/g,
    replacement: (match) => {
      const name = /^function ([A-Za-z_$][\w$]*)/.exec(match)?.[1] ?? "listPlugins";
      return `function ${name}(e,t){return Promise.resolve({featuredPluginIds:[],marketplaces:[],remoteSyncError:null})}`;
    },
  },
  {
    name: "webviewPluginListHandler",
    pattern: /"list-plugins":mT\(\(e,\{hostId:t,\.\.\.n\}\)=>e\.sendRequest\(`plugin\/list`,n\)\)/g,
    replacement: '"list-plugins":mT(async()=>({featuredPluginIds:[],marketplaces:[],remoteSyncError:null}))',
  },
  {
    name: "recommendedSkillsFetcher",
    pattern: /async function [A-Za-z_$][\w$]*\(\{refresh:[\s\S]*?\}(?=async function [A-Za-z_$][\w$]*\(\{repoRoot:)/g,
    replacement: (match) => {
      const name = /^async function ([A-Za-z_$][\w$]*)/.exec(match)?.[1] ?? "loadRecommendedSkills";
      return `async function ${name}(e){return{skills:[],fetchedAt:null,source:\`gui-lite\`,repoRoot:null,error:null}}`;
    },
  },
  {
    name: "recommendedSkillInstallFunction",
    pattern: /async function [A-Za-z_$][\w$]*\(\{skillId:[\s\S]*?\}(?=async function [A-Za-z_$][\w$]*\(\{repoRoot:)/g,
    replacement: (match) => {
      const name = /^async function ([A-Za-z_$][\w$]*)/.exec(match)?.[1] ?? "installRecommendedSkill";
      return `async function ${name}(e){throw Error(\`Recommended skills are disabled in GUI-lite\`)}`;
    },
  },
  {
    name: "recommendedSkillsHandler",
    pattern: /"recommended-skills":async\(\{hostId:[\s\S]*?\}(?=,"local-custom-agents")/g,
    replacement: '"recommended-skills":async()=>({skills:[],fetchedAt:null,source:`gui-lite`,repoRoot:null,error:null})',
  },
  {
    name: "installRecommendedSkillHandler",
    pattern: /"install-recommended-skill":async\(\{hostId:[\s\S]*?\}(?=,"remove-skill")/g,
    replacement: '"install-recommended-skill":async()=>({success:false,destination:null,error:`disabled in GUI-lite`})',
  },
];

const patchedCounts = Object.fromEntries(patches.map((patch) => [patch.name, 0]));

function listJavaScriptFiles(rootDir) {
  if (!fs.existsSync(rootDir)) {
    return [];
  }

  const files = [];
  for (const entry of fs.readdirSync(rootDir, { withFileTypes: true })) {
    const filePath = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      files.push(...listJavaScriptFiles(filePath));
    } else if (entry.isFile() && entry.name.endsWith(".js")) {
      files.push(filePath);
    }
  }
  return files;
}

for (const filePath of [...listJavaScriptFiles(buildDir), ...listJavaScriptFiles(webviewDir)]) {
  let source = fs.readFileSync(filePath, "utf8");
  let changed = false;

  for (const patch of patches) {
    source = source.replace(patch.pattern, (match, ...args) => {
      patchedCounts[patch.name] += 1;
      changed = true;
      return typeof patch.replacement === "function"
        ? patch.replacement(match, ...args)
        : patch.replacement;
    });
  }

  if (changed) {
    fs.writeFileSync(filePath, source, "utf8");
  }
}

const missing = Object.entries(patchedCounts)
  .filter(([, count]) => count === 0)
  .map(([name]) => name);

if (missing.length > 0) {
  console.error(`Failed to patch GUI-lite methods: ${missing.join(", ")}`);
  process.exit(1);
}

console.log("Patched GUI-lite app-server hydration methods:", patchedCounts);
