import Foundation

@main
enum CampMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let commands: Set<String> = ["status", "bootstrap", "rewrite", "start", "stop", "passwords", "project", "projects", "help", "--help", "-h"]
        if let command = arguments.first, commands.contains(command) {
            runCampCTL(arguments)
        }
        CampApp.main()
    }
}

private func runCampCTL(_ arguments: [String]) -> Never {
    let settings = CampSettings.load()
    let controller = ServiceController()
    let command = arguments.first ?? "help"

    func service(named name: String) -> CampService? {
        CampService(rawValue: name)
    }

    func ensureCLIConfig() -> ProjectsConfig {
        var config = ProjectManager.shared.load()
        if config.projects.isEmpty && ProjectManager.shared.hasLegacyData {
            _ = try? ProjectManager.shared.migrateLegacy(name: "default", settings: settings, controller: controller)
            config = ProjectManager.shared.load()
        }
        return config
    }

    func printStatus() {
        if let active = ProjectManager.shared.activeProject {
            print("project \(active.name) (id: \(active.id))")
        }
        let all = controller.allStatesAndMetrics()
        for item in CampService.allCases {
            let state = all.states[item] ?? .stopped
            if state == .running, let metrics = all.metrics[item] {
                print("\(item.rawValue) \(state.rawValue) (\(metrics.formattedCPU) CPU, \(metrics.formattedMemory))")
            } else {
                print("\(item.rawValue) \(state.rawValue)")
            }
        }
        if let php = StackLayout.binary(["bin/php"]) {
            let version = Shell.run(executable: php.path, arguments: [
                "-c", StackLayout.conf.appendingPathComponent("php.ini").path,
                "-r", "echo PHP_VERSION;",
            ])
            print("php \(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let perl = StackLayout.binary(["bin/perl"]) {
            let version = Shell.run(executable: perl.path, arguments: ["-e", "print $^V"])
            print("perl \(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    do {
        switch command {
        case "status":
            printStatus()
        case "bootstrap":
            let active = ProjectManager.shared.activeProject
            let report = try StackBootstrap().run(settings: settings, project: active)
            if let database = report.databasePassword { print("database \(database)") }
            if let ftp = report.ftpPassword { print("ftp \(ftp)") }
            print("bootstrapped")
        case "rewrite":
            let active = ProjectManager.shared.activeProject
            try ConfigWriter().write(settings: try settings.validated(), project: active)
            print("rewritten")
        case "project", "projects":
            let sub = arguments.count > 1 ? arguments[1] : "list"
            switch sub {
            case "list":
                let config = ensureCLIConfig()
                if config.projects.isEmpty {
                    print("No projects found. Create one with: Camp project create <name>")
                } else {
                    let activeId = config.activeProjectId
                    for p in config.projects {
                        let marker = (p.id == activeId) ? "* " : "  "
                        var feat: [String] = []
                        if p.features.apache { feat.append("apache") }
                        if p.features.mariadb { feat.append("mariadb") }
                        if p.features.phpMyAdmin { feat.append("phpmyadmin") }
                        if p.features.ftp { feat.append("ftp") }
                        print("\(marker)\(p.name) (id: \(p.id)) [\(feat.joined(separator: ", "))]")
                    }
                }
            case "current":
                let config = ensureCLIConfig()
                if let active = ProjectManager.shared.getActiveProject(in: config) {
                    var feat: [String] = []
                    if active.features.apache { feat.append("apache") }
                    if active.features.mariadb { feat.append("mariadb") }
                    if active.features.phpMyAdmin { feat.append("phpmyadmin") }
                    if active.features.ftp { feat.append("ftp") }
                    print("\(active.name) (id: \(active.id)) [\(feat.joined(separator: ", "))]")
                } else {
                    print("No active project")
                }
            case "switch":
                let rest = Array(arguments.dropFirst(2))
                let positional = rest.filter { !$0.hasPrefix("-") }
                guard let target = positional.first else {
                    fputs("Missing project name or id.\nUsage: Camp project switch <name-or-id>\n", stderr)
                    exit(1)
                }
                _ = ensureCLIConfig()
                let switched = try ProjectManager.shared.switchProject(to: target, settings: settings, controller: controller)
                print("Switched to project '\(switched.name)' (id: \(switched.id)).")
                printStatus()
            case "create":
                let rest = Array(arguments.dropFirst(2))
                let flags = Set(rest.filter { $0.hasPrefix("-") }.map { $0.lowercased() })
                let positional = rest.filter { !$0.hasPrefix("-") }
                guard let name = positional.first, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                    fputs("Missing project name.\nUsage: Camp project create <name> [--apache] [--mariadb] [--phpmyadmin] [--ftp] [--template <blank|php|wordpress|phpmyadmin>]\n", stderr)
                    exit(1)
                }

                var selectedTemplate: ProjectTemplate = .blank
                if let tmplFlag = rest.first(where: { $0.hasPrefix("--template=") }) {
                    let val = String(tmplFlag.dropFirst("--template=".count)).lowercased()
                    if let t = ProjectTemplate(rawValue: val) { selectedTemplate = t }
                } else if let idx = rest.firstIndex(of: "--template"), idx + 1 < rest.count {
                    let val = rest[idx + 1].lowercased()
                    if let t = ProjectTemplate(rawValue: val) { selectedTemplate = t }
                } else if flags.contains("--wordpress") {
                    selectedTemplate = .wordpress
                } else if flags.contains("--php") && !flags.contains("--phpmyadmin") {
                    selectedTemplate = .php
                }

                let hasFeatureFlags = flags.contains("--apache") || flags.contains("--mariadb") || flags.contains("--phpmyadmin") || flags.contains("--ftp")
                let features: ProjectFeatures
                if hasFeatureFlags {
                    let apache = flags.contains("--apache") || flags.contains("--phpmyadmin")
                    let mariadb = flags.contains("--mariadb") || flags.contains("--phpmyadmin")
                    let phpMyAdmin = flags.contains("--phpmyadmin")
                    let ftp = flags.contains("--ftp")
                    features = ProjectFeatures(apache: apache, mariadb: mariadb, phpMyAdmin: phpMyAdmin, ftp: ftp)
                } else {
                    switch selectedTemplate {
                    case .blank:
                        features = ProjectFeatures(apache: true, mariadb: false, phpMyAdmin: false, ftp: false)
                    case .php:
                        features = ProjectFeatures(apache: true, mariadb: false, phpMyAdmin: false, ftp: false)
                    case .wordpress:
                        features = ProjectFeatures(apache: true, mariadb: true, phpMyAdmin: false, ftp: false)
                    case .phpmyadmin:
                        features = ProjectFeatures(apache: true, mariadb: true, phpMyAdmin: true, ftp: false)
                    }
                }
                let created = try ProjectManager.shared.createProject(
                    name: name,
                    features: features,
                    template: selectedTemplate,
                    settings: settings
                )
                print("Created project '\(created.name)' (id: \(created.id)).")
                let config = ProjectManager.shared.load()
                if config.projects.count == 1 || config.activeProjectId == created.id {
                    _ = try ProjectManager.shared.switchProject(to: created.id, settings: settings, controller: controller)
                    print("Switched to project '\(created.name)'.")
                }
            case "delete":
                let rest = Array(arguments.dropFirst(2))
                let flags = Set(rest.filter { $0.hasPrefix("-") }.map { $0.lowercased() })
                let positional = rest.filter { !$0.hasPrefix("-") }
                guard let target = positional.first else {
                    fputs("Missing project name or id.\nUsage: Camp project delete <name-or-id> [--trash]\n", stderr)
                    exit(1)
                }
                let moveToTrash = flags.contains("--trash")
                let config = ProjectManager.shared.load()
                guard let proj = config.projects.first(where: {
                    $0.id.lowercased() == target.lowercased() || $0.name.localizedCaseInsensitiveCompare(target) == .orderedSame
                }) else {
                    fputs("Project '\(target)' not found.\n", stderr)
                    exit(1)
                }
                try ProjectManager.shared.deleteProject(id: proj.id, moveToTrash: moveToTrash, settings: settings, controller: controller)
                print("Deleted project '\(proj.name)'.")
            default:
                print("usage: Camp project list|current|switch <name-or-id>|create <name> [--apache] [--mariadb] [--phpmyadmin] [--ftp]|delete <name-or-id> [--trash]")
            }
        case "start", "stop":
            let name = arguments.count > 1 ? arguments[1] : "all"
            let targets: [CampService] = name == "all" ? Array(CampService.allCases) : [service(named: name)].compactMap { $0 }
            if targets.isEmpty {
                fputs("Unknown service \(name)\n", stderr)
                exit(2)
            }
            if command == "start" {
                if !FileManager.default.fileExists(atPath: StackLayout.marker.path) {
                    _ = try StackBootstrap().run(settings: settings)
                }
                _ = ensureCLIConfig()
                let activeProject = ProjectManager.shared.activeProject
                try ConfigWriter().write(settings: try settings.validated(), project: activeProject)
                let activeFeatures = activeProject?.features ?? .all
                for item in targets {
                    switch item {
                    case .apache where !activeFeatures.apache: continue
                    case .mariadb where !activeFeatures.mariadb: continue
                    case .proftpd where !activeFeatures.ftp: continue
                    default: break
                    }
                    try controller.start(item, settings: settings)
                    if item == .mariadb {
                        try StackBootstrap().waitForDatabase(port: settings.mariadbPort)
                        _ = try StackBootstrap().ensureDatabasePassword(port: settings.mariadbPort, settings: settings)
                    }
                }
            } else {
                for item in targets {
                    controller.stop(item, settings: settings)
                }
            }
            printStatus()
        case "passwords":
            print("database \(KeychainStore.get(account: KeychainStore.databaseAccount) ?? "")")
            print("ftp \(KeychainStore.get(account: KeychainStore.ftpAccount) ?? "")")
        case "help", "--help", "-h":
            print("usage: Camp status|bootstrap|rewrite|start|stop|passwords|project [list|current|switch|create|delete]")
        default:
            print("usage: Camp status|bootstrap|rewrite|start|stop|passwords|project [list|current|switch|create|delete]")
        }
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        exit(1)
    }
    exit(0)
}
