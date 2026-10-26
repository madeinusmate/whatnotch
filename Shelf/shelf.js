const post = (body) => {
  window.webkit?.messageHandlers?.shelf?.postMessage(body);
};

const widgetsEl = document.getElementById("widgets");
const emptyEl = document.getElementById("empty");
const threadEl = document.getElementById("thread");
const errorEl = document.getElementById("error");
const inputEl = document.getElementById("input");
const goEl = document.getElementById("go");
const composerEl = document.getElementById("composer");
const attachmentsEl = document.getElementById("attachments");
const attachEl = document.getElementById("attach");
const attachNoteEl = document.getElementById("attach-note");
const chatEl = document.getElementById("chat");
const settingsEl = document.getElementById("settings");
const confirmEl = document.getElementById("confirm");
const menuEl = document.getElementById("menu");
const shelfEl = document.getElementById("shelf");
const titleEl = document.getElementById("chat-title");
const keyEl = document.getElementById("key");
const modelEl = document.getElementById("model");
const providerEl = document.getElementById("provider");
const providerNameEl = document.getElementById("provider-name");
const providerCopyEl = document.getElementById("provider-copy");
const keyLabelEl = document.getElementById("key-label");
const providerStatusEl = document.getElementById("provider-status");
const providerSummaryEl = document.getElementById("provider-summary");
const providerEditEl = document.getElementById("provider-edit");
const providerCancelEl = document.getElementById("provider-cancel");
const settingsFormEl = document.getElementById("settings-form");
const credentialFieldEl = document.getElementById("credential-field");
const modelFieldEl = document.getElementById("model-field");
let providerEditing = false;
let savedProvider = "cursor";
const listEl = document.getElementById("widget-list");
const titlesToggleEl = document.getElementById("titles-toggle");
const confirmTitleEl = document.getElementById("confirm-title");
const confirmBodyEl = document.getElementById("confirm-body");
const confirmAcceptEl = document.getElementById("confirm-accept");
const gearEl = document.getElementById("gear");
const createEl = document.getElementById("create");
const doneEl = document.getElementById("done");
const menubarEl = document.getElementById("menubar");
const appEl = document.getElementById("app");
const compactEl = document.getElementById("compact");
const rootEl = document.documentElement;

let widgetSignature = "";
let messageSignature = "";
let modelSignature = "";
let librarySignature = "";
let compactSignature = "";
let lastMode = "shelf";
let showTitles = true;
let press = null;
let layoutRows = [];
let widgetsById = new Map();
let shelfEditingId = "";
let wantReorder = false;
let pendingCreates = [];
let busyIds = new Set();
const MAX_ROWS = 3;
const SKELETON_WIDTH = 200;
const SKELETON_HEIGHT = 112;
let composerLocked = false;
let composerRunning = false;
let sessionId = "";
let attachNoteTimer = 0;
const attachments = [];
const maxAttachments = 8;
const maxAttachmentBytes = 4 * 1024 * 1024;

const reduceMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const motions = new Map();
let motionFrame = 0;
let motionStamp = 0;

const readMotion = (element) => {
  const value = getComputedStyle(element).transform;
  if (!value || value === "none") return { x: 0, y: 0, scale: 1 };
  const matrix = new DOMMatrix(value);
  return { x: matrix.m41, y: matrix.m42, scale: matrix.a || 1 };
};

const stepMotions = (now) => {
  const dt = Math.min(1 / 30, Math.max(0.001, motionStamp ? (now - motionStamp) / 1000 : 1 / 60));
  motionStamp = now;
  motions.forEach((motion, element) => {
    const omega = (2 * Math.PI) / motion.response;
    const stiffness = omega * omega;
    const damping = 2 * motion.ratio * Math.sqrt(stiffness);
    motion.vx += (stiffness * (motion.targetX - motion.x) - damping * motion.vx) * dt;
    motion.vy += (stiffness * (motion.targetY - motion.y) - damping * motion.vy) * dt;
    motion.vs += (stiffness * (motion.targetScale - motion.scale) - damping * motion.vs) * dt;
    motion.x += motion.vx * dt;
    motion.y += motion.vy * dt;
    motion.scale += motion.vs * dt;
    const settled = Math.hypot(motion.targetX - motion.x, motion.targetY - motion.y) < 0.4
      && Math.abs(motion.targetScale - motion.scale) < 0.004
      && Math.hypot(motion.vx, motion.vy) < 8
      && Math.abs(motion.vs) < 0.05;
    if (settled) {
      element.style.transform = "";
      motions.delete(element);
      motion.onDone?.();
      return;
    }
    const scale = Math.abs(motion.scale - 1) < 0.001 ? "" : ` scale(${motion.scale})`;
    element.style.transform = `translate3d(${motion.x}px, ${motion.y}px, 0)${scale}`;
  });
  motionFrame = motions.size ? requestAnimationFrame(stepMotions) : 0;
};

const springTo = (element, target, velocity = {}, options = {}) => {
  if (!element) return;
  if (reduceMotion()) {
    element.style.transform = "";
    options.onDone?.();
    return;
  }
  const current = readMotion(element);
  const previous = motions.get(element);
  motions.set(element, {
    x: current.x,
    y: current.y,
    scale: current.scale,
    vx: velocity.x ?? previous?.vx ?? 0,
    vy: velocity.y ?? previous?.vy ?? 0,
    vs: previous?.vs ?? 0,
    targetX: target.x,
    targetY: target.y,
    targetScale: target.scale ?? 1,
    response: options.momentum ? 0.34 : 0.3,
    ratio: options.momentum ? 0.86 : 1,
    onDone: options.onDone,
  });
  if (!motionFrame) {
    motionStamp = 0;
    motionFrame = requestAnimationFrame(stepMotions);
  }
};

const cancelMotion = (element) => {
  if (element) motions.delete(element);
};

const rubberband = (overshoot, dimension, constant = 0.55) =>
  (overshoot * dimension * constant) / (dimension + constant * Math.abs(overshoot));

const project = (velocity, deceleration = 0.99) =>
  (velocity / 1000) * deceleration / (1 - deceleration);

const sameRows = (left, right) =>
  left.length === right.length && left.every((row, index) => row.length === right[index].length && row.every((id, slot) => id === right[index][slot]));

const relocate = (rows, id, rowIndex, index, create) => {
  const resting = rows.map((row) => row.filter((item) => item !== id)).filter((row) => row.length);
  const next = resting.map((row) => row.slice());
  if (create && next.length < MAX_ROWS) {
    const at = Math.max(0, Math.min(next.length, rowIndex));
    next.splice(at, 0, [id]);
    return next;
  }
  if (!next.length) return [[id]];
  const row = Math.max(0, Math.min(next.length - 1, rowIndex));
  const at = Math.max(0, Math.min(next[row].length, index));
  next[row].splice(at, 0, id);
  return next;
};

const groupIds = (widgets) => {
  const rowOf = (widget) => Number.isInteger(widget.row) ? widget.row : 0;
  const slotOf = (widget) => Number.isInteger(widget.slot) ? widget.slot : 0;
  const sorted = widgets.slice().sort((a, b) => rowOf(a) - rowOf(b) || slotOf(a) - slotOf(b) || a.id.localeCompare(b.id));
  const rows = [];
  let current = null;
  sorted.forEach((widget) => {
    const row = Number.isInteger(widget.row) ? widget.row : 0;
    if (current !== row) {
      rows.push([]);
      current = row;
    }
    rows[rows.length - 1].push(widget.id);
  });
  return rows.filter((row) => row.length);
};

const buildBones = () => {
  const bones = document.createElement("div");
  bones.className = "bones";
  bones.setAttribute("aria-hidden", "true");
  bones.append(document.createElement("i"), document.createElement("i"), document.createElement("i"));
  return bones;
};

const buildCard = (widget) => {
  const card = document.createElement("article");
  card.className = "widget";
  card.dataset.id = widget.id;
  card.dataset.phase = String(Math.random());
  card.style.setProperty("--phase", card.dataset.phase);
  card.draggable = false;
  const header = document.createElement("header");
  const title = document.createElement("span");
  header.append(title);
  const frame = document.createElement("iframe");
  frame.dataset.id = widget.id;
  card.append(header, frame, buildBones());
  return card;
};

const buildPending = (session) => {
  const slot = document.createElement("div");
  slot.className = "widget-slot pending";
  slot.dataset.id = `pending:${session.id}`;
  const card = document.createElement("article");
  card.className = "widget skeleton";
  card.dataset.id = slot.dataset.id;
  card.setAttribute("aria-busy", "true");
  const header = document.createElement("header");
  const title = document.createElement("span");
  header.append(title);
  card.append(header, buildBones());
  card.style.width = `${SKELETON_WIDTH}px`;
  card.style.height = `${SKELETON_HEIGHT}px`;
  slot.append(card);
  syncPending(slot, session);
  return slot;
};

