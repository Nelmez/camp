import AppKit
import Foundation

@MainActor
final class CampModel: ObservableObject {
    @Published var section: CampSection = .web
    @Published var settings: CampSettings
    @Published var apache: ServiceStatus = .stopped
    @Published var mariadb: ServiceStatus = .stopped
    @Published var proftpd: ServiceStatus = .stopped
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

    private let controller = ServiceController()
    private var refreshing = false

    init() {
        settings = CampSettings.load()
        stackInstalled = StackLayout.installed
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

    func refresh() {
        stackInstalled = StackLayout.installed
        guard stackInstalled, !refreshing else { return }
        refreshing = true
        let snapshot = settings
        Task.detached {
            let controller = ServiceController()
            let apache = controller.status(.apache, settings: snapshot)
            let mariadb = controller.status(.mariadb, settings: snapshot)
            let proftpd = controller.status(.proftpd, settings: snapshot)
            await MainActor.run {
                self.apache = apache
                self.mariadb = mariadb
                self.proftpd = proftpd
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
        if !FileManager.default.fileExists(atPath: StackLayout.marker.path) {
            let report = try await Task.detached { try StackBootstrap().run(settings: snapshot) }.value
            newDatabasePassword = report.databasePassword
            newFTPPassword = report.ftpPassword
        }
        try await Task.detached { try ConfigWriter().write(settings: try snapshot.validated()) }.value
        settings = try snapshot.validated()
        settings.save()
    }

    func start(_ service: CampService) {
        run {
            try await self.prepareIfNeeded()
            let snapshot = self.settings
            try await Task.detached { try ServiceController().start(service, settings: snapshot) }.value
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
            try await Task.detached { try ServiceController().start(service, settings: snapshot) }.value
        }
    }

    func startAll() {
        run {
            try await self.prepareIfNeeded()
            let snapshot = self.settings
            try await Task.detached {
                let controller = ServiceController()
                for service in CampService.allCases {
                    try controller.start(service, settings: snapshot)
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
            try await Task.detached { try ConfigWriter().write(settings: draft) }.value
            if FileManager.default.fileExists(atPath: StackLayout.marker.path) {
                let password = KeychainStore.get(account: KeychainStore.databaseAccount) ?? ""
                let blowfish = try KeychainStore.get(account: KeychainStore.blowfishAccount) ?? Secrets.password(length: 32)
                try await Task.detached {
                    try ConfigWriter().writeWebFiles(
                        databasePassword: password,
                        port: draft.mariadbPort,
                        blowfish: blowfish,
                        bindAllInterfaces: draft.bindAllInterfaces
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
        NSWorkspace.shared.activateFileViewerSelecting([StackLayout.htdocs])
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
