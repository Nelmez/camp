import Foundation

struct ConfigWriter {
    func write(settings: CampSettings, project: CampProject? = nil) throws {
        try StackLayout.ensureDataDirectories()
        if let project {
            try FileManager.default.createDirectory(at: project.rootUrl, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project.htdocsUrl, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project.htdocsUrl.appendingPathComponent("cgi-bin"), withIntermediateDirectories: true)
            if project.features.mariadb {
                try FileManager.default.createDirectory(at: project.mysqlDataUrl, withIntermediateDirectories: true)
            }
        }
        let values = try baseValues(settings: settings, project: project)
        try writeFile(StackLayout.conf.appendingPathComponent("my.cnf"), try TemplateStore.render("my.cnf.tmpl", values))
        try writePHPIni(values: values)
        try writeFile(StackLayout.conf.appendingPathComponent("proftpd.conf"), try TemplateStore.render("proftpd.conf.tmpl", values))
        try writeApacheConfig(settings: settings, project: project)
        try writeAutostart(settings)
    }

    func writeApacheConfig(settings: CampSettings, project: CampProject? = nil) throws {
        try StackLayout.ensureDataDirectories()
        if let project {
            try FileManager.default.createDirectory(at: project.rootUrl, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project.htdocsUrl, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project.htdocsUrl.appendingPathComponent("cgi-bin"), withIntermediateDirectories: true)
        }
        let values = try baseValues(settings: settings, project: project)
        var httpdValues = values
        httpdValues["LOAD_MODULES"] = loadModules()
        httpdValues["LISTEN"] = listenLines(settings)
        httpdValues["SSL_VHOST"] = sslVhost(settings, values: values)

        let enablePMA = (project == nil) || (project?.features.phpMyAdmin == true && project?.features.mariadb == true)
        if enablePMA {
            let pmaDir = StackLayout.sharedPhpMyAdmin.path
            httpdValues["PHPMYADMIN_ALIAS"] = """
            Alias /phpmyadmin "\(pmaDir)"
            <Directory "\(pmaDir)">
                Options Indexes FollowSymLinks
                AllowOverride All
                Require all granted
            </Directory>
            """
        } else {
            httpdValues["PHPMYADMIN_ALIAS"] = ""
        }

        var rendered = try TemplateStore.render("httpd.conf.tmpl", httpdValues)
        if enablePMA && !rendered.contains("Alias /phpmyadmin") {
            let aliasSnippet = httpdValues["PHPMYADMIN_ALIAS"] ?? ""
            if let insertPoint = rendered.range(of: "<FilesMatch") {
                rendered.insert(contentsOf: aliasSnippet + "\n\n", at: insertPoint.lowerBound)
            }
        }
        try writeFile(StackLayout.conf.appendingPathComponent("httpd.conf"), rendered)
    }

    func writeWebFiles(databasePassword: String, port: Int, blowfish: String, bindAllInterfaces: Bool, project: CampProject? = nil) throws {
        let php = """
        <?php
        return [
            'host' => '127.0.0.1',
            'port' => \(port),
            'user' => 'root',
            'password' => '\(databasePassword)',
        ];
        """
        let web = StackLayout.conf.appendingPathComponent("camp-web.php")
        try writeFile(web, php, permissions: 0o600)
        let authentication = bindAllInterfaces ? "cookie" : "config"
        let autoLogin = bindAllInterfaces ? "" : """
        $campDatabase = require '\(web.path)';
        $cfg['Servers'][$i]['user'] = $campDatabase['user'];
        $cfg['Servers'][$i]['password'] = $campDatabase['password'];
        """
        let admin = try TemplateStore.render("phpmyadmin.config.inc.php.tmpl", [
            "BLOWFISH": blowfish,
            "MARIADB_PORT": String(port),
            "TMP": StackLayout.tmp.path,
            "AUTH_TYPE": authentication,
            "AUTO_LOGIN": autoLogin,
        ])
        let adminURL = StackLayout.sharedPhpMyAdmin.appendingPathComponent("config.inc.php")
        try writeFile(adminURL, admin, permissions: 0o600)
        let legacyAdminURL = StackLayout.htdocs.appendingPathComponent("phpmyadmin/config.inc.php")
        if legacyAdminURL.path != adminURL.path && FileManager.default.fileExists(atPath: StackLayout.htdocs.appendingPathComponent("phpmyadmin").path) {
            try? writeFile(legacyAdminURL, admin, permissions: 0o600)
        }
        if project == nil {
            try writeWelcome("index.php.tmpl", StackLayout.htdocs.appendingPathComponent("index.php"), permissions: 0o644)
            let cgi = StackLayout.htdocs.appendingPathComponent("cgi-bin/hello.cgi")
            try writeWelcome("hello.cgi.tmpl", cgi, permissions: 0o755)
        }
    }

    private func writeWelcome(_ template: String, _ destination: URL, permissions: Int) throws {
        if let existing = try? String(contentsOf: destination, encoding: .utf8),
           !existing.contains("CAMP-WELCOME") {
            return
        }
        let text = try TemplateStore.render(template, [
            "CONF": StackLayout.conf.path,
            "STACK": StackLayout.resolvedPrefix.path,
        ])
        try writeFile(destination, text, permissions: permissions)
    }

