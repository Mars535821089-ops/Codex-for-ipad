"use strict";

const net = require("node:net");
const path = require("node:path");
const { Worker } = require("node:worker_threads");

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || index + 1 >= process.argv.length) {
    throw new Error(`missing ${name}`);
  }
  return process.argv[index + 1];
}

const controlFD = Number.parseInt(
  argumentValue("--control-fd"),
  10
);
if (!Number.isInteger(controlFD) || controlFD < 0) {
  throw new Error("invalid --control-fd");
}

const control = new net.Socket({
  fd: controlFD,
  readable: true,
  writable: true,
});
const workerScript = path.join(
  __dirname,
  "codex-node-mcp-worker.js"
);
const sessions = new Map();
let readBuffer = "";

function send(message) {
  control.write(`${JSON.stringify(message)}\n`);
}

function stopSession(id) {
  const session = sessions.get(id);
  if (!session) {
    return;
  }
  sessions.delete(id);
  session.worker.stdin.end();
  void session.worker.terminate();
}

function startSession(message) {
  if (sessions.has(message.id)) {
    throw new Error(`duplicate session: ${message.id}`);
  }
  const environment = {
    ...process.env,
    ...(message.environment || {}),
  };
  const worker = new Worker(workerScript, {
    env: environment,
    stdin: true,
    stdout: true,
    stderr: true,
    workerData: {
      id: message.id,
      arguments: message.arguments || [],
      cwd: message.cwd || null,
    },
  });
  sessions.set(message.id, { worker });
  worker.stdout.on("data", (chunk) => {
    send({
      type: "stream",
      id: message.id,
      stream: "stdout",
      data: chunk.toString("base64"),
    });
  });
  worker.stderr.on("data", (chunk) => {
    send({
      type: "stream",
      id: message.id,
      stream: "stderr",
      data: chunk.toString("base64"),
    });
  });
  worker.on("message", (event) => {
    send({
      type: "sessionState",
      id: message.id,
      ...event,
    });
  });
  worker.on("error", (error) => {
    send({
      type: "sessionState",
      id: message.id,
      state: "failed",
      message: String(error && error.stack || error),
    });
  });
  worker.on("exit", (code) => {
    sessions.delete(message.id);
    send({
      type: "sessionExit",
      id: message.id,
      code,
    });
  });
  send({
    type: "sessionState",
    id: message.id,
    state: "starting",
  });
}

function handle(message) {
  switch (message.op) {
    case "start":
      startSession(message);
      return;
    case "stdin": {
      const session = sessions.get(message.id);
      if (!session) {
        throw new Error(`unknown session: ${message.id}`);
      }
      session.worker.stdin.write(
        Buffer.from(message.data, "base64")
      );
      return;
    }
    case "stop":
      stopSession(message.id);
      return;
    default:
      throw new Error(`unknown operation: ${message.op}`);
  }
}

control.setEncoding("utf8");
control.on("data", (chunk) => {
  readBuffer += chunk;
  while (true) {
    const newline = readBuffer.indexOf("\n");
    if (newline < 0) {
      return;
    }
    const line = readBuffer.slice(0, newline);
    readBuffer = readBuffer.slice(newline + 1);
    if (!line) {
      continue;
    }
    try {
      handle(JSON.parse(line));
    } catch (error) {
      send({
        type: "runtimeError",
        message: String(error && error.stack || error),
      });
    }
  }
});
control.on("close", () => {
  for (const id of sessions.keys()) {
    stopSession(id);
  }
  process.exit(0);
});
control.on("error", (error) => {
  process.stderr.write(
    `Codex Node control channel failed: ${error}\n`
  );
  process.exit(1);
});

send({
  type: "runtimeReady",
  nodeVersion: process.version,
});
