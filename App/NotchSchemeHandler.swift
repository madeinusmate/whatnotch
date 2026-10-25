import Foundation
import WebKit

final class NotchSchemeHandler: NSObject, WKURLSchemeHandler {
    let shelfRoot: URL
    let widgetsRoot: () -> URL
    private var stopped = Set<ObjectIdentifier>()

    init(shelfRoot: URL, widgetsRoot: @escaping () -> URL) {
        self.shelfRoot = shelfRoot
        self.widgetsRoot = widgetsRoot
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let url = urlSchemeTask.request.url else {
            finish(urlSchemeTask, status: 400, data: Data(), mime: "text/plain")
            return
        }
        let file: URL?
        switch url.host {
        case "shelf":
            file = fileIn(shelfRoot, relative: relativePath(url))
        case "widget":
            file = widgetFile(url)
        default:
            file = nil
        }
        guard let file, let data = try? Data(contentsOf: file) else {
            finish(urlSchemeTask, status: 404, data: Data("missing".utf8), mime: "text/plain")
            return
        }
        guard !stopped.contains(id) else { return }
        finish(urlSchemeTask, status: 200, data: data, mime: mime(for: file))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    private func finish(_ task: any WKURLSchemeTask, status: Int, data: Data, mime: String) {
        let id = ObjectIdentifier(task as AnyObject)
        guard !stopped.contains(id), let url = task.request.url else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
                "Access-Control-Allow-Origin": "*",
            ]
        )
        guard let response else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func widgetFile(_ url: URL) -> URL? {
        let parts = relativePath(url).split(separator: "/").map(String.init)
        guard let slug = parts.first, slug.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        let rest = parts.dropFirst().joined(separator: "/")
        let relative = rest.isEmpty ? "index.html" : rest
        let root = widgetsRoot().appendingPathComponent(slug, isDirectory: true)
        return fileIn(root, relative: relative)
    }

    private func relativePath(_ url: URL) -> String {
        let path = url.path.removingPercentEncoding ?? url.path
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    private func fileIn(_ root: URL, relative: String) -> URL? {
        let base = root.standardizedFileURL
        let target = base.appendingPathComponent(relative).standardizedFileURL
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard target.path == base.path || target.path.hasPrefix(prefix) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return target
    }

    private func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