const syncPending = (slot, session) => {
  const label = session.title || "New widget";
  const card = slot.querySelector(".widget");
  const title = slot.querySelector("span");
  if (title) title.textContent = label;
  card?.setAttribute("aria-label", `Building ${label}`);
};

const syncCardElement = (card, widget, editingId) => {
  if (!card.dataset.phase) {
    card.dataset.phase = String(Math.random());
    card.style.setProperty("--phase", card.dataset.phase);
  }
  const busy = busyIds.has(widget.id);
  card.classList.toggle("editing", widget.id === editingId);
  card.classList.toggle("busy", busy);
  if (busy) card.setAttribute("aria-busy", "true");
  else card.removeAttribute("aria-busy");
  if (busy && !card.querySelector(".bones")) card.append(buildBones());
  card.style.width = `${widget.width}px`;
  card.style.height = `${widget.height || 112}px`;
  const title = card.querySelector("span");
  if (title) title.textContent = widget.title;
  const frame = card.querySelector("iframe");
  const src = `notch://widget/${encodeURIComponent(widget.id)}/index.html?rev=${widget.revision}`;
  if (frame && frame.getAttribute("src") !== src) frame.src = src;
};

const syncCard = (slot, widget, editingId) => {
  const card = slot.querySelector(".widget") || document.querySelector(`.widget[data-id="${CSS.escape(widget.id)}"]`);
  if (card) syncCardElement(card, widget, editingId);
};

const ensureSlot = (widget) => {
  let slot = widgetsEl.querySelector(`.widget-slot[data-id="${CSS.escape(widget.id)}"]`);
  if (slot) return slot;
  slot = document.createElement("div");
  slot.className = "widget-slot";
  slot.dataset.id = widget.id;
  let card = document.querySelector(`.widget[data-id="${CSS.escape(widget.id)}"]`);
  if (!card) card = buildCard(widget);
  if (!card.classList.contains("lifted")) slot.append(card);
  return slot;
};

const realBands = () => [...widgetsEl.querySelectorAll(":scope > .band")];

const ensureBand = (index) => {
  const bands = realBands();
  if (bands[index]) return bands[index];
  const band = document.createElement("div");
  band.className = "band";
  widgetsEl.insertBefore(band, widgetsEl.querySelector(":scope > .new-row"));
  return band;
};

const placePending = () => {
  widgetsEl.querySelectorAll(".widget-slot.pending").forEach((slot) => {
    const id = slot.dataset.id?.slice("pending:".length) || "";
    const session = pendingCreates.find((item) => item.id === id);
    if (!session) slot.remove();
    else syncPending(slot, session);
  });
  if (!pendingCreates.length) return;
  let band = realBands().at(-1);
  if (!band) {
    band = document.createElement("div");
    band.className = "band";
    widgetsEl.insertBefore(band, widgetsEl.querySelector(":scope > .new-row"));
  }
  pendingCreates.forEach((session) => {
    const id = `pending:${session.id}`;
    let slot = widgetsEl.querySelector(`.widget-slot.pending[data-id="${CSS.escape(id)}"]`);
    const fresh = !slot;
    if (!slot) slot = buildPending(session);
    if (slot.parentElement !== band) band.append(slot);
    if (fresh) requestAnimationFrame(() => { band.scrollLeft = band.scrollWidth; });
  });
};

const syncLane = (count) => {
  const show = wantReorder && count > 0 && count < MAX_ROWS;
  let lane = widgetsEl.querySelector(":scope > .new-row");
  if (!show) {
    lane?.remove();
    return;
  }
  if (!lane) {
    lane = document.createElement("div");
    lane.className = "new-row";
    lane.setAttribute("aria-hidden", "true");
    widgetsEl.append(lane);
  }
};

const paintBands = (widgets, rows, editingId) => {
  const byId = new Map(widgets.map((widget) => [widget.id, widget]));
  rows.forEach((ids, index) => {
    const band = ensureBand(index);
    band.dataset.row = String(index);
    ids.forEach((id, slotIndex) => {
      const widget = byId.get(id);
      if (!widget) return;
      const slot = ensureSlot(widget);
      syncCard(slot, widget, editingId);
      if (slot.classList.contains("held")) {
        slot.style.width = `${widget.width}px`;
        slot.style.height = `${widget.height || 112}px`;
      }
      const current = band.children[slotIndex];
      if (current !== slot) band.insertBefore(slot, current ?? null);
    });
  });
  realBands().forEach((band, index) => {
    if (index >= rows.length) {
      band.querySelectorAll(":scope > .widget-slot.pending").forEach((slot) => widgetsEl.append(slot));
      band.remove();
      return;
    }
    const ids = new Set(rows[index]);
    [...band.children].forEach((child) => {
      if (child.classList.contains("pending")) return;
      if (!ids.has(child.dataset.id)) child.remove();
    });
  });
  syncLane(rows.length);
  placePending();
};

const snapshotSlots = () => new Map([...widgetsEl.querySelectorAll(".widget-slot")].map((slot) => [slot, slot.getBoundingClientRect()]));

const flipSlots = (before) => {
  if (!before || reduceMotion()) return;
  widgetsEl.querySelectorAll(".widget-slot").forEach((slot) => {
    const previous = before.get(slot);
    if (!previous) return;
    const velocity = motions.get(slot);
    slot.style.transform = "none";
    const next = slot.getBoundingClientRect();
    const dx = previous.left - next.left;
    const dy = previous.top - next.top;
    if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) {
      slot.style.transform = "";
      cancelMotion(slot);
      return;
    }
    slot.style.transform = `translate3d(${dx}px, ${dy}px, 0)`;
    springTo(slot, { x: 0, y: 0 }, { x: velocity?.vx ?? 0, y: velocity?.vy ?? 0 });
  });
};

const renderWidgets = (widgets, editingId, activity) => {
  pendingCreates = activity?.creating || [];
  busyIds = activity?.busy || new Set();
  widgetsById = new Map(widgets.map((widget) => [widget.id, widget]));
  shelfEditingId = editingId || "";
  widgetsEl.classList.toggle("titles-off", !showTitles);
  if (press?.lifted) {
    widgets.forEach((widget) => syncCard(ensureSlot(widget), widget, shelfEditingId));
    return;
  }
  const rows = groupIds(widgets);
  const pendingKey = pendingCreates.map((session) => `${session.id}:${session.title || ""}`).join(",");
  const busyKey = [...busyIds].sort().join(",");
  const signature = `${widgets.map((widget) => `${widget.id}:${widget.revision}:${widget.title}:${widget.width}:${widget.height}:${widget.row}:${widget.slot}:${shelfEditingId}`).join("|")}#${pendingKey}#${busyKey}`;
  const laneWanted = wantReorder && rows.length > 0 && rows.length < MAX_ROWS;
  const laneShown = Boolean(widgetsEl.querySelector(":scope > .new-row"));
  if (signature === widgetSignature && laneShown === laneWanted) {
    if (!wantReorder) layoutRows = rows;
    emptyEl.hidden = widgets.length > 0 || pendingCreates.length > 0;
    return;
  }
  const before = widgetSignature ? snapshotSlots() : null;
  widgetSignature = signature;
  layoutRows = rows;
  paintBands(widgets, rows, shelfEditingId);
  flipSlots(before);
  emptyEl.hidden = widgets.length > 0 || pendingCreates.length > 0;
};

const bandBoxes = () =>
  [...widgetsEl.querySelectorAll(":scope > .band")].map((band) => {
    const slots = [...band.querySelectorAll(":scope > .widget-slot:not(.held):not(.pending)")];
    if (!slots.length) return null;
    const rects = slots.map((slot) => slot.getBoundingClientRect());
    return {
      top: Math.min(...rects.map((rect) => rect.top)),
      bottom: Math.max(...rects.map((rect) => rect.bottom)),
      slots,
    };
  }).filter(Boolean);

const indexFromSlots = (slots, x) => {
  for (let index = 0; index < slots.length; index += 1) {
    const rect = slots[index].getBoundingClientRect();
    if (x < rect.left + rect.width / 2) return index;
  }
  return slots.length;
};

const canOpenRow = () => bandBoxes().length < MAX_ROWS;

