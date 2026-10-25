import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: CampModel

    var body: some View {
        Group {
            if model.stackInstalled {
                stack
            } else {
                InstallView()
            }
        }
        .task {
            model.refresh()
            model.refreshVersions()
            model.refreshLogs()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                model.refresh()
                if model.section == .logs { model.refreshLogs() }
            }
        }
        .sheet(isPresented: secretPresented) {
            SecretSheet()
        }
    }

    private var secretPresented: Binding<Bool> {
        Binding(
            get: { model.newDatabasePassword != nil || model.newFTPPassword != nil },
            set: { presented in
                if !presented {
                    model.newDatabasePassword = nil
                    model.newFTPPassword = nil
                }
            }
        )
    }

    private var stack: some View {
        NavigationSplitView {
            List(CampSection.allCases, selection: $model.section) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 220)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if let error = model.errorMessage {
                    banner(error, tint: .red, onDismiss: { model.errorMessage = nil })
                } else if let notice = model.notice {
                    banner(notice, tint: .secondary, onDismiss: { model.notice = nil })
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationTitle(model.section.title)
            .toolbar {
                ToolbarItemGroup {
                    Button("Start all") { model.startAll() }
                        .disabled(model.busy)
                    Button("Stop all") { model.stopAll() }
                        .disabled(model.busy)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .web:
            WebView()
        case .database:
            DatabaseView()
        case .ftp:
            FTPView()
        case .logs:
            LogsView()
        case .settings:
            SettingsView()
        }
    }

    private func banner(_ text: String, tint: Color, onDismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if text.contains("\n") {
                    ScrollView(.vertical) {
                        Text(text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .foregroundStyle(tint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                } else {
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .foregroundStyle(tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(tint.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08))
    }
}

struct InstallView: View {
    @EnvironmentObject private var model: CampModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Camp")
                .font(.largeTitle)
            Text("This Mac does not have the Camp server tree yet. Install compiles Apache, PHP, MariaDB, Perl, and ProFTPD for this Mac, then unpacks phpMyAdmin. Binaries go in /opt/camp. The web root, databases, and logs stay in /Library/Application Support/Camp. macOS will ask for an administrator password once.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(model.installing ? "Installing" : "Install stack") {
                model.install()
            }
            .disabled(model.installing)
            .keyboardShortcut(.defaultAction)
            if model.installing {
                ProgressView()
                    .controlSize(.small)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            ScrollView {
                Text(model.installLog.isEmpty ? "The build log will show up here." : model.installLog)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct WebView: View {
    @EnvironmentObject private var model: CampModel

    var body: some View {
        Form {
            ServiceRow(service: .apache)
            LabeledContent("PHP", value: model.phpVersion)
            LabeledContent("Perl", value: model.perlVersion)
            LabeledContent("Document root", value: StackLayout.htdocs.path)
            LabeledContent("Address") {
                Text("127.0.0.1:\(model.settings.apachePort)")
                    .textSelection(.enabled)
            }
            HStack {
                Button("Open site") { model.openSite() }
                Button("Open phpMyAdmin") { model.openAdmin() }
                Button("Reveal in Finder") { model.revealWebRoot() }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

struct DatabaseView: View {
    @EnvironmentObject private var model: CampModel

    var body: some View {
        Form {
            ServiceRow(service: .mariadb)
            LabeledContent("Port", value: "\(model.settings.mariadbPort)")
            LabeledContent("Account", value: "root")
            LabeledContent("Password") {
                Text(model.revealedDatabase ? model.databasePassword : String(repeating: "•", count: 12))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            HStack {
                Button(model.revealedDatabase ? "Hide" : "Show") { model.revealedDatabase.toggle() }
                Button("Copy") { model.copyDatabasePassword() }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

struct FTPView: View {
    @EnvironmentObject private var model: CampModel

    var body: some View {
        Form {
            ServiceRow(service: .proftpd)
            LabeledContent("Host", value: "127.0.0.1")
            LabeledContent("Port", value: "\(model.settings.ftpPort)")
            LabeledContent("User", value: "camp")
            LabeledContent("Folder", value: StackLayout.ftp.path)
            LabeledContent("Password") {
                Text(model.revealedFTP ? model.ftpPassword : String(repeating: "•", count: 32))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            HStack {
                Button(model.revealedFTP ? "Hide" : "Show") { model.revealedFTP.toggle() }
                Button("Copy") { model.copyFTPPassword() }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

struct LogsView: View {
    @EnvironmentObject private var model: CampModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Log", selection: $model.logKind) {
                ForEach(LogKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.logKind) { _, _ in model.refreshLogs() }
            ScrollView {
                Text(model.logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: CampModel

    var body: some View {
        Form {
            Toggle("Listen on all interfaces", isOn: $model.settings.bindAllInterfaces)
            Text("FTP stays on this Mac because this build does not support encrypted FTP connections.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
            Toggle("Standard ports (80, 443, 21)", isOn: $model.settings.usePrivilegedPorts)
                .disabled(true)
            Text("Camp uses high ports to keep server processes running as your account instead of root.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Apache", value: $model.settings.apachePort, format: .number)
            TextField("HTTPS", value: $model.settings.apacheSSLPort, format: .number)
            TextField("MariaDB", value: $model.settings.mariadbPort, format: .number)
            TextField("FTP", value: $model.settings.ftpPort, format: .number)
            Button("Apply and restart running services") { model.applySettings() }
                .disabled(model.busy)
            HStack {
                Button("Apache config") { model.openConfig("httpd.conf") }
                Button("MariaDB config") { model.openConfig("my.cnf") }
                Button("PHP config") { model.openConfig("php.ini") }
                Button("FTP config") { model.openConfig("proftpd.conf") }
            }
            Text("Apache HTTP Server is Apache License 2.0. PHP is the PHP License. MariaDB, ProFTPD, and phpMyAdmin are GPL. Camp starts them as separate programs and does not link their libraries. Perl is the Artistic License and the GPL.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

struct ServiceRow: View {
    @EnvironmentObject private var model: CampModel
    let service: CampService

    var body: some View {
        LabeledContent(service.title) {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.status(for: service) == .running ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 8, height: 8)
                Text(model.status(for: service) == .running ? "Running" : "Stopped")
                    .foregroundStyle(.secondary)
                if model.status(for: service) == .running, let metrics = model.metrics(for: service) {
                    Text("(\(metrics.formattedCPU) CPU, \(metrics.formattedMemory))")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("Start") { model.start(service) }
                    .disabled(model.busy || model.status(for: service) == .running)
                Button("Stop") { model.stop(service) }
                    .disabled(model.busy || model.status(for: service) == .stopped)
                Button("Restart") { model.restart(service) }
                    .disabled(model.busy)
            }
        }
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: CampModel

    var body: some View {
        Button("Open Camp") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Text(model.menuBarSummary(for: .apache))
        Text(model.menuBarSummary(for: .mariadb))
        Text(model.menuBarSummary(for: .proftpd))
        Divider()
        Button("Start all") { model.startAll() }
        Button("Stop all") { model.stopAll() }
        Button("Open site") { model.openSite() }
        Button("Check for Updates…") { CampUpdater.shared.checkForUpdates() }
        Divider()
        Button("Quit Camp") { NSApp.terminate(nil) }
    }
}

struct SecretSheet: View {
    @EnvironmentObject private var model: CampModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save these passwords")
                .font(.title2)
            Text("They are in the login Keychain. This is the only time Camp shows the new ones together.")
                .foregroundStyle(.secondary)
            if let password = model.newDatabasePassword {
                LabeledContent("MariaDB root") {
                    Text(password).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let password = model.newFTPPassword {
                LabeledContent("FTP user camp") {
                    Text(password).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
            Button("Done") {
                model.newDatabasePassword = nil
                model.newFTPPassword = nil
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 460)
    }
}
