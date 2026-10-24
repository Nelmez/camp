import Darwin
import Foundation

enum CampService: String, CaseIterable, Identifiable {
    case apache
    case mariadb
    case proftpd

    var id: String { rawValue }
    var label: String { "com.nelmez.camp.\(rawValue)" }

    var title: String {
        switch self {
        case .apache: return "Apache"
        case .mariadb: return "MariaDB"
        case .proftpd: return "ProFTPD"
        }
    }

}

enum ServiceStatus: String {
    case running
    case stopped
}

struct ServiceController {
    func start(_ service: CampService, settings: CampSettings) throws {
        let plist = try writePlist(service, settings: settings)
        try loadAndStart(service, plist: plist, timeout: service == .mariadb ? 40 : 12)
    }

    func stop(_ service: CampService, settings: CampSettings) {
        stopLaunchd(service)
    }

    func status(_ service: CampService, settings: CampSettings) -> ServiceStatus {
        return launchdStatus(service.label)
    }

    private func loadAndStart(_ service: CampService, plist: URL, timeout: TimeInterval) throws {
        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(service.label)"
        let printed = Shell.run(executable: "/bin/launchctl", arguments: ["print", target])
        if printed.status == 0 {
            let unload = Shell.run(executable: "/bin/launchctl", arguments: ["bootout", domain, plist.path])
            if unload.status != 0 {
                throw StackError.command("launchctl reload \(service.title)", unload.combined)
            }
        }
        let boot = Shell.run(executable: "/bin/launchctl", arguments: ["bootstrap", domain, plist.path])
        if boot.status != 0 {
            throw StackError.command("launchctl bootstrap \(service.title)", boot.combined)
        }
        let kick = Shell.run(executable: "/bin/launchctl", arguments: ["kickstart", "-k", target])
        if kick.status != 0 {
            throw StackError.command("launchctl kickstart \(service.title)", kick.combined)
        }
        if !waitLaunchd(service.label, timeout: timeout) {
            throw StackError.message("\(service.title) did not stay running.\n\(logTail(service))")
        }
    }

    private func stopLaunchd(_ service: CampService) {
        let target = "gui/\(getuid())/\(service.label)"
        _ = Shell.run(executable: "/bin/launchctl", arguments: ["kill", "SIGTERM", target])
        let timeout: TimeInterval = service == .mariadb ? 30 : 10
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && launchdStatus(service.label) == .running {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if launchdStatus(service.label) == .running {
            _ = Shell.run(executable: "/bin/launchctl", arguments: ["kill", "SIGKILL", target])
        }
    }

    private func launchdStatus(_ label: String) -> ServiceStatus {
        let result = Shell.run(executable: "/bin/launchctl", arguments: ["print", "gui/\(getuid())/\(label)"])
        if result.status == 0 && result.stdout.contains("state = running") {
            return .running
        }
        return .stopped
    }

    private func waitLaunchd(_ label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if launchdStatus(label) == .running { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func writePlist(_ service: CampService, settings: CampSettings) throws -> URL {
        let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let url = agents.appendingPathComponent("\(service.label).plist")
        let arguments = programArguments(service)
        let log = StackLayout.logs.appendingPathComponent("\(service.rawValue).launchd.log").path
        let prefix = StackLayout.resolvedPrefix.path
        let plist: [String: Any] = [
            "Label": service.label,
            "ProgramArguments": arguments,
            "RunAtLoad": settings.launchAtLogin,
            "KeepAlive": false,
            "WorkingDirectory": StackLayout.dataRoot.path,
            "StandardOutPath": log,
            "StandardErrorPath": log,
            "EnvironmentVariables": [
                "PATH": "\(prefix)/bin:\(prefix)/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    private func programArguments(_ service: CampService) -> [String] {
        switch service {
        case .apache:
            let httpd = StackLayout.binary(["bin/httpd"])?.path ?? StackLayout.prefix.appendingPathComponent("bin/httpd").path
            return [httpd, "-D", "FOREGROUND", "-f", StackLayout.conf.appendingPathComponent("httpd.conf").path]
        case .mariadb:
            let server = StackLayout.binary(["sbin/mariadbd", "bin/mariadbd", "sbin/mysqld", "libexec/mariadbd"])?.path
                ?? StackLayout.prefix.appendingPathComponent("sbin/mariadbd").path
            return [server, "--defaults-file=\(StackLayout.conf.appendingPathComponent("my.cnf").path)", "--console"]
        case .proftpd:
            let ftp = StackLayout.binary(["sbin/proftpd", "bin/proftpd"])?.path
                ?? StackLayout.prefix.appendingPathComponent("sbin/proftpd").path
            return [ftp, "-n", "-c", StackLayout.conf.appendingPathComponent("proftpd.conf").path]
        }
    }

    private func logTail(_ service: CampService) -> String {
        let urls = [
            LogKind(rawValue: service.rawValue)?.file,
            StackLayout.logs.appendingPathComponent("\(service.rawValue).launchd.log"),
        ].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let newest = urls.max { modificationDate($0) < modificationDate($1) }
        return newest.map { tail($0) } ?? ""
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    func tail(_ url: URL, lines: Int = 40) -> String {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return ""
        }
        let clipped = text.count > 60_000 ? String(text.suffix(60_000)) : text
        return clipped.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

