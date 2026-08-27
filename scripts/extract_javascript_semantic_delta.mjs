#!/usr/bin/env node
/**
 * Extract a stable semantic delta from two generated JavaScript bundles.
 *
 * The comparison deliberately excludes local identifiers. Minifiers routinely
 * rename those identifiers even when product behavior is unchanged. Evidence
 * is instead derived from AST string values, object keys, methods, routes,
 * AppHost operations, URL schemes, and feature-flag-like values.
 */

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";


function loadBundledAcorn() {
  const require = createRequire(import.meta.url);
  const Module = require("node:module");
  const key = "internal/deps/acorn/acorn/dist/acorn";
  const source = process.binding("natives")[key];
  if (typeof source !== "string") {
    throw new Error(
      "This Node.js runtime does not expose its bundled Acorn parser; " +
        "use the project-supported Node runtime.",
    );
  }
  const parserModule = new Module("codex-bundled-acorn");
  parserModule.filename = "codex-bundled-acorn.js";
  parserModule.paths = Module._nodeModulePaths(process.cwd());
  parserModule._compile(source, parserModule.filename);
  return parserModule.exports;
}


const acorn = loadBundledAcorn();
const CATEGORIES = [
  "stringLiterals",
  "objectKeys",
  "methodNames",
  "routes",
  "appHostOperations",
  "urlSchemes",
  "featureFlags",
];


function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined) {
      throw new Error(`invalid argument sequence near ${flag ?? "<end>"}`);
    }
    result[flag.slice(2)] = value;
  }
  for (const required of [
    "old",
    "new",
    "old-version",
    "new-version",
    "json-out",
    "markdown-out",
  ]) {
    if (!result[required]) {
      throw new Error(`missing required --${required}`);
    }
  }
  return result;
}


function increment(counter, value) {
  if (typeof value !== "string" || value.length === 0) return;
  counter.set(value, (counter.get(value) ?? 0) + 1);
}


function staticString(node) {
  if (!node || typeof node !== "object") return null;
  if (node.type === "Literal" && typeof node.value === "string") {
    return node.value;
  }
  if (node.type === "TemplateLiteral" && node.expressions.length === 0) {
    return node.quasis[0]?.value?.cooked ?? node.quasis[0]?.value?.raw ?? "";
  }
  return null;
}


function staticPropertyName(node) {
  if (!node || node.computed) return null;
  if (node.key?.type === "Identifier" || node.key?.type === "PrivateIdentifier") {
    return node.key.name;
  }
  return staticString(node.key);
}


function memberName(node) {
  if (!node || node.type !== "MemberExpression") return null;
  if (!node.computed && node.property?.type === "Identifier") {
    return node.property.name;
  }
  return staticString(node.property);
}


function memberObjectName(node) {
  if (!node || node.type !== "MemberExpression") return null;
  if (node.object?.type === "Identifier") return node.object.name;
  if (node.object?.type === "MemberExpression") {
    return memberName(node.object);
  }
  return null;
}


function isRoute(value) {
  if (value.length > 240 || /\s/.test(value)) return false;
  return /^[A-Za-z][A-Za-z0-9_.:@{}+-]*(?:\/[A-Za-z0-9_.:@{}+\-*]+)+$/.test(
    value,
  );
}


function isURLScheme(value) {
  return /^[A-Za-z][A-Za-z0-9+.-]*:(?:\/\/)?[^\s]+$/.test(value);
}


function isFeatureFlag(value) {
  if (value.length > 180 || /\s/.test(value)) return false;
  return /(?:feature|flag|enabled|disabled|experiment|rollout)/i.test(value);
}


function isAppHostOperation(value, parent) {
  if (/^apphost(?:[./:-])[A-Za-z0-9_.:/-]+$/i.test(value)) return true;
  if (parent?.type !== "CallExpression" || parent.arguments?.[0] === undefined) {
    return false;
  }
  if (staticString(parent.arguments[0]) !== value) return false;
  const callName = memberName(parent.callee);
  const objectName = memberObjectName(parent.callee);
  return (
    /apphost/i.test(objectName ?? "") &&
    /^(?:call|handle|invoke|register|request|send)$/i.test(callName ?? "")
  );
}


function emptyInventory() {
  return Object.fromEntries(CATEGORIES.map((category) => [category, new Map()]));
}


function extractInventory(source, sourcePath) {
  const ast = acorn.parse(source, {
    allowHashBang: true,
    ecmaVersion: "latest",
    sourceType: "module",
  });
  const inventory = emptyInventory();

  function visit(node, parent = null) {
    if (!node || typeof node !== "object" || typeof node.type !== "string") {
      return;
    }

    const value = staticString(node);
    if (value !== null) {
      increment(inventory.stringLiterals, value);
      if (isRoute(value)) increment(inventory.routes, value);
      if (isURLScheme(value)) increment(inventory.urlSchemes, value);
      if (isFeatureFlag(value)) increment(inventory.featureFlags, value);
      if (isAppHostOperation(value, parent)) {
        increment(inventory.appHostOperations, value);
      }
    }

    if (node.type === "Property") {
      const key = staticPropertyName(node);
      if (key !== null) {
        increment(inventory.objectKeys, key);
        if (
          node.method ||
          node.value?.type === "FunctionExpression" ||
          node.value?.type === "ArrowFunctionExpression"
        ) {
          increment(inventory.methodNames, key);
        }
      }
    } else if (node.type === "MethodDefinition" || node.type === "PropertyDefinition") {
      const key = staticPropertyName(node);
      if (key !== null) {
        increment(inventory.objectKeys, key);
        if (node.type === "MethodDefinition") increment(inventory.methodNames, key);
      }
    }

    for (const [key, child] of Object.entries(node)) {
      if (key === "start" || key === "end" || key === "loc" || key === "range") {
        continue;
      }
      if (Array.isArray(child)) {
        for (const item of child) visit(item, node);
      } else if (child && typeof child === "object") {
        visit(child, node);
      }
    }
  }

  visit(ast);
  return {
    path: sourcePath,
    bytes: Buffer.byteLength(source),
    sha256: crypto.createHash("sha256").update(source).digest("hex"),
    inventory,
  };
}


