import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const arkdeckPath = requiredEnvironment("ARKDECK_PI_ARKDECK_PATH");
const socketPath = requiredEnvironment("ARKDECK_PI_AGENTD_SOCKET");
const allowSensitiveArtifacts =
  process.env.ARKDECK_PI_ALLOW_SENSITIVE_ARTIFACTS === "1";

const MAX_OPERATION_RUNS = 8;
const MAX_WALL_CLOCK_SECONDS = 30 * 60;
const MAX_ARTIFACT_BYTES = 64 * 1024 * 1024;
const MAX_ARTIFACT_READ_BYTES = 4 * 1024 * 1024;
const MAX_TOOL_OUTPUT_BYTES = 8 * 1024 * 1024;
const MAX_MODEL_ARTIFACT_TEXT_BYTES = 256 * 1024;
const CAPTURE_ARTIFACT_BUDGET_BYTES = 8 * 1024 * 1024;

type JSONRecord = Record<string, unknown>;
type CommandResult = {
  status: number;
  stdout: string;
  stderr: string;
};
type PendingPause = {
  resumeToken: string;
  selectionOptions: string[];
  userTurn: number;
};

const budget = {
  startedAt: Date.now(),
  operationRuns: 0,
  artifactBytesObserved: 0,
  artifactBytesRead: 0,
  consecutiveFailures: 0,
  stoppedReason: undefined as string | undefined,
};

let userTurn = 0;
let pendingPause: PendingPause | undefined;
const currentChatArtifacts = new Map<string, Set<string>>();

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`ArkDeck Pi extension requires ${name}`);
  return value;
}

function isRecord(value: unknown): value is JSONRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function safeIdentifier(value: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value);
}

function childEnvironment(): Record<string, string> {
  const environment: Record<string, string> = {};
  for (const name of ["HOME", "TMPDIR", "LANG", "LC_ALL", "TZ"]) {
    const value = process.env[name];
    if (value) environment[name] = value;
  }
  return environment;
}

