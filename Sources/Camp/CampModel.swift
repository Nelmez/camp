import AppKit
import Foundation

@MainActor
final class CampModel: ObservableObject {
    @Published var section: CampSection = .web
    @Published var settings: CampSettings
    @Published var apache: ServiceStatus = .stopped
    @Published var mariadb: ServiceStatus = .stopped
    @Published var proftpd: ServiceStatus = .stopped
    @Published var metrics: [CampService: ServiceMetrics] = [:]
    @Published var stackInstalled = false
    @Published var busy = false
    @Published var installing = false
    @Published var installLog = ""
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var phpVersion = "—"
    @Published var perlVersion = "—"
    @Published var logKind: LogKind = .apache
    @Published var logText = ""
    @Published var revealedDatabase = false
    @Published var revealedFTP = false
    @Published var newDatabasePassword: String?
    @Published var newFTPPassword: String?

    // Project state
    @Published var projects: [CampProject] = []
    @Published var activeProject: CampProject?
    @Published var hasProjects = false
    @Published var projectSwitchStatus: String?

    private let controller = ServiceController()
    private var refreshing = false

    init() {
        settings = CampSettings.load()
        stackInstalled = StackLayout.installed
        refreshProjects()
    }

    var availableSections: [CampSection] {
        guard let active = activeProject else {
            return CampSection.allCases
        }
        var sections: [CampSection] = []
        if active.features.apache { sections.append(.web) }
        if active.features.mariadb { sections.append(.database) }
        if active.features.ftp { sections.append(.ftp) }
        sections.append(.logs)
        sections.append(.settings)
        return sections
    }

    func refreshProjects() {
        let config = ProjectManager.shared.load()
        projects = config.projects
        activeProject = ProjectManager.shared.getActiveProject(in: config)
        hasProjects = !projects.isEmpty
        validateCurrentSection()
    }

    func validateCurrentSection() {
        if !availableSections.contains(section) {
            section = availableSections.first ?? .settings
        }
    }

    var anyRunning: Bool {
        apache == .running || mariadb == .running || proftpd == .running
    }

    func status(for service: CampService) -> ServiceStatus {
        switch service {
        case .apache: return apache
        case .mariadb: return mariadb
        case .proftpd: return proftpd
        }
    }

    func metrics(for service: CampService) -> ServiceMetrics? {
        status(for: service) == .running ? metrics[service] : nil
    }

    func menuBarSummary(for service: CampService) -> String {
        if let active = activeProject {
            switch service {
            case .apache where !active.features.apache:
                return "\(service.title): Disabled for project"
            case .mariadb where !active.features.mariadb:
                return "\(service.title): Disabled for project"
            case .proftpd where !active.features.ftp:
                return "\(service.title): Disabled for project"
            default: break
            }
        }
        let isRunning = status(for: service) == .running
        if isRunning, let m = metrics[service] {
            return "\(service.title): Running (\(m.formattedCPU) CPU, \(m.formattedMemory))"
        } else if isRunning {
            return "\(service.title): Running"
        } else {
            return "\(service.title): Stopped"
        }
    }

    func refresh() {
        stackInstalled = StackLayout.installed
        guard stackInstalled, !refreshing else { return }
        refreshing = true
        Task.detached {
            let controller = ServiceController()
            let result = controller.allStatesAndMetrics()
            await MainActor.run {
                self.apache = result.states[.apache] ?? .stopped
                self.mariadb = result.states[.mariadb] ?? .stopped
                self.proftpd = result.states[.proftpd] ?? .stopped
                self.metrics = result.metrics
                self.refreshing = false
            }
        }
    }

