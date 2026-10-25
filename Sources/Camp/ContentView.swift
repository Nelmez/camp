import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: CampModel

    @State private var showNewProjectSheet = false
    @State private var showProjectSettingsSheet = false
    @State private var showDeleteProjectSheet = false
    @State private var projectToDelete: CampProject? = nil

    var body: some View {
        Group {
            if !model.stackInstalled {
                InstallView()
            } else if !model.hasProjects {
                ProjectWelcomeView(showNewProject: $showNewProjectSheet)
            } else {
                stack
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
        .sheet(isPresented: $showNewProjectSheet) {
            NewProjectSheet()
        }
        .sheet(isPresented: $showProjectSettingsSheet) {
            if let active = model.activeProject {
                ProjectSettingsSheet(project: active)
            }
        }
        .sheet(isPresented: $showDeleteProjectSheet, onDismiss: { projectToDelete = nil }) {
            if let target = projectToDelete ?? model.activeProject {
                DeleteProjectSheet(project: target)
            }
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
            VStack(spacing: 0) {
                projectHeader
                Divider()
                List(model.availableSections, selection: $model.section) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if let switchStatus = model.projectSwitchStatus {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(switchStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                } else if let error = model.errorMessage {
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
                    if let active = model.activeProject {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(model.anyRunning ? Color.green : Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(active.name)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    Button("Start all") { model.startAll() }
                        .disabled(model.busy)
                    Button("Stop all") { model.stopAll() }
                        .disabled(model.busy)
                }
            }
        }
    }

    private var projectHeader: some View {
        HStack(spacing: 8) {
            Menu {
                Section("Projects") {
                    Picker("Active Project", selection: Binding(
                        get: { model.activeProject?.id ?? "" },
                        set: { newId in
                            if let proj = model.projects.first(where: { $0.id == newId }), proj.id != model.activeProject?.id {
                                model.switchToProject(proj)
                            }
                        }
                    )) {
                        ForEach(model.projects) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Divider()
                Button {
                    showNewProjectSheet = true
                } label: {
                    Label("New Project…", systemImage: "plus")
                }
                if let active = model.activeProject {
                    Button {
                        showProjectSettingsSheet = true
                    } label: {
                        Label("Project Settings…", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        model.revealProjectFolder()
                    } label: {
                        Label("Reveal Project Folder", systemImage: "folder")
                    }
                    Divider()
                    Button(role: .destructive) {
                        projectToDelete = active
                        showDeleteProjectSheet = true
                    } label: {
                        Label("Delete Project…", systemImage: "trash")
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 28, height: 28)
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.activeProject?.name ?? "Select Project")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(projectSubtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor).opacity(model.busy ? 0.4 : 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .disabled(model.busy)

            Button {
                showNewProjectSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(model.busy ? 0.35 : 0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            .help("Create New Project")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var projectSubtitle: String {
        if let status = model.projectSwitchStatus {
            return status
        }
        guard let active = model.activeProject else { return "None" }
        return active.features.summary
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

struct ProjectWelcomeView: View {
    @EnvironmentObject private var model: CampModel
    @Binding var showNewProject: Bool
    @State private var importName = "Default Project"

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(systemName: "shippingbox.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)
                Text("Welcome to Camp Projects")
                    .font(.system(size: 28, weight: .bold))
                Text("Organize your websites and databases into self-contained projects. Easily switch between them with custom feature sets.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            HStack(spacing: 20) {
                if ProjectManager.shared.hasLegacyData {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            Text("Import Existing Files")
                                .font(.headline)
                        }
                        Text("Camp detected files in your current installation. Import them into an isolated project to keep working seamlessly.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("Project Name", text: $importName)
                            .textFieldStyle(.roundedBorder)
                        Button("Import as Project") {
                            model.migrateLegacy(name: importName)
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(importName.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                    }
                    .padding(20)
                    .frame(maxWidth: 320, minHeight: 220, alignment: .topLeading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "plus.square.fill")
                            .font(.title2)
                            .foregroundStyle(Color.green)
                        Text("Create New Project")
                            .font(.headline)
                    }
                    Text("Start fresh with a brand new project. Choose only the features you need (Apache, MariaDB, FTP) and select a starter template.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Create First Project…") {
                        showNewProject = true
                    }
                    .keyboardShortcut(ProjectManager.shared.hasLegacyData ? .none : .defaultAction)
                }
                .padding(20)
                .frame(maxWidth: 320, minHeight: 220, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: CampModel

    @State private var name = ""
    @State private var enableApache = true
    @State private var enableMariaDB = true
    @State private var enablePhpMyAdmin = true
    @State private var enableFTP = false
    @State private var selectedTemplate: ProjectTemplate = .blank

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Project")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Create an isolated environment for your web application.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Form {
                Section("Project Details") {
                    TextField("Project Name (e.g. My Portfolio, Shop, Client Site)", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Enabled Features") {
                    Toggle("Apache & PHP (Web Server)", isOn: $enableApache)
                        .onChange(of: enableApache) { _, on in
                            if !on { enablePhpMyAdmin = false }
                        }
                    Toggle("MariaDB (Database Engine)", isOn: $enableMariaDB)
                        .onChange(of: enableMariaDB) { _, on in
                            if !on { enablePhpMyAdmin = false }
                        }
                    Toggle("phpMyAdmin (Web Database Manager)", isOn: $enablePhpMyAdmin)
                        .disabled(!enableMariaDB || !enableApache)
                        .onChange(of: enablePhpMyAdmin) { _, on in
                            if on {
                                enableMariaDB = true
                                enableApache = true
                            }
                        }
                    Toggle("ProFTPD (FTP Server scoped to project)", isOn: $enableFTP)
                }

                Section("Starter Template") {
                    Picker("Template", selection: $selectedTemplate) {
                        ForEach(ProjectTemplate.allCases) { tmpl in
                            HStack {
                                Image(systemName: tmpl.icon)
                                Text(tmpl.title)
                                Text("— \(tmpl.subtitle)")
                                    .foregroundStyle(.secondary)
                            }
                            .tag(tmpl)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: selectedTemplate) { _, tmpl in
                        switch tmpl {
                        case .blank:
                            enableApache = true
                        case .php:
                            enableApache = true
                        case .wordpress:
                            enableApache = true
                            enableMariaDB = true
                        case .phpmyadmin:
                            enableApache = true
                            enableMariaDB = true
                            enablePhpMyAdmin = true
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create Project") {
                    let features = ProjectFeatures(
                        apache: enableApache,
                        mariadb: enableMariaDB,
                        phpMyAdmin: enablePhpMyAdmin,
                        ftp: enableFTP
                    )
                    model.createProject(name: name, features: features, template: selectedTemplate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 480, maxHeight: 560)
    }
}

struct ProjectSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: CampModel

    let project: CampProject

    @State private var name: String
    @State private var enableApache: Bool
    @State private var enableMariaDB: Bool
    @State private var enablePhpMyAdmin: Bool
    @State private var enableFTP: Bool

    init(project: CampProject) {
        self.project = project
        _name = State(initialValue: project.name)
        _enableApache = State(initialValue: project.features.apache)
        _enableMariaDB = State(initialValue: project.features.mariadb)
        _enablePhpMyAdmin = State(initialValue: project.features.phpMyAdmin)
        _enableFTP = State(initialValue: project.features.ftp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Project Settings")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Configure features and options for “\(project.name)”.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Form {
                Section("Project Details") {
                    TextField("Project Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                    LabeledContent("Project ID", value: project.id)
                    LabeledContent("Created", value: project.createdAt.formatted(date: .abbreviated, time: .shortened))
                }

                Section("Feature Toggles") {
                    Toggle("Apache & PHP (Web Server)", isOn: $enableApache)
                        .onChange(of: enableApache) { _, on in
                            if !on { enablePhpMyAdmin = false }
                        }
                    Toggle("MariaDB (Database Engine)", isOn: $enableMariaDB)
                        .onChange(of: enableMariaDB) { _, on in
                            if !on { enablePhpMyAdmin = false }
                        }
                    Toggle("phpMyAdmin (Requires Apache + MariaDB)", isOn: $enablePhpMyAdmin)
                        .disabled(!enableMariaDB || !enableApache)
                        .onChange(of: enablePhpMyAdmin) { _, on in
                            if on {
                                enableMariaDB = true
                                enableApache = true
                            }
                        }
                    Toggle("ProFTPD (FTP Server)", isOn: $enableFTP)
                }

                Section("Directories") {
                    LabeledContent("Root", value: project.rootUrl.path)
                    LabeledContent("Web Root", value: project.htdocsUrl.path)
                    if enableMariaDB {
                        LabeledContent("Database", value: project.mysqlDataUrl.path)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Changes") {
                    var updated = project
                    updated.name = name.trimmingCharacters(in: .whitespaces)
                    updated.features = ProjectFeatures(
                        apache: enableApache,
                        mariadb: enableMariaDB,
                        phpMyAdmin: enablePhpMyAdmin,
                        ftp: enableFTP
                    )
                    model.updateProject(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520, height: 500)
    }
}

struct DeleteProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: CampModel

    let project: CampProject
    @State private var moveToTrash = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete Project “\(project.name)”")
                .font(.title2)
                .fontWeight(.bold)

            Text("Are you sure you want to remove this project from Camp? If any services are running for this project, they will be stopped.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Move project files and database to macOS Trash", isOn: $moveToTrash)
                .padding(.vertical, 4)

            Text(moveToTrash
                 ? "Files in \(project.rootUrl.path) will be moved to macOS Trash."
                 : "Files will remain on disk in \(project.rootUrl.path), but the project will be removed from Camp.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Delete Project", role: .destructive) {
                    model.deleteProject(project, moveToTrash: moveToTrash)
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 480)
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
            if let project = model.activeProject {
                LabeledContent("Project", value: project.name)
                LabeledContent("Document root", value: project.htdocsUrl.path)
            } else {
                LabeledContent("Document root", value: StackLayout.htdocs.path)
            }
            LabeledContent("PHP", value: model.phpVersion)
            LabeledContent("Perl", value: model.perlVersion)
            LabeledContent("Address") {
                Text("127.0.0.1:\(model.settings.apachePort)")
                    .textSelection(.enabled)
            }
            HStack {
                Button("Open site") { model.openSite() }
                if model.activeProject?.features.phpMyAdmin == true {
                    Button("Open phpMyAdmin") { model.openAdmin() }
                }
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
            if let project = model.activeProject {
                LabeledContent("Project", value: project.name)
                LabeledContent("Data folder", value: project.mysqlDataUrl.path)
            } else {
                LabeledContent("Data folder", value: StackLayout.mysqlData.path)
            }
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
                if model.activeProject?.features.phpMyAdmin == true {
                    Button("Open phpMyAdmin") { model.openAdmin() }
                }
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
            if let project = model.activeProject {
                LabeledContent("Project", value: project.name)
                LabeledContent("Folder", value: project.rootUrl.path)
            } else {
                LabeledContent("Folder", value: StackLayout.ftp.path)
            }
            LabeledContent("Host", value: "127.0.0.1")
            LabeledContent("Port", value: "\(model.settings.ftpPort)")
            LabeledContent("User", value: "camp")
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
        if let project = model.activeProject {
            Text("Project: \(project.name)")
            if model.projects.count > 1 {
                Menu("Switch Project") {
                    ForEach(model.projects) { proj in
                        Button {
                            if model.activeProject?.id != proj.id {
                                model.switchToProject(proj)
                            }
                        } label: {
                            if model.activeProject?.id == proj.id {
                                Text("✓ \(proj.name)")
                            } else {
                                Text(proj.name)
                            }
                        }
                    }
                }
            }
            Divider()
        }
        if model.activeProject?.features.apache != false {
            Text(model.menuBarSummary(for: .apache))
        }
        if model.activeProject?.features.mariadb != false {
            Text(model.menuBarSummary(for: .mariadb))
        }
        if model.activeProject?.features.ftp != false {
            Text(model.menuBarSummary(for: .proftpd))
        }
        Divider()
        Button("Start all") { model.startAll() }
        Button("Stop all") { model.stopAll() }
        if model.activeProject?.features.apache != false {
            Button("Open site") { model.openSite() }
        }
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
