import Foundation

enum BridgeRunner {
    private static let outputCap = 1_000_000

    static func shell(command: String, cwd: URL) -> Result<String, BridgeFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = cwd
        process.environment = WidgetBridge.scrubbedEnvironment()
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return .failure(BridgeFailure("The command could not start."))
        }
        let group = DispatchGroup()
        var stdout = Data()
        var stderr = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdout = out.fileHandleForReading.readData(ofLength: outputCap)
            if stdout.count >= outputCap { process.terminate() }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderr = err.fileHandleForReading.readData(ofLength: outputCap)
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        if process.terminationStatus == 0 {
            return .success(String(data: stdout, encoding: .utf8) ?? "")
        }
        let failure = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = String(data: stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(BridgeFailure(failure?.isEmpty == false ? failure! : (fallback ?? "Command failed.")))
    }

    static func readFile(_ path: String, cwd: URL) -> Result<String, BridgeFailure> {
        let url = resolve(path, cwd: cwd)
        guard let data = try? Data(contentsOf: url), data.count <= outputCap else {
            return .failure(BridgeFailure("The file could not be read."))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(BridgeFailure("The file is not text."))
        }
        return .success(text)
    }

    static func writeFile(_ path: String, contents: String, cwd: URL) -> Result<Bool, BridgeFailure> {
        let url = resolve(path, cwd: cwd)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.data(using: .utf8)?.write(to: url)
            return .success(true)
        } catch {
            return .failure(BridgeFailure("The file could not be written."))
        }
    }

    static func list(_ path: String, cwd: URL) -> Result<[String], BridgeFailure> {
        let url = resolve(path, cwd: cwd)
        do {
            return .success(try FileManager.default.contentsOfDirectory(atPath: url.path).sorted())
        } catch {
            return .failure(BridgeFailure("The folder could not be listed."))
        }
    }

    static func http(urlString: String, method: String?, headers: [String: String]?, body: String?) async -> Result<[String: Any], BridgeFailure> {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(BridgeFailure("Only http and https URLs are allowed."))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method ?? "GET"
        headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body { request.httpBody = body.data(using: .utf8) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let clipped = data.prefix(outputCap)
            let text = String(data: clipped, encoding: .utf8) ?? ""
            return .success(["status": status, "body": text])
        } catch {
            return .failure(BridgeFailure("The request failed."))
        }
    }

    private static func resolve(_ path: String, cwd: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return cwd.appendingPathComponent(path).standardizedFileURL
    }
}

struct BridgeFailure: Error {
    var message: String
    init(_ message: String) { self.message = message }
}
