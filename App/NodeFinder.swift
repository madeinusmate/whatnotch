import Foundation

enum NodeFinder {
    static func locate() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/opt/homebrew/opt/node@22/bin/node",
            "/opt/homebrew/opt/node/bin/node",
            "/usr/local/bin/node",
            "/usr/local/opt/node@22/bin/node",
            "/usr/bin/node",
        ].map { URL(fileURLWithPath: $0) }
        if let found = candidates.first(where: isSupported) {
            return found
        }
        guard let fromShell = loginShellNode(), isSupported(fromShell) else { return nil }
        return fromShell
    }

    private static func isSupported(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        guard let version = readVersion(url) else { return false }
        return supports(version)
    }

    private static func readVersion(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-p", "process.versions.node"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func supports(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return false }
        if major > 22 { return true }
        if major < 22 { return false }
        let minor = parts.count > 1 ? parts[1] : 0
        return minor >= 13
    }

    private static func loginShellNode() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}