    func refreshVersions() {
        Task.detached {
            var php = "—"
            var perl = "—"
            if let binary = StackLayout.binary(["bin/php"]) {
                let result = Shell.run(executable: binary.path, arguments: [
                    "-c", StackLayout.conf.appendingPathComponent("php.ini").path,
                    "-r", "echo PHP_VERSION;",
                ])
                if result.status == 0 { php = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if let binary = StackLayout.binary(["bin/perl"]) {
                let result = Shell.run(executable: binary.path, arguments: ["-e", "print $^V"])
                if result.status == 0 { perl = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            let phpVersion = php
            let perlVersion = perl
            await MainActor.run {
                self.phpVersion = phpVersion
                self.perlVersion = perlVersion
            }
        }
    }

    func refreshLogs() {
        let kind = logKind
        let controller = self.controller
        Task.detached {
            let text = controller.tail(kind.file, lines: 200)
            await MainActor.run {
                self.logText = text.isEmpty ? "No log yet." : text
            }
        }
    }

    func prepareIfNeeded() async throws {
        let snapshot = settings
        let currentProject = activeProject
        if !FileManager.default.fileExists(atPath: StackLayout.marker.path) {
            let report = try await Task.detached { try StackBootstrap().run(settings: snapshot, project: currentProject) }.value
            newDatabasePassword = report.databasePassword
            newFTPPassword = report.ftpPassword
        } else if let currentProject, currentProject.features.mariadb, !currentProject.isMariaDBInitialized {
            try await Task.detached {
                try StackBootstrap().installDatabase(datadir: currentProject.mysqlDataUrl)
            }.value
        }
        try await Task.detached {
            try ConfigWriter().write(settings: try snapshot.validated(), project: currentProject)
        }.value
        settings = try snapshot.validated()
        settings.save()
    }

    func createProject(name: String, features: ProjectFeatures, template: ProjectTemplate) {
        run {
            let snapshot = self.settings
            let created = try await Task.detached {
                try ProjectManager.shared.createProject(
                    name: name,
                    features: features,
                    template: template,
                    settings: snapshot
                )
            }.value
            self.refreshProjects()
            try await self.performSwitch(to: created, snapshot: snapshot)
        }
    }

    func switchToProject(_ project: CampProject) {
        run {
            let snapshot = self.settings
            try await self.performSwitch(to: project, snapshot: snapshot)
        }
    }

    private func performSwitch(to project: CampProject, snapshot: CampSettings) async throws {
        self.projectSwitchStatus = "Switching to \(project.name)…"
        let updated = try await Task.detached {
            let controller = ServiceController()
            return try ProjectManager.shared.switchProject(to: project.id, settings: snapshot, controller: controller)
        }.value
        self.activeProject = updated
        self.refreshProjects()
        self.projectSwitchStatus = nil
        self.notice = "Switched to \(updated.name)."
    }

    func updateProject(_ project: CampProject) {
        run {
            let snapshot = self.settings
            try await Task.detached {
                let controller = ServiceController()
                try ProjectManager.shared.updateProject(project, settings: snapshot, controller: controller)
            }.value
            self.refreshProjects()
            self.notice = "Project updated."
        }
    }

    func deleteProject(_ project: CampProject, moveToTrash: Bool) {
        run {
            let snapshot = self.settings
            try await Task.detached {
                let controller = ServiceController()
                try ProjectManager.shared.deleteProject(
                    id: project.id,
                    moveToTrash: moveToTrash,
                    settings: snapshot,
                    controller: controller
                )
            }.value
            self.refreshProjects()
            self.notice = "Project “\(project.name)” deleted."
        }
    }

    func migrateLegacy(name: String = "Default Project") {
        run {
            let snapshot = self.settings
            let migrated = try await Task.detached {
                let controller = ServiceController()
                return try ProjectManager.shared.migrateLegacy(name: name, settings: snapshot, controller: controller)
            }.value
            self.refreshProjects()
            self.activeProject = migrated
            self.notice = "Imported into \(migrated.name)."
        }
    }

    func start(_ service: CampService) {
        run {
            try await self.prepareIfNeeded()
            let snapshot = self.settings
            try await Task.detached {
                try ServiceController().start(service, settings: snapshot)
                if service == .mariadb {
                    try StackBootstrap().waitForDatabase(port: snapshot.mariadbPort)
                    _ = try StackBootstrap().ensureDatabasePassword(port: snapshot.mariadbPort, settings: snapshot)
                }
            }.value
        }
    }

    func stop(_ service: CampService) {
        run {
            let snapshot = self.settings
            await Task.detached { ServiceController().stop(service, settings: snapshot) }.value
        }
    }

    func restart(_ service: CampService) {
        run {
            try await self.prepareIfNeeded()
            let snapshot = self.settings
            await Task.detached { ServiceController().stop(service, settings: snapshot) }.value
            try await Task.detached {
                try ServiceController().start(service, settings: snapshot)
                if service == .mariadb {
                    try StackBootstrap().waitForDatabase(port: snapshot.mariadbPort)
                    _ = try StackBootstrap().ensureDatabasePassword(port: snapshot.mariadbPort, settings: snapshot)
                }
            }.value
        }
    }

    func startAll() {
        run {
            try await self.prepareIfNeeded()
            let snapshot = self.settings
            let currentFeatures = self.activeProject?.features ?? .all
            try await Task.detached {
                let controller = ServiceController()
                if currentFeatures.apache {
                    try controller.start(.apache, settings: snapshot)
                }
                if currentFeatures.mariadb {
                    try controller.start(.mariadb, settings: snapshot)
                    try StackBootstrap().waitForDatabase(port: snapshot.mariadbPort)
                    _ = try StackBootstrap().ensureDatabasePassword(port: snapshot.mariadbPort, settings: snapshot)
                }
                if currentFeatures.ftp {
                    try controller.start(.proftpd, settings: snapshot)
                }
            }.value
        }
    }

    func stopAll() {
        run {
            let snapshot = self.settings
            await Task.detached {
                let controller = ServiceController()
                for service in CampService.allCases {
                    controller.stop(service, settings: snapshot)
                }
            }.value
        }
    }

    func applySettings() {
        run {
            let draft = try self.settings.validated()
            let running = CampService.allCases.filter { self.status(for: $0) == .running }
            let previous = CampSettings.load()
            for service in running {
                await Task.detached { ServiceController().stop(service, settings: previous) }.value
            }
            self.settings = draft
            draft.save()
            let currentProject = self.activeProject
            try await Task.detached { try ConfigWriter().write(settings: draft, project: currentProject) }.value
            if FileManager.default.fileExists(atPath: StackLayout.marker.path) {
                let password = KeychainStore.get(account: KeychainStore.databaseAccount) ?? ""
                let blowfish = KeychainStore.get(account: KeychainStore.blowfishAccount) ?? (try? Secrets.password(length: 32)) ?? "abcdef0123456789abcdef0123456789"
                try await Task.detached {
                    try ConfigWriter().writeWebFiles(
                        databasePassword: password,
                        port: draft.mariadbPort,
                        blowfish: blowfish,
                        bindAllInterfaces: draft.bindAllInterfaces,
                        project: currentProject
                    )
                }.value
            }
            for service in running {
                try await Task.detached { try ServiceController().start(service, settings: draft) }.value
            }
            self.notice = "Settings saved."
        }
    }

    func install() {
        guard let root = TemplateStore.sourceRoot() else {
            errorMessage = "Camp could not find scripts/build-stack.sh."
            return
        }
        let script = root.appendingPathComponent("scripts/build-stack.sh")
        installing = true
        installLog = ""
        errorMessage = nil
        Task.detached {
            let status = Shell.stream(executable: "/bin/bash", arguments: [script.path]) { chunk in
                Task { @MainActor in
                    self.installLog.append(chunk)
                }
            }
            await MainActor.run {
                self.installing = false
                self.stackInstalled = StackLayout.installed
                if status != 0 {
                    self.errorMessage = "The stack build stopped before it finished."
                } else {
                    self.notice = "Stack installed."
                    self.refreshVersions()
                }
            }
        }
    }

    func openSite() {
        open(URL(string: "http://127.0.0.1:\(settings.apachePort)/"))
    }

    func openAdmin() {
        open(URL(string: "http://127.0.0.1:\(settings.apachePort)/phpmyadmin/"))
    }

    func revealWebRoot() {
        let url = activeProject?.htdocsUrl ?? StackLayout.htdocs
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealProjectFolder() {
        let url = activeProject?.rootUrl ?? StackLayout.dataRoot
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openConfig(_ name: String) {
        NSWorkspace.shared.open(StackLayout.conf.appendingPathComponent(name))
    }

    func copyDatabasePassword() {
        copy(KeychainStore.get(account: KeychainStore.databaseAccount))
    }

    func copyFTPPassword() {
        copy(KeychainStore.get(account: KeychainStore.ftpAccount))
    }

    var databasePassword: String {
        KeychainStore.get(account: KeychainStore.databaseAccount) ?? ""
    }

    var ftpPassword: String {
        KeychainStore.get(account: KeychainStore.ftpAccount) ?? ""
    }

    private func copy(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        notice = "Copied."
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        notice = nil
        Task {
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
            refresh()
            refreshLogs()
        }
    }
}
