import AppKit
import UniformTypeIdentifiers
import WebKit

struct ShelfMessage: Codable, Equatable {
    var id: String
    var role: String
    var text: String
}

struct ShelfModel: Codable, Equatable {
    var id: String
    var displayName: String
}

struct ShelfWidget: Codable, Equatable {
    var id: String
    var title: String
    var width: Int
    var height: Int
    var revision: String
    var hidden: Bool
    var row: Int
    var slot: Int
    var hasCompact: Bool
    var compactLeadingWidth: Int
    var compactTrailingWidth: Int
}

struct ShelfSession: Codable, Equatable {
    var id: String
    var title: String
    var preview: String
    var widgetId: String?
    var running: Bool
}

struct ShelfState: Codable {
    var hasKey: Bool
    var nodeMissing: Bool
    var models: [ShelfModel]
    var modelId: String
    var messages: [ShelfMessage]
    var running: Bool
    var error: String?
    var widgets: [ShelfWidget]
    var mode: String
    var sessionTitle: String
    var editingWidgetId: String?
    var sessions: [ShelfSession]
    var menuWidgetId: String?
    var confirmKind: String
    var confirmWidgetId: String
    var showTitles: Bool
    var sessionId: String
    var compactWidgetId: String
    var focusedWidgetId: String
    var pinnedCompactId: String
}

private struct ChatSession: Codable, Equatable {
    var id: String
    var agentId: String
    var widgetId: String?
    var title: String
    var preview: String
    var updated: TimeInterval
}

@MainActor
final class AppModel: NSObject {
    private let panel: NotchPanel
    private let webView: WKWebView
    private let sidecar = SidecarClient()
    private let runtime: WidgetRuntime
    private let scheme: NotchSchemeHandler
    private let proxy: ScriptProxy

    private var hasKey = false
    private var nodeMissing = false
    private var models: [ShelfModel] = []
    private var modelId = ""
    private var transcripts: [String: [ShelfMessage]] = [:]
    private var runningIds: Set<String> = []
    private var pendingSend: Set<String> = []
    private var sessionErrors: [String: String] = [:]
    private var error: String?
    private var widgets: [ShelfWidget] = []
    private var sessions: [ChatSession] = []
    private var drafts: Set<String> = []
    private var activeSessionId: String?
    private var mode = "shelf"
    private var seenWidgetIds: Set<String>?
    private var acceptTranscript: Set<String> = []
    private var pageReady = false
    private var promptedForKey = false
    private var escapeLatch = false
    private var hovering = false
    private var textFocused = false
    private var composerFocused = false
    private var widgetFields: [String: Bool] = [:]
    private var unread = false
    private var restartLeft = 1
    private var nodeURL: URL?
    private var scriptURL: URL?
    private var hiddenIds: Set<String> = []
    private var menuWidgetId: String?
    private var confirmKind = ""
    private var confirmWidgetId = ""
    private var showTitles = true
    private var layoutRows: [[String]] = []
    private var previewRows: [[String]]?
    private var lifting = false
    private var announcedRows = 0
    private var picking = false

    private let modelDefaultsKey = "modelId"
    private let titlesDefaultsKey = "showWidgetTitles"
    private let pinDefaultsKey = "pinnedCompactId"
    private let maxWidgetRows = 3
    // 28px drop lane plus the 8px gap beneath the last row.
    private let reorderLane: CGFloat = 36
    private let skeletonHeight: CGFloat = 112
    private var laidOutHeight: CGFloat = -1
    private var pinnedCompactId: String?
    private var focusedWidgetId: String?
    private var compactLive: [String: TimeInterval] = [:]
    private var compactMeasured: [String: CompactLayout] = [:]
    private var workerBodies: [String: Any] = [:]
    private var reportedOpen: CGFloat = -1
    private let sessionsURL: URL
    private let hiddenURL: URL
    private let layoutURL: URL

