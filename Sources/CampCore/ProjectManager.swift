import Foundation

enum ProjectTemplate: String, Codable, CaseIterable, Identifiable {
    case blank
    case php
    case wordpress
    case phpmyadmin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "Blank (HTML)"
        case .php: return "Basic PHP"
        case .wordpress: return "WordPress Ready"
        case .phpmyadmin: return "phpMyAdmin Test"
        }
    }

    var subtitle: String {
        switch self {
        case .blank: return "Minimal HTML5 template"
        case .php: return "PHP test script with phpinfo()"
        case .wordpress: return "MariaDB check & WordPress starter"
        case .phpmyadmin: return "MariaDB check & phpMyAdmin link"
        }
    }

    var icon: String {
        switch self {
        case .blank: return "doc.text"
        case .php: return "chevron.left.forwardslash.chevron.right"
        case .wordpress: return "w.circle"
        case .phpmyadmin: return "cylinder.split.1x2"
        }
    }
}

struct ProjectFeatures: Codable, Equatable {
    var apache: Bool
    var mariadb: Bool
    var phpMyAdmin: Bool
    var ftp: Bool

    init(apache: Bool = true, mariadb: Bool = true, phpMyAdmin: Bool = true, ftp: Bool = false) {
        self.apache = apache
        self.mariadb = mariadb
        // phpMyAdmin requires MariaDB and Apache
        self.phpMyAdmin = phpMyAdmin && mariadb && apache
        self.ftp = ftp
    }

    static let all = ProjectFeatures(apache: true, mariadb: true, phpMyAdmin: true, ftp: true)
    static let standard = ProjectFeatures(apache: true, mariadb: true, phpMyAdmin: true, ftp: false)

    var summary: String {
        var items: [String] = []
        if apache { items.append("Apache") }
        if mariadb { items.append("MariaDB") }
        if phpMyAdmin { items.append("phpMyAdmin") }
        if ftp { items.append("FTP") }
        return items.isEmpty ? "None" : items.joined(separator: ", ")
    }
}

struct CampProject: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var createdAt: Date
    var features: ProjectFeatures
    var template: ProjectTemplate?

    init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        createdAt: Date = Date(),
        features: ProjectFeatures = .standard,
        template: ProjectTemplate? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.features = features
        self.template = template
    }

    var rootUrl: URL {
        StackLayout.projectsRoot.appendingPathComponent(id, isDirectory: true)
    }

    var htdocsUrl: URL {
        rootUrl.appendingPathComponent("htdocs", isDirectory: true)
    }

    var mysqlDataUrl: URL {
        rootUrl.appendingPathComponent("mysql", isDirectory: true)
    }

    var manifestUrl: URL {
        rootUrl.appendingPathComponent("project.json")
    }

    var isMariaDBInitialized: Bool {
        FileManager.default.fileExists(atPath: mysqlDataUrl.appendingPathComponent("mysql").path)
    }
}

struct ProjectsConfig: Codable {
    var activeProjectId: String?
    var projects: [CampProject]

    init(activeProjectId: String? = nil, projects: [CampProject] = []) {
        self.activeProjectId = activeProjectId
        self.projects = projects
    }
}

final class ProjectManager {
    static let shared = ProjectManager()

    private let fileManager = FileManager.default

    init() {}

    func load() -> ProjectsConfig {
        if let data = try? Data(contentsOf: StackLayout.projectsConfig),
           let config = try? JSONDecoder().decode(ProjectsConfig.self, from: data) {
            return config
        }

        // Check if individual project directories exist in projectsRoot
        var discovered: [CampProject] = []
        if let items = try? fileManager.contentsOfDirectory(at: StackLayout.projectsRoot, includingPropertiesForKeys: nil) {
            for item in items where item.hasDirectoryPath {
                let manifest = item.appendingPathComponent("project.json")
                if let data = try? Data(contentsOf: manifest),
                   let project = try? JSONDecoder().decode(CampProject.self, from: data) {
                    discovered.append(project)
                }
            }
        }

        if !discovered.isEmpty {
            let active = discovered.first?.id
            let config = ProjectsConfig(activeProjectId: active, projects: discovered)
            try? save(config: config)
            return config
        }

        return ProjectsConfig(activeProjectId: nil, projects: [])
    }

    func save(config: ProjectsConfig) throws {
        try StackLayout.ensureDataDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: StackLayout.projectsConfig, options: .atomic)

