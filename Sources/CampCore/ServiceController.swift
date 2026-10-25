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

struct ServiceMetrics: Codable, Equatable {
    var cpuPercent: Double
    var memoryBytes: UInt64

    var formattedCPU: String {
        String(format: "%.1f%%", cpuPercent)
    }

    var formattedMemory: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }

    var summary: String {
        "\(formattedCPU) CPU, \(formattedMemory)"
    }
}

struct ProcessRow: Equatable {
    let pid: Int32
    let ppid: Int32
    let cpu: Double
    let rssKB: UInt64
}

struct ServiceState: Equatable {
    var status: ServiceStatus
    var pid: pid_t?
}

struct ServiceController {
    func start(_ service: CampService, settings: CampSettings) throws {
        if status(service, settings: settings) == .running {
            return
        }
        if service == .mariadb {
            // Remove any stale socket file left from an unclean shutdown
            if FileManager.default.fileExists(atPath: StackLayout.mysqlSocket.path) {
                try? FileManager.default.removeItem(at: StackLayout.mysqlSocket)
            }
        }
        let plist = try writePlist(service, settings: settings)
        // A clean MariaDB install can spend a long time building its first
        // InnoDB tablespaces, especially on slower or nearly-full disks. Do not
        // report a failed start while that first initialization is still in
        // progress.
        try loadAndStart(service, plist: plist, timeout: service == .mariadb ? 180 : 12, settings: settings)
    }

    func stop(_ service: CampService, settings: CampSettings) {
        stopLaunchd(service)
    }

    func status(_ service: CampService, settings: CampSettings) -> ServiceStatus {
        return launchdStatus(service.label)
    }

    func serviceState(_ service: CampService) -> ServiceState {
        let result = Shell.run(executable: "/bin/launchctl", arguments: ["print", "gui/\(getuid())/\(service.label)"])
        guard result.status == 0 && result.stdout.contains("state = running") else {
            return ServiceState(status: .stopped, pid: nil)
        }
        var foundPid: pid_t? = nil
        for line in result.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = ") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count == 2, let parsed = pid_t(parts[1].trimmingCharacters(in: .whitespaces)) {
                    foundPid = parsed
                    break
                }
            }
        }
        return ServiceState(status: .running, pid: foundPid)
    }

    func servicePid(_ service: CampService) -> pid_t? {
        serviceState(service).pid
    }

    func metrics(for service: CampService) -> ServiceMetrics? {
        guard let pid = servicePid(service) else { return nil }
        let processes = Self.parseProcessTable()
        return Self.calculateMetrics(for: pid, in: processes)
    }

    func allStatesAndMetrics() -> (states: [CampService: ServiceStatus], metrics: [CampService: ServiceMetrics]) {
        var states = [CampService: ServiceStatus]()
        var pids = [CampService: pid_t]()
        for service in CampService.allCases {
            let state = serviceState(service)
            states[service] = state.status
            if let pid = state.pid {
                pids[service] = pid
            }
        }
        var metrics = [CampService: ServiceMetrics]()
        if !pids.isEmpty {
            let processes = Self.parseProcessTable()
            for (service, pid) in pids {
                metrics[service] = Self.calculateMetrics(for: pid, in: processes)
            }
        }
        return (states, metrics)
    }

    static func parseProcessTable() -> [ProcessRow] {
        let result = Shell.run(executable: "/bin/ps", arguments: ["-A", "-o", "pid,ppid,%cpu,rss"])
        guard result.status == 0 else { return [] }
        var rows = [ProcessRow]()
        for line in result.stdout.components(separatedBy: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let cpu = Double(parts[2]),
                  let rss = UInt64(parts[3]) else { continue }
            rows.append(ProcessRow(pid: pid, ppid: ppid, cpu: cpu, rssKB: rss))
        }
        return rows
    }

    static func calculateMetrics(for rootPid: pid_t, in processes: [ProcessRow]) -> ServiceMetrics {
        var targetPids = Set<Int32>([rootPid])
        var changed = true
        while changed {
            changed = false
            for row in processes {
                if targetPids.contains(row.ppid) && !targetPids.contains(row.pid) {
                    targetPids.insert(row.pid)
                    changed = true
                }
            }
        }
        var totalCPU = 0.0
        var totalKB: UInt64 = 0
        for row in processes where targetPids.contains(row.pid) {
            totalCPU += row.cpu
            totalKB += row.rssKB
        }
        return ServiceMetrics(cpuPercent: totalCPU, memoryBytes: totalKB * 1024)
    }

    private func loadAndStart(_ service: CampService, plist: URL, timeout: TimeInterval, settings: CampSettings) throws {
        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(service.label)"
        let printed = Shell.run(executable: "/bin/launchctl", arguments: ["print", target])
        if printed.status == 0 {
            let unload = Shell.run(executable: "/bin/launchctl", arguments: ["bootout", domain, plist.path])
            if unload.status != 0 {
                throw StackError.command("launchctl reload \(service.title)", unload.combined)
            }
            let deadline = Date().addingTimeInterval(service == .mariadb ? 15 : 5)
            while Date() < deadline && launchdStatus(service.label) == .running {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if service == .mariadb {
                let socketDeadline = Date().addingTimeInterval(5)
                while Date() < socketDeadline && FileManager.default.fileExists(atPath: StackLayout.mysqlSocket.path) {
                    Thread.sleep(forTimeInterval: 0.1)
                }
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
        if !waitLaunchd(service, timeout: timeout, settings: settings) {
            let target = "gui/\(getuid())/\(service.label)"
            let launchd = Shell.run(executable: "/bin/launchctl", arguments: ["print", target]).combined
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let details = [launchd, logTail(service)]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\nRecent service output:\n")
            throw StackError.message("\(service.title) did not stay running.\n\(details)")
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

    private func waitLaunchd(_ service: CampService, timeout: TimeInterval, settings: CampSettings) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var sawRunning = false
        while Date() < deadline {
            let current = launchdStatus(service.label)
            if current == .running {
                sawRunning = true
                if service != .mariadb {
                    Thread.sleep(forTimeInterval: 0.5)
                    return launchdStatus(service.label) == .running
                }
                if isMariaDBReady(port: settings.mariadbPort) {
                    return true
                }
            } else if sawRunning {
                return false
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func isMariaDBReady(port: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: StackLayout.mysqlSocket.path) else {
            return false
        }
        guard let client = StackLayout.binary(["bin/mariadb", "bin/mysql"]) else {
            return true
        }
        let myCnf = StackLayout.conf.appendingPathComponent("my.cnf")
        let args = FileManager.default.fileExists(atPath: myCnf.path)
            ? ["--defaults-file=\(myCnf.path)", "-e", "SELECT 1"]
            : ["--socket=\(StackLayout.mysqlSocket.path)", "-u", "root", "-e", "SELECT 1"]
        let res = Shell.run(executable: client.path, arguments: args)
        return res.status == 0 || res.combined.contains("Access denied") || res.combined.contains("1045")
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