const decide = (x, y) => {
  const boxes = bandBoxes();
  const canCreate = canOpenRow();
  const inside = boxes.findIndex((box) => y >= box.top && y <= box.bottom);
  if (inside !== -1) return { create: false, row: inside, index: indexFromSlots(boxes[inside].slots, x) };
  if (!boxes.length) return { create: true, row: 0, index: 0 };
  if (canCreate && y > boxes[boxes.length - 1].bottom + 12) return { create: true, row: boxes.length, index: 0 };
  if (canCreate && y < boxes[0].top - 12) return { create: true, row: 0, index: 0 };
  for (let index = 0; index < boxes.length - 1; index += 1) {
    if (y > boxes[index].bottom && y < boxes[index + 1].top) {
      if (canCreate) return { create: true, row: index + 1, index: 0 };
      const row = y - boxes[index].bottom <= boxes[index + 1].top - y ? index : index + 1;
      return { create: false, row, index: indexFromSlots(boxes[row].slots, x) };
    }
  }
  let row = 0;
  let best = Infinity;
  boxes.forEach((box, index) => {
    const distance = Math.abs(y - (box.top + box.bottom) / 2);
    if (distance < best) {
      best = distance;
      row = index;
    }
  });
  return { create: false, row, index: indexFromSlots(boxes[row].slots, x) };
};

const applyTarget = (point) => {
  if (!press?.id) return;
  const decision = decide(point.x, point.y);
  const next = relocate(layoutRows, press.id, decision.row, decision.index, decision.create);
  if (sameRows(next, layoutRows)) return;
  const before = snapshotSlots();
  layoutRows = next;
  paintBands([...widgetsById.values()], layoutRows, shelfEditingId);
  flipSlots(before);
  post({ type: "layoutPreview", layout: JSON.stringify(layoutRows) });
};

const velocityOf = (history) => {
  if (!history?.length) return { x: 0, y: 0 };
  const last = history[history.length - 1];
  const first = history.find((sample) => last.t - sample.t <= 90) ?? history[0];
  const dt = (last.t - first.t) / 1000;
  if (dt < 0.008) return { x: 0, y: 0 };
  return { x: (last.x - first.x) / dt, y: (last.y - first.y) / dt };
};

const settleLifted = (card, velocity) => {
  const slot = widgetsEl.querySelector(`.widget-slot[data-id="${CSS.escape(card.dataset.id)}"]`);
  if (!slot) return;
  const visual = card.getBoundingClientRect();
  cancelMotion(card);
  cancelMotion(slot);
  card.classList.remove("lifted", "pressing");
  card.style.left = "";
  card.style.top = "";
  card.style.transform = "";
  card.removeAttribute("aria-grabbed");
  slot.classList.remove("held");
  slot.style.width = "";
  slot.style.height = "";
  slot.style.transform = "";
  slot.append(card);
  if (reduceMotion()) return;
  const home = slot.getBoundingClientRect();
  const dx = visual.left - home.left;
  const dy = visual.top - home.top;
  const speed = Math.hypot(velocity.x, velocity.y);
  if (Math.hypot(dx, dy) < 0.5 && speed < 40) return;
  slot.style.transform = `translate3d(${dx}px, ${dy}px, 0)`;
  springTo(slot, { x: 0, y: 0 }, velocity, { momentum: speed > 80 });
};

const track = (point) => {
  const gesture = press;
  if (!gesture?.card) return;
  gesture.last = point;
  gesture.history.push(point);
  const cutoff = point.t - 90;
  while (gesture.history.length > 2 && gesture.history[0].t < cutoff) gesture.history.shift();
  const bounds = widgetsEl.getBoundingClientRect();
  const width = gesture.card.offsetWidth;
  const height = gesture.card.offsetHeight;
  const canCreate = canOpenRow();
  const slack = canCreate ? 48 : 0;
  let left = point.x - gesture.grabX;
  let top = point.y - gesture.grabY;
  if (left < bounds.left) left = bounds.left - rubberband(bounds.left - left, bounds.width);
  else if (left + width > bounds.right) left = bounds.right - width + rubberband(left + width - bounds.right, bounds.width);
  if (top < bounds.top - slack) top = bounds.top - slack - rubberband(bounds.top - slack - top, Math.max(bounds.height, 1));
  else if (top + height > bounds.bottom + slack) {
    top = bounds.bottom + slack - height + rubberband(top + height - (bounds.bottom + slack), Math.max(bounds.height, 1));
  }
  const originLeft = parseFloat(gesture.card.style.left) || 0;
  const originTop = parseFloat(gesture.card.style.top) || 0;
  gesture.card.style.transform = `translate3d(${left - originLeft}px, ${top - originTop}px, 0) scale(1.04)`;
  applyTarget(point);
};

const followScroll = () => {
  if (!press?.lifted) return;
  const point = press.last;
  let scrolled = false;
  if (point) {
    widgetsEl.querySelectorAll(":scope > .band").forEach((band) => {
      const rect = band.getBoundingClientRect();
      if (point.y < rect.top - 8 || point.y > rect.bottom + 8) return;
      if (point.x < rect.left + 32) {
        band.scrollLeft -= 12;
        scrolled = true;
      } else if (point.x > rect.right - 32) {
        band.scrollLeft += 12;
        scrolled = true;
      }
    });
    if (scrolled) applyTarget(point);
  }
  press.scrollFrame = requestAnimationFrame(followScroll);
};

const lift = (gesture) => {
  if (!gesture || gesture.lifted) return;
  if (lastMode !== "shelf" && lastMode !== "reorder") {
    press = null;
    return;
  }
  if (widgetsEl.querySelectorAll(".widget-slot:not(.pending)").length < 2) return;
  clearTimeout(gesture.timer);
  clearTimeout(gesture.warm);
  const card = document.querySelector(`.widget[data-id="${CSS.escape(gesture.id)}"]`);
  const slot = card?.parentElement;
  if (!card || !slot?.classList.contains("widget-slot")) return;
  cancelMotion(slot);
  const visual = card.getBoundingClientRect();
  slot.style.transform = "";
  const point = gesture.last ?? { x: gesture.x, y: gesture.y, t: performance.now() };
  gesture.lifted = true;
  gesture.card = card;
  gesture.grabX = point.x - visual.left;
  gesture.grabY = point.y - visual.top;
  gesture.history = [point];
  gesture.last = point;
  slot.classList.add("held");
  slot.style.width = `${visual.width}px`;
  slot.style.height = `${visual.height}px`;
  card.classList.remove("pressing");
  card.classList.add("lifted");
  card.setAttribute("aria-grabbed", "true");
  card.style.left = `${visual.left}px`;
  card.style.top = `${visual.top}px`;
  document.body.append(card);
  wantReorder = true;
  widgetsEl.classList.add("reordering");
  menubarEl.classList.add("reordering");
  doneEl.hidden = false;
  menuEl.hidden = true;
  document.documentElement.classList.add("lifting");
  if (lastMode !== "reorder") post({ type: "beginReorder" });
  post({ type: "reorderLift", active: true });
  syncLane(layoutRows.length);
  track(point);
  followScroll();
};

const drop = (point) => {
  const gesture = press;
  if (!gesture?.card) return;
  const velocity = velocityOf(gesture.history);
  const speed = Math.hypot(velocity.x, velocity.y);
  const bounds = widgetsEl.getBoundingClientRect();
  const landing = {
    x: Math.min(bounds.right, Math.max(bounds.left, point.x + (speed > 80 ? project(velocity.x) : 0))),
    y: Math.min(bounds.bottom + 48, Math.max(bounds.top - 48, point.y + (speed > 80 ? project(velocity.y) : 0))),
    t: point.t,
  };
  const releasedOnControl = document.elementFromPoint(point.x, point.y)?.closest?.("#actions");
  if (!releasedOnControl) applyTarget(landing);
  const card = gesture.card;
  cancelAnimationFrame(gesture.scrollFrame);
  press = null;
  document.documentElement.classList.remove("lifting");
  settleLifted(card, velocity);
  post({ type: "commitLayout", layout: JSON.stringify(layoutRows) });
  post({ type: "reorderLift", active: false });
};

const clearIdlePress = () => {
  if (!press || press.lifted) return;
  clearTimeout(press.timer);
  clearTimeout(press.warm);
  document.querySelector(`.widget[data-id="${CSS.escape(press.id)}"]`)?.classList.remove("pressing");
  press = null;
};

const abortDrag = () => {
  const gesture = press;
  const lifted = Boolean(gesture?.lifted);
  clearTimeout(gesture?.timer);
  clearTimeout(gesture?.warm);
  cancelAnimationFrame(gesture?.scrollFrame);
  press = null;
  document.documentElement.classList.remove("lifting");
  if (gesture?.card) {
    cancelMotion(gesture.card);
    gesture.card.classList.remove("lifted", "pressing");
    gesture.card.style.left = "";
    gesture.card.style.top = "";
    gesture.card.style.transform = "";
    gesture.card.removeAttribute("aria-grabbed");
    const slot = widgetsEl.querySelector(`.widget-slot[data-id="${CSS.escape(gesture.id)}"]`);
    if (slot) {
      cancelMotion(slot);
      slot.classList.remove("held");
      slot.style.width = "";
      slot.style.height = "";
      slot.style.transform = "";
      slot.append(gesture.card);
    }
  }
  widgetsEl.querySelectorAll(".widget-slot").forEach((slot) => {
    cancelMotion(slot);
    slot.style.transform = "";
  });
  widgetSignature = "";
  const widgets = [...widgetsById.values()];
  if (widgets.length || pendingCreates.length) {
    layoutRows = groupIds(widgets);
    paintBands(widgets, layoutRows, shelfEditingId);
  }
  if (lifted) post({ type: "reorderLift", active: false });
};