        // Also write individual project manifests
        for project in config.projects {
            try? fileManager.createDirectory(at: project.rootUrl, withIntermediateDirectories: true)
            let projectData = try encoder.encode(project)
            try? projectData.write(to: project.manifestUrl, options: .atomic)
        }
    }

    func getActiveProject(in config: ProjectsConfig) -> CampProject? {
        guard let id = config.activeProjectId else {
            return config.projects.first
        }
        return config.projects.first { $0.id == id } ?? config.projects.first
    }

    var activeProject: CampProject? {
        getActiveProject(in: load())
    }

    func sanitizeId(name: String, existingProjects: [CampProject]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet.alphanumerics
        var slug = trimmed.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { result, char in
                if char == "-" && result.last == "-" { return }
                result.append(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if slug.isEmpty {
            slug = "project"
        }

        var candidate = slug
        var counter = 2
        let existingIds = Set(existingProjects.map { $0.id.lowercased() })
        while existingIds.contains(candidate.lowercased()) || fileManager.fileExists(atPath: StackLayout.projectsRoot.appendingPathComponent(candidate).path) {
            candidate = "\(slug)-\(counter)"
            counter += 1
        }
        return candidate
    }

    @discardableResult
    func createProject(
        name: String,
        id: String? = nil,
        features: ProjectFeatures,
        template: ProjectTemplate = .blank,
        settings: CampSettings
    ) throws -> CampProject {
        var config = load()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty {
            throw StackError.message("Project name cannot be empty.")
        }

        let projectId = (id?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? sanitizeId(name: cleanName, existingProjects: config.projects)

        let project = CampProject(
            id: projectId,
            name: cleanName,
            createdAt: Date(),
            features: features,
            template: template
        )

        // Create directories
        try fileManager.createDirectory(at: project.rootUrl, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: project.htdocsUrl, withIntermediateDirectories: true)
        let readme = project.rootUrl.appendingPathComponent("README.txt")
        if !fileManager.fileExists(atPath: readme.path) {
            let text = "Welcome to Camp. Upload web assets to your document root or use this folder for FTP transfers.\n"
            try? text.write(to: readme, atomically: true, encoding: .utf8)
        }
        try fileManager.createDirectory(at: project.htdocsUrl.appendingPathComponent("cgi-bin"), withIntermediateDirectories: true)

        if features.mariadb {
            try fileManager.createDirectory(at: project.mysqlDataUrl, withIntermediateDirectories: true)
        }

        // Provision template files
        provisionTemplate(template, for: project, settings: settings)

        config.projects.append(project)
        if config.activeProjectId == nil {
            config.activeProjectId = project.id
        }
        try save(config: config)
        return project
    }

    func updateProject(_ project: CampProject, settings: CampSettings, controller: ServiceController) throws {
        var config = load()
        guard let index = config.projects.firstIndex(where: { $0.id == project.id }) else {
            throw StackError.message("Project '\(project.name)' not found.")
        }
        config.projects[index] = project
        try save(config: config)

        if config.activeProjectId == project.id {
            // Re-apply services based on updated features
            _ = try switchProject(to: project.id, settings: settings, controller: controller)
        }
    }

    func deleteProject(
        id: String,
        moveToTrash: Bool,
        settings: CampSettings,
        controller: ServiceController
    ) throws {
        var config = load()
        guard let index = config.projects.firstIndex(where: { $0.id == id }) else {
            throw StackError.message("Project with id '\(id)' not found.")
        }
        let project = config.projects[index]
        let wasActive = (config.activeProjectId == id)

        if wasActive {
            // Stop services before moving/deleting files
            for service in CampService.allCases {
                controller.stop(service, settings: settings)
            }
        }

        if moveToTrash && fileManager.fileExists(atPath: project.rootUrl.path) {
            try fileManager.trashItem(at: project.rootUrl, resultingItemURL: nil)
        }

        config.projects.remove(at: index)

        if wasActive {
            config.activeProjectId = config.projects.first?.id
            try save(config: config)
            if let nextProject = config.projects.first {
                _ = try switchProject(to: nextProject.id, settings: settings, controller: controller)
            } else {
                // No projects left, rewrite configs without project
                try ConfigWriter().write(settings: try settings.validated(), project: nil)
            }
        } else {
            try save(config: config)
        }
    }

    @discardableResult
    func switchProject(
        to target: String,
        settings: CampSettings,
        controller: ServiceController
    ) throws -> CampProject {
        var config = load()
        guard let project = config.projects.first(where: {
            $0.id.lowercased() == target.lowercased() || $0.name.localizedCaseInsensitiveCompare(target) == .orderedSame
        }) else {
            throw StackError.message("Project '\(target)' not found.")
        }

        let validatedSettings = try settings.validated()

        // 1. Stop all currently running services
        for service in CampService.allCases {
            controller.stop(service, settings: validatedSettings)
        }

        // Wait briefly for launchd and socket cleanup
        if fileManager.fileExists(atPath: StackLayout.mysqlSocket.path) {
            try? fileManager.removeItem(at: StackLayout.mysqlSocket)
        }

        // 2. Ensure project directories exist
        try fileManager.createDirectory(at: project.rootUrl, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: project.htdocsUrl, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: project.htdocsUrl.appendingPathComponent("cgi-bin"), withIntermediateDirectories: true)
        let readme = project.rootUrl.appendingPathComponent("README.txt")
        if !fileManager.fileExists(atPath: readme.path) {
            let text = "Welcome to Camp. Upload web assets to your document root or use this folder for FTP transfers.\n"
            try? text.write(to: readme, atomically: true, encoding: .utf8)
        }

        // 3. If MariaDB is enabled, ensure database is initialized
        if project.features.mariadb {
            try fileManager.createDirectory(at: project.mysqlDataUrl, withIntermediateDirectories: true)
            if !project.isMariaDBInitialized {
                try StackBootstrap().installDatabase(datadir: project.mysqlDataUrl)
            }
        }

        // 4. Update config files pointing to this project's directories and features
        try ConfigWriter().write(settings: validatedSettings, project: project)

        // Save active project so config files and activeProjectId stay in sync
        config.activeProjectId = project.id
        try save(config: config)

        // 5. Update credentials files for phpMyAdmin
        if project.features.mariadb {
            let password = KeychainStore.get(account: KeychainStore.databaseAccount) ?? ""
            let blowfish = KeychainStore.get(account: KeychainStore.blowfishAccount) ?? (try? Secrets.password(length: 32)) ?? "abcdef0123456789abcdef0123456789"
            try ConfigWriter().writeWebFiles(
                databasePassword: password,
                port: validatedSettings.mariadbPort,
                blowfish: blowfish,
                bindAllInterfaces: validatedSettings.bindAllInterfaces,
                project: project
            )
        }

        // 6. Update FTP user home directory if FTP enabled
        if project.features.ftp {
            try updateFTPUserHome(home: project.rootUrl)
        }

        // 7. Start enabled services
        if project.features.mariadb {
            try controller.start(.mariadb, settings: validatedSettings)
            try StackBootstrap().waitForDatabase(port: validatedSettings.mariadbPort)
            _ = try StackBootstrap().ensureDatabasePassword(port: validatedSettings.mariadbPort, settings: validatedSettings)
        }

        if project.features.apache {
            try controller.start(.apache, settings: validatedSettings)
        }

        if project.features.ftp {
            try controller.start(.proftpd, settings: validatedSettings)
        }

        return project
    }

    func updateFTPUserHome(home: URL) throws {
        let passwd = StackLayout.conf.appendingPathComponent("ftpd.passwd")
        guard fileManager.fileExists(atPath: passwd.path),
              let text = try? String(contentsOf: passwd, encoding: .utf8) else {
            return
        }
        let lines = text.components(separatedBy: "\n")
        var newLines: [String] = []
        for line in lines {
            if line.hasPrefix("camp:") {
                var parts = line.components(separatedBy: ":")
                if parts.count >= 7 {
                    parts[5] = home.path
                    newLines.append(parts.joined(separator: ":"))
                    continue
                }
            }
            newLines.append(line)
        }
        try newLines.joined(separator: "\n").write(to: passwd, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwd.path)
    }

    var hasLegacyData: Bool {
        let htdocsItems = (try? fileManager.contentsOfDirectory(atPath: StackLayout.htdocs.path)) ?? []
        let userHtdocs = htdocsItems.filter { $0 != "phpmyadmin" && !$0.hasPrefix(".") }
        let mysqlItems = (try? fileManager.contentsOfDirectory(atPath: StackLayout.mysqlData.path)) ?? []
        return !userHtdocs.isEmpty || !mysqlItems.isEmpty
    }

    @discardableResult
    func migrateLegacy(
        name: String = "Default Project",
        settings: CampSettings,
        controller: ServiceController
    ) throws -> CampProject {
        var config = load()
        let id = sanitizeId(name: name, existingProjects: config.projects)
        let hasDB = fileManager.fileExists(atPath: StackLayout.mysqlData.appendingPathComponent("mysql").path)
        let hasPMA = fileManager.fileExists(atPath: StackLayout.sharedPhpMyAdmin.appendingPathComponent("index.php").path)

        let project = CampProject(
            id: id,
            name: name,
            createdAt: Date(),
            features: ProjectFeatures(
                apache: true,
                mariadb: hasDB,
                phpMyAdmin: hasDB && hasPMA,
                ftp: true
            ),
            template: .php
        )

        // Stop services before copying files so MariaDB data is flushed cleanly
        for service in CampService.allCases {
            controller.stop(service, settings: settings)
        }

        try fileManager.createDirectory(at: project.rootUrl, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: project.htdocsUrl, withIntermediateDirectories: true)
        let readme = project.rootUrl.appendingPathComponent("README.txt")
        if !fileManager.fileExists(atPath: readme.path) {
            let text = "Welcome to Camp. Upload web assets to your document root or use this folder for FTP transfers.\n"
            try? text.write(to: readme, atomically: true, encoding: .utf8)
        }

        // Copy files from legacy htdocs (excluding phpmyadmin)
        if fileManager.fileExists(atPath: StackLayout.htdocs.path) {
            let items = (try? fileManager.contentsOfDirectory(atPath: StackLayout.htdocs.path)) ?? []
            for item in items where item != "phpmyadmin" {
                let src = StackLayout.htdocs.appendingPathComponent(item)
                let dst = project.htdocsUrl.appendingPathComponent(item)
                if !fileManager.fileExists(atPath: dst.path) {
                    try? fileManager.copyItem(at: src, to: dst)
                }
            }
        }

        // Copy legacy mysql data if present
        if hasDB {
            try fileManager.createDirectory(at: project.mysqlDataUrl, withIntermediateDirectories: true)
            let items = (try? fileManager.contentsOfDirectory(atPath: StackLayout.mysqlData.path)) ?? []
            for item in items {
                let src = StackLayout.mysqlData.appendingPathComponent(item)
                let dst = project.mysqlDataUrl.appendingPathComponent(item)
                if !fileManager.fileExists(atPath: dst.path) {
                    try? fileManager.copyItem(at: src, to: dst)
                }
            }
        }

        config.projects.append(project)
        config.activeProjectId = project.id
        try save(config: config)

        // Switch to the newly migrated project
        return try switchProject(to: project.id, settings: settings, controller: controller)
    }

    func provisionTemplate(_ template: ProjectTemplate, for project: CampProject, settings: CampSettings) {
        let htdocs = project.htdocsUrl
        let projectName = project.name
        let port = settings.mariadbPort

        switch template {
        case .blank:
            let html = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>\(projectName) - Camp</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: #f6f8fa; color: #24292f; }
                    .card { background: white; padding: 40px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.08); text-align: center; max-width: 480px; }
                    h1 { margin-top: 0; color: #0969da; }
                    p { color: #57606a; line-height: 1.6; }
                    code { background: #f6f8fa; padding: 2px 6px; border-radius: 4px; font-family: ui-monospace, SFMono-Regular, monospace; }
                </style>
            </head>
            <body>
                <div class="card">
                    <h1>\(projectName)</h1>
                    <p>Your project is ready. Add web files to <code>htdocs</code> to get started.</p>
                </div>
            </body>
            </html>
            """
            try? html.write(to: htdocs.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        case .php:
            let php = """
            <?php
            $projectName = "\(projectName)";
            $phpVersion = phpversion();
            $serverSoftware = $_SERVER['SERVER_SOFTWARE'] ?? 'Apache';
            $documentRoot = $_SERVER['DOCUMENT_ROOT'] ?? __DIR__;
            ?>
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title><?= htmlspecialchars($projectName) ?> - Camp</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f6f8fa; color: #24292f; margin: 0; padding: 40px 20px; display: flex; justify-content: center; }
                    .card { background: white; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.06); padding: 36px; max-width: 600px; width: 100%; }
                    h1 { margin-top: 0; color: #0969da; font-size: 26px; }
                    .badge { display: inline-block; background: #dafbe1; color: #1a7f37; padding: 4px 10px; border-radius: 20px; font-size: 13px; font-weight: 600; margin-bottom: 20px; }
                    .info-table { width: 100%; border-collapse: collapse; margin-top: 20px; }
                    .info-table td { padding: 10px 0; border-bottom: 1px solid #eaeef2; font-size: 14px; }
                    .info-table td:first-child { color: #57606a; width: 140px; }
                    .info-table td:last-child { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
                    .actions { margin-top: 24px; display: flex; gap: 12px; }
                    .btn { display: inline-block; background: #0969da; color: white; padding: 8px 16px; border-radius: 6px; text-decoration: none; font-size: 14px; font-weight: 500; }
                    .btn-secondary { background: #f3f4f6; color: #24292f; }
                </style>
            </head>
            <body>
                <div class="card">
                    <span class="badge">PHP Running</span>
                    <h1><?= htmlspecialchars($projectName) ?></h1>
                    <p>PHP is working properly in this project.</p>
                    <table class="info-table">
                        <tr><td>PHP Version</td><td><?= htmlspecialchars($phpVersion) ?></td></tr>
                        <tr><td>Server</td><td><?= htmlspecialchars($serverSoftware) ?></td></tr>
                        <tr><td>Document Root</td><td><?= htmlspecialchars($documentRoot) ?></td></tr>
                    </table>
                    <div class="actions">
                        <a href="?phpinfo=1" class="btn btn-secondary">View phpinfo()</a>
                    </div>
                    <?php if (isset($_GET['phpinfo'])) { echo '<hr style="margin-top:30px;">'; phpinfo(); } ?>
                </div>
            </body>
            </html>
            """
            try? php.write(to: htdocs.appendingPathComponent("index.php"), atomically: true, encoding: .utf8)

        case .wordpress:
            let wpIndex = """
            <?php
            $projectName = "\(projectName)";
            $port = \(port);
            $user = 'root';
            $pass = '';
            if (file_exists('/Library/Application Support/Camp/conf/camp-web.php')) {
                $campDb = require '/Library/Application Support/Camp/conf/camp-web.php';
                $pass = $campDb['password'] ?? '';
            }

            $connected = false;
            $error = null;
            if (extension_loaded('mysqli')) {
                $mysqli = @new mysqli('127.0.0.1', $user, $pass, '', $port);
                if ($mysqli->connect_error) {
                    $error = $mysqli->connect_error;
                } else {
                    $connected = true;
                    $mysqli->query("CREATE DATABASE IF NOT EXISTS `wordpress` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
                    $mysqli->close();
                }
            }
            ?>
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title><?= htmlspecialchars($projectName) ?> - WordPress Ready</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f6f8fa; color: #24292f; margin: 0; padding: 40px 20px; display: flex; justify-content: center; }
                    .card { background: white; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.06); padding: 36px; max-width: 640px; width: 100%; }
                    h1 { margin-top: 0; color: #21759b; font-size: 26px; }
                    .status-badge { display: inline-block; padding: 4px 10px; border-radius: 20px; font-size: 13px; font-weight: 600; margin-bottom: 20px; }
                    .status-ok { background: #dafbe1; color: #1a7f37; }
                    .status-err { background: #ffebe9; color: #cf222e; }
                    .info-table { width: 100%; border-collapse: collapse; margin: 20px 0; }
                    .info-table td { padding: 10px 0; border-bottom: 1px solid #eaeef2; font-size: 14px; }
                    .info-table td:first-child { color: #57606a; width: 160px; }
                    .info-table td:last-child { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
                    .step { background: #f6f8fa; border-left: 4px solid #21759b; padding: 14px 16px; margin-top: 20px; border-radius: 0 6px 6px 0; font-size: 14px; line-height: 1.5; }
                    code { background: #eaeef2; padding: 2px 5px; border-radius: 3px; font-family: ui-monospace, monospace; }
                </style>
            </head>
            <body>
                <div class="card">
                    <?php if ($connected): ?>
                        <span class="status-badge status-ok">MariaDB Connected</span>
                    <?php else: ?>
                        <span class="status-badge status-err">Database Not Connected: <?= htmlspecialchars($error ?? 'Unknown error') ?></span>
                    <?php endif; ?>
                    <h1><?= htmlspecialchars($projectName) ?></h1>
                    <p>This project is configured and ready for WordPress.</p>
                    <table class="info-table">
                        <tr><td>Database Host</td><td>127.0.0.1:\(port)</td></tr>
                        <tr><td>Database Name</td><td>wordpress</td></tr>
                        <tr><td>Database User</td><td>root</td></tr>
                        <tr><td>Database Password</td><td>(from Camp Database tab)</td></tr>
                    </table>
                    <div class="step">
                        <strong>Ready to install:</strong> Download WordPress from <a href="https://wordpress.org/download/" target="_blank">wordpress.org</a>, extract files into this project's <code>htdocs</code> directory, and reload this page to start the installation.
                    </div>
                </div>
            </body>
            </html>
            """
            try? wpIndex.write(to: htdocs.appendingPathComponent("index.php"), atomically: true, encoding: .utf8)

        case .phpmyadmin:
            let pmaIndex = """
            <?php
            $projectName = "\(projectName)";
            $port = \(port);
            $user = 'root';
            $pass = '';
            if (file_exists('/Library/Application Support/Camp/conf/camp-web.php')) {
                $campDb = require '/Library/Application Support/Camp/conf/camp-web.php';
                $pass = $campDb['password'] ?? '';
            }

            $connected = false;
            $version = '';
            $databases = [];
            $error = null;

            if (extension_loaded('mysqli')) {
                $mysqli = @new mysqli('127.0.0.1', $user, $pass, '', $port);
                if ($mysqli->connect_error) {
                    $error = $mysqli->connect_error;
                } else {
                    $connected = true;
                    $version = $mysqli->server_info;
                    if ($res = $mysqli->query("SHOW DATABASES")) {
                        while ($row = $res->fetch_row()) {
                            $databases[] = $row[0];
                        }
                    }
                    $mysqli->close();
                }
            }
            ?>
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title><?= htmlspecialchars($projectName) ?> - phpMyAdmin Test</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f6f8fa; color: #24292f; margin: 0; padding: 40px 20px; display: flex; justify-content: center; }
                    .card { background: white; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.06); padding: 36px; max-width: 600px; width: 100%; }
                    h1 { margin-top: 0; color: #f39c12; font-size: 26px; }
                    .status-badge { display: inline-block; padding: 4px 10px; border-radius: 20px; font-size: 13px; font-weight: 600; margin-bottom: 20px; }
                    .status-ok { background: #dafbe1; color: #1a7f37; }
                    .status-err { background: #ffebe9; color: #cf222e; }
                    .info-table { width: 100%; border-collapse: collapse; margin: 20px 0; }
                    .info-table td { padding: 10px 0; border-bottom: 1px solid #eaeef2; font-size: 14px; }
                    .info-table td:first-child { color: #57606a; width: 160px; }
                    .info-table td:last-child { font-family: ui-monospace, SFMono-Regular, monospace; }
                    .btn { display: inline-block; background: #f39c12; color: white; padding: 10px 20px; border-radius: 6px; text-decoration: none; font-size: 14px; font-weight: 600; }
                    .btn:hover { background: #e67e22; }
                    ul { margin: 8px 0; padding-left: 20px; font-family: ui-monospace, SFMono-Regular, monospace; font-size: 13px; }
                </style>
            </head>
            <body>
                <div class="card">
                    <?php if ($connected): ?>
                        <span class="status-badge status-ok">MariaDB Connected</span>
                    <?php else: ?>
                        <span class="status-badge status-err">MariaDB Error: <?= htmlspecialchars($error ?? 'Unknown error') ?></span>
                    <?php endif; ?>
                    <h1><?= htmlspecialchars($projectName) ?></h1>
                    <p>Database integration and phpMyAdmin test page.</p>
                    <table class="info-table">
                        <tr><td>Server Version</td><td><?= htmlspecialchars($version ?: 'N/A') ?></td></tr>
                        <tr><td>Host & Port</td><td>127.0.0.1:\(port)</td></tr>
                        <tr><td>Active Databases</td><td><?= count($databases) ?> found</td></tr>
                    </table>
                    <?php if (!empty($databases)): ?>
                        <p><strong>Databases in this project:</strong></p>
                        <ul>
                            <?php foreach ($databases as $db): ?>
                                <li><?= htmlspecialchars($db) ?></li>
                            <?php endforeach; ?>
                        </ul>
                    <?php endif; ?>
                    <div style="margin-top: 24px;">
                        <a href="/phpmyadmin/" class="btn">Launch phpMyAdmin &rarr;</a>
                    </div>
                </div>
            </body>
            </html>
            """
            try? pmaIndex.write(to: htdocs.appendingPathComponent("index.php"), atomically: true, encoding: .utf8)
        }
    }
}
