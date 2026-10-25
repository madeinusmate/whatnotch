import Foundation

struct WidgetRecord: Equatable {
    var id: String
    var title: String
    var width: Int
    var height: Int
    var revision: String
    var hasCompact: Bool
    var compactWidth: Int
}

enum WidgetBridge {
    static let script = """
    (() => {
      const pending = new Map();
      window.__notchSettle = (id, payload) => {
        const entry = pending.get(id);
        if (!entry) return;
        pending.delete(id);
        if (payload.ok) entry.resolve(payload.value);
        else entry.reject(new Error(payload.error || "Request failed"));
      };
      const deliver = (body) => {
        window.dispatchEvent(new CustomEvent("notch-state", { detail: body }));
      };
      window.__notchState = deliver;
      let onHousing = () => {};
      window.addEventListener("message", (event) => {
        if (!event.data || event.data.source !== "notch-host") return;
        if (event.data.type === "housing") {
          onHousing(event.data.width);
          return;
        }
        deliver(event.data.body);
      });
      if (location.host !== "widget") return;
      const call = (method, args) => new Promise((resolve, reject) => {
        const id = crypto.randomUUID();
        pending.set(id, { resolve, reject });
        window.webkit.messageHandlers.widget.postMessage({ id, method, args });
      });
      window.notch = {
        shell: (command) => call("shell", { command }),
        readFile: (path) => call("readFile", { path }),
        writeFile: (path, contents) => call("writeFile", { path, contents }),
        list: (path) => call("list", { path }),
        http: (url, options = {}) => call("http", {
          url,
          method: options.method,
          headers: options.headers,
          body: options.body,
        }),
      };
      const slug = decodeURIComponent((location.pathname.split("/").filter(Boolean)[0] || ""));
      const compactPage = location.pathname.endsWith("/compact.html");
      if (compactPage) {
        const style = document.createElement("style");
        const housingFrom = (value) => Math.max(0, Number(value) || 0);
        let housing = housingFrom(new URLSearchParams(location.search).get("housing"));
        const paint = () => {
          document.documentElement.style.setProperty("--hardware-notch", housing + "px");
        };
        paint();
        const base = "html,body{margin:0;height:100%;background:transparent;color:rgba(255,255,255,.92);font:13px/1 ui-sans-serif,system-ui,sans-serif;overflow:hidden}";
        const centered = "body{display:flex;align-items:center;justify-content:center;gap:8px;padding:0 12px;white-space:nowrap}";
        const around = "html body{display:grid !important;grid-template-columns:minmax(0,1fr) var(--hardware-notch,0px) minmax(0,1fr) !important;grid-template-rows:100%;align-items:center;justify-content:stretch !important;gap:0 !important;padding:0 !important;overflow:hidden}html body>:not([data-notch-ear]){visibility:hidden !important}[data-notch-ear]{position:relative;box-sizing:border-box;display:flex;align-items:center;gap:8px;min-width:0;height:100%;overflow:hidden;white-space:nowrap}[data-notch-ear=leading]{grid-column:1;grid-row:1;justify-content:flex-end;padding:0 8px 0 12px}[data-notch-ear=trailing]{grid-column:3;grid-row:1;justify-content:flex-start;padding:0 12px 0 8px}";
        const usesEars = () => housing > 1;
        style.textContent = base + (usesEars() ? around : centered);
        document.documentElement.append(style);
        let arranging = false;
        const isContent = (node) => {
          if (!(node instanceof Element) || node.hasAttribute("data-notch-ear")) return false;
          const tag = node.tagName;
          return tag !== "SCRIPT" && tag !== "STYLE" && tag !== "LINK";
        };
        const arrange = () => {
          if (!usesEars() || arranging || !document.body) return;
          arranging = true;
          let leading = document.body.querySelector("[data-notch-ear=leading]");
          let trailing = document.body.querySelector("[data-notch-ear=trailing]");
          if (!leading) {
            leading = document.createElement("div");
            leading.setAttribute("data-notch-ear", "leading");
            document.body.append(leading);
          }
          if (!trailing) {
            trailing = document.createElement("div");
            trailing.setAttribute("data-notch-ear", "trailing");
            document.body.append(trailing);
          }
          const items = [...document.body.children].filter(isContent);
          const mid = Math.ceil(items.length / 2);
          items.forEach((node, index) => {
            (index < mid ? leading : trailing).append(node);
          });
          arranging = false;
        };
        const park = () => {
          if (!usesEars() || arranging || !document.body) return;
          const stray = [...document.body.children].filter(isContent);
          if (!stray.length) return;
          const trailing = document.body.querySelector("[data-notch-ear=trailing]");
          if (!trailing) {
            arrange();
            return;
          }
          arranging = true;
          stray.forEach((node) => trailing.append(node));
          arranging = false;
        };
        const ready = () => {
          (document.head || document.documentElement).append(style);
          arrange();
          if (!document.body) return;
          const observer = new MutationObserver(() => park());
          observer.observe(document.body, { childList: true });
        };
        if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", ready, { once: true });
        else ready();
        onHousing = (value) => {
          const next = housingFrom(value);
          if (next === housing) {
            paint();
            return;
          }
          housing = next;
          paint();
        };
      }
      const actionOf = (event) => {
        const node = event.target instanceof Element ? event.target.closest("[data-action]") : null;
        return node ? (node.getAttribute("data-action") || "") : "";
      };
      const blockedTypes = new Set(["button", "checkbox", "color", "file", "hidden", "image", "radio", "range", "reset", "submit"]);
      const isField = (node) => {
        if (!(node instanceof Element)) return false;
        if (node instanceof HTMLTextAreaElement || node instanceof HTMLSelectElement) return !node.disabled;
        if (node instanceof HTMLInputElement) return !node.disabled && !blockedTypes.has((node.type || "text").toLowerCase());
        if (node instanceof HTMLLabelElement && node.control) return isField(node.control);
        return node.isContentEditable;
      };
      const focusedField = () => {
        let node = document.activeElement;
        while (node && node.shadowRoot && node.shadowRoot.activeElement) node = node.shadowRoot.activeElement;
        return isField(node);
      };
      const eventHitsField = (event) => event.composedPath().some((node) => isField(node));
      const reportField = (focused) => {
        window.webkit.messageHandlers.widget.postMessage({ type: "editing", id: slug, focused });
      };
      document.addEventListener("focusin", () => reportField(focusedField()), true);
      document.addEventListener("focusout", () => setTimeout(() => reportField(focusedField()), 0), true);
      document.addEventListener("contextmenu", (event) => {
        event.preventDefault();
        window.webkit.messageHandlers.widget.postMessage({ type: "context", id: slug });
      }, true);
      let tracking = { current: null };
      let suppressClick = { current: false };
      const sendPress = (phase, event, extra = {}) => {
        window.parent.postMessage({
          source: "notch-press",
          phase,
          id: slug,
          x: event.clientX,
          y: event.clientY,
          action: extra.action || "",
          moved: Boolean(extra.moved),
        }, "*");
      };
      document.addEventListener("pointerdown", (event) => {
        if (event.button !== 0) return;
        window.webkit.messageHandlers.widget.postMessage({ type: "closeMenu" });
        if (eventHitsField(event)) {
          reportField(true);
          return;
        }
        tracking.current = { x: event.clientX, y: event.clientY, t: Date.now(), moved: false, action: actionOf(event) };
        sendPress("down", event, tracking.current);
      }, true);
      document.addEventListener("pointermove", (event) => {
        const active = tracking.current;
        if (!active) return;
        if (Math.hypot(event.clientX - active.x, event.clientY - active.y) > 10) active.moved = true;
        sendPress("move", event);
      }, true);
      const endPress = (event) => {
        const active = tracking.current;
        if (!active) return;
        suppressClick.current = !active.moved && Date.now() - active.t >= 420;
        tracking.current = null;
        sendPress("up", event, active);
      };
      document.addEventListener("pointerup", endPress, true);
      document.addEventListener("pointercancel", endPress, true);
      document.addEventListener("click", (event) => {
        if (!suppressClick.current) return;
        suppressClick.current = false;
        event.preventDefault();
        event.stopPropagation();
      }, true);
    })();
    """

