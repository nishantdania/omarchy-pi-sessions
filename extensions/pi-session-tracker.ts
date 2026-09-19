import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, readlink, rename, unlink, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { homedir } from "node:os";

const STATE_DIR = join(
  process.env.XDG_STATE_HOME || join(homedir(), ".local", "state"),
  "pi",
  "session-tracker",
);
const INSTANCE_ID = String(process.pid);
const STATE_PATH = join(STATE_DIR, `${INSTANCE_ID}.json`);
const TITLE_MODEL_PROVIDER = "openai-codex";
const TITLE_MODEL_ID = "gpt-5.6-luna";

type SessionStatus = "idle" | "running" | "waiting" | "done";

interface SessionRecord {
  schemaVersion: 1;
  instanceId: string;
  pid: number;
  processStartTicks: string;
  tty: string;
  sessionId: string;
  sessionFile: string;
  sessionName: string;
  title: string;
  titleSource: "generated" | "manual" | "fallback";
  cwd: string;
  project: string;
  model: string;
  status: SessionStatus;
  statusDetail: string;
  terminalTitle: string;
  startedAt: string;
  activityAt: string;
  heartbeatAt: string;
  settledAt: string;
}

function now(): string {
  return new Date().toISOString();
}

function processStartTicks(): string {
  try {
    const stat = require("node:fs").readFileSync(`/proc/${process.pid}/stat`, "utf8") as string;
    const fields = stat.slice(stat.lastIndexOf(") ") + 2).trim().split(/\s+/);
    return fields[19] || "";
  } catch {
    return "";
  }
}

async function currentTty(): Promise<string> {
  try {
    return await readlink("/proc/self/fd/0");
  } catch {
    return "";
  }
}

function textFromResponse(response: any): string {
  return (response.content || [])
    .filter((part: any) => part && part.type === "text")
    .map((part: any) => String(part.text || ""))
    .join(" ");
}