const pressDown = (id, point) => {
  if (press?.lifted) return;
  clearIdlePress();
  if (lastMode !== "shelf" && lastMode !== "reorder") return;
  const card = document.querySelector(`.widget[data-id="${CSS.escape(id)}"]`);
  if (!card || card.classList.contains("skeleton") || widgetsEl.querySelectorAll(".widget-slot:not(.pending)").length < 2) return;
  press = { id, x: point.x, y: point.y, last: point, history: [point], lifted: false, card: null };
  if (widgetsEl.classList.contains("reordering")) return;
  if (!reduceMotion()) {
    press.warm = setTimeout(() => {
      if (press?.id === id && !press.lifted) card.classList.add("pressing");
    }, 120);
  }
  const token = press;
  press.timer = setTimeout(() => {
    if (press !== token) return;
    lift(token);
  }, 420);
};

const pressMove = (point) => {
  if (!press) return;
  const distance = Math.hypot(point.x - press.x, point.y - press.y);
  if (!press.lifted) {
    if (!widgetsEl.classList.contains("reordering")) {
      if (distance > 10) clearIdlePress();
      return;
    }
    if (distance < 8) return;
    lift(press);
    if (!press?.lifted) return;
  }
  track(point);
};

const pressUp = (point) => {
  if (!press) return;
  if (press.lifted) drop(point);
  else clearIdlePress();
};

const pressPoint = (x, y) => ({ x, y, t: performance.now() });

const isWordChar = (char) => char !== undefined && /[\p{L}\p{N}]/u.test(char);

const canWrap = (text, start, markerLength, end) => {
  if (end <= start + markerLength) return false;
  const afterOpen = text[start + markerLength];
  const beforeClose = text[end - 1];
  if (afterOpen === undefined || beforeClose === undefined) return false;
  if (/\s/.test(afterOpen) || /\s/.test(beforeClose)) return false;
  return !isWordChar(text[start - 1]) && !isWordChar(text[end + markerLength]);
};

const readWrapped = (text, start, marker) => {
  if (!text.startsWith(marker, start)) return null;
  const end = text.indexOf(marker, start + marker.length);
  if (end === -1 || !canWrap(text, start, marker.length, end)) return null;
  return { inner: text.slice(start + marker.length, end), next: end + marker.length };
};