    init(paths: AppPaths) {
        let scheme = NotchSchemeHandler(shelfRoot: paths.shelf, widgetsRoot: { paths.widgets })
        self.scheme = scheme
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "notch")
        let controller = WKUserContentController()
        let proxy = ScriptProxy()
        controller.add(proxy, name: "shelf")
        controller.add(proxy, name: "widget")
        controller.addUserScript(WKUserScript(
            source: WidgetBridge.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        self.webView = webView
        self.proxy = proxy
        panel = NotchPanel(webView: webView)
        runtime = WidgetRuntime(widgetsRoot: paths.widgets, dismissedRoot: paths.dismissed)
        sessionsURL = paths.support.appendingPathComponent("sessions.json")
        hiddenURL = paths.support.appendingPathComponent("hidden.json")
        layoutURL = paths.support.appendingPathComponent("layout.json")
        super.init()
        migratePreferences()
        proxy.owner = self
        panel.hoverChanged = { [weak self] inside in
            self?.pointer(inside: inside)
        }
        panel.escaped = { [weak self] in
            self?.escape()
        }
        panel.onProgress = { [weak self] progress, settled in
            self?.publishOpen(progress, force: settled)
        }
        panel.onScreenChange = { [weak self] in
            self?.publishHousing()
        }
        sidecar.onEvent = { [weak self] event in
            self?.handleSidecar(event)
        }
        sidecar.onExit = { [weak self] message in
            self?.sidecarExited(message)
        }
        runtime.onWidgets = { [weak self] records in
            self?.widgetsChanged(records)
        }
        runtime.onWorkerState = { [weak self] id, body, live in
            if let live {
                self?.noteCompact(id: id, live: live)
            }
            self?.forwardWorker(id: id, body: body)
        }
        modelId = UserDefaults.standard.string(forKey: modelDefaultsKey) ?? ""
        if UserDefaults.standard.object(forKey: titlesDefaultsKey) != nil {
            showTitles = UserDefaults.standard.bool(forKey: titlesDefaultsKey)
        }
        let storedPin = UserDefaults.standard.string(forKey: pinDefaultsKey) ?? ""
        pinnedCompactId = storedPin.isEmpty ? nil : storedPin
        hasKey = KeychainStore.load() != nil
        if let data = try? Data(contentsOf: sessionsURL),
           let stored = try? JSONDecoder().decode([ChatSession].self, from: data) {
            let kept = stored.filter { !$0.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            sessions = kept.sorted { $0.updated > $1.updated }
            if kept.count != stored.count {
                persistSessions()
            }
        }
        if let data = try? Data(contentsOf: hiddenURL),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            hiddenIds = Set(stored)
        }
        if let data = try? Data(contentsOf: layoutURL),
           let stored = try? JSONDecoder().decode([[String]].self, from: data) {
            layoutRows = stored
        }
    }

    func start(script: URL) {
        scriptURL = script
        nodeURL = NodeFinder.locate()
        nodeMissing = nodeURL == nil
        if nodeMissing {
            error = "Node.js 22.13 or newer is required on this Mac."
        }
        let restored = runtime.restoreDismissed()
        if !restored.isEmpty {
            hiddenIds.formUnion(restored)
            persistHidden()
        }
        runtime.start()
        if let key = KeychainStore.load(), let nodeURL {
            launchSidecar(node: nodeURL, script: script, apiKey: key)
        }
        panel.present()
        webView.load(URLRequest(url: URL(string: "notch://shelf/index.html")!))
    }

    func stop() {
        runtime.stop()
        sidecar.stop()
        panel.stop()
    }

    func handle(_ message: WKScriptMessage) {
        if message.name == "widget" {
            if let body = message.body as? [String: Any], let kind = body["type"] as? String {
                if kind == "context", let id = body["id"] as? String {
                    showMenu(id)
                    return
                }
                if kind == "closeMenu" {
                    guard menuWidgetId != nil else { return }
                    menuWidgetId = nil
                    push()
                    return
                }
                if kind == "editing" {
                    noteWidgetField(body["id"] as? String ?? "", focused: body["focused"] as? Bool ?? false)
                    return
                }
            }
            handleWidget(message)
            return
        }
        guard message.name == "shelf",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            pageReady = true
            push()
        case "composerFocus":
            noteComposerFocus(body["focused"] as? Bool ?? false)
        case "editMenu":
            let copyOnly = body["copyOnly"] as? Bool ?? false
            let text = body["text"] as? String ?? ""
            let x = (body["x"] as? NSNumber).map { CGFloat(truncating: $0) }
            let y = (body["y"] as? NSNumber).map { CGFloat(truncating: $0) }
            DispatchQueue.main.async { [weak self] in
                self?.showEditMenu(copyOnly: copyOnly, text: text, x: x, y: y)
            }
        case "escape":
            escape()
        case "exitEdit":
            exitEdit()
        case "createWidget":
            beginCreate()
        case "openSession":
            if let id = body["id"] as? String { reopen(id) }
        case "editWidget":
            if let id = body["id"] as? String { editWidget(id) }
        case "showSettings":
            toggleSettings()
        case "saveSettings":
            saveSettings(body)
        case "send":
            send(body["text"] as? String ?? "", attachments: attachmentPayloads(body))
        case "pickAttachments":
            DispatchQueue.main.async { [weak self] in
                self?.pickAttachments()
            }
        case "cancel":
            guard let id = activeSessionId else { return }
            pendingSend.remove(id)
            runningIds.remove(id)
            sidecar.send(["type": "cancel", "sessionId": id])
        case "widgetMenu":
            if let id = body["id"] as? String { showMenu(id) }
        case "closeMenu":
            menuWidgetId = nil
            push()
        case "confirmHide":
            if let id = body["id"] as? String { askConfirm(kind: "hide", id: id) }
        case "confirmDelete":
            if let id = body["id"] as? String { askConfirm(kind: "delete", id: id) }
        case "cancelConfirm":
            cancelConfirm()
        case "acceptConfirm":
            acceptConfirm()
        case "setHidden":
            if let id = body["id"] as? String {
                setHidden(id, hidden: body["hidden"] as? Bool ?? false)
            }
        case "renameWidget":
            if let id = body["id"] as? String, let title = body["title"] as? String {
                renameWidget(id: id, title: title)
            }
        case "setShowTitles":
            setShowTitles(body["show"] as? Bool ?? true)
        case "pinCompact":
            if let id = body["id"] as? String { pinCompact(id) }
        case "openCompact":
            if let id = body["id"] as? String { openFromCompact(id) }
        case "compactAction":
            panel.holdClosed()
        case "compactSize":
            if let id = body["id"] as? String {
                noteCompactSize(
                    id: id,
                    leading: body["leading"] as? Double ?? 0,
                    trailing: body["trailing"] as? Double ?? 0
                )
            }
        case "clearFocus":
            clearFocus()
        case "compactReady":
            if let id = body["id"] as? String, let cached = workerBodies[id] {
                forwardWorker(id: id, body: cached)
            }
        case "beginReorder":
            beginReorder()
        case "endReorder":
            endReorder()
        case "layoutPreview":
            previewLayout(body["layout"] ?? body["rows"])
        case "commitLayout":
            if let rows = stringRows(body["layout"] ?? body["rows"]) { commitLayout(rows) }
        case "reorderLift":
            lifting = body["active"] as? Bool ?? false
            if !lifting && mode == "reorder" && !hovering {
                endReorder(collapse: true)
            }
        case "openLink":
            openLink(body["url"] as? String ?? "")
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private func openLink(_ raw: String) {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return }
        NSWorkspace.shared.open(url)
    }

    private func pointer(inside: Bool) {
        if picking {
            hovering = inside
            return
        }
        if inside && escapeLatch { return }
        if !inside { escapeLatch = false }
        if !inside && lifting && mode == "reorder" {
            hovering = false
            return
        }
        hovering = inside
        if inside {
            unread = false
            panel.chrome.showsMark = false
            layoutPanel()
            if !hasKey && !promptedForKey {
                promptedForKey = true
                openSettings()
            }
        } else if textFocused && mode != "chat" {
            return
        } else if mode == "chat" || (activeSessionId.map { runningIds.contains($0) } ?? false) {
            releaseComposer()
            focusedWidgetId = nil
            panel.setExpanded(false)
        } else {
            releaseComposer()
            previewRows = nil
            lifting = false
            focusedWidgetId = nil
            mode = "shelf"
            panel.setExpanded(false)
            push()
        }
    }

    private func releaseComposer() {
        guard textFocused else { return }
        clearTyping()
        panel.releaseTyping()
        webView.evaluateJavaScript("document.activeElement?.blur()", completionHandler: nil)
    }

    private func showEditMenu(copyOnly: Bool, text: String, x: CGFloat?, y: CGFloat?) {
        panel.focusForTyping()
        let menu = NSMenu()
        menu.autoenablesItems = false
        if copyOnly {
            let item = NSMenuItem(title: "Copy", action: #selector(copyText(_:)), keyEquivalent: "c")
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.representedObject = text
            menu.addItem(item)
        } else {
            let add = { (title: String, action: Selector, key: String) in
                let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = .command
                item.target = self.webView
                menu.addItem(item)
            }
            add("Cut", #selector(NSText.cut(_:)), "x")
            add("Copy", #selector(NSText.copy(_:)), "c")
            add("Paste", #selector(NSText.paste(_:)), "v")
            menu.addItem(.separator())
            add("Select All", #selector(NSText.selectAll(_:)), "a")
        }
        let point: NSPoint
        if let x, let y {
            let local = CGPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
            point = panel.convertPoint(toScreen: webView.convert(local, to: nil))
        } else {
            point = NSEvent.mouseLocation
        }
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, !text.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private func noteComposerFocus(_ focused: Bool) {
        if focused && !hovering { return }
        composerFocused = focused
        syncTyping()
    }

    private func noteWidgetField(_ id: String, focused: Bool) {
        guard !id.isEmpty else { return }
        if focused && !hovering { return }
        if focused {
            widgetFields[id] = true
        } else {
            widgetFields.removeValue(forKey: id)
        }
        syncTyping()
    }

    private func syncTyping() {
        textFocused = composerFocused || !widgetFields.isEmpty
        panel.textFieldFocused = textFocused
        if textFocused {
            panel.focusForTyping()
        }
    }

    private func clearTyping() {
        textFocused = false
        composerFocused = false
        widgetFields.removeAll()
        panel.textFieldFocused = false
    }

    private func escape() {
        if menuWidgetId != nil {
            menuWidgetId = nil
            push()
            return
        }
        if mode == "confirm" {
            cancelConfirm()
            return
        }
        if mode == "reorder" {
            endReorder()
            return
        }
        escapeLatch = true
        clearTyping()
        focusedWidgetId = nil
        mode = "shelf"
        panel.setExpanded(false)
        panel.releaseTyping()
        push()
    }

    private func exitEdit() {
        guard mode == "chat" else { return }
        clearTyping()
        mode = "shelf"
        menuWidgetId = nil
        panel.releaseTyping()
        if hovering {
            layoutPanel()
        } else {
            panel.setExpanded(false)
        }
        push()
    }

    private func saveSettings(_ body: [String: Any]) {
        if let model = body["modelId"] as? String, !model.isEmpty {
            modelId = model
            UserDefaults.standard.set(model, forKey: modelDefaultsKey)
            sidecar.send(["type": "setModel", "modelId": model])
        }
        let apiKey = (body["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hasKey && apiKey.isEmpty {
            error = "Add a Cursor API key."
            push()
            return
        }
        if !apiKey.isEmpty {
            do {
                try KeychainStore.save(apiKey)
                hasKey = true
                error = nil
                guard let nodeURL, let scriptURL else {
                    nodeMissing = true
                    error = "Node.js 22.13 or newer is required on this Mac."
                    push()
                    return
                }
                restartLeft = 1
                launchSidecar(node: nodeURL, script: scriptURL, apiKey: apiKey)
            } catch {
                self.error = "The key could not be saved."
            }
        }
        push()
    }

    private func pickAttachments() {
        guard mode == "chat", !picking else { return }
        picking = true
        composerFocused = true
        textFocused = true
        panel.focusForTyping()
        let chooser = NSOpenPanel()
        chooser.allowsMultipleSelection = true
        chooser.canChooseFiles = true
        chooser.canChooseDirectories = false
        chooser.resolvesAliases = true
        chooser.prompt = "Attach"
        chooser.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        let response = chooser.runModal()
        picking = false
        if response == .OK {
            deliverPicked(chooser.urls)
        }
        if panel.pointerInside() {
            hovering = true
            layoutPanel()
        } else {
            pointer(inside: false)
        }
    }

    private func deliverPicked(_ urls: [URL]) {
        let limit = 4 * 1024 * 1024
        var items: [[String: Any]] = []
        for url in urls.prefix(8) {
            let name = url.lastPathComponent
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > limit {
                items.append(["name": name, "tooLarge": true])
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            if data.count > limit {
                items.append(["name": name, "tooLarge": true])
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            items.append([
                "name": name,
                "mime": mime,
                "data": data.base64EncodedString(),
            ])
        }
        guard let json = try? JSONSerialization.data(withJSONObject: items),
              let text = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.shelf && window.shelf.attachLocal(\(text))", completionHandler: nil)
    }

    private func attachmentPayloads(_ body: [String: Any]) -> [[String: String]] {
        guard let items = body["attachments"] as? [[String: Any]] else { return [] }
        return items.prefix(8).compactMap { item in
            guard let name = item["name"] as? String,
                  let data = item["data"] as? String,
                  !name.isEmpty, !data.isEmpty, data.count <= 5_800_000 else { return nil }
            let mime = item["mime"] as? String ?? ""
            return [
                "name": name,
                "kind": (item["kind"] as? String) == "image" ? "image" : "file",
                "mime": mime.isEmpty ? "application/octet-stream" : mime,
                "data": data,
            ]
        }
    }

    private func send(_ raw: String, attachments: [[String: String]] = []) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = activeSessionId, hasKey, !runningIds.contains(id), !nodeMissing else { return }
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let names = attachments.compactMap { $0["name"] }.joined(separator: ", ")
        let display = text.isEmpty ? names : (names.isEmpty ? text : "\(text)\n\(names)")
        let headline = text.isEmpty ? (attachments.first?["name"] ?? display) : text
        acceptTranscript.remove(id)
        drafts.remove(id)
        pendingSend.insert(id)
        runningIds.insert(id)
        sessionErrors[id] = nil
        updateMessages(id) { $0.append(ShelfMessage(id: UUID().uuidString, role: "user", text: display)) }
        touch(id) { session in
            if session.title == "New widget" {
                session.title = String(headline.prefix(42))
            }
            session.preview = String(display.prefix(80))
        }
        error = nil
        push()
        var payload: [String: Any] = ["type": "send", "sessionId": id, "text": text]
        if !attachments.isEmpty {
            payload["attachments"] = attachments
        }
        if !modelId.isEmpty {
            payload["modelId"] = modelId
        }
        sidecar.send(payload)
    }

    private func launchSidecar(node: URL, script: URL, apiKey: String) {
        do {
            try sidecar.start(node: node, script: script)
        } catch {
            self.error = "The agent could not start."
            push()
            return
        }
        var start: [String: Any] = [
            "type": "start",
            "apiKey": apiKey,
            "workspace": runtime.widgetsRoot.deletingLastPathComponent().path,
        ]
        if !modelId.isEmpty {
            start["modelId"] = modelId
        }
        sidecar.send(start)
    }

    private func sidecarExited(_ message: String) {
        runningIds.removeAll()
        pendingSend.removeAll()
        guard hasKey, restartLeft > 0, let nodeURL, let scriptURL, let key = KeychainStore.load() else {
            error = message
            push()
            return
        }
        restartLeft -= 1
        launchSidecar(node: nodeURL, script: scriptURL, apiKey: key)
    }

    private func handleSidecar(_ event: SidecarEvent) {
        switch event.type {
        case "models":
            models = event.models.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                let name = item["displayName"] as? String ?? id
                return ShelfModel(id: id, displayName: name)
            }
            let previous = modelId
            if modelId.isEmpty || !models.contains(where: { $0.id == modelId }) {
                modelId = models.first?.id ?? modelId
            }
            if !modelId.isEmpty, modelId != previous {
                UserDefaults.standard.set(modelId, forKey: modelDefaultsKey)
                sidecar.send(["type": "setModel", "modelId": modelId])
            }
            if mode == "settings" { layoutPanel() }
        case "agent":
            if let agentId = event.agentId, let id = event.sessionId {
                touch(id) { $0.agentId = agentId }
            }
        case "transcript":
            guard let id = event.sessionId, acceptTranscript.contains(id) else { break }
            acceptTranscript.remove(id)
            let stored = event.messages.compactMap { item -> ShelfMessage? in
                guard let role = item["role"] as? String, let text = item["text"] as? String else { return nil }
                let messageId = item["id"] as? String ?? UUID().uuidString
                return ShelfMessage(id: messageId, role: role, text: text)
            }
            transcripts[id] = stored
            if stored.contains(where: { $0.role == "user" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                drafts.remove(id)
            }
            if let last = stored.last(where: {
                ($0.role == "user" || $0.role == "assistant") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                touch(id) { $0.preview = String(last.text.prefix(80)) }
            }
        case "delta":
            if let id = event.sessionId { appendDelta(id, event.text ?? "") }
        case "tool":
            guard let id = event.sessionId else { break }
            let summary = event.summary ?? "tool"
            updateMessages(id) { $0.append(ShelfMessage(id: event.id ?? UUID().uuidString, role: "tool", text: summary)) }
        case "run":
            guard let id = event.sessionId else { break }
            let state = event.state ?? "idle"
            let wasRunning = runningIds.contains(id)
            if state == "running" {
                pendingSend.remove(id)
                runningIds.insert(id)
                sessionErrors[id] = nil
            } else if pendingSend.contains(id) {
                break
            } else {
                runningIds.remove(id)
                if state == "error" {
                    sessionErrors[id] = event.message ?? "The agent could not finish that turn."
                }
                if let last = transcripts[id]?.last(where: {
                    ($0.role == "user" || $0.role == "assistant") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) {
                    touch(id) { $0.preview = String(last.text.prefix(80)) }
                }
            }
            if wasRunning && !runningIds.contains(id) && !hovering {
                unread = true
                panel.chrome.showsMark = true
            }
        case "error":
            if let id = event.sessionId {
                pendingSend.remove(id)
                runningIds.remove(id)
                sessionErrors[id] = event.message ?? "The agent could not start."
            } else {
                error = event.message ?? "The agent could not start."
                runningIds.removeAll()
                pendingSend.removeAll()
            }
        default:
            break
        }
        push()
    }

    private func updateMessages(_ id: String, _ change: (inout [ShelfMessage]) -> Void) {
        var list = transcripts[id] ?? []
        change(&list)
        transcripts[id] = list
    }

    private func appendDelta(_ id: String, _ text: String) {
        guard !text.isEmpty else { return }
        updateMessages(id) { list in
            if list.last?.role == "assistant" {
                list[list.count - 1].text += text
            } else {
                list.append(ShelfMessage(id: UUID().uuidString, role: "assistant", text: text))
            }
        }
    }

    private func push() {
        guard pageReady else { return }
        stampPlacement()
        if mode != "chat" {
            discardDrafts()
        }
        let active = sessions.first { $0.id == activeSessionId }
        let shownError = mode == "chat" ? (activeSessionId.flatMap { sessionErrors[$0] } ?? error) : error
        let state = ShelfState(
            hasKey: hasKey,
            nodeMissing: nodeMissing,
            models: models,
            modelId: modelId,
            messages: activeSessionId.flatMap { transcripts[$0] } ?? [],
            running: activeSessionId.map { runningIds.contains($0) } ?? false,
            error: shownError,
            widgets: widgets,
            mode: mode,
            sessionTitle: active?.title ?? "",
            editingWidgetId: mode == "chat" ? active?.widgetId : nil,
            sessions: sessions.compactMap { session in
                guard !drafts.contains(session.id) else { return nil }
                return ShelfSession(
                    id: session.id,
                    title: session.title,
                    preview: session.preview,
                    widgetId: session.widgetId,
                    running: runningIds.contains(session.id)
                )
            },
            menuWidgetId: menuWidgetId,
            confirmKind: confirmKind,
            confirmWidgetId: confirmWidgetId,
            showTitles: showTitles,
            sessionId: activeSessionId ?? "",
            compactWidgetId: activeCompactId ?? "",
            focusedWidgetId: focusedWidgetId ?? "",
            pinnedCompactId: pinnedCompactId ?? ""
        )
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return }
        let notch = panel.notchHeight
        let housing = String(format: "%.1f", panel.hardwareNotchWidth)
        webView.evaluateJavaScript(
            "document.documentElement.style.setProperty('--notch','\(notch)px');document.documentElement.style.setProperty('--hardware-notch','\(housing)px');window.shelf && window.shelf.apply(\(json));window.shelf && window.shelf.setHousing(\(housing))",
            completionHandler: nil
        )
        publishOpen(panel.openProgress, force: true)
        if hovering || textFocused, openHeight != laidOutHeight {
            layoutPanel()
        }
    }

    private var pendingCreateCount: Int {
        sessions.filter { $0.widgetId == nil && runningIds.contains($0.id) }.count
    }

    /// A new widget has no card until the agent writes it. The skeleton shares the last shelf row.
    private var showsPendingCreate: Bool {
        guard pendingCreateCount > 0 else { return false }
        if mode == "settings" || mode == "confirm" { return false }
        if mode == "chat",
           sessions.first(where: { $0.id == activeSessionId })?.widgetId != nil {
            return false
        }
        return true
    }

    private var shelfWidgets: [ShelfWidget] {
        if mode == "chat",
           let id = sessions.first(where: { $0.id == activeSessionId })?.widgetId {
            return widgets.filter { $0.id == id }
        }
        if mode == "shelf" || mode == "reorder",
           let focusedWidgetId,
           widgets.contains(where: { $0.id == focusedWidgetId && !$0.hidden }) {
            return widgets.filter { $0.id == focusedWidgetId }
        }
        return widgets.filter { !$0.hidden }
    }

    private var activeRows: [[String]] {
        if mode == "reorder", let previewRows { return previewRows }
        return layoutRows
    }

    private func shelfBands(using rows: [[String]]) -> [[ShelfWidget]] {
        let shown = Dictionary(uniqueKeysWithValues: shelfWidgets.map { ($0.id, $0) })
        var seen = Set<String>()
        var result: [[ShelfWidget]] = []
        for row in rows {
            let items = row.compactMap { id -> ShelfWidget? in
                guard let widget = shown[id], seen.insert(id).inserted else { return nil }
                return widget
            }
            if !items.isEmpty { result.append(items) }
        }
        let missing = shelfWidgets.filter { !seen.contains($0.id) }
        if !missing.isEmpty {
            if result.isEmpty {
                result = [missing]
            } else {
                result[result.count - 1].append(contentsOf: missing)
            }
        }
        return result
    }

    private var shelfHeight: CGFloat {
        let rows = shelfBands(using: activeRows)
        let notch = panel.notchHeight
        let pending = showsPendingCreate
        guard !rows.isEmpty else { return notch + (pending ? skeletonHeight : 72) + 20 }
        var rowHeights = rows.map { row in CGFloat(row.map(\.height).max() ?? 112) }
        if pending {
            let last = rowHeights.count - 1
            rowHeights[last] = max(rowHeights[last], skeletonHeight)
        }
        let cards = rowHeights.reduce(0, +)
        let gaps = CGFloat(rowHeights.count - 1) * 8
        let lane: CGFloat = mode == "reorder" && rows.count < maxWidgetRows ? reorderLane : 0
        return notch + cards + gaps + lane + 20
    }

    private var openHeight: CGFloat {
        switch mode {
        case "chat": return shelfHeight + 252
        case "settings": return panel.notchHeight + 588 + CGFloat(widgets.count) * 46
        case "confirm": return panel.notchHeight + 168
        default: return shelfHeight
        }
    }

    private func layoutPanel() {
        guard hovering || textFocused else { return }
        laidOutHeight = openHeight
        panel.setExpanded(true, height: laidOutHeight)
    }

    private func openSettings() {
        mode = "settings"
        menuWidgetId = nil
        confirmKind = ""
        confirmWidgetId = ""
        layoutPanel()
        push()
    }

    private func toggleSettings() {
        if mode == "settings" {
            mode = "shelf"
            layoutPanel()
            push()
        } else {
            openSettings()
        }
    }

    private func stringList(_ value: Any) -> [String]? {
        if let typed = value as? [String] { return typed }
        let items: [Any]
        if let typed = value as? [Any] {
            items = typed
        } else if let typed = value as? NSArray {
            items = (0..<typed.count).map { typed[$0] }
        } else {
            return nil
        }
        var ids: [String] = []
        ids.reserveCapacity(items.count)
        for item in items {
            if let id = item as? String {
                ids.append(id)
            } else {
                return nil
            }
        }
        return ids
    }

    private func stringRows(_ value: Any?) -> [[String]]? {
        if let text = value as? String {
            guard let data = text.data(using: .utf8),
                  let rows = try? JSONDecoder().decode([[String]].self, from: data) else { return nil }
            return rows
        }
        if let rows = value as? [[String]] { return rows }
        let source: [Any]
        if let rows = value as? [Any] {
            source = rows
        } else if let rows = value as? NSArray {
            source = (0..<rows.count).map { rows[$0] }
        } else {
            return nil
        }
        var parsed: [[String]] = []
        parsed.reserveCapacity(source.count)
        for row in source {
            guard let ids = stringList(row) else { return nil }
            parsed.append(ids)
        }
        return parsed
    }

    private func beginReorder() {
        guard mode == "shelf" || mode == "reorder" else { return }
        guard shelfWidgets.count > 1 else { return }
        guard mode != "reorder" else { return }
        menuWidgetId = nil
        mode = "reorder"
        previewRows = nil
        announcedRows = shelfBands(using: layoutRows).count
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        layoutPanel()
        push()
    }

    private func endReorder(collapse: Bool = false) {
        guard mode == "reorder" else { return }
        lifting = false
        previewRows = nil
        mode = "shelf"
        if collapse || !hovering {
            panel.setExpanded(false)
        } else {
            layoutPanel()
        }
        push()
    }

    private func previewLayout(_ value: Any?) {
        guard mode == "reorder", let rows = stringRows(value) else { return }
        let count = shelfBands(using: rows).count
        if count > announcedRows {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        announcedRows = count
        previewRows = Array(rows.prefix(maxWidgetRows))
        layoutPanel()
    }

    private func commitLayout(_ raw: [[String]]) {
        let known = Set(widgets.map(\.id))
        var seen = Set<String>()
        var cleaned: [[String]] = []
        for row in raw.prefix(maxWidgetRows) {
            var keep: [String] = []
            for id in row where known.contains(id) && !hiddenIds.contains(id) && seen.insert(id).inserted {
                keep.append(id)
            }
            if !keep.isEmpty { cleaned.append(keep) }
        }
        let visibleMissing = widgets.map(\.id).filter { !hiddenIds.contains($0) && !seen.contains($0) }
        if !visibleMissing.isEmpty {
            if cleaned.isEmpty {
                cleaned = [visibleMissing]
            } else {
                cleaned[cleaned.count - 1].append(contentsOf: visibleMissing)
            }
            visibleMissing.forEach { seen.insert($0) }
        }
        for id in layoutRows.flatMap({ $0 }) where hiddenIds.contains(id) && known.contains(id) && seen.insert(id).inserted {
            let previous = placement(for: id)
            if cleaned.isEmpty {
                cleaned = [[id]]
            } else {
                let row = min(previous.row, cleaned.count - 1)
                let slot = min(previous.slot, cleaned[row].count)
                cleaned[row].insert(id, at: slot)
            }
        }
        if cleaned.count > maxWidgetRows {
            let overflow = cleaned.dropFirst(maxWidgetRows).flatMap { $0 }
            cleaned = Array(cleaned.prefix(maxWidgetRows))
            cleaned[maxWidgetRows - 1].append(contentsOf: overflow)
        }
        layoutRows = cleaned
        previewRows = nil
        announcedRows = shelfBands(using: layoutRows).count
        persistLayout()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        layoutPanel()
        push()
    }

    private func placement(for id: String) -> (row: Int, slot: Int) {
        for (row, ids) in layoutRows.enumerated() {
            if let slot = ids.firstIndex(of: id) {
                return (row, slot)
            }
        }
        return (0, layoutRows.first?.count ?? 0)
    }

    private func stampPlacement() {
        widgets = widgets.map { widget in
            var copy = widget
            let place = placement(for: widget.id)
            copy.row = place.row
            copy.slot = place.slot
            return copy
        }
    }

    private func normalizeLayout(orderedIds: [String]) {
        let known = Set(orderedIds)
        var seen = Set<String>()
        var cleaned: [[String]] = []
        let source = layoutRows.isEmpty ? [orderedIds] : layoutRows
        for row in source {
            var keep: [String] = []
            for id in row where known.contains(id) && seen.insert(id).inserted {
                keep.append(id)
            }
            if !keep.isEmpty { cleaned.append(keep) }
        }
        let missing = orderedIds.filter { !seen.contains($0) }
        if !missing.isEmpty {
            if cleaned.isEmpty {
                cleaned = [missing]
            } else {
                let index = min(cleaned.count - 1, maxWidgetRows - 1)
                cleaned[index].append(contentsOf: missing)
            }
        }
        if cleaned.count > maxWidgetRows {
            let overflow = cleaned.dropFirst(maxWidgetRows).flatMap { $0 }
            cleaned = Array(cleaned.prefix(maxWidgetRows))
            cleaned[maxWidgetRows - 1].append(contentsOf: overflow)
        }
        let changed = cleaned != layoutRows
        layoutRows = cleaned
        if changed { persistLayout() }
    }

    private func persistLayout() {
        guard let data = try? JSONEncoder().encode(layoutRows) else { return }
        try? data.write(to: layoutURL, options: .atomic)
    }

    private func showMenu(_ id: String) {
        guard mode != "reorder" else { return }
        if pendingSessionId(id) != nil {
            menuWidgetId = id
            push()
            return
        }
        guard widgets.contains(where: { $0.id == id && !$0.hidden }) else { return }
        menuWidgetId = id
        push()
    }

    private func pendingSessionId(_ id: String) -> String? {
        let prefix = "pending:"
        guard id.hasPrefix(prefix) else { return nil }
        let sessionId = String(id.dropFirst(prefix.count))
        guard sessions.contains(where: { $0.id == sessionId && $0.widgetId == nil }) else { return nil }
        return sessionId
    }

    private func askConfirm(kind: String, id: String) {
        guard widgets.contains(where: { $0.id == id }) else { return }
        confirmKind = kind
        confirmWidgetId = id
        menuWidgetId = nil
        mode = "confirm"
        layoutPanel()
        push()
    }

    private func cancelConfirm() {
        let returning = confirmKind == "delete" ? "settings" : "shelf"
        confirmKind = ""
        confirmWidgetId = ""
        mode = returning
        layoutPanel()
        push()
    }

    private func acceptConfirm() {
        let id = confirmWidgetId
        let kind = confirmKind
        confirmKind = ""
        confirmWidgetId = ""
        menuWidgetId = nil
        if kind == "hide" {
            mode = "shelf"
            setHidden(id, hidden: true)
            return
        }
        guard kind == "delete" else { return }
        let removed = sessions.filter { $0.widgetId == id }
        let removedActive = removed.contains { $0.id == activeSessionId }
        for session in removed {
            transcripts[session.id] = nil
            sessionErrors[session.id] = nil
            acceptTranscript.remove(session.id)
            pendingSend.remove(session.id)
            if runningIds.contains(session.id) {
                sidecar.send(["type": "cancel", "sessionId": session.id])
            }
            runningIds.remove(session.id)
        }
        sessions.removeAll { $0.widgetId == id }
        if removedActive {
            activeSessionId = nil
        }
        hiddenIds.remove(id)
        persistHidden()
        persistSessions()
        mode = "settings"
        runtime.deleteFolder(id: id)
        layoutPanel()
        push()
    }

    private func setShowTitles(_ show: Bool) {
        showTitles = show
        UserDefaults.standard.set(show, forKey: titlesDefaultsKey)
        push()
    }

    private func renameWidget(id: String, title: String) {
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        guard !trimmed.isEmpty, let current = widgets.first(where: { $0.id == id }) else {
            push()
            return
        }
        guard trimmed != current.title else { return }
        guard runtime.rename(id: id, title: trimmed) else {
            push()
            return
        }
        let previous = current.title
        var changed = false
        for index in sessions.indices where sessions[index].widgetId == id && sessions[index].title == previous {
            sessions[index].title = trimmed
            changed = true
        }
        if changed { persistSessions() }
        push()
    }

    private func setHidden(_ id: String, hidden: Bool) {
        if hidden {
            hiddenIds.insert(id)
        } else {
            hiddenIds.remove(id)
        }
        persistHidden()
        widgets = widgets.map { widget in
            var copy = widget
            if copy.id == id { copy.hidden = hidden }
            return copy
        }
        if hidden, menuWidgetId == id { menuWidgetId = nil }
        if hidden, focusedWidgetId == id { focusedWidgetId = nil }
        syncCompact()
        layoutPanel()
        push()
    }

    private func persistHidden() {
        let ids = hiddenIds.sorted()
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: hiddenURL, options: .atomic)
    }

    private func beginCreate() {
        menuWidgetId = nil
        focusedWidgetId = nil
        guard requireKey() else { return }
        if mode == "chat",
           let activeId = activeSessionId,
           drafts.contains(activeId),
           sessions.first(where: { $0.id == activeId })?.widgetId == nil,
           !runningIds.contains(activeId) {
            layoutPanel()
            return
        }
        let session = ChatSession(
            id: UUID().uuidString,
            agentId: "",
            widgetId: nil,
            title: "New widget",
            preview: "",
            updated: Date().timeIntervalSince1970
        )
        discardDrafts()
        drafts.insert(session.id)
        sessions.insert(session, at: 0)
        activeSessionId = session.id
        transcripts[session.id] = []
        error = nil
        mode = "chat"
        acceptTranscript.insert(session.id)
        openAgent(session)
        panel.focusForTyping()
        layoutPanel()
        push()
    }

    private func editWidget(_ id: String) {
        menuWidgetId = nil
        focusedWidgetId = nil
        guard requireKey() else { return }
        if let sessionId = pendingSessionId(id) {
            reopen(sessionId)
            return
        }
        if let existing = sessions.first(where: { $0.widgetId == id }) {
            reopen(existing.id)
            return
        }
        let title = widgets.first { $0.id == id }?.title ?? "Widget"
        let session = ChatSession(
            id: UUID().uuidString,
            agentId: "",
            widgetId: id,
            title: title,
            preview: "",
            updated: Date().timeIntervalSince1970
        )
        discardDrafts()
        drafts.insert(session.id)
        sessions.insert(session, at: 0)
        activeSessionId = session.id
        transcripts[session.id] = []
        error = nil
        mode = "chat"
        acceptTranscript.insert(session.id)
        openAgent(session)
        panel.focusForTyping()
        layoutPanel()
        push()
    }

    private func reopen(_ id: String) {
        guard requireKey(), let session = sessions.first(where: { $0.id == id }) else { return }
        discardDrafts(keeping: id)
        activeSessionId = id
        error = nil
        mode = "chat"
        if runningIds.contains(id) {
            acceptTranscript.remove(id)
        } else {
            acceptTranscript.insert(id)
            openAgent(session)
        }
        panel.focusForTyping()
        layoutPanel()
        push()
    }

    private func openAgent(_ session: ChatSession) {
        var payload: [String: Any] = ["type": "open", "sessionId": session.id]
        if !session.agentId.isEmpty { payload["agentId"] = session.agentId }
        sidecar.send(payload)
    }

    private func requireKey() -> Bool {
        guard hasKey, !nodeMissing else {
            if !hasKey { openSettings() }
            return false
        }
        return true
    }

    private func widgetsChanged(_ records: [WidgetRecord]) {
        normalizeLayout(orderedIds: records.map(\.id))
        let next = records.map { record -> ShelfWidget in
            let place = placement(for: record.id)
            return ShelfWidget(
                id: record.id,
                title: record.title,
                width: record.width,
                height: record.height,
                revision: record.revision,
                hidden: hiddenIds.contains(record.id),
                row: place.row,
                slot: place.slot,
                hasCompact: record.hasCompact,
                compactLeadingWidth: record.compactLeadingWidth,
                compactTrailingWidth: record.compactTrailingWidth
            )
        }
        let ids = Set(next.map(\.id))
        let staleFields = widgetFields.keys.filter { !ids.contains($0) }
        if !staleFields.isEmpty {
            staleFields.forEach { widgetFields.removeValue(forKey: $0) }
            syncTyping()
        }
        if let seen = seenWidgetIds {
            let fresh = next.filter { !seen.contains($0.id) }
            var candidates = sessions.filter { $0.widgetId == nil && runningIds.contains($0.id) }
            if candidates.isEmpty, let activeSessionId {
                candidates = sessions.filter { $0.id == activeSessionId && $0.widgetId == nil }
            }
            var changed = false
            for widget in fresh {
                guard let sessionId = candidates.first?.id,
                      let index = sessions.firstIndex(where: { $0.id == sessionId }) else { break }
                sessions[index].widgetId = widget.id
                sessions[index].title = widget.title
                sessions[index].updated = Date().timeIntervalSince1970
                candidates.removeFirst()
                changed = true
            }
            if changed { persistSessions() }
        }
        seenWidgetIds = ids
        widgets = next
        syncCompact()
        if mode == "reorder", shelfWidgets.count < 2 {
            lifting = false
            previewRows = nil
            mode = "shelf"
        }
        layoutPanel()
        push()
    }

    private func touch(_ id: String, change: (inout ChatSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions.remove(at: index)
        change(&session)
        session.updated = Date().timeIntervalSince1970
        sessions.insert(session, at: 0)
        persistSessions()
    }

    private func discardDrafts(keeping kept: String? = nil) {
        let dropping = sessions.filter { drafts.contains($0.id) && $0.id != kept }
        guard !dropping.isEmpty else { return }
        for session in dropping {
            drafts.remove(session.id)
            transcripts[session.id] = nil
            sessionErrors[session.id] = nil
            acceptTranscript.remove(session.id)
            pendingSend.remove(session.id)
            runningIds.remove(session.id)
            if activeSessionId == session.id {
                activeSessionId = nil
            }
        }
        let ids = Set(dropping.map(\.id))
        sessions.removeAll { ids.contains($0.id) }
    }

    private func persistSessions() {
        let kept = sessions.filter { !drafts.contains($0.id) }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? data.write(to: sessionsURL, options: .atomic)
    }

    private var activeCompactId: String? {
        if let pinnedCompactId,
           let widget = widgets.first(where: { $0.id == pinnedCompactId }),
           widget.hasCompact, !widget.hidden {
            return pinnedCompactId
        }
        let live = compactLive.filter { id, _ in
            guard let widget = widgets.first(where: { $0.id == id }) else { return false }
            return widget.hasCompact && !widget.hidden
        }
        return live.max { $0.value < $1.value }?.key
    }

    private func noteCompact(id: String, live: Bool) {
        let before = activeCompactId
        if live {
            compactLive[id] = Date().timeIntervalSince1970
        } else {
            compactLive.removeValue(forKey: id)
        }
        syncCompact()
        if activeCompactId != before { push() }
    }

    private func syncCompact() {
        if let pinnedCompactId {
            let widget = widgets.first { $0.id == pinnedCompactId }
            if widget == nil || widget?.hasCompact != true {
                self.pinnedCompactId = nil
                UserDefaults.standard.removeObject(forKey: pinDefaultsKey)
            }
        }
        let known = Set(widgets.map(\.id))
        compactLive = compactLive.filter { known.contains($0.key) }
        compactMeasured = compactMeasured.filter { known.contains($0.key) }
        if let focusedWidgetId, !widgets.contains(where: { $0.id == focusedWidgetId && !$0.hidden }) {
            self.focusedWidgetId = nil
        }
        let layout = activeCompactId.flatMap { id in
            widgets.first { $0.id == id }.map { widget in
                let measured = compactMeasured[id]
                return CompactLayout(
                    leadingWidth: min(CGFloat(widget.compactLeadingWidth), measured?.leadingWidth ?? CGFloat(widget.compactLeadingWidth)),
                    trailingWidth: min(CGFloat(widget.compactTrailingWidth), measured?.trailingWidth ?? CGFloat(widget.compactTrailingWidth))
                )
            }
        }
        panel.setCompactLayout(layout)
    }

    private func noteCompactSize(id: String, leading: Double, trailing: Double) {
        guard let widget = widgets.first(where: { $0.id == id && $0.hasCompact && !$0.hidden }) else { return }
        let layout = CompactLayout(
            leadingWidth: min(CGFloat(widget.compactLeadingWidth), max(0, CGFloat(leading))),
            trailingWidth: min(CGFloat(widget.compactTrailingWidth), max(0, CGFloat(trailing)))
        )
        guard compactMeasured[id] != layout else { return }
        compactMeasured[id] = layout
        if activeCompactId == id { syncCompact() }
    }

    private func pinCompact(_ id: String) {
        guard let widget = widgets.first(where: { $0.id == id }), widget.hasCompact, !widget.hidden else {
            push()
            return
        }
        if pinnedCompactId == id {
            pinnedCompactId = nil
            UserDefaults.standard.removeObject(forKey: pinDefaultsKey)
        } else {
            pinnedCompactId = id
            UserDefaults.standard.set(id, forKey: pinDefaultsKey)
        }
        syncCompact()
        push()
    }

    private func openFromCompact(_ id: String) {
        guard widgets.contains(where: { $0.id == id && !$0.hidden }) else { return }
        escapeLatch = false
        clearTyping()
        previewRows = nil
        lifting = false
        menuWidgetId = nil
        mode = "shelf"
        focusedWidgetId = id
        unread = false
        panel.chrome.showsMark = false
        panel.reveal()
        layoutPanel()
        push()
    }

    private func clearFocus() {
        focusedWidgetId = nil
        if hovering || textFocused { layoutPanel() }
        push()
    }

    private func publishHousing() {
        guard pageReady else { return }
        let housing = String(format: "%.1f", panel.hardwareNotchWidth)
        webView.evaluateJavaScript(
            "window.shelf && window.shelf.setHousing(\(housing))",
            completionHandler: nil
        )
    }

    private func publishOpen(_ progress: CGFloat, force: Bool) {
        guard pageReady else { return }
        let value = min(1, max(0, (progress * 1000).rounded() / 1000))
        if abs(value - reportedOpen) < (force ? 0.0005 : 0.02) { return }
        reportedOpen = value
        let text = String(format: "%.3f", value)
        webView.evaluateJavaScript("window.shelf && window.shelf.setOpen(\(text))", completionHandler: nil)
    }

    private func forwardWorker(id: String, body: Any) {
        workerBodies[id] = body
        guard JSONSerialization.isValidJSONObject(["value": body]),
              let data = try? JSONSerialization.data(withJSONObject: ["value": body]),
              let json = String(data: data, encoding: .utf8) else { return }
        let slug = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript(
            "window.shelf && window.shelf.deliver('\(slug)', \(json).value)",
            completionHandler: nil
        )
    }

    private func handleWidget(_ message: WKScriptMessage) {
        guard message.frameInfo.request.url?.host == "widget",
              let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let method = body["method"] as? String,
              let args = body["args"] as? [String: Any],
              let slug = widgetSlug(message.frameInfo.request.url),
              let cwd = runtime.directory(for: slug) else { return }
        let frame = message.frameInfo
        switch method {
        case "shell":
            let command = args["command"] as? String ?? ""
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = BridgeRunner.shell(command: command, cwd: cwd)
                DispatchQueue.main.async {
                    self?.settle(frame: frame, id: id, result: result.map { $0 as Any })
                }
            }
        case "readFile":
            let path = args["path"] as? String ?? ""
            settle(frame: frame, id: id, result: BridgeRunner.readFile(path, cwd: cwd).map { $0 as Any })
        case "writeFile":
            let path = args["path"] as? String ?? ""
            let contents = args["contents"] as? String ?? ""
            settle(frame: frame, id: id, result: BridgeRunner.writeFile(path, contents: contents, cwd: cwd).map { $0 as Any })
        case "list":
            let path = args["path"] as? String ?? "."
            settle(frame: frame, id: id, result: BridgeRunner.list(path, cwd: cwd).map { $0 as Any })
        case "http":
            let url = args["url"] as? String ?? ""
            let methodName = args["method"] as? String
            let headers = args["headers"] as? [String: String]
            let bodyText = args["body"] as? String
            Task { [weak self] in
                let result = await BridgeRunner.http(urlString: url, method: methodName, headers: headers, body: bodyText)
                self?.settle(frame: frame, id: id, result: result.map { $0 as Any })
            }
        default:
            settle(frame: frame, id: id, result: .failure(BridgeFailure("Unknown call.")))
        }
    }

    private func settle(frame: WKFrameInfo, id: String, result: Result<Any, BridgeFailure>) {
        let payload: [String: Any]
        switch result {
        case .success(let value):
            payload = ["ok": true, "value": value]
        case .failure(let failure):
            payload = ["ok": false, "error": failure.message]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let callID = jsonString(id)
        webView.evaluateJavaScript(
            "window.__notchSettle(\(callID), \(json))",
            in: frame,
            in: .page,
            completionHandler: nil
        )
    }

    private func widgetSlug(_ url: URL?) -> String? {
        guard let path = url?.path.removingPercentEncoding else { return nil }
        return path.split(separator: "/").first.map(String.init)
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8),
              text.count >= 2 else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    private func migratePreferences() {
        let previousName = "app.agenticnotch.AgenticNotch"
        guard let previous = UserDefaults.standard.persistentDomain(forName: previousName) else { return }
        let keys = [modelDefaultsKey, titlesDefaultsKey, pinDefaultsKey]
        for key in keys where UserDefaults.standard.object(forKey: key) == nil {
            if let value = previous[key] {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        UserDefaults.standard.removePersistentDomain(forName: previousName)
    }
}

final class ScriptProxy: NSObject, WKScriptMessageHandler {
    weak var owner: AppModel?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            owner?.handle(message)
        }
    }
}

struct AppPaths {
    var support: URL
    var shelf: URL
    var widgets: URL
    var dismissed: URL
    var sidecarScript: URL

    static func make() throws -> AppPaths {
        let resources = Bundle.main.resourceURL
        let shelf = resources?.appendingPathComponent("Shelf", isDirectory: true)
        let template = resources?.appendingPathComponent("AGENTS.md")
        let script = resources?.appendingPathComponent("Sidecar/dist/index.js")
        guard let shelf, let template, let script else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let support = root.appendingPathComponent("Whatnotch", isDirectory: true)
        let previous = root.appendingPathComponent("Agentic Notch", isDirectory: true)
        if !FileManager.default.fileExists(atPath: support.path),
           FileManager.default.fileExists(atPath: previous.path) {
            try FileManager.default.moveItem(at: previous, to: support)
        }
        let workspace = support.appendingPathComponent("workspace", isDirectory: true)
        let widgets = workspace.appendingPathComponent("widgets", isDirectory: true)
        let dismissed = workspace.appendingPathComponent(".dismissed", isDirectory: true)
        try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dismissed, withIntermediateDirectories: true)
        let agents = workspace.appendingPathComponent("AGENTS.md")
        try Self.syncAgentInstructions(template: template, destination: agents)
        if let rulesTemplate = resources?.appendingPathComponent("whatnotch-agent.mdc") {
            let rulesDir = workspace.appendingPathComponent(".cursor/rules", isDirectory: true)
            try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
            let rulesDest = rulesDir.appendingPathComponent("whatnotch.mdc")
            try Self.syncFileIfChanged(from: rulesTemplate, to: rulesDest)
        }
        return AppPaths(support: support, shelf: shelf, widgets: widgets, dismissed: dismissed, sidecarScript: script)
    }

    private static func agentSpecVersion(in text: String) -> Int {
        let pattern = #"whatnotch-spec-version:\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text),
              let value = Int(text[range]) else {
            return 0
        }
        return value
    }

    private static func syncAgentInstructions(template: URL, destination: URL) throws {
        let manager = FileManager.default
        let templateText = try String(contentsOf: template, encoding: .utf8)
        let templateVersion = agentSpecVersion(in: templateText)
        if !manager.fileExists(atPath: destination.path) {
            try templateText.write(to: destination, atomically: true, encoding: .utf8)
            return
        }
        guard let existing = try? String(contentsOf: destination, encoding: .utf8) else {
            try templateText.write(to: destination, atomically: true, encoding: .utf8)
            return
        }
        if agentSpecVersion(in: existing) < templateVersion {
            try templateText.write(to: destination, atomically: true, encoding: .utf8)
            return
        }
        guard existing.hasPrefix("# Agentic Notch\n") else { return }
        var text = existing
        let heading = text.startIndex..<text.index(text.startIndex, offsetBy: "# Agentic Notch".count)
        text.replaceSubrange(heading, with: "# Whatnotch")
        let previousIntro = "You are the agent that lives in the notch on this Mac."
        let intro = "You are Whatnotch, the agent that lives in the notch on this Mac."
        if let range = text.range(of: previousIntro) {
            text.replaceSubrange(range, with: intro)
        }
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }

    private static func syncFileIfChanged(from source: URL, to destination: URL) throws {
        guard let incoming = try? Data(contentsOf: source) else { return }
        if let current = try? Data(contentsOf: destination), current == incoming { return }
        try incoming.write(to: destination, options: .atomic)
    }
}
