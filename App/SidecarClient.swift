import Foundation

struct SidecarEvent {
    var type: String
    var message: String?
    var text: String?
    var id: String?
    var summary: String?
    var state: String?
    var agentId: String?
    var sessionId: String?
    var models: [[String: Any]] = []
    var messages: [[String: Any]] = []

    init?(line: String) {
        guard line.hasPrefix("AGN\t") else { return nil }
        let payload = String(line.dropFirst(4))
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        self.type = type
        message = object["message"] as? String
        text = object["text"] as? String
        id = object["id"] as? String
        summary = object["summary"] as? String
        state = object["state"] as? String
        agentId = object["agentId"] as? String
        sessionId = object["sessionId"] as? String
        models = object["models"] as? [[String: Any]] ?? []
        messages = object["messages"] as? [[String: Any]] ?? []
    }
}

final class SidecarClient {
    var onEvent: ((SidecarEvent) -> Void)?
    var onExit: ((String) -> Void)?

    private var process: Process?
    private let queue = DispatchQueue(label: "app.whatnotch.sidecar")
    private var buffer = ""
    private var errorTail = ""
    private var stopped = false
    private var reportedExit = false
    private var generation = 0
    private var stdinFD: Int32 = -1

    func start(node: URL, script: URL) throws {
        stop()
        generation += 1
        let generation = generation
        stopped = false
        reportedExit = false
        buffer = ""
        errorTail = ""
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        process.environment = environment(node: node)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.qualityOfService = .userInitiated
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            self?.queue.asyncAfter(deadline: .now() + 0.15) {
                self?.reportExit(status: status, generation: generation)
            }
        }
        try process.run()
        stdinFD = Darwin.dup(input.fileHandleForWriting.fileDescriptor)
        let outputFD = Darwin.dup(output.fileHandleForReading.fileDescriptor)
        let errorFD = Darwin.dup(errors.fileHandleForReading.fileDescriptor)
        readLoop(fd: outputFD) { [weak self] data in self?.consume(data) }
        readLoop(fd: errorFD) { [weak self] data in self?.consumeError(data) }
        self.process = process
    }

    func send(_ object: [String: Any]) {
        guard stdinFD >= 0, let process, process.isRunning,
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A)
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(stdinFD, base.advanced(by: written), raw.count - written)
                if count <= 0 { break }
                written += count
            }
        }
    }

    func stop() {
        stopped = true
        if stdinFD >= 0 {
            Darwin.close(stdinFD)
            stdinFD = -1
        }
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private func environment(node: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CURSOR_API_KEY")
        let bin = node.deletingLastPathComponent().path
        let path = env["PATH"] ?? "/usr/bin:/bin"
        if !path.split(separator: ":").contains(Substring(bin)) {
            env["PATH"] = bin + ":" + path
        }
        env["NODE_NO_WARNINGS"] = "1"
        return env
    }

    private func readLoop(fd: Int32, consume: @escaping (Data) -> Void) {
        queue.async { [weak self] in
            var storage = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = storage.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return Darwin.read(fd, base, raw.count)
                }
                if count <= 0 { break }
                consume(Data(storage.prefix(count)))
            }
            Darwin.close(fd)
            _ = self
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        buffer.append(text)
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            guard let event = SidecarEvent(line: line) else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(event)
            }
        }
    }

    private func consumeError(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        errorTail.append(text)
        if errorTail.count > 4_000 {
            errorTail = String(errorTail.suffix(4_000))
        }
    }

    private func reportExit(status: Int32, generation: Int) {
        guard generation == self.generation, !stopped, !reportedExit else { return }
        reportedExit = true
        let tail = errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let message: String
        if let line = tail.split(separator: "\n").first {
            let text = String(line)
            message = text.count > 180 ? String(text.prefix(177)) + "..." : text
        } else {
            message = "The agent stopped responding."
        }
        DispatchQueue.main.async { [weak self] in
            self?.onExit?(message)
        }
        _ = status
    }
}
