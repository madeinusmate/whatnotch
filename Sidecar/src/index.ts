import { mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { Agent, Cursor, type SDKImage, type SDKMessage, type SDKUserMessage } from "@cursor/sdk";

type Attachment = { name: string; kind?: string; mime?: string; data?: string };

type Inbound =
  | { type: "start"; apiKey: string; workspace: string; agentId?: string; modelId?: string }
  | { type: "send"; text: string; modelId?: string; sessionId?: string; attachments?: Attachment[] }
  | { type: "cancel"; sessionId?: string }
  | { type: "newChat"; sessionId?: string }
  | { type: "open"; agentId?: string; sessionId?: string }
  | { type: "setModel"; modelId: string };

type Row = { id: string; role: "user" | "assistant" | "tool"; text: string };

type CatalogItem = Awaited<ReturnType<typeof Cursor.models.list>>[number];

const emit = (message: Record<string, unknown>) => {
  process.stdout.write(`AGN\t${JSON.stringify(message)}\n`);
};

const logError = (error: unknown, secret: string) => {
  const text = error instanceof Error ? error.message : "error";
  process.stderr.write(`${secret ? text.split(secret).join("[key]") : text}\n`);
};

const safeError = (error: unknown) => {
  const text = error instanceof Error ? error.message : "";
  const safe = apiKey ? text.split(apiKey).join("[key]") : text;
  return safe.split("\n")[0]?.trim() ?? "";
};

const friendly = (error: unknown) => {
  const text = safeError(error);
  if (/401|403|unauthor|invalid api key|auth/i.test(text)) return "That API key was rejected.";
  if (/explicit `model`|cannot use this model/i.test(text)) return "Choose a model in settings, then send again.";
  if (text) return text.length > 180 ? `${text.slice(0, 177)}...` : text;
  return "The agent could not start.";
};

const rememberModel = () => {
  if (modelId && catalog.some((item) => item.id === modelId)) return;
  modelId = catalog[0]?.id ?? "";
};

const firstString = (record: Record<string, unknown>, keys: string[]) => {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
};

const summarize = (name: string, args: unknown) => {
  const record = args && typeof args === "object" ? (args as Record<string, unknown>) : {};
  const command = firstString(record, ["command", "cmd", "script"]);
  if (command) return command.length > 180 ? `${command.slice(0, 177)}...` : command;
  const path = firstString(record, ["path", "file_path", "target_file", "file", "target", "filename", "globPattern"]);
  if (path) return `${name} ${path}`;
  const query = firstString(record, ["pattern", "searchTerm", "url", "query"]);
  if (query) return `${name} ${query.length > 80 ? `${query.slice(0, 77)}...` : query}`;
  return name || "tool";
};

const rowsFromContent = (content: unknown, role: "user" | "assistant"): Row[] => {
  if (typeof content === "string") {
    return content ? [{ id: crypto.randomUUID(), role, text: content }] : [];
  }
  if (!Array.isArray(content)) return [];
  const rows: Row[] = [];
  const texts: string[] = [];
  const flush = () => {
    const text = texts.join("");
    texts.length = 0;
    if (text) rows.push({ id: crypto.randomUUID(), role, text });
  };
  for (const block of content) {
    if (!block || typeof block !== "object") continue;
    const item = block as Record<string, unknown>;
    if (item.type === "text" && typeof item.text === "string") texts.push(item.text);
    if (item.type === "tool_use") {
      flush();
      rows.push({
        id: crypto.randomUUID(),
        role: "tool",
        text: summarize(String(item.name ?? "tool"), item.input),
      });
    }
  }
  flush();
  return rows;
};

const asRecord = (value: unknown) =>
  value && typeof value === "object" ? (value as Record<string, unknown>) : null;

const rowsFromTurn = (message: { uuid?: string; message?: unknown }): Row[] | null => {
  const turn = asRecord(asRecord(message.message)?.turn);
  const value = asRecord(turn?.value);
  if (!value) return null;
  const rows: Row[] = [];
  const userText = firstString(asRecord(value.userMessage) ?? {}, ["text"]);
  if (userText) rows.push({ id: message.uuid || crypto.randomUUID(), role: "user", text: userText });
  const steps = Array.isArray(value.steps) ? value.steps : [];
  for (const step of steps) {
    const item = asRecord(asRecord(step)?.message);
    const stepValue = asRecord(item?.value);
    if (!item || !stepValue) continue;
    if (item.case === "assistantMessage") {
      const text = firstString(stepValue, ["text"]);
      if (text) rows.push({ id: crypto.randomUUID(), role: "assistant", text });
    }
    if (item.case === "toolCall") {
      const tool = asRecord(stepValue.tool);
      const name = String(tool?.case ?? "tool").replace(/ToolCall$/, "");
      const id = typeof stepValue.toolCallId === "string" && stepValue.toolCallId
        ? stepValue.toolCallId
        : crypto.randomUUID();
      rows.push({ id, role: "tool", text: summarize(name, asRecord(tool?.value)?.args) });
    }
  }
  return rows;
};

export const rowsFromStored = (message: { type?: string; uuid?: string; message?: unknown }): Row[] => {
  const fromTurn = rowsFromTurn(message);
  if (fromTurn) return fromTurn;
  const role = message.type === "user" ? "user" : "assistant";
  const body = asRecord(message.message);
  if (!body) return [];
  return rowsFromContent(body.content ?? body.text, role);
};

type LiveAgent = Awaited<ReturnType<typeof Agent.create>>;
type LiveRun = Awaited<ReturnType<LiveAgent["send"]>>;

type Slot = {
  agentId: string;
  agent: LiveAgent | null;
  run: LiveRun | null;
  generation: number;
};

let apiKey = "";
let workspace = "";
let modelId = "";
let catalog: CatalogItem[] = [];
const slots = new Map<string, Slot>();

const paramsFor = (id: string) => {
  const model = catalog.find((item) => item.id === id);
  const variant = model?.variants?.find((item) => item.isDefault) ?? model?.variants?.[0];
  return variant?.params?.length ? variant.params : undefined;
};

const selection = () => {
  if (!modelId) return undefined;
  const params = paramsFor(modelId);
  return params ? { id: modelId, params } : { id: modelId };
};

const agentOptions = () => ({
  apiKey,
  model: selection(),
  local: {
    cwd: workspace,
    settingSources: ["project" as const],
  },
});

const slotFor = (sessionId: string) => {
  let slot = slots.get(sessionId);
  if (!slot) {
    slot = { agentId: "", agent: null, run: null, generation: 0 };
    slots.set(sessionId, slot);
  }
  return slot;
};

const ensureAgent = async (sessionId: string) => {
  const slot = slotFor(sessionId);
  if (slot.agent) return slot.agent;
  if (slot.agentId) {
    try {
      slot.agent = await Agent.resume(slot.agentId, agentOptions());
      emit({ type: "agent", sessionId, agentId: slot.agent.agentId });
      return slot.agent;
    } catch (error) {
      logError(error, apiKey);
      slot.agentId = "";
    }
  }
  slot.agent = await Agent.create(agentOptions());
  slot.agentId = slot.agent.agentId;
  emit({ type: "agent", sessionId, agentId: slot.agent.agentId });
  return slot.agent;
};

const loadTranscript = async (sessionId: string) => {
  const slot = slots.get(sessionId);
  if (!slot?.agent) return;
  try {
    const stored = await Agent.messages.list(slot.agent.agentId, { runtime: "local", cwd: workspace });
    const messages = stored.flatMap((message) => rowsFromStored(message));
    emit({ type: "transcript", sessionId, messages });
  } catch (error) {
    logError(error, apiKey);
    emit({ type: "transcript", sessionId, messages: [] });
  }
};

const handleTool = (sessionId: string, event: SDKMessage, seen: Set<string>) => {
  if (event.type !== "tool_call") return;
  if (seen.has(event.call_id)) return;
  if (event.status !== "running" && event.status !== "completed") return;
  seen.add(event.call_id);
  emit({ type: "tool", sessionId, id: event.call_id, summary: summarize(event.name, event.args) });
};

const start = async (message: Extract<Inbound, { type: "start" }>) => {
  apiKey = message.apiKey;
  workspace = message.workspace;
  modelId = message.modelId ?? "";
  slots.clear();
  try {
    catalog = await Cursor.models.list({ apiKey });
  } catch (error) {
    logError(error, apiKey);
    emit({ type: "error", message: "That API key was rejected." });
    return;
  }
  rememberModel();
  emit({
    type: "models",
    models: catalog.map((item) => ({ id: item.id, displayName: item.displayName })),
  });
};

const openSession = async (sessionId: string, agentId?: string) => {
  const slot = slotFor(sessionId);
  if (slot.run) {
    emit({ type: "run", sessionId, state: "running" });
    return;
  }
  const requested = agentId?.trim() ?? "";
  if (!slot.agent || slot.agentId !== requested) {
    slot.agent = null;
    slot.agentId = requested;
  }
  try {
    await ensureAgent(sessionId);
    await loadTranscript(sessionId);
    if (!slot.run) emit({ type: "run", sessionId, state: "idle" });
  } catch (error) {
    logError(error, apiKey);
    emit({ type: "error", sessionId, message: friendly(error) });
  }
};

const safeName = (name: string) => {
  const base = name.split(/[/\\]/).pop() ?? "file";
  const cleaned = base.replace(/[^\w.\- ]+/g, "_").replace(/^\.+$/, "").trim();
  return cleaned.slice(0, 80) || "file";
};

const stageAttachment = async (item: Attachment) => {
  const dir = join(tmpdir(), "whatnotch-attachments");
  await mkdir(dir, { recursive: true });
  const path = join(dir, `${crypto.randomUUID()}-${safeName(item.name)}`);
  await writeFile(path, Buffer.from(item.data ?? "", "base64"));
  return path;
};

const compose = async (text: string, attachments: Attachment[]): Promise<string | SDKUserMessage> => {
  const images: SDKImage[] = [];
  const lines: string[] = [];
  for (const item of attachments.slice(0, 8)) {
    if (!item.data || item.data.length > 5_800_000) continue;
    const mime = item.mime?.trim() || "application/octet-stream";
    const path = await stageAttachment(item);
    lines.push(`- ${item.name}: ${path}`);
    if (item.kind === "image" && mime.startsWith("image/")) images.push({ data: item.data, mimeType: mime });
  }
  const note = lines.length ? `Attached files:\n${lines.join("\n")}` : "";
  const body = [text.trim(), note].filter(Boolean).join("\n\n");
  const prompt = body || "Look at the attached images.";
  return images.length ? { text: prompt, images } : prompt;
};

const send = async (sessionId: string, text: string, requestedModel?: string, attachments: Attachment[] = []) => {
  if (requestedModel) modelId = requestedModel;
  rememberModel();
  const model = selection();
  if (!model) {
    emit({ type: "run", sessionId, state: "error", message: "Choose a model in settings, then send again." });
    return;
  }
  const slot = slotFor(sessionId);
  const token = slot.generation + 1;
  slot.generation = token;
  const current = await ensureAgent(sessionId);
  if (slot.generation !== token) return;
  emit({ type: "run", sessionId, state: "running" });
  const seen = new Set<string>();
  let streamed = false;
  const onDelta = ({ update }: { update: { type: string; text?: string } }) => {
    if (slot.generation !== token) return;
    if (update.type === "text-delta" && update.text) {
      streamed = true;
      emit({ type: "delta", sessionId, text: update.text });
    }
  };
  let message: string | SDKUserMessage;
  try {
    message = await compose(text, attachments);
  } catch (error) {
    if (slot.generation !== token) return;
    logError(error, apiKey);
    emit({ type: "run", sessionId, state: "error", message: "That attachment could not be saved." });
    return;
  }
  try {
    let run;
    try {
      run = await current.send(message, { model, onDelta });
    } catch (error) {
      if (streamed || slot.generation !== token || !/already has active run/i.test(safeError(error))) throw error;
      run = await current.send(message, { model, local: { force: true }, onDelta });
    }
    if (slot.generation !== token) {
      await run.cancel().catch((error) => logError(error, apiKey));
      return;
    }
    slot.run = run;
    for await (const event of run.stream()) {
      if (slot.generation !== token) return;
      handleTool(sessionId, event, seen);
    }
    const result = await run.wait();
    if (slot.generation !== token) return;
    if (result.status === "error") {
      const raw = result.error?.message ?? "";
      const message = (apiKey ? raw.split(apiKey).join("[key]") : raw) || "The agent could not finish that turn.";
      emit({ type: "run", sessionId, state: "error", message });
      return;
    }
    if (!streamed && result.result) emit({ type: "delta", sessionId, text: result.result });
    emit({ type: "run", sessionId, state: "idle" });
  } catch (error) {
    if (slot.generation !== token) return;
    logError(error, apiKey);
    emit({ type: "run", sessionId, state: "error", message: friendly(error) });
  } finally {
    if (slot.generation === token) slot.run = null;
  }
};

const cancel = async (sessionId: string) => {
  const slot = slots.get(sessionId);
  if (!slot) return;
  slot.generation += 1;
  const run = slot.run;
  slot.run = null;
  try {
    await run?.cancel();
  } catch (error) {
    logError(error, apiKey);
  }
  emit({ type: "run", sessionId, state: "idle" });
};

const handle = async (message: Inbound) => {
  if (message.type === "start") await start(message);
  if (message.type === "setModel") modelId = message.modelId;
  if (message.type === "send" && message.sessionId) {
    await send(message.sessionId, message.text, message.modelId, message.attachments ?? []);
  }
  if (message.type === "open" && message.sessionId) await openSession(message.sessionId, message.agentId);
  if (message.type === "newChat" && message.sessionId) await openSession(message.sessionId);
};

const lines = createInterface({ input: process.stdin });
const queues = new Map<string, Promise<void>>();
const enqueue = (key: string, work: () => Promise<void>) => {
  const previous = queues.get(key) ?? Promise.resolve();
  const next = previous.then(work).catch((error) => logError(error, apiKey));
  queues.set(key, next);
};
lines.on("line", (line) => {
  if (!line.trim()) return;
  let message: Inbound;
  try {
    message = JSON.parse(line) as Inbound;
  } catch (error) {
    logError(error, apiKey);
    return;
  }
  if (message.type === "cancel") {
    void cancel(message.sessionId ?? "");
    return;
  }
  const key = message.type === "send" || message.type === "open" || message.type === "newChat"
    ? message.sessionId || "global"
    : "global";
  enqueue(key, () => handle(message));
});