    private func baseValues(settings: CampSettings, project: CampProject? = nil) throws -> [String: String] {
        let prefix = StackLayout.resolvedPrefix.path
        var group = Shell.run(executable: "/usr/bin/id", arguments: ["-gn"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if group.isEmpty { group = "staff" }
        let privileged = settings.usePrivilegedPorts ? "User \(NSUserName())\nGroup \(group)\n" : ""
        let ftpIdentity = "User \(NSUserName())\nGroup \(group)"
        let masquerade = settings.bindAllInterfaces ? "" : "MasqueradeAddress 127.0.0.1"

        let htdocsPath = project?.htdocsUrl.path ?? StackLayout.htdocs.path
        let mysqlDataPath = project?.mysqlDataUrl.path ?? StackLayout.mysqlData.path
        let ftpPath = project?.rootUrl.path ?? StackLayout.ftp.path

        return [
            "STACK": prefix,
            "ROOT": StackLayout.dataRoot.path,
            "HTDOCS": htdocsPath,
            "CONF": StackLayout.conf.path,
            "LOGS": StackLayout.logs.path,
            "DATA": mysqlDataPath,
            "FTP": ftpPath,
            "TMP": StackLayout.tmp.path,
            "RUN": StackLayout.run.path,
            "SOCKET": StackLayout.mysqlSocket.path,
            "BIND": settings.bindAddress,
            // This build has no FTPS module, so keep FTP local even when the
            // web servers are exposed to the LAN.
            "FTP_BIND": "127.0.0.1",
            "MARIADB_PORT": String(settings.mariadbPort),
            "FTP_PORT": String(settings.ftpPort),
            "PRIVILEGED_USER": privileged,
            "FTP_IDENTITY": ftpIdentity,
            "MASQUERADE": masquerade,
            "PHP_EXT_DIR": phpExtensionDirectory()?.path ?? "\(prefix)/lib/php/extensions",
            "EXTENSIONS": "",
            "LOAD_MODULES": "",
            "LISTEN": "",
            "SSL_VHOST": "",
            "PHPMYADMIN_ALIAS": "",
        ]
    }

    private func listenLines(_ settings: CampSettings) -> String {
        if settings.bindAllInterfaces {
            return "Listen \(settings.apachePort)\nListen \(settings.apacheSSLPort)"
        }
        return "Listen 127.0.0.1:\(settings.apachePort)\nListen 127.0.0.1:\(settings.apacheSSLPort)"
    }

    private func sslVhost(_ settings: CampSettings, values: [String: String]) -> String {
        let fixed = settings.bindAllInterfaces ? "*:\(settings.apacheSSLPort)" : "127.0.0.1:\(settings.apacheSSLPort)"
        return """
        <VirtualHost \(fixed)>
            SSLEngine on
            SSLCertificateFile "\(values["CONF"] ?? "")/server.crt"
            SSLCertificateKeyFile "\(values["CONF"] ?? "")/server.key"
            DocumentRoot "\(values["HTDOCS"] ?? "")"
            ErrorLog "\(values["LOGS"] ?? "")/apache-ssl-error.log"
            CustomLog "\(values["LOGS"] ?? "")/apache-ssl-access.log" combined
        </VirtualHost>
        """
    }

    private func loadModules() -> String {
        let conf = StackLayout.resolvedPrefix.appendingPathComponent("conf/httpd.conf")
        var modules = (try? String(contentsOf: conf, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("LoadModule ") } ?? []

        let moduleDirectory = StackLayout.resolvedPrefix.appendingPathComponent("modules")
        let cgi = moduleDirectory.appendingPathComponent("mod_cgi.so")
        let sslCache = moduleDirectory.appendingPathComponent("mod_socache_shmcb.so")
        let ssl = moduleDirectory.appendingPathComponent("mod_ssl.so")
        if FileManager.default.fileExists(atPath: cgi.path),
           !modules.contains(where: { $0.contains("cgi_module") }) {
            modules.append("LoadModule cgi_module modules/mod_cgi.so")
        }
        if FileManager.default.fileExists(atPath: sslCache.path),
           !modules.contains(where: { $0.contains("socache_shmcb_module") }) {
            modules.append("LoadModule socache_shmcb_module modules/mod_socache_shmcb.so")
        }
        if FileManager.default.fileExists(atPath: ssl.path),
           !modules.contains(where: { $0.contains("ssl_module") }) {
            modules.append("LoadModule ssl_module modules/mod_ssl.so")
        }
        return modules
            .joined(separator: "\n")
    }

    private func phpExtensionDirectory() -> URL? {
        let base = StackLayout.resolvedPrefix.appendingPathComponent("lib/php/extensions")
        guard let items = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return nil
        }
        return items.first { $0.hasDirectoryPath }
    }

    private func writePHPIni(values: [String: String]) throws {
        let destination = StackLayout.conf.appendingPathComponent("php.ini")
        var draft = values
        try writeFile(destination, try TemplateStore.render("php.ini.tmpl", draft))
        guard let php = StackLayout.binary(["bin/php"]) else { return }
        let listed = Shell.run(executable: php.path, arguments: ["-c", destination.path, "-m"])
        let loaded = Set(listed.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let directory = phpExtensionDirectory()
        let wanted = ["mysqli", "pdo_mysql", "curl", "gd", "mbstring", "openssl", "zip", "intl", "opcache"]
        let lines = wanted.compactMap { name -> String? in
            if loaded.contains(name) { return nil }
            guard let directory else { return nil }
            let file = directory.appendingPathComponent("\(name).so")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return name == "opcache" ? "zend_extension=opcache.so" : "extension=\(name).so"
        }
        draft["EXTENSIONS"] = lines.joined(separator: "\n")
        try writeFile(destination, try TemplateStore.render("php.ini.tmpl", draft))
    }

    private func writeAutostart(_ settings: CampSettings) throws {
        let body: String
        if settings.launchAtLogin && settings.usePrivilegedPorts {
            body = "apache\nproftpd\n"
        } else {
            body = ""
        }
        try writeFile(StackLayout.autostart, body)
    }

    private func writeFile(_ url: URL, _ contents: String, permissions: Int = 0o644) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