function records(counter, values) {
  return values
    .sort((left, right) => left.localeCompare(right))
    .map((value) => ({ value, count: counter.get(value) }));
}


function compareCounters(oldCounter, newCounter) {
  const values = new Set([...oldCounter.keys(), ...newCounter.keys()]);
  const added = new Map();
  const removed = new Map();
  const unchanged = new Map();
  for (const value of values) {
    const oldCount = oldCounter.get(value) ?? 0;
    const newCount = newCounter.get(value) ?? 0;
    const common = Math.min(oldCount, newCount);
    if (newCount > oldCount) added.set(value, newCount - oldCount);
    if (oldCount > newCount) removed.set(value, oldCount - newCount);
    if (common > 0) unchanged.set(value, common);
  }
  return {
    added: records(added, [...added.keys()]),
    removed: records(removed, [...removed.keys()]),
    unchanged: records(unchanged, [...unchanged.keys()]),
  };
}


function totalCount(recordsList) {
  return recordsList.reduce((sum, item) => sum + item.count, 0);
}


function buildDelta(oldInfo, newInfo, oldVersion, newVersion) {
  const semanticDelta = {};
  const summary = {};
  for (const category of CATEGORIES) {
    const delta = compareCounters(
      oldInfo.inventory[category],
      newInfo.inventory[category],
    );
    semanticDelta[category] = delta;
    summary[category] = {
      addedUnique: delta.added.length,
      addedOccurrences: totalCount(delta.added),
      removedUnique: delta.removed.length,
      removedOccurrences: totalCount(delta.removed),
      unchangedUnique: delta.unchanged.length,
      unchangedOccurrences: totalCount(delta.unchanged),
    };
  }
  return {
    schemaVersion: 1,
    parser: { name: "acorn", version: acorn.version, source: "node-bundled" },
    comparisonPolicy: {
      localIdentifiersExcluded: true,
      staticTemplatesIncluded: true,
      dynamicTemplatesExcluded: true,
      occurrenceCountsPreserved: true,
    },
    oldVersion,
    newVersion,
    oldSource: {
      path: oldInfo.path,
      bytes: oldInfo.bytes,
      sha256: oldInfo.sha256,
    },
    newSource: {
      path: newInfo.path,
      bytes: newInfo.bytes,
      sha256: newInfo.sha256,
    },
    summary,
    semanticDelta,
  };
}


function markdownValue(value) {
  return value.replaceAll("`", "\\`").replaceAll("\n", "\\n");
}


function renderMarkdown(delta) {
  const lines = [
    `# JavaScript Semantic Delta: ${delta.oldVersion} → ${delta.newVersion}`,
    "",
    `- Parser: ${delta.parser.name} ${delta.parser.version} (${delta.parser.source})`,
    `- Old SHA-256: \`${delta.oldSource.sha256}\``,
    `- New SHA-256: \`${delta.newSource.sha256}\``,
    "- Local identifiers: excluded to suppress minifier-only renames",
    "",
  ];
  for (const category of CATEGORIES) {
    const deltaCategory = delta.semanticDelta[category];
    const summary = delta.summary[category];
    lines.push(`## ${category}`);
    lines.push("");
    lines.push(
      `Added ${summary.addedUnique} unique / ${summary.addedOccurrences} occurrences; ` +
        `removed ${summary.removedUnique} unique / ${summary.removedOccurrences} occurrences.`,
    );
    lines.push("");
    lines.push("### Added");
    lines.push("");
    if (deltaCategory.added.length === 0) lines.push("- None");
    for (const item of deltaCategory.added) {
      lines.push(`- \`${markdownValue(item.value)}\` (${item.count})`);
    }
    lines.push("");
    lines.push("### Removed");
    lines.push("");
    if (deltaCategory.removed.length === 0) lines.push("- None");
    for (const item of deltaCategory.removed) {
      lines.push(`- \`${markdownValue(item.value)}\` (${item.count})`);
    }
    lines.push("");
  }
  return `${lines.join("\n")}\n`;
}


function writeAtomic(targetPath, contents) {
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  const temporary = `${targetPath}.tmp-${process.pid}`;
  fs.writeFileSync(temporary, contents);
  fs.renameSync(temporary, targetPath);
}


function main() {
  const args = parseArgs(process.argv.slice(2));
  const oldSource = fs.readFileSync(args.old, "utf8");
  const newSource = fs.readFileSync(args.new, "utf8");
  const delta = buildDelta(
    extractInventory(oldSource, args.old),
    extractInventory(newSource, args.new),
    args["old-version"],
    args["new-version"],
  );
  writeAtomic(args["json-out"], `${JSON.stringify(delta, null, 2)}\n`);
  writeAtomic(args["markdown-out"], renderMarkdown(delta));
}


try {
  main();
} catch (error) {
  process.stderr.write(`${error?.stack ?? error}\n`);
  process.exitCode = 1;
}