async function runArkDeck(
  arguments_: string[],
  signal?: AbortSignal,
): Promise<CommandResult> {
  return await new Promise((resolve, reject) => {
    const child = spawn(arkdeckPath, arguments_, {
      env: childEnvironment(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let byteCount = 0;
    let settled = false;

    const settle = (work: () => void) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener("abort", abort);
      work();
    };
    const append = (destination: Buffer[], chunk: Buffer) => {
      byteCount += chunk.length;
      if (byteCount > MAX_TOOL_OUTPUT_BYTES) {
        child.kill("SIGTERM");
        settle(() => reject(new Error("ArkDeck tool output exceeded 8 MiB")));
        return;
      }
      destination.push(chunk);
    };
    const abort = () => {
      child.kill("SIGTERM");
      settle(() => reject(new Error("ArkDeck tool call was cancelled")));
    };

    child.stdout.on("data", (chunk: Buffer) => append(stdout, chunk));
    child.stderr.on("data", (chunk: Buffer) => append(stderr, chunk));
    child.on("error", (error) => settle(() => reject(error)));
    child.on("close", (status) =>
      settle(() =>
        resolve({
          status: status ?? 1,
          stdout: Buffer.concat(stdout).toString("utf8"),
          stderr: Buffer.concat(stderr).toString("utf8"),
        }),
      ),
    );
    if (signal?.aborted) abort();
    else signal?.addEventListener("abort", abort, { once: true });
  });
}

function parseJSON(result: CommandResult, action: string): unknown {
  const output = result.stdout.trim();
  if (!output) {
    const detail = sanitizedError(result.stderr) || `exit status ${result.status}`;
    throw new Error(`${action} returned no JSON: ${detail}`);
  }
  try {
    return JSON.parse(output);
  } catch {
    throw new Error(`${action} returned malformed JSON`);
  }
}

function sanitizedError(value: string): string {
  return value
    .replace(/resume-[A-Za-z0-9._-]+/g, "resume-[stored by ArkDeck]")
    .trim();
}

function elapsedSeconds(): number {
  return Math.floor((Date.now() - budget.startedAt) / 1000);
}

function budgetSnapshot(): JSONRecord {
  return {
    operationRuns: budget.operationRuns,
    maxOperationRuns: MAX_OPERATION_RUNS,
    elapsedSeconds: elapsedSeconds(),
    maxWallClockSeconds: MAX_WALL_CLOCK_SECONDS,
    artifactBytesObserved: budget.artifactBytesObserved,
    maxArtifactBytes: MAX_ARTIFACT_BYTES,
    artifactBytesRead: budget.artifactBytesRead,
    maxArtifactReadBytes: MAX_ARTIFACT_READ_BYTES,
    stoppedReason: budget.stoppedReason ?? null,
  };
}

function assertCanRunOperation(): void {
  if (budget.stoppedReason) throw new Error(budget.stoppedReason);
  if (elapsedSeconds() >= MAX_WALL_CLOCK_SECONDS) {
    budget.stoppedReason = "The 30-minute Agent wall-clock budget is exhausted.";
    throw new Error(budget.stoppedReason);
  }
  if (budget.operationRuns >= MAX_OPERATION_RUNS) {
    budget.stoppedReason = "The 8-operation Agent run budget is exhausted.";
    throw new Error(budget.stoppedReason);
  }
  if (budget.artifactBytesObserved >= MAX_ARTIFACT_BYTES) {
    budget.stoppedReason = "The 64 MiB Agent Artifact budget is exhausted.";
    throw new Error(budget.stoppedReason);
  }
}

function receiptArtifactBytes(receipt: unknown): number {
  if (!isRecord(receipt) || !Array.isArray(receipt.artifacts)) return 0;
  return receipt.artifacts.reduce((total, artifact) => {
    if (!isRecord(artifact) || typeof artifact.byteCount !== "number") return total;
    return total + Math.max(0, artifact.byteCount);
  }, 0);
}

function noteRuntimeFailure(detail: string): void {
  budget.consecutiveFailures += 1;
  if (/authorization\s*required/i.test(detail)) {
    budget.stoppedReason =
      "Runtime requires authorization. This read-only Agent session cannot widen authority.";
  } else if (budget.consecutiveFailures >= 2) {
    budget.stoppedReason =
      "Runtime failed twice consecutively. The Agent stopped instead of repeating the same strategy.";
  }
}

function capturePause(receipt: unknown): void {
  if (!isRecord(receipt) || !Array.isArray(receipt.humanActions)) return;
  const last = receipt.humanActions.at(-1);
  if (!isRecord(last) || typeof last.resumeToken !== "string") return;
  const selectionOptions = Array.isArray(last.selectionOptions)
    ? last.selectionOptions.filter((value): value is string => typeof value === "string")
    : [];
  pendingPause = {
    resumeToken: last.resumeToken,
    selectionOptions,
    userTurn,
  };
  budget.stoppedReason =
    "Runtime is waiting for a physical user action. Wait for the user's next message before resuming.";
}

function sanitizeReceipt(receipt: unknown): unknown {
  if (!isRecord(receipt)) return receipt;
  const copy: JSONRecord = { ...receipt };
  if (Array.isArray(copy.humanActions)) {
    copy.humanActions = copy.humanActions.map((action) => {
      if (!isRecord(action)) return action;
      const sanitized = { ...action };
      delete sanitized.resumeToken;
      return sanitized;
    });
  }
  return copy;
}

async function artifactList(jobID: string, signal?: AbortSignal): Promise<unknown> {
  const result = await runArkDeck(
    ["artifact", "list", "--job", jobID, "--socket", socketPath, "--json"],
    signal,
  );
  return parseJSON(result, "artifact list");
}

function rememberCurrentChatArtifacts(jobID: string, artifacts: unknown): void {
  if (!Array.isArray(artifacts)) return;
  const identifiers = new Set<string>();
  for (const artifact of artifacts) {
    if (
      isRecord(artifact) &&
      typeof artifact.artifactId === "string" &&
      safeIdentifier(artifact.artifactId)
    ) {
      identifiers.add(artifact.artifactId);
    }
  }
  currentChatArtifacts.set(jobID, identifiers);
}

async function finishRuntimeInvocation(
  result: CommandResult,
  signal?: AbortSignal,
): Promise<JSONRecord> {
  let receipt: unknown;
  try {
    receipt = parseJSON(result, "Agent Runtime execution");
  } catch (error) {
    noteRuntimeFailure(sanitizedError(result.stderr));
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(
      budget.stoppedReason ? `${detail} ${budget.stoppedReason}` : detail,
    );
  }
  budget.artifactBytesObserved += receiptArtifactBytes(receipt);

  if (isRecord(receipt) && receipt.outcomeUnknown === true) {
    budget.stoppedReason =
      "Runtime reported outcomeUnknown. No new operation will be dispatched; use typed reconcile outside this chat.";
  } else if (isRecord(receipt) && receipt.terminalState === "awaitingHumanAction") {
    capturePause(receipt);
  } else if (result.status !== 0) {
    noteRuntimeFailure(sanitizedError(result.stderr));
  } else {
    budget.consecutiveFailures = 0;
  }

  if (budget.artifactBytesObserved >= MAX_ARTIFACT_BYTES && !budget.stoppedReason) {
    budget.stoppedReason = "The 64 MiB Agent Artifact budget is exhausted.";
  }

  const jobID = isRecord(receipt) && typeof receipt.jobID === "string"
    ? receipt.jobID
    : undefined;
  let artifacts: unknown = [];
  if (jobID && safeIdentifier(jobID)) {
    try {
      artifacts = await artifactList(jobID, signal);
      rememberCurrentChatArtifacts(jobID, artifacts);
    } catch (error) {
      artifacts = { error: error instanceof Error ? error.message : String(error) };
    }
  }

  return {
    execution: sanitizeReceipt(receipt),
    artifacts,
    commandStatus: result.status,
    error: result.status === 0 ? null : sanitizedError(result.stderr),
    budget: budgetSnapshot(),
  };
}

async function runTypedOperation(
  operation: "observe.device@1" | "capture.diagnostics@1",
  inputs: JSONRecord,
  targetID: string | undefined,
  signal?: AbortSignal,
): Promise<JSONRecord> {
  assertCanRunOperation();
  if (targetID && !safeIdentifier(targetID)) throw new Error("targetId is malformed");
  budget.operationRuns += 1;

  let directory: string | undefined;
  try {
    const arguments_ = [
      "agent", "run",
      "--operation", operation,
      "--execution-id", randomUUID().toLowerCase(),
      "--socket", socketPath,
      "--json",
    ];
    if (targetID) arguments_.push("--target", targetID);
    if (Object.keys(inputs).length > 0) {
      directory = await mkdtemp(join(tmpdir(), "arkdeck-pi-"));
      const inputPath = join(directory, "inputs.json");
      await writeFile(inputPath, JSON.stringify(inputs), { encoding: "utf8", mode: 0o600 });
      arguments_.push("--inputs-file", inputPath);
    }
    let result: CommandResult;
    try {
      result = await runArkDeck(arguments_, signal);
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      noteRuntimeFailure(detail);
      throw error;
    }
    return await finishRuntimeInvocation(result, signal);
  } finally {
    if (directory) await rm(directory, { recursive: true, force: true });
  }
}

function toolResult(value: unknown) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }],
    details: value,
  };
}

