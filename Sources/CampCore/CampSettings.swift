import Foundation

struct CampSettings: Codable, Equatable {
    var apachePort: Int
    var apacheSSLPort: Int
    var mariadbPort: Int
    var ftpPort: Int
    var bindAllInterfaces: Bool
    var launchAtLogin: Bool
    var usePrivilegedPorts: Bool

    static let storageKey = "settings"

    static let standard = CampSettings(
        apachePort: 8080,
        apacheSSLPort: 8443,
        mariadbPort: 3306,
        ftpPort: 2121,
        bindAllInterfaces: false,
        launchAtLogin: false,
        usePrivilegedPorts: false
    )

    var bindAddress: String { bindAllInterfaces ? "0.0.0.0" : "127.0.0.1" }

    func validated() throws -> CampSettings {
        let copy = self
        if copy.usePrivilegedPorts {
            throw StackError.message("Standard ports are unavailable in this release. Use ports above 1024.")
        }
        let ports = [copy.apachePort, copy.apacheSSLPort, copy.mariadbPort, copy.ftpPort]
        for port in ports where port < 1 || port > 65535 {
            throw StackError.message("Ports have to be between 1 and 65535.")
        }
        if Set(ports).count != ports.count {
            throw StackError.message("Each service needs its own port.")
        }
        if !copy.usePrivilegedPorts && ports.contains(where: { $0 < 1024 }) {
            throw StackError.message("Camp only supports ports above 1024 in this release.")
        }
        return copy
    }

    static func load() -> CampSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(CampSettings.self, from: data) else {
            return .standard
        }
        if settings.usePrivilegedPorts {
            settings.usePrivilegedPorts = false
            settings.apachePort = 8080
            settings.apacheSSLPort = 8443
            settings.ftpPort = 2121
            settings.save()
            if StackLayout.installed {
                try? ConfigWriter().writeApacheConfig(settings: settings)
            }
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

enum LogKind: String, CaseIterable, Identifiable {
    case apache
    case mariadb
    case proftpd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apache: return "Apache"
        case .mariadb: return "MariaDB"
        case .proftpd: return "ProFTPD"
        }
    }

    var file: URL {
        switch self {
        case .apache: return StackLayout.logs.appendingPathComponent("apache-error.log")
        case .mariadb: return StackLayout.logs.appendingPathComponent("mariadb.launchd.log")
        case .proftpd: return StackLayout.logs.appendingPathComponent("proftpd.launchd.log")
        }
    }
}

enum CampSection: String, CaseIterable, Identifiable {
    case web
    case database
    case ftp
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .web: return "Web"
        case .database: return "Database"
        case .ftp: return "FTP"
        case .logs: return "Logs"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .web: return "globe"
        case .database: return "cylinder"
        case .ftp: return "arrow.up.arrow.down"
        case .logs: return "text.alignleft"
        case .settings: return "gearshape"
        }
    }
}