function cleanTitle(raw: string): string {
  let title = String(raw || "")
    .split(/\r?\n/)[0]
    .replace(/^\s*(?:title\s*:\s*)?/i, "")
    .replace(/^[`*_'“”"‘’]+|[`*_'“”"‘’]+$/g, "")
    .replace(/[\x00-\x1f\x7f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();

  if (title.length > 56) title = title.slice(0, 53).trimEnd() + "…";
  return title;
}

function fallbackTitle(prompt: string, project: string): string {
  const cleaned = String(prompt || "")
    .replace(/^\/[\w:-]+\s*/, "")
    .replace(/[`*_#>\[\]()]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!cleaned) return project || "Pi session";
  return cleanTitle(cleaned.split(" ").slice(0, 6).join(" ")) || project || "Pi session";
}

export default function (pi: ExtensionAPI) {
  let heartbeat: ReturnType<typeof setInterval> | undefined;
  let titleRequested = false;
  let clearingGeneratedName = false;
  let writeQueue: Promise<void> = Promise.resolve();
  let record: SessionRecord = {
    schemaVersion: 1,
    instanceId: INSTANCE_ID,
    pid: process.pid,
    processStartTicks: processStartTicks(),
    tty: "",
    sessionId: "",
    sessionFile: "",
    sessionName: "",
    title: "Pi session",
    titleSource: "fallback",
    cwd: process.cwd(),
    project: basename(process.cwd()),
    model: "",
    status: "idle",
    statusDetail: "Ready",
    terminalTitle: "",
    startedAt: now(),
    activityAt: now(),
    heartbeatAt: now(),
    settledAt: "",
  };

  function displayTerminalTitle(): string {
    return `π · ${record.title} · ${INSTANCE_ID}`;
  }

  function persist(ctx?: ExtensionContext, activity = false): void {
    if (activity) record.activityAt = now();
    record.heartbeatAt = now();
    record.terminalTitle = displayTerminalTitle();
    if (ctx?.hasUI) ctx.ui.setTitle(record.terminalTitle);

    const snapshot = JSON.stringify(record, null, 2) + "\n";
    writeQueue = writeQueue
      .then(async () => {
        await mkdir(STATE_DIR, { recursive: true });
        const temporary = `${STATE_PATH}.${randomUUID()}.tmp`;
        await writeFile(temporary, snapshot, { encoding: "utf8", mode: 0o600 });
        await rename(temporary, STATE_PATH);
      })
      .catch(() => undefined);
  }

  function updateModel(ctx: ExtensionContext): void {
    record.model = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : "";
  }

  async function generateTitle(prompt: string, ctx: ExtensionContext, targetSessionId: string): Promise<void> {
    const fallback = fallbackTitle(prompt, record.project);
    const model = ctx.modelRegistry.find(TITLE_MODEL_PROVIDER, TITLE_MODEL_ID);
    let title = fallback;

    if (model && ctx.modelRegistry.hasConfiguredAuth(model)) {
      try {
        const response = await ctx.modelRegistry.complete(
          model,
          {
            messages: [
              {
                role: "user" as const,
                content: [
                  {
                    type: "text" as const,
                    text: `Create a concise 3-6 word title for this coding task. Use specific nouns and verbs. Return only the title with no quotes, markdown, punctuation suffix, or explanation.\n\nTask:\n${prompt.slice(0, 4000)}`,
                  },
                ],
                timestamp: Date.now(),
              },
            ],
          },
          {
            reasoningEffort: "low",
            maxTokens: 40,
            cacheRetention: "none",
            sessionId: randomUUID(),
          },
        );
        title = cleanTitle(textFromResponse(response)) || fallback;
      } catch {
        title = fallback;
      }
    }

    if (record.sessionId !== targetSessionId || pi.getSessionName()) return;

    record.title = title;
    record.titleSource = model ? "generated" : "fallback";
    persist(ctx, true);
  }

  pi.on("session_start", async (_event, ctx) => {
    if (heartbeat) clearInterval(heartbeat);
    titleRequested = false;
    clearingGeneratedName = false;

    const sessionId = ctx.sessionManager.getSessionId();
    let sessionName = pi.getSessionName() || "";
    let generatedTitle = "";
    try {
      const previous = JSON.parse(await readFile(STATE_PATH, "utf8")) as SessionRecord;
      if (previous.sessionId === sessionId && previous.titleSource === "generated" && previous.title === sessionName) {
        generatedTitle = previous.title;
        sessionName = "";
        titleRequested = true;
        clearingGeneratedName = true;
      }
    } catch {}

    record = {
      ...record,
      tty: await currentTty(),
      sessionId,
      sessionFile: ctx.sessionManager.getSessionFile() || "",
      sessionName,
      title: sessionName || generatedTitle || basename(ctx.cwd) || "Pi session",
      titleSource: sessionName ? "manual" : generatedTitle ? "generated" : "fallback",
      cwd: ctx.cwd,
      project: basename(ctx.cwd),
      status: "idle",
      statusDetail: "Ready",
      startedAt: now(),
      activityAt: now(),
      settledAt: "",
    };
    if (clearingGeneratedName) pi.setSessionName(undefined);
    updateModel(ctx);
    persist(ctx);

    heartbeat = setInterval(() => persist(ctx), 15000);
  });

  pi.on("before_agent_start", (event, ctx) => {
    record.status = "running";
    record.statusDetail = "Working";
    record.settledAt = "";
    updateModel(ctx);
    persist(ctx, true);

    if (!titleRequested && !pi.getSessionName()) {
      titleRequested = true;
      const targetSessionId = record.sessionId;
      void generateTitle(event.prompt, ctx, targetSessionId);
    }
  });

  pi.on("ui_prompt_start", (event, ctx) => {
    record.status = "waiting";
    record.statusDetail = event.title ? `Waiting: ${event.title}` : "Waiting for input";
    persist(ctx, true);
  });

  pi.on("ui_prompt_end", (_event, ctx) => {
    record.status = "running";
    record.statusDetail = "Working";
    persist(ctx, true);
  });

  pi.on("agent_settled", (_event, ctx) => {
    record.status = "done";
    record.statusDetail = "Ready to check";
    record.settledAt = now();
    updateModel(ctx);
    persist(ctx, true);
  });

  pi.on("model_select", (_event, ctx) => {
    updateModel(ctx);
    persist(ctx, true);
  });

  pi.on("session_info_changed", (event, ctx) => {
    const name = event.name || "";
    record.sessionName = name;
    if (clearingGeneratedName && !name) {
      clearingGeneratedName = false;
    } else if (name) {
      record.title = name;
      record.titleSource = "manual";
    } else {
      record.title = record.project || "Pi session";
      record.titleSource = "fallback";
    }
    persist(ctx, true);
  });

  pi.on("session_shutdown", async (event, ctx) => {
    if (heartbeat) {
      clearInterval(heartbeat);
      heartbeat = undefined;
    }

    if (event.reason !== "reload" && event.reason !== "new" && event.reason !== "resume" && event.reason !== "fork") {
      writeQueue = writeQueue.then(async () => {
        try {
          await unlink(STATE_PATH);
        } catch {}
      });
      await writeQueue;
    }
  });
}
