"use strict";

const path = require("node:path");
const { pathToFileURL } = require("node:url");
const {
  parentPort,
  workerData,
} = require("node:worker_threads");

function resolveInvocation(argumentsList, cwd) {
  const argumentsCopy = [...argumentsList];
  if (
    argumentsCopy[0] === "-e"
    || argumentsCopy[0] === "--eval"
  ) {
    if (argumentsCopy.length < 2) {
      throw new Error("node eval source is missing");
    }
    return {
      kind: "eval",
      source: argumentsCopy[1],
      arguments: argumentsCopy.slice(2),
    };
  }

  while (
    argumentsCopy.length > 0
    && argumentsCopy[0].startsWith("-")
    && argumentsCopy[0] !== "-"
  ) {
    if (argumentsCopy[0] === "--") {
      argumentsCopy.shift();
      break;
    }
    argumentsCopy.shift();
  }
  if (argumentsCopy.length === 0) {
    throw new Error("node script path is missing");
  }
  const script = path.resolve(
    cwd || process.cwd(),
    argumentsCopy.shift()
  );
  return {
    kind: "script",
    script,
    arguments: argumentsCopy,
  };
}

async function main() {
  const cwd = workerData.cwd || process.cwd();
  process.env.PWD = cwd;
  const invocation = resolveInvocation(
    workerData.arguments,
    cwd
  );
  parentPort.postMessage({ state: "ready" });

  if (invocation.kind === "eval") {
    process.argv = [
      "node",
      ...invocation.arguments,
    ];
    const evaluate = new Function(
      "require",
      "module",
      "__filename",
      "__dirname",
      invocation.source
    );
    const moduleValue = { exports: {} };
    evaluate(
      require,
      moduleValue,
      "[eval]",
      cwd
    );
    return;
  }

  process.argv = [
    "node",
    invocation.script,
    ...invocation.arguments,
  ];
  await import(pathToFileURL(invocation.script).href);
}

main().catch((error) => {
  process.stderr.write(
    `${String(error && error.stack || error)}\n`
  );
  parentPort.postMessage({
    state: "failed",
    message: String(error && error.message || error),
  });
  process.exitCode = 1;
});