    static func scrubbedEnvironment() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        return [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": env["HOME"] ?? NSHomeDirectory(),
            "USER": env["USER"] ?? NSUserName(),
            "TMPDIR": env["TMPDIR"] ?? NSTemporaryDirectory(),
            "LANG": env["LANG"] ?? "en_US.UTF-8",
        ]
    }
}

final class WidgetRuntime {
    let widgetsRoot: URL
    let dismissedRoot: URL
    var onWidgets: (([WidgetRecord]) -> Void)?
    var onWorkerState: ((String, Any, Bool?) -> Void)?

    private let watcher = FolderWatcher()
    private var workers: [String: Process] = [:]
    private var workerStamps: [String: Date] = [:]
    private var outputBuffers: [String: String] = [:]
    private let outputQueue = DispatchQueue(label: "app.whatnotch.widgets")
    init(widgetsRoot: URL, dismissedRoot: URL) {
        self.widgetsRoot = widgetsRoot
        self.dismissedRoot = dismissedRoot
    }

    func restoreDismissed() -> [String] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: dismissedRoot.path) else { return [] }
        var restored: [String] = []
        for name in names {
            guard name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { continue }
            let source = dismissedRoot.appendingPathComponent(name, isDirectory: true)
            let destination = widgetsRoot.appendingPathComponent(name, isDirectory: true)
            if manager.fileExists(atPath: destination.path) { continue }
            do {
                try manager.moveItem(at: source, to: destination)
                restored.append(name)
            } catch {
                continue
            }
        }
        return restored
    }

    func start() {
        watcher.onChange = { [weak self] in
            self?.rescan()
        }
        watcher.start(path: widgetsRoot.path)
        rescan()
    }

    func stop() {
        watcher.stop()
        for process in workers.values where process.isRunning {
            process.terminate()
        }
        workers.removeAll()
    }

    func rescan() {
        let records = loadRecords()
        syncWorkers(records)
        onWidgets?(records)
    }

    func rename(id: String, title: String) -> Bool {
        guard let directory = directory(for: id) else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let url = directory.appendingPathComponent("manifest.json")
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            object = existing
        }
        object["title"] = trimmed
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        do {
            try (data + Data([0x0A])).write(to: url, options: .atomic)
        } catch {
            return false
        }
        rescan()
        return true
    }

    func deleteFolder(id: String) {
        guard let directory = directory(for: id) else { return }
        stopWorker(id)
        try? FileManager.default.removeItem(at: directory)
        rescan()
    }

    func directory(for id: String) -> URL? {
        guard id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        let url = widgetsRoot.appendingPathComponent(id, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }

    private func loadRecords() -> [WidgetRecord] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: widgetsRoot.path) else { return [] }
        return names.sorted().compactMap { name -> WidgetRecord? in
            guard name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
            let folder = widgetsRoot.appendingPathComponent(name, isDirectory: true)
            let index = folder.appendingPathComponent("index.html")
            guard manager.fileExists(atPath: index.path) else { return nil }
            let manifest = readManifest(folder.appendingPathComponent("manifest.json"))
            let title = manifest.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasCompact = manager.fileExists(atPath: folder.appendingPathComponent("compact.html").path)
            return WidgetRecord(
                id: name,
                title: (title?.isEmpty == false ? title! : name),
                width: manifest.width ?? 200,
                height: manifest.height ?? 112,
                revision: revision(of: folder),
                hasCompact: hasCompact,
                compactWidth: hasCompact ? (manifest.compactWidth ?? 200) : 0
            )
        }
    }

    private func readManifest(_ url: URL) -> (title: String?, width: Int?, height: Int?, compactWidth: Int?) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil, nil)
        }
        let title = object["title"] as? String
        let width = Self.positive(object["width"])
        let height = Self.positive(object["height"])
        let compact = object["compact"] as? [String: Any]
        let compactWidth = Self.positive(compact?["width"])
        return (title, width, height, compactWidth)
    }

    private static func flag(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private static func positive(_ value: Any?) -> Int? {
        let number: Int?
        if let int = value as? Int {
            number = int
        } else if let double = value as? Double {
            number = Int(double)
        } else {
            number = nil
        }
        guard let number, number > 0 else { return nil }
        return number
    }

    private func revision(of folder: URL) -> String {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return "0" }
        let newest = names.compactMap { name -> Date? in
            guard name != "manifest.json" else { return nil }
            let url = folder.appendingPathComponent(name)
            return try? manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        }.max() ?? .distantPast
        return String(Int(newest.timeIntervalSince1970 * 1000))
    }

    private func syncWorkers(_ records: [WidgetRecord]) {
        let live = Set(records.map(\.id))
        for id in workers.keys where !live.contains(id) {
            stopWorker(id)
        }
        for record in records {
            let script = widgetsRoot.appendingPathComponent(record.id).appendingPathComponent("worker.mjs")
            guard FileManager.default.fileExists(atPath: script.path) else {
                stopWorker(record.id)
                continue
            }
            let stamp = (try? FileManager.default.attributesOfItem(atPath: script.path)[.modificationDate] as? Date) ?? .distantPast
            if workers[record.id]?.isRunning == true, workerStamps[record.id] == stamp {
                continue
            }
            stopWorker(record.id)
            startWorker(id: record.id, script: script, stamp: stamp)
        }
    }

    private func startWorker(id: String, script: URL, stamp: Date) {
        guard let node = NodeFinder.locate() else { return }
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        process.environment = WidgetBridge.scrubbedEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        outputBuffers[id] = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.outputQueue.async {
                self?.consumeWorker(id: id, text: text)
            }
        }
        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        do {
            try process.run()
            workers[id] = process
            workerStamps[id] = stamp
        } catch {
            return
        }
    }

    private func stopWorker(_ id: String) {
        if let process = workers[id], process.isRunning {
            process.terminate()
        }
        workers[id] = nil
        workerStamps[id] = nil
        outputBuffers[id] = nil
    }

    private func consumeWorker(id: String, text: String) {
        var buffer = outputBuffers[id] ?? ""
        buffer.append(text)
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            deliver(id: id, line: line)
        }
        outputBuffers[id] = buffer
    }

    private func deliver(id: String, line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "state" else { return }
        let body = object["body"] ?? NSNull()
        let compact = object["compact"] as? [String: Any]
        let live = Self.flag(compact?["live"])
        DispatchQueue.main.async { [weak self] in
            self?.onWorkerState?(id, body, live)
        }
    }
}