export default function arkdeckExtension(pi: ExtensionAPI) {
  pi.on("user_bash", () => ({
    result: {
      output: "Raw commands are disabled in ArkDeck Agent chat. Use a typed ArkDeck tool.",
      exitCode: 126,
      cancelled: false,
      truncated: false,
    },
  }));

  pi.on("before_agent_start", async () => {
    userTurn += 1;
  });

  pi.registerTool({
    name: "arkdeck_runtime_overview",
    label: "ArkDeck runtime overview",
    description:
      "Read ArkDeck daemon health, typed operation availability, and adopted device targets. This performs no device operation.",
    promptSnippet: "Inspect ArkDeck Runtime health, operation availability, and adopted targets",
    promptGuidelines: [
      "Use arkdeck_runtime_overview before a device operation when target or availability is unknown.",
    ],
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, signal) {
      const doctor = parseJSON(
        await runArkDeck(["doctor", "--socket", socketPath, "--json"], signal),
        "doctor",
      );
      const operations = parseJSON(
        await runArkDeck(["operation", "list", "--socket", socketPath, "--json"], signal),
        "operation list",
      );
      const targets = parseJSON(
        await runArkDeck(["device", "list", "--socket", socketPath, "--json"], signal),
        "device list",
      );
      return toolResult({ doctor, operations, targets, budget: budgetSnapshot() });
    },
  });

  pi.registerTool({
    name: "arkdeck_observe_device",
    label: "Observe OpenHarmony device",
    description:
      "Run the published observe.device@1 typed Runtime operation. Omit targetId only when ArkDeck can safely select or adopt one device.",
    promptSnippet: "Run a typed, read-only observation of one OpenHarmony device",
    promptGuidelines: [
      "Use arkdeck_observe_device for current device, binding, HDC server, and tool facts.",
    ],
    parameters: Type.Object({
      targetId: Type.Optional(
        Type.String({
          description: "Exact adopted ArkDeck target ID from arkdeck_runtime_overview",
          pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
        }),
      ),
    }),
    async execute(_toolCallId, params, signal) {
      return toolResult(
        await runTypedOperation("observe.device@1", {}, params.targetId, signal),
      );
    },
  });

  pi.registerTool({
    name: "arkdeck_capture_diagnostics",
    label: "Capture OpenHarmony diagnostics",
    description:
      "Run the read-only shape of capture.diagnostics@1 for bounded HiLog, UI dump, optional crash index, and derived summaries. Trace, screenshot, and component-tree mutation legs are intentionally unavailable.",
    promptSnippet: "Capture bounded read-only diagnostics through ArkDeck Runtime",
    promptGuidelines: [
      "Use arkdeck_capture_diagnostics only after confirming the target and choose the shortest useful duration.",
    ],
    parameters: Type.Object({
      durationSeconds: Type.Integer({
        description: "Bounded HiLog window in seconds",
        minimum: 1,
        maximum: 120,
      }),
      targetId: Type.Optional(
        Type.String({
          description: "Exact adopted ArkDeck target ID",
          pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
        }),
      ),
      bundleName: Type.Optional(
        Type.String({
          description: "Optional reverse-DNS application bundle name for liveness readback",
          maxLength: 200,
          pattern: "^[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z][a-zA-Z0-9_]*)+$",
        }),
      ),
      abilityName: Type.Optional(
        Type.String({
          description: "Optional typed ability identity",
          maxLength: 200,
          pattern: "^[a-zA-Z][a-zA-Z0-9_.]*$",
        }),
      ),
      processName: Type.Optional(
        Type.String({
          description: "Optional typed process identity",
          maxLength: 200,
          pattern: "^[a-zA-Z][a-zA-Z0-9_.:]*$",
        }),
      ),
      hilogFilters: Type.Optional(
        Type.Array(Type.String({ maxLength: 200 }), {
          description: "Up to 16 typed HiLog filter expressions",
          maxItems: 16,
        }),
      ),
      includeUIDump: Type.Optional(
        Type.Boolean({ description: "Include the read-only window inventory; defaults to true" }),
      ),
      includeCrashIndex: Type.Optional(
        Type.Boolean({ description: "Include the read-only Faultlogger index" }),
      ),
    }),
    async execute(_toolCallId, params, signal) {
      const inputs: JSONRecord = {
        durationSeconds: params.durationSeconds,
        totalArtifactByteBudget: CAPTURE_ARTIFACT_BUDGET_BYTES,
        // `strict` is catalogued but intentionally unavailable until Runtime
        // publishes an implementation. Keep this minimal loop on the working
        // standard redactor; Artifact privacy still independently gates what
        // Pi may read.
        redactionProfile: "standard",
      };
      if (params.bundleName) inputs.bundleName = params.bundleName;
      if (params.abilityName) inputs.abilityName = params.abilityName;
      if (params.processName) inputs.processName = params.processName;
      if (params.hilogFilters) inputs.hilogFilters = params.hilogFilters;
      if (params.includeUIDump !== undefined) inputs.uiDump = params.includeUIDump;
      if (params.includeCrashIndex !== undefined) inputs.crashLogs = params.includeCrashIndex;
      return toolResult(
        await runTypedOperation(
          "capture.diagnostics@1",
          inputs,
          params.targetId,
          signal,
        ),
      );
    },
  });

  pi.registerTool({
    name: "arkdeck_read_artifact",
    label: "Read ArkDeck Artifact",
    description: allowSensitiveArtifacts
      ? "Read bounded text from one Artifact produced in this chat. Sensitive Artifact sharing is enabled for this session; binary products are never returned."
      : "Read bounded text from one standard-privacy Artifact produced in this chat. Sensitive products stay local and are not returned to Pi.",
    promptSnippet: "Read bounded text from a named ArkDeck Artifact",
    promptGuidelines: [
      "Use arkdeck_read_artifact only for a job and Artifact ID returned by an ArkDeck tool in this chat.",
    ],
    parameters: Type.Object({
      jobId: Type.String({ pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$" }),
      artifactId: Type.String({ pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$" }),
    }),
    async execute(_toolCallId, params, signal) {
      if (!safeIdentifier(params.jobId) || !safeIdentifier(params.artifactId)) {
        throw new Error("jobId or artifactId is malformed");
      }
      if (!currentChatArtifacts.get(params.jobId)?.has(params.artifactId)) {
        throw new Error(
          "The Artifact was not produced by an ArkDeck operation in this chat.",
        );
      }
      if (budget.artifactBytesRead >= MAX_ARTIFACT_READ_BYTES) {
        throw new Error("The 4 MiB Artifact read budget is exhausted.");
      }
      const common = [
        "--job", params.jobId,
        "--artifact", params.artifactId,
        "--socket", socketPath,
        "--json",
      ];
      const metadata = parseJSON(
        await runArkDeck(["artifact", "inspect", ...common], signal),
        "artifact inspect",
      );
      if (!isRecord(metadata)) throw new Error("artifact inspect returned malformed metadata");
      if (metadata.privacy !== "standard" && metadata.privacy !== "sensitive") {
        return toolResult({
          metadata,
          content: null,
          blocked: "Artifact privacy classification is missing or unknown.",
          budget: budgetSnapshot(),
        });
      }
      if (metadata.privacy === "sensitive" && !allowSensitiveArtifacts) {
        return toolResult({
          metadata,
          content: null,
          blocked:
            "Sensitive Artifact text stays local. Review this metadata, then restart agent chat with --allow-sensitive-artifacts if sharing it with the selected Pi model is appropriate.",
          budget: budgetSnapshot(),
        });
      }
      if (
        typeof metadata.mediaType !== "string" ||
        !(metadata.mediaType === "application/json" || metadata.mediaType.startsWith("text/"))
      ) {
        return toolResult({
          metadata,
          content: null,
          blocked: "Binary Artifact content is not exposed in the minimal Pi Agent.",
          budget: budgetSnapshot(),
        });
      }

      const readArguments = ["artifact", "read", ...common];
      if (metadata.privacy === "sensitive") readArguments.push("--allow-sensitive");
      const read = parseJSON(await runArkDeck(readArguments, signal), "artifact read");
      if (!isRecord(read) || typeof read.base64 !== "string") {
        throw new Error("artifact read returned malformed content");
      }
      const bytes = Buffer.from(read.base64, "base64");
      budget.artifactBytesRead += bytes.length;
      const visible = bytes.subarray(0, MAX_MODEL_ARTIFACT_TEXT_BYTES);
      return toolResult({
        metadata,
        content: visible.toString("utf8"),
        truncatedForModel: bytes.length > visible.length || read.eof === false,
        bytesReturnedToModel: visible.length,
        budget: budgetSnapshot(),
      });
    },
  });

  pi.registerTool({
    name: "arkdeck_resume_after_user_action",
    label: "Resume ArkDeck operation",
    description:
      "Resume the exact persisted Runtime execution after ArkDeck requested a physical action. This is accepted only after the user sends a new message; it cannot alter the operation, target, inputs, or authority.",
    promptSnippet: "Resume the paused ArkDeck execution after the user completes the requested action",
    promptGuidelines: [
      "Call arkdeck_resume_after_user_action only after the user explicitly says the requested physical action is complete.",
    ],
    parameters: Type.Object({
      selection: Type.Optional(
        Type.String({ description: "Exact target or candidate selection offered by Runtime" }),
      ),
    }),
    async execute(_toolCallId, params, signal) {
      const pause = pendingPause;
      if (!pause) throw new Error("No ArkDeck execution is waiting for a user action.");
      if (userTurn <= pause.userTurn) {
        throw new Error("Wait for the user's next message before resuming this execution.");
      }
      if (pause.selectionOptions.length > 0) {
        if (!params.selection || !pause.selectionOptions.includes(params.selection)) {
          throw new Error(
            `Choose one Runtime selection: ${pause.selectionOptions.join(", ")}`,
          );
        }
      } else if (params.selection !== undefined) {
        throw new Error("This Runtime pause does not accept a selection.");
      }

      budget.stoppedReason = undefined;
      pendingPause = undefined;
      const arguments_ = [
        "agent", "resume",
        "--resume-token", pause.resumeToken,
        "--socket", socketPath,
        "--json",
      ];
      if (params.selection) arguments_.push("--selection", params.selection);
      const result = await runArkDeck(arguments_, signal);
      return toolResult(await finishRuntimeInvocation(result, signal));
    },
  });
}
