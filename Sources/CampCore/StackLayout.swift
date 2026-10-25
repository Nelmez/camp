import Foundation

enum StackLayout {
    /// Compiled prefix. Apache, PHP, and MariaDB mishandle a prefix that contains spaces,
    /// so the binaries live here and `dataRoot/stack` is a symlink to this folder.
    static let prefix = URL(fileURLWithPath: "/opt/camp", isDirectory: true)
    static let dataRoot = URL(fileURLWithPath: "/Library/Application Support/Camp", isDirectory: true)

    static var stack: URL { dataRoot.appendingPathComponent("stack", isDirectory: true) }
    static var htdocs: URL { dataRoot.appendingPathComponent("htdocs", isDirectory: true) }
    static var conf: URL { dataRoot.appendingPathComponent("conf", isDirectory: true) }
    static var logs: URL { dataRoot.appendingPathComponent("logs", isDirectory: true) }
    static var mysqlData: URL { dataRoot.appendingPathComponent("data/mysql", isDirectory: true) }
    static var ftp: URL { dataRoot.appendingPathComponent("ftp", isDirectory: true) }
    static var tmp: URL { dataRoot.appendingPathComponent("tmp", isDirectory: true) }
    static var run: URL { dataRoot.appendingPathComponent("run", isDirectory: true) }
    static var marker: URL { conf.appendingPathComponent(".bootstrapped") }
    static var autostart: URL { conf.appendingPathComponent("autostart") }
    static var credentials: URL { conf.appendingPathComponent(".credentials") }
    static var mysqlSocket: URL { tmp.appendingPathComponent("mysql.sock") }
    static var projectsRoot: URL { dataRoot.appendingPathComponent("projects", isDirectory: true) }
    static var projectsConfig: URL { dataRoot.appendingPathComponent("projects.json") }

    static var sharedPhpMyAdmin: URL {
        let dedicated = dataRoot.appendingPathComponent("phpmyadmin", isDirectory: true)
        if FileManager.default.fileExists(atPath: dedicated.appendingPathComponent("index.php").path) {
            return dedicated
        }
        return htdocs.appendingPathComponent("phpmyadmin", isDirectory: true)
    }

    static var installed: Bool {
        binary(["bin/httpd"]) != nil
            && binary(["bin/php"]) != nil
            && binary(["bin/perl"]) != nil
            && binary(["sbin/mariadbd", "bin/mariadbd", "sbin/mysqld", "libexec/mariadbd"]) != nil
            && binary(["sbin/proftpd", "bin/proftpd"]) != nil
            && binary(["bin/openssl"]) != nil
            && (FileManager.default.fileExists(atPath: sharedPhpMyAdmin.appendingPathComponent("index.php").path)
                || FileManager.default.fileExists(atPath: htdocs.appendingPathComponent("phpmyadmin/index.php").path))
    }

    static func binary(_ relativePaths: [String]) -> URL? {
        for root in [prefix, stack] {
            for relative in relativePaths {
                let url = root.appendingPathComponent(relative)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    static func ensureDataDirectories() throws {
        let manager = FileManager.default
        let directories = [
            htdocs,
            htdocs.appendingPathComponent("cgi-bin", isDirectory: true),
            conf,
            logs,
            mysqlData,
            ftp,
            tmp,
            run,
            projectsRoot,
        ]
        for url in directories {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static var resolvedPrefix: URL {
        if FileManager.default.fileExists(atPath: prefix.appendingPathComponent("bin").path) {
            return prefix
        }
        return stack.resolvingSymlinksInPath()
    }
}

enum StackError: LocalizedError {
    case message(String)
    case command(String, String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        case .command(let name, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "\(name) failed." }
            return "\(name) failed.\n\(trimmed)"
        case .keychain(let status):
            return "Keychain returned \(status)."
        }
    }
}

enum TemplateStore {
    static func sourceRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["CAMP_ROOT"] {
            let url = URL(fileURLWithPath: env)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/build-stack.sh").path) {
                return url
            }
        }
        if let resource = Bundle.main.url(forResource: "source-root", withExtension: "txt"),
           let text = try? String(contentsOf: resource, encoding: .utf8) {
            let url = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/build-stack.sh").path) {
                return url
            }
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Camp", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("scripts/build-stack.sh").path) {
            return bundled
        }
        let starts = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
            Bundle.main.bundleURL,
        ]
        var seen = Set<String>()
        for start in starts {
            var current = start.resolvingSymlinksInPath()
            for _ in 0..<8 {
                if seen.insert(current.path).inserted {
                    if FileManager.default.fileExists(atPath: current.appendingPathComponent("scripts/build-stack.sh").path) {
                        return current
                    }
                    let nested = current.appendingPathComponent("Camp")
                    if FileManager.default.fileExists(atPath: nested.appendingPathComponent("scripts/build-stack.sh").path) {
                        return nested
                    }
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        return nil
    }

    static func templates() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("templates"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        guard let root = sourceRoot() else { return nil }
        let url = root.appendingPathComponent("stack/templates")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func text(_ name: String) throws -> String {
        guard let dir = templates() else {
            throw StackError.message("Camp’s config templates were not found.")
        }
        return try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    static func render(_ name: String, _ values: [String: String]) throws -> String {
        var text = try text(name)
        for (key, value) in values {
            text = text.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return text
    }
}