const readLink = (text, start) => {
  if (text[start] !== "[") return null;
  const labelEnd = text.indexOf("]", start + 1);
  if (labelEnd <= start + 1 || text[labelEnd + 1] !== "(") return null;
  const urlEnd = text.indexOf(")", labelEnd + 2);
  if (urlEnd === -1) return null;
  const url = text.slice(labelEnd + 2, urlEnd).trim();
  if (!url || /[\s<>"]/.test(url)) return null;
  return { label: text.slice(start + 1, labelEnd), url, next: urlEnd + 1 };
};

const appendInline = (parent, text) => {
  let index = 0;
  const pushText = (value) => {
    if (value) parent.append(document.createTextNode(value));
  };
  const isSpecial = (cursor) => {
    const char = text[cursor];
    if ("\\`*~[!".includes(char)) return true;
    return (text.startsWith("https://", cursor) || text.startsWith("http://", cursor)) && !isWordChar(text[cursor - 1]);
  };
  while (index < text.length) {
    if (text[index] === "\\") {
      pushText(text[index + 1] ?? "\\");
      index += text[index + 1] ? 2 : 1;
      continue;
    }
    if (text[index] === "`") {
      let ticks = 0;
      while (text[index + ticks] === "`") ticks += 1;
      const marker = "`".repeat(ticks);
      const end = text.indexOf(marker, index + ticks);
      if (end > index + ticks) {
        const code = document.createElement("code");
        code.textContent = text.slice(index + ticks, end);
        parent.append(code);
        index = end + ticks;
        continue;
      }
    }
    const strike = readWrapped(text, index, "~~");
    if (strike) {
      const node = document.createElement("del");
      appendInline(node, strike.inner);
      parent.append(node);
      index = strike.next;
      continue;
    }
    const bold = readWrapped(text, index, "**");
    if (bold) {
      const node = document.createElement("strong");
      appendInline(node, bold.inner);
      parent.append(node);
      index = bold.next;
      continue;
    }
    const italic = readWrapped(text, index, "*");
    if (italic) {
      const node = document.createElement("em");
      appendInline(node, italic.inner);
      parent.append(node);
      index = italic.next;
      continue;
    }
    const image = text.startsWith("![", index);
    if (image || text[index] === "[") {
      const link = readLink(text, image ? index + 1 : index);
      if (link) {
        if (!image && /^https?:\/\//i.test(link.url)) {
          const anchor = document.createElement("a");
          anchor.href = link.url;
          appendInline(anchor, link.label);
          parent.append(anchor);
        } else {
          appendInline(parent, link.label);
        }
        index = link.next;
        continue;
      }
    }
    if ((text.startsWith("https://", index) || text.startsWith("http://", index)) && !isWordChar(text[index - 1])) {
      const match = text.slice(index).match(/^https?:\/\/[^\s<]+/i);
      const url = match?.[0].replace(/[),.;:!?]+$/g, "") ?? "";
      if (url) {
        const anchor = document.createElement("a");
        anchor.href = url;
        anchor.textContent = url;
        parent.append(anchor);
        index += url.length;
        continue;
      }
    }
    let next = index + 1;
    while (next < text.length && !isSpecial(next)) next += 1;
    pushText(text.slice(index, next));
    index = next;
  }
};

const fenceOpen = (line) => {
  const match = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
  if (!match) return null;
  return { marker: match[1][0], count: match[1].length, info: match[2].trim() };
};

const fenceClose = (line, open) => {
  const match = line.match(/^ {0,3}([`~]+)\s*$/);
  return !!match && match[1][0] === open.marker && match[1].length >= open.count;
};

const headingOpen = (line) => {
  const match = line.match(/^ {0,3}(#{1,6})\s+(\S.*?)\s*#*\s*$/);
  if (!match) return null;
  return { level: Math.min(match[1].length, 3), text: match[2].trim() };
};

const ruleOpen = (line) => /^ {0,3}([-*_])(?:\s*\1){2,}\s*$/.test(line);
const bulletOpen = (line) => /^ {0,3}[-*]\s+\S/.test(line) && !ruleOpen(line);
const orderedOpen = (line) => /^ {0,3}\d{1,3}[.)]\s+\S/.test(line);
const quoteOpen = (line) => /^ {0,3}>\s?/.test(line);
const tableRule = (line) => /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line ?? "");
const tableOpen = (line, next) => line.includes("|") && tableRule(next);

const tableCells = (line) => {
  let row = line.trim();
  if (row.startsWith("|")) row = row.slice(1);
  if (row.endsWith("|")) row = row.slice(0, -1);
  return row.split("|").map((cell) => cell.trim());
};

const blockStart = (line, next) =>
  !!fenceOpen(line) || !!headingOpen(line) || ruleOpen(line) || bulletOpen(line) || orderedOpen(line) || quoteOpen(line) || tableOpen(line, next);

const appendParagraph = (root, lines) => {
  const paragraph = document.createElement("p");
  let buffer = "";
  const flush = () => {
    if (!buffer) return;
    appendInline(paragraph, buffer);
    buffer = "";
  };
  lines.forEach((line, lineIndex) => {
    const hard = /(?:  |\\)$/.test(line);
    const cleaned = line.replace(/\s+$/, "").replace(/\\$/, "");
    if (lineIndex > 0 && buffer) buffer += " ";
    buffer += cleaned;
    if (hard) {
      flush();
      paragraph.append(document.createElement("br"));
    }
  });
  flush();
  if (paragraph.childNodes.length) root.append(paragraph);
};

const fillMarkdown = (root, source) => {
  const lines = source.replace(/\r\n?/g, "\n").split("\n");
  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    if (line.trim() === "") {
      index += 1;
      continue;
    }
    const fence = fenceOpen(line);
    if (fence) {
      const body = [];
      index += 1;
      while (index < lines.length && !fenceClose(lines[index], fence)) {
        body.push(lines[index]);
        index += 1;
      }
      if (index < lines.length) index += 1;
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      code.textContent = body.join("\n");
      pre.append(code);
      root.append(pre);
      continue;
    }
    const heading = headingOpen(line);
    if (heading) {
      const node = document.createElement(`h${heading.level}`);
      appendInline(node, heading.text);
      root.append(node);
      index += 1;
      continue;
    }
    if (ruleOpen(line)) {
      root.append(document.createElement("hr"));
      index += 1;
      continue;
    }
    if (tableOpen(line, lines[index + 1])) {
      const headers = tableCells(line);
      index += 2;
      const table = document.createElement("table");
      const head = document.createElement("thead");
      const headRow = document.createElement("tr");
      headers.forEach((cell) => {
        const th = document.createElement("th");
        appendInline(th, cell);
        headRow.append(th);
      });
      head.append(headRow);
      const body = document.createElement("tbody");
      while (index < lines.length && lines[index].trim() !== "" && lines[index].includes("|")) {
        const cells = tableCells(lines[index]);
        const row = document.createElement("tr");
        headers.forEach((_, cellIndex) => {
          const td = document.createElement("td");
          appendInline(td, cells[cellIndex] ?? "");
          row.append(td);
        });
        body.append(row);
        index += 1;
      }
      table.append(head, body);
      const wrap = document.createElement("div");
      wrap.className = "table-wrap";
      wrap.append(table);
      root.append(wrap);
      continue;
    }
    if (bulletOpen(line) || orderedOpen(line)) {
      const ordered = orderedOpen(line);
      const list = document.createElement(ordered ? "ol" : "ul");
      if (ordered) {
        const start = Number(line.match(/^ {0,3}(\d+)/)?.[1] ?? "1");
        if (start !== 1) list.start = start;
      }
      while (index < lines.length && (ordered ? orderedOpen(lines[index]) : bulletOpen(lines[index]))) {
        const item = lines[index].replace(ordered ? /^ {0,3}\d{1,3}[.)]\s+/ : /^ {0,3}[-*]\s+/, "");
        index += 1;
        const extra = [];
        while (index < lines.length && /^ {2,}\S/.test(lines[index])) {
          extra.push(lines[index].trim());
          index += 1;
        }
        const li = document.createElement("li");
        appendInline(li, [item, ...extra].join(" "));
        list.append(li);
      }
      root.append(list);
      continue;
    }
    if (quoteOpen(line)) {
      const body = [];
      while (index < lines.length && quoteOpen(lines[index])) {
        body.push(lines[index].replace(/^ {0,3}>\s?/, ""));
        index += 1;
      }
      const quote = document.createElement("blockquote");
      fillMarkdown(quote, body.join("\n"));
      if (quote.childNodes.length) root.append(quote);
      continue;
    }
    const chunk = [];
    while (index < lines.length && lines[index].trim() !== "" && !blockStart(lines[index], lines[index + 1])) {
      chunk.push(lines[index]);
      index += 1;
    }
    appendParagraph(root, chunk);
  }
};

const renderMessages = (messages) => {
  const signature = messages.map((message) => `${message.id}:${message.role}:${message.text}`).join("\u0001");
  if (signature === messageSignature) return;
  const nearBottom = threadEl.scrollHeight - threadEl.scrollTop - threadEl.clientHeight < 24;
  messageSignature = signature;
  threadEl.replaceChildren();
  messages.forEach((message) => {
    if (!message.text && message.role !== "tool") return;
    const row = document.createElement("div");
    row.className = message.role;
    if (message.role === "assistant") fillMarkdown(row, message.text);
    else row.textContent = message.text;
    if (!row.childNodes.length) return;
    threadEl.append(row);
  });
  if (nearBottom) threadEl.scrollTop = threadEl.scrollHeight;
};

const renderModels = (models, modelId) => {
  const signature = `${modelId}|${models.map((model) => model.id).join("|")}`;
  if (signature === modelSignature) return;
  modelSignature = signature;
  modelEl.replaceChildren();
  models.forEach((model) => {
    const option = document.createElement("option");
    option.value = model.id;
    option.textContent = model.displayName || model.id;
    modelEl.append(option);
  });
  if (modelId) modelEl.value = modelId;
};

const commitName = (input) => {
  const id = input.dataset.rename;
  const title = input.value.trim();
  const original = input.dataset.original || "";
  if (!id || !title || title === original) {
    input.value = original;
    return;
  }
  post({ type: "renameWidget", id, title });
};

const housingWidth = () => {
  const specified = rootEl.style.getPropertyValue("--hardware-notch");
  const raw = specified || getComputedStyle(rootEl).getPropertyValue("--hardware-notch");
  const value = Number.parseFloat(raw);
  return Number.isFinite(value) && value > 0 ? value : 0;
};

const compactSource = (id, revision, housing, leading, trailing) =>
  `notch://widget/${encodeURIComponent(id)}/compact.html?rev=${revision}&housing=${housing}&leading=${leading}&trailing=${trailing}`;

const ensureCompactFrame = () => {
  let frame = compactEl.querySelector("iframe");
  if (frame) return frame;
  frame = document.createElement("iframe");
  frame.title = "Notch";
  frame.addEventListener("load", () => {
    const id = frame.dataset.id;
    if (id) post({ type: "compactReady", id });
    const width = Number(frame.dataset.housing || "0");
    frame.contentWindow?.postMessage({ source: "notch-host", type: "housing", width }, "*");
  });
  compactEl.append(frame);
  return frame;
};

const renderCompact = (id, widgets) => {
  const widget = id ? widgets.find((item) => item.id === id && item.hasCompact) : null;
  rootEl.classList.toggle("has-compact", Boolean(widget));
  if (!widget) {
    compactSignature = "";
    compactEl.hidden = true;
    compactEl.replaceChildren();
    return;
  }
  const leading = Math.max(0, Number(widget.compactLeadingWidth) || 0);
  const trailing = Math.max(0, Number(widget.compactTrailingWidth) || 0);
  const signature = `${widget.id}:${widget.revision}:${leading}:${trailing}`;
  compactEl.hidden = false;
  const frame = ensureCompactFrame();
  frame.dataset.id = widget.id;
  frame.dataset.rev = widget.revision;
  frame.title = widget.title;
  if (signature === compactSignature) return;
  compactSignature = signature;
  frame.dataset.requestedLeading = String(leading);
  frame.dataset.requestedTrailing = String(trailing);
  frame.dataset.leading = String(leading);
  frame.dataset.trailing = String(trailing);
  const housing = housingWidth();
  frame.dataset.housing = String(housing);
  frame.src = compactSource(widget.id, widget.revision, housing, leading, trailing);
};

const renderLibrary = (widgets, pinnedId) => {
  const signature = `${pinnedId}|${widgets.map((widget) => `${widget.id}:${widget.title}:${widget.hidden}:${widget.hasCompact}:${widget.compactDisabled}`).join("|")}`;
  if (signature === librarySignature) {
    listEl.querySelectorAll("input[data-rename]").forEach((input) => {
      if (document.activeElement === input) return;
      const widget = widgets.find((item) => item.id === input.dataset.rename);
      if (!widget || input.value === widget.title) return;
      input.value = widget.title;
      input.dataset.original = widget.title;
    });
    return;
  }
  const focused = document.activeElement;
  const editingId = focused instanceof HTMLInputElement ? focused.dataset.rename || "" : "";
  const draft = editingId ? focused.value : "";
  librarySignature = signature;
  listEl.classList.toggle("notchable", widgets.some((widget) => widget.hasCompact));
  listEl.replaceChildren();
  if (widgets.length === 0) {
    const empty = document.createElement("p");
    empty.className = "library-empty";
    empty.textContent = "No widgets yet";
    listEl.append(empty);
    return;
  }
  widgets.forEach((widget) => {
    const row = document.createElement("div");
    row.className = "widget-row";
    const title = document.createElement("input");
    title.type = "text";
    title.maxLength = 48;
    title.spellcheck = false;
    title.autocomplete = "off";
    title.setAttribute("aria-label", "Widget name");
    title.dataset.rename = widget.id;
    title.dataset.original = widget.title;
    title.value = widget.id === editingId ? draft : widget.title;
    title.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        title.blur();
      }
      if (event.key === "Escape") {
        event.stopPropagation();
        title.value = title.dataset.original || "";
        title.blur();
      }
    });
    title.addEventListener("blur", () => commitName(title));
    const pin = document.createElement("button");
    pin.type = "button";
    pin.className = "pin";
    pin.textContent = "Notch";
    if (widget.hasCompact && !widget.compactDisabled && !widget.hidden) {
      pin.classList.toggle("on", widget.id === pinnedId);
      pin.setAttribute("aria-label", widget.id === pinnedId ? "Unpin from the notch" : "Pin to the notch");
      pin.addEventListener("click", () => post({ type: "pinCompact", id: widget.id }));
    } else {
      pin.disabled = true;
      pin.style.visibility = "hidden";
      pin.tabIndex = -1;
    }
    const compact = document.createElement("button");
    compact.type = "button";
    compact.className = "compact";
    compact.textContent = "Compact";
    if (widget.hasCompact) {
      const enabled = !widget.compactDisabled;
      compact.classList.toggle("on", enabled);
      compact.classList.toggle("off", !enabled);
      compact.setAttribute("aria-label", enabled ? "Disable compact view" : "Enable compact view");
      compact.setAttribute("aria-pressed", String(enabled));
      compact.addEventListener("click", () => post({ type: "setCompactDisabled", id: widget.id, disabled: enabled }));
    } else {
      compact.disabled = true;
      compact.style.visibility = "hidden";
      compact.tabIndex = -1;
    }
    const visibility = document.createElement("input");
    visibility.type = "checkbox";
    visibility.setAttribute("switch", "");
    visibility.checked = !widget.hidden;
    visibility.setAttribute("aria-label", "Show on shelf");
    visibility.addEventListener("change", () => {
      post({ type: "setHidden", id: widget.id, hidden: !visibility.checked });
    });
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "remove";
    remove.textContent = "Delete";
    remove.addEventListener("click", () => post({ type: "confirmDelete", id: widget.id }));
    row.append(title);
    if (listEl.classList.contains("notchable")) row.append(pin, compact);
    row.append(visibility, remove);
    listEl.append(row);
  });
  if (editingId) {
    const field = listEl.querySelector(`input[data-rename="${CSS.escape(editingId)}"]`);
    if (field instanceof HTMLInputElement) {
      field.focus();
      const end = field.value.length;
      field.setSelectionRange(end, end);
    }
  }
};

const placeMenu = (id) => {
  const card = id ? widgetsEl.querySelector(`.widget[data-id="${CSS.escape(id)}"]`) : null;
  if (!card) {
    menuEl.hidden = true;
    return;
  }
  const rect = card.getBoundingClientRect();
  menuEl.dataset.id = id;
  const hide = menuEl.querySelector("[data-action=delete]");
  if (hide) hide.hidden = id.startsWith("pending:");
  menuEl.hidden = false;
  menuEl.style.left = `${Math.max(8, rect.right - 148)}px`;
  menuEl.style.top = `${rect.top + (showTitles ? 26 : 8)}px`;
};

window.shelf = {
  apply: (state) => {
    rootEl.classList.add("ready");
    const widgets = state.widgets || [];
    showTitles = state.showTitles !== false;
    titlesToggleEl.checked = showTitles;
    const visible = widgets.filter((widget) => !widget.hidden);
    const editingId = state.editingWidgetId || "";
    const shelfWidgets = editingId
      ? widgets.filter((widget) => widget.id === editingId)
      : visible;
    if (state.mode === "reorder" && press) press.sawReorder = true;
    if (press?.lifted && press.sawReorder && state.mode !== "reorder") abortDrag();
    wantReorder = state.mode === "reorder" || Boolean(press?.lifted);
    const editing = Boolean(editingId);
    const composing = state.mode === "chat";
    widgetsEl.classList.toggle("solo", editing && shelfWidgets.length > 0);
    widgetsEl.classList.toggle("reordering", wantReorder);
    const focusing = Boolean(state.focusedWidgetId) && state.mode === "shelf";
    appEl.classList.toggle("focusing", focusing);
    menubarEl.classList.toggle("editing", composing);
    menubarEl.classList.toggle("reordering", wantReorder && !composing);
    doneEl.hidden = !composing && !wantReorder && !focusing;
    const sessions = state.sessions || [];
    const creating = sessions.filter((session) => session.running && !session.widgetId);
    const busy = new Set(sessions.filter((session) => session.running && session.widgetId).map((session) => session.widgetId));
    renderWidgets(shelfWidgets, editingId, { creating: editing ? [] : creating, busy });
    if (editing || creating.length) emptyEl.hidden = true;
    renderMessages(state.messages);
    renderModels(state.models || [], state.modelId || "");
    const provider = state.provider || "cursor";
    savedProvider = provider;
    providerEl.value = provider;
    const providerInfo = {
      cursor: ["Cursor", "Uses a Cursor API key for this workspace.", "API key", true, true],
      claude: ["Claude Code", "Uses the Claude Code account signed in on this Mac.", "API key (optional)", false, true],
      codex: ["Codex (ChatGPT)", "Uses the Codex account signed in on this Mac.", "API key (optional)", false, false],
    }[provider] || ["Cursor", "Uses a Cursor API key for this workspace.", "API key", true, true];
    providerNameEl.textContent = providerInfo[0];
    providerCopyEl.textContent = providerInfo[1];
    keyLabelEl.textContent = providerInfo[2];
    credentialFieldEl.hidden = !providerInfo[3] || !providerEditing;
    modelFieldEl.hidden = !providerInfo[4] || !providerEditing;
    providerSummaryEl.hidden = providerEditing;
    settingsFormEl.hidden = !providerEditing;
    const auth = state.auth || {};
    providerStatusEl.textContent = auth.message || (auth.checked ? "Not connected" : "Checking connection…");
    providerStatusEl.dataset.connected = auth.connected ? "true" : "false";
    renderLibrary(widgets, state.pinnedCompactId || "");
    renderCompact(state.compactWidgetId || "", widgets);
    const locked = !state.hasKey || state.nodeMissing;
    const chatting = state.mode === "chat";
    const morph = state.mode === "settings" || state.mode === "confirm";
    shelfEl.hidden = morph;
    chatEl.hidden = !chatting;
    settingsEl.hidden = state.mode !== "settings";
    confirmEl.hidden = state.mode !== "confirm";
    gearEl.classList.toggle("on", state.mode === "settings");
    const target = widgets.find((widget) => widget.id === state.confirmWidgetId);
    const name = target?.title || "this widget";
    const deleting = state.confirmKind === "delete";
    confirmTitleEl.textContent = deleting ? `Delete ${name}?` : `Hide ${name}?`;
    confirmBodyEl.textContent = deleting
      ? "This removes the widget folder and its chat."
      : "It leaves the shelf. You can show it again in Settings.";
    confirmAcceptEl.textContent = deleting ? "Delete" : "Hide";
    confirmAcceptEl.classList.toggle("danger", deleting);
    titleEl.textContent = state.sessionTitle || "";
    const emptyTitle = emptyEl.querySelector("p");
    const emptyHint = emptyEl.querySelector("span");
    if (visible.length === 0 && widgets.length > 0) {
      emptyTitle.textContent = "Nothing on the shelf";
      emptyHint.textContent = "Hidden widgets are in Settings.";
      createEl.hidden = true;
    } else {
      emptyTitle.textContent = "No widgets yet";
      emptyHint.textContent = "They show up here once you describe one.";
      createEl.hidden = false;
    }
    keyEl.placeholder = provider === "cursor"
      ? (state.hasKey ? "Key saved" : "Paste a key")
      : "Leave blank to use the local sign-in";
    inputEl.disabled = locked;
    inputEl.placeholder = state.nodeMissing
      ? "Node.js 22.13 or newer is required"
      : state.editingWidgetId
        ? "Ask for a change"
        : "Describe a widget";
    composerLocked = locked;
    composerRunning = Boolean(state.running);
    attachEl.disabled = locked;
    if ((state.sessionId || "") !== sessionId) {
      sessionId = state.sessionId || "";
      clearAttachments();
    }
    refreshSend();
    goEl.classList.toggle("stop", state.running);
    goEl.setAttribute("aria-label", state.running ? "Stop" : "Send");
    document.getElementById("add").disabled = locked;
    document.getElementById("create").disabled = locked;
    errorEl.hidden = !state.error;
    errorEl.textContent = state.error || "";
    placeMenu(!wantReorder && (state.mode === "shelf" || state.mode === "chat") ? state.menuWidgetId : "");
    if (chatting && lastMode !== "chat") inputEl.focus();
    lastMode = state.mode;
  },
  deliver: (id, body) => {
    const frame = widgetsEl.querySelector(`iframe[data-id="${CSS.escape(id)}"]`);
    frame?.contentWindow?.postMessage({ source: "notch-host", body }, "*");
    const compact = compactEl.querySelector(`iframe[data-id="${CSS.escape(id)}"]`);
    compact?.contentWindow?.postMessage({ source: "notch-host", body }, "*");
  },
  setOpen: (value) => {
    const open = Math.max(0, Math.min(1, Number(value) || 0));
    rootEl.style.setProperty("--open", String(open));
    rootEl.classList.toggle("compact-closed", open < 0.28);
  },
  setHousing: (width) => {
    const value = Math.max(0, Number(width) || 0);
    rootEl.style.setProperty("--hardware-notch", `${value}px`);
    const frame = compactEl.querySelector("iframe");
    if (!frame?.dataset.id) return;
    const previous = Number(frame.dataset.housing || "0");
    const split = (amount) => amount > 1;
    frame.dataset.housing = String(value);
    if (split(previous) !== split(value)) {
      frame.src = compactSource(frame.dataset.id, frame.dataset.rev || "", value, frame.dataset.leading || "0", frame.dataset.trailing || "0");
      return;
    }
    frame.contentWindow?.postMessage({ source: "notch-host", type: "housing", width: value }, "*");
  },
};

doneEl.addEventListener("click", () => {
  if (widgetsEl.classList.contains("reordering")) {
    if (press?.lifted) drop(press.last ?? pressPoint(press.x, press.y));
    else post({ type: "commitLayout", layout: JSON.stringify(layoutRows) });
    post({ type: "endReorder" });
    return;
  }
  if (appEl.classList.contains("focusing")) {
    post({ type: "clearFocus" });
    return;
  }
  post({ type: "exitEdit" });
});
threadEl.addEventListener("click", (event) => {
  const link = event.target instanceof Element ? event.target.closest("a") : null;
  if (!link || !threadEl.contains(link)) return;
  event.preventDefault();
  const url = link.getAttribute("href") || "";
  if (/^https?:\/\//i.test(url)) post({ type: "openLink", url });
});

document.getElementById("gear").addEventListener("click", () => post({ type: "showSettings" }));
document.getElementById("add").addEventListener("click", () => post({ type: "createWidget" }));
document.getElementById("create").addEventListener("click", () => post({ type: "createWidget" }));
titlesToggleEl.addEventListener("change", () => {
  post({ type: "setShowTitles", show: titlesToggleEl.checked });
});

document.getElementById("settings-form").addEventListener("submit", (event) => {
  event.preventDefault();
  post({ type: "saveSettings", provider: providerEl.value, apiKey: keyEl.value, modelId: modelEl.value });
  providerEditing = false;
  providerSummaryEl.hidden = false;
  settingsFormEl.hidden = true;
  keyEl.value = "";
});

providerEl.addEventListener("change", () => {
  const provider = providerEl.value;
  const providerInfo = {
    cursor: ["Cursor", "Uses a Cursor API key for this workspace.", "API key", true, true],
    claude: ["Claude Code", "Uses the Claude Code account signed in on this Mac.", "API key (optional)", false, true],
    codex: ["Codex (ChatGPT)", "Uses the Codex account signed in on this Mac.", "API key (optional)", false, false],
  }[provider];
  if (!providerInfo) return;
  providerNameEl.textContent = providerInfo[0];
  providerCopyEl.textContent = providerInfo[1];
  keyLabelEl.textContent = providerInfo[2];
  credentialFieldEl.hidden = !providerInfo[3];
  modelFieldEl.hidden = !providerInfo[4];
  keyEl.placeholder = provider === "cursor" ? "Paste a key" : "Leave blank to use the local sign-in";
  providerStatusEl.textContent = provider === "cursor" ? "Enter your Cursor API key, then Save." : "Save to check local sign-in status.";
  providerStatusEl.dataset.connected = "false";
  modelEl.replaceChildren();
});

providerEditEl.addEventListener("click", () => {
  providerEditing = true;
  providerSummaryEl.hidden = true;
  settingsFormEl.hidden = false;
  credentialFieldEl.hidden = providerEl.value !== "cursor";
  modelFieldEl.hidden = providerEl.value === "codex";
});

providerCancelEl.addEventListener("click", () => {
  providerEditing = false;
  providerEl.value = savedProvider;
  providerEl.dispatchEvent(new Event("change"));
  providerSummaryEl.hidden = false;
  settingsFormEl.hidden = true;
});

document.getElementById("quit").addEventListener("click", () => post({ type: "quit" }));

document.getElementById("confirm-cancel").addEventListener("click", () => post({ type: "cancelConfirm" }));
document.getElementById("confirm-accept").addEventListener("click", () => post({ type: "acceptConfirm" }));

menuEl.addEventListener("click", (event) => {
  const action = event.target.closest("button")?.dataset.action;
  const id = menuEl.dataset.id;
  if (!action || !id) return;
  if (action === "edit") post({ type: "editWidget", id });
  if (action === "delete" && !id.startsWith("pending:")) post({ type: "confirmHide", id });
});

const textControl = (target) => {
  const element = target instanceof Element ? target : target instanceof Node ? target.parentElement : null;
  const field = element?.closest?.("textarea, input");
  if (!(field instanceof HTMLTextAreaElement || field instanceof HTMLInputElement)) return null;
  if (field.disabled) return null;
  if (field instanceof HTMLInputElement) {
    const type = (field.type || "text").toLowerCase();
    if (["button", "checkbox", "color", "file", "hidden", "image", "radio", "range", "reset", "submit"].includes(type)) {
      return null;
    }
  }
  return field;
};

const selectedThreadText = () => {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || !selection.rangeCount) return "";
  const node = selection.anchorNode;
  if (!(node instanceof Node) || !threadEl.contains(node)) return "";
  return selection.toString();
};

document.addEventListener("contextmenu", (event) => {
  const field = textControl(event.target);
  if (field) {
    event.preventDefault();
    field.focus();
    post({ type: "editMenu", x: event.clientX, y: event.clientY });
    return;
  }
  const bubble = event.target instanceof Element
    ? event.target.closest("#thread .user, #thread .assistant, #thread .tool")
    : null;
  if (bubble) {
    event.preventDefault();
    const text = selectedThreadText() || bubble.innerText || "";
    if (text.trim()) post({ type: "editMenu", copyOnly: true, text, x: event.clientX, y: event.clientY });
    return;
  }
  event.preventDefault();
  if (widgetsEl.classList.contains("reordering") || press) return;
  const card = event.target.closest?.(".widget");
  if (!card?.dataset.id) return;
  post({ type: "widgetMenu", id: card.dataset.id });
});

widgetsEl.addEventListener("pointerdown", (event) => {
  if (event.button !== 0) return;
  if (event.target.closest?.("button, a, input, textarea, select")) return;
  const card = event.target.closest?.(".widget");
  if (!card?.dataset.id || card.classList.contains("lifted") || card.classList.contains("skeleton")) return;
  if (widgetsEl.classList.contains("reordering")) event.preventDefault();
  pressDown(card.dataset.id, pressPoint(event.clientX, event.clientY));
});

window.addEventListener("pointermove", (event) => {
  if (!press) return;
  pressMove(pressPoint(event.clientX, event.clientY));
});

window.addEventListener("pointerup", (event) => {
  if (!press) return;
  pressUp(pressPoint(event.clientX, event.clientY));
});

window.addEventListener("pointercancel", () => {
  if (!press) return;
  if (press.lifted) drop(press.last ?? pressPoint(press.x, press.y));
  else clearIdlePress();
});

window.addEventListener("blur", () => {
  if (!press?.lifted) return;
  drop(press.last ?? pressPoint(press.x, press.y));
});

window.addEventListener("message", (event) => {
  const data = event.data;
  if (data?.source === "notch-compact-size") {
    const frame = compactEl.querySelector("iframe");
    if (!frame || event.source !== frame.contentWindow || data.id !== frame.dataset.id) return;
    const requestedLeading = Math.max(0, Number(frame.dataset.requestedLeading) || 0);
    const requestedTrailing = Math.max(0, Number(frame.dataset.requestedTrailing) || 0);
    const leading = Math.min(requestedLeading, Math.max(0, Number(data.leading) || 0));
    const trailing = Math.min(requestedTrailing, Math.max(0, Number(data.trailing) || 0));
    if (leading === Number(frame.dataset.leading) && trailing === Number(frame.dataset.trailing)) return;
    frame.dataset.leading = String(leading);
    frame.dataset.trailing = String(trailing);
    post({ type: "compactSize", id: data.id, leading, trailing });
    frame.src = compactSource(data.id, frame.dataset.rev || "", frame.dataset.housing || "0", leading, trailing);
    return;
  }
  if (!data || data.source !== "notch-press" || typeof data.id !== "string") return;
  const compactFrame = compactEl.querySelector("iframe");
  if (compactFrame && event.source === compactFrame.contentWindow) {
    if (!rootEl.classList.contains("compact-closed")) return;
    if (data.action && (data.phase === "down" || data.phase === "up")) {
      post({ type: "compactAction" });
      return;
    }
    if (data.phase === "up" && !data.moved && !data.action) {
      post({ type: "openCompact", id: data.id });
    }
    return;
  }
  const frame = widgetsEl.querySelector(`iframe[data-id="${CSS.escape(data.id)}"]`);
  if (!frame || event.source !== frame.contentWindow) return;
  const rect = frame.getBoundingClientRect();
  const point = pressPoint(rect.left + Number(data.x), rect.top + Number(data.y));
  if (data.phase === "down") pressDown(data.id, point);
  else if (data.phase === "move") pressMove(point);
  else pressUp(point);
});

document.addEventListener("pointerdown", (event) => {
  if (event.button !== 0 || menuEl.hidden || menuEl.contains(event.target)) return;
  post({ type: "closeMenu" });
});

const refreshSend = () => {
  const ready = inputEl.value.trim() !== "" || attachments.length > 0;
  goEl.disabled = composerLocked || (!composerRunning && !ready);
};

const attachNote = (text) => {
  attachNoteEl.hidden = !text;
  attachNoteEl.textContent = text;
  window.clearTimeout(attachNoteTimer);
  if (!text) return;
  attachNoteTimer = window.setTimeout(() => {
    attachNoteEl.hidden = true;
  }, 3200);
};

const fileLabel = (file) => {
  if (file.type.startsWith("image/")) return "Image";
  const ext = file.name.includes(".") ? file.name.split(".").pop() : "";
  if (!ext || ext.length > 5) return "File";
  return ext.toUpperCase();
};

const sizeLabel = (bytes) => {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
};

const icon = (viewBox, paths) => {
  const node = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  node.setAttribute("viewBox", viewBox);
  node.setAttribute("aria-hidden", "true");
  paths.forEach((d) => {
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", d);
    path.setAttribute("fill", "none");
    path.setAttribute("stroke", "currentColor");
    path.setAttribute("stroke-width", viewBox === "0 0 8 8" ? "1.4" : "1.3");
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
    node.append(path);
  });
  return node;
};

const renderAttachments = () => {
  attachmentsEl.replaceChildren();
  attachmentsEl.hidden = attachments.length === 0;
  composerEl.classList.toggle("has-files", attachments.length > 0);
  attachments.forEach((item) => {
    const chip = document.createElement("div");
    chip.className = item.kind === "image" ? "attachment image" : "attachment file";
    if (item.kind === "image") {
      const img = document.createElement("img");
      img.src = item.preview;
      img.alt = item.name;
      img.addEventListener("error", () => {
        if (item.kind !== "image") return;
        item.kind = "file";
        if (item.preview) URL.revokeObjectURL(item.preview);
        item.preview = "";
        renderAttachments();
      });
      chip.append(img);
    } else {
      const mark = document.createElement("span");
      mark.className = "mark";
      mark.append(icon("0 0 16 16", ["M4.2 1.8h4.4L12.2 5.4V14.2H4.2V1.8Z", "M8.5 1.9v3.6h3.6"]));
      const meta = document.createElement("span");
      meta.className = "meta";
      const name = document.createElement("strong");
      name.textContent = item.name;
      name.title = item.name;
      const detail = document.createElement("span");
      detail.textContent = `${fileLabel(item.file)} · ${sizeLabel(item.file.size)}`;
      meta.append(name, detail);
      chip.append(mark, meta);
    }
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "remove";
    remove.setAttribute("aria-label", `Remove ${item.name}`);
    remove.append(icon("0 0 8 8", ["M1.5 1.5 6.5 6.5", "M6.5 1.5 1.5 6.5"]));
    remove.addEventListener("click", () => removeAttachment(item.id));
    chip.append(remove);
    attachmentsEl.append(chip);
  });
};

const removeAttachment = (id) => {
  const index = attachments.findIndex((item) => item.id === id);
  if (index < 0) return;
  const item = attachments[index];
  if (item.preview) URL.revokeObjectURL(item.preview);
  attachments.splice(index, 1);
  renderAttachments();
  refreshSend();
};

const clearAttachments = () => {
  attachments.forEach((item) => {
    if (item.preview) URL.revokeObjectURL(item.preview);
  });
  attachments.splice(0, attachments.length);
  renderAttachments();
};

const addFiles = (files) => {
  let added = false;
  let rejected = false;
  files.forEach((file) => {
    if (attachments.length >= maxAttachments) {
      attachNote("You can attach up to 8 files.");
      rejected = true;
      return;
    }
    if (file.size > maxAttachmentBytes) {
      attachNote(`${file.name || "That file"} is over 4 MB.`);
      rejected = true;
      return;
    }
    const image = file.type.startsWith("image/");
    attachments.push({
      id: crypto.randomUUID(),
      file,
      name: file.name || (image ? "Image" : "File"),
      kind: image ? "image" : "file",
      preview: image ? URL.createObjectURL(file) : "",
    });
    added = true;
  });
  if (!added) return;
  if (!rejected) attachNote("");
  renderAttachments();
  refreshSend();
};

const readFile = (file) => new Promise((resolve, reject) => {
  const reader = new FileReader();
  reader.onload = () => {
    const raw = String(reader.result || "");
    const split = raw.indexOf(",");
    resolve(split >= 0 ? raw.slice(split + 1) : raw);
  };
  reader.onerror = () => reject(reader.error);
  reader.readAsDataURL(file);
});

const submit = async () => {
  if (goEl.classList.contains("stop")) {
    post({ type: "cancel" });
    return;
  }
  const text = inputEl.value;
  const files = attachments.slice();
  if (!text.trim() && files.length === 0) return;
  let payload = [];
  try {
    payload = await Promise.all(files.map(async (item) => ({
      name: item.name,
      kind: item.kind,
      mime: item.file.type || "application/octet-stream",
      data: await readFile(item.file),
    })));
  } catch {
    attachNote("That file could not be read.");
    return;
  }
  inputEl.value = "";
  clearAttachments();
  fitComposer();
  refreshSend();
  post({ type: "send", text, attachments: payload });
};

composerEl.addEventListener("submit", (event) => event.preventDefault());

attachEl.addEventListener("click", () => {
  if (attachEl.disabled) return;
  post({ type: "pickAttachments" });
});

window.shelf.attachLocal = (items) => {
  const files = [];
  (items || []).forEach((item) => {
    if (item.tooLarge) {
      attachNote(`${item.name || "That file"} is over 4 MB.`);
      return;
    }
    if (!item.data) return;
    try {
      const binary = atob(item.data);
      const bytes = new Uint8Array(binary.length);
      for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
      files.push(new File([bytes], item.name || "File", { type: item.mime || "application/octet-stream" }));
    } catch {
      attachNote(`${item.name || "That file"} could not be read.`);
    }
  });
  if (files.length) addFiles(files);
};

inputEl.addEventListener("paste", (event) => {
  const files = [...(event.clipboardData?.files ?? [])];
  if (!files.length) return;
  event.preventDefault();
  addFiles(files);
});

const draggedFiles = (event) => [...(event.dataTransfer?.types ?? [])].includes("Files");

chatEl.addEventListener("dragenter", (event) => {
  if (!draggedFiles(event)) return;
  event.preventDefault();
  composerEl.classList.add("dropping");
});

chatEl.addEventListener("dragover", (event) => {
  if (!draggedFiles(event)) return;
  event.preventDefault();
});

chatEl.addEventListener("dragleave", (event) => {
  if (event.relatedTarget instanceof Node && chatEl.contains(event.relatedTarget)) return;
  composerEl.classList.remove("dropping");
});

window.addEventListener("drop", (event) => {
  const files = [...(event.dataTransfer?.files ?? [])];
  if (!files.length) return;
  event.preventDefault();
  composerEl.classList.remove("dropping");
  if (!chatEl.hidden && event.target instanceof Node && chatEl.contains(event.target)) addFiles(files);
});

goEl.addEventListener("click", () => {
  submit();
});

inputEl.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    goEl.click();
    return;
  }
  if (event.key === "Backspace" && inputEl.value === "" && attachments.length > 0) {
    event.preventDefault();
    removeAttachment(attachments[attachments.length - 1].id);
  }
});

const fitComposer = () => {
  const style = getComputedStyle(inputEl);
  const line = parseFloat(style.lineHeight) || 20;
  const pad = (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0);
  const min = line + pad;
  inputEl.style.overflowY = "hidden";
  inputEl.style.height = "auto";
  const needed = inputEl.value ? inputEl.scrollHeight : min;
  const lines = Math.max(1, Math.round((needed - pad) / line));
  const shown = Math.min(4, lines);
  inputEl.style.height = `${shown * line + pad}px`;
  inputEl.style.overflowY = lines > 4 ? "auto" : "hidden";
  composerEl.classList.toggle("multiline", shown > 1);
};

inputEl.addEventListener("input", () => {
  fitComposer();
  refreshSend();
});

let composerWidth = 0;
new ResizeObserver(() => {
  const width = composerEl.clientWidth;
  if (width === composerWidth) return;
  composerWidth = width;
  fitComposer();
}).observe(composerEl);

fitComposer();

const reportFocus = () => {
  const active = document.activeElement;
  const focused = active instanceof HTMLTextAreaElement || active instanceof HTMLInputElement || active instanceof HTMLSelectElement;
  post({ type: "composerFocus", focused });
};

document.addEventListener("focusin", reportFocus);
document.addEventListener("focusout", () => setTimeout(reportFocus, 0));

window.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return;
  if (widgetsEl.classList.contains("reordering") || press?.lifted) {
    if (press) abortDrag();
    post({ type: "endReorder" });
    return;
  }
  post({ type: "escape" });
});

post({ type: "ready" });
