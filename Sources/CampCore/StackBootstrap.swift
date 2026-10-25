import Darwin
import Foundation

struct BootstrapReport: Equatable {
    var databasePassword: String?
    var ftpPassword: String?
}

struct StackBootstrap {
    private let services = ServiceController()
    private let configs = ConfigWriter()

    func run(settings: CampSettings) throws -> BootstrapReport {
        guard StackLayout.installed else {
            throw StackError.message("The Camp stack is not installed yet.")
        }
        try StackLayout.ensureDataDirectories()
        let settings = try settings.validated()
        try configs.write(settings: settings)
        try ensureCertificate()
        if !mysqlInitialized {
            try installDatabase()
        }
        if services.status(.mariadb, settings: settings) != .running {
            try services.start(.mariadb, settings: settings)
        }
        try waitForDatabase(port: settings.mariadbPort)
        var report = BootstrapReport()
        report.databasePassword = try ensureDatabasePassword(port: settings.mariadbPort, settings: settings)
        let blowfish = try ensureBlowfish()
        let ftpPassword = try ensureFTPAccount()
        report.ftpPassword = ftpPassword
        guard let databasePassword = KeychainStore.get(account: KeychainStore.databaseAccount) else {
            throw StackError.message("The MariaDB password is missing from the credential store.")
        }
        try configs.writeWebFiles(
            databasePassword: databasePassword,
            port: settings.mariadbPort,
            blowfish: blowfish,
            bindAllInterfaces: settings.bindAllInterfaces
        )
        let readme = StackLayout.ftp.appendingPathComponent("README.txt")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try "Files uploaded to Camp land in this folder.\n".write(to: readme, atomically: true, encoding: .utf8)
        }
        try "ok\n".write(to: StackLayout.marker, atomically: true, encoding: .utf8)
        return report
    }

    private var mysqlInitialized: Bool {
        FileManager.default.fileExists(atPath: StackLayout.mysqlData.appendingPathComponent("mysql").path)
    }

    private func installDatabase() throws {
        guard let tool = StackLayout.binary(["bin/mariadb-install-db", "bin/mysql_install_db", "scripts/mariadb-install-db"]) else {
            throw StackError.message("mariadb-install-db is not in the Camp prefix.")
        }
        let myCnf = StackLayout.conf.appendingPathComponent("my.cnf")
        let result = Shell.run(executable: tool.path, arguments: [
            "--defaults-file=\(myCnf.path)",
            "--datadir=\(StackLayout.mysqlData.path)",
            "--basedir=\(StackLayout.resolvedPrefix.path)",
            "--auth-root-authentication-method=normal",
        ])
        if result.status != 0 {
            throw StackError.command("mariadb-install-db", result.combined)
        }
    }

    private func waitForDatabase(port: Int) throws {
        // Match the MariaDB launch timeout above so a clean first-run database
        // has enough time to finish InnoDB initialization before Camp gives up.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if isDatabaseResponding(port: port) {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw StackError.message("MariaDB did not become ready.\n\(ServiceController().tail(LogKind.mariadb.file))")
    }

    private func isDatabaseResponding(port: Int) -> Bool {
        let noAuthTCP = mysql(port: port, password: nil, sql: "SELECT 1", useSocket: false)
        if noAuthTCP.status == 0 || isAccessDenied(noAuthTCP) {
            return true
        }
        if let existing = KeychainStore.get(account: KeychainStore.databaseAccount) {
            let authTCP = mysql(port: port, password: existing, sql: "SELECT 1", useSocket: false)
            if authTCP.status == 0 || isAccessDenied(authTCP) {
                return true
            }
        }
        if FileManager.default.fileExists(atPath: StackLayout.mysqlSocket.path) {
            let noAuthSocket = mysql(port: port, password: nil, sql: "SELECT 1", useSocket: true)
            if noAuthSocket.status == 0 || isAccessDenied(noAuthSocket) {
                return true
            }
            if let existing = KeychainStore.get(account: KeychainStore.databaseAccount) {
                let authSocket = mysql(port: port, password: existing, sql: "SELECT 1", useSocket: true)
                if authSocket.status == 0 || isAccessDenied(authSocket) {
                    return true
                }
            }
        }
        return false
    }

    private func isAccessDenied(_ result: ShellResult) -> Bool {
        result.combined.contains("Access denied") || result.combined.contains("1045")
    }

    private func ensureDatabasePassword(port: Int, settings: CampSettings) throws -> String? {
        let existing = KeychainStore.get(account: KeychainStore.databaseAccount)
        // 1. If existing password already connects over TCP, we are done.
        if let existing, connect(port: port, password: existing, useSocket: false) {
            return nil
        }
        // 2. If existing password connects over UNIX socket, ensure root@127.0.0.1 has access so TCP works.
        if let existing, connect(port: port, password: existing, useSocket: true) {
            try grant(port: port, password: existing, current: existing, useSocket: true)
            if connect(port: port, password: existing, useSocket: false) {
                return nil
            }
        }
        // 3. Try connecting with a blank password (via socket on clean install or via TCP).
        let fresh = try Secrets.password(length: 20)
        let blankSocket = connect(port: port, password: nil, useSocket: true)
        let blankTCP = connect(port: port, password: nil, useSocket: false)
        if blankSocket || blankTCP {
            let viaSocket = blankSocket
            try grant(port: port, password: fresh, current: nil, useSocket: viaSocket)
            guard connect(port: port, password: fresh, useSocket: false) else {
                throw StackError.message("MariaDB rejected the password Camp just stored.")
            }
            try KeychainStore.set(account: KeychainStore.databaseAccount, password: fresh)
            return fresh
        }
        // 4. Fallback of last resort: credentials desynchronized or locked out. Recover via bootstrap.
        return try resetRootPasswordViaBootstrap(port: port, settings: settings)
    }

    private func resetRootPasswordViaBootstrap(port: Int, settings: CampSettings) throws -> String {
        guard let server = StackLayout.binary(["sbin/mariadbd", "bin/mariadbd", "sbin/mysqld", "libexec/mariadbd"]) else {
            throw StackError.message("mariadbd server is missing from the Camp prefix.")
        }
        let fresh = try Secrets.password(length: 20)
        let sql = """
        FLUSH PRIVILEGES;
        ALTER USER 'root'@'localhost' IDENTIFIED BY '\(fresh)';
        CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '\(fresh)';
        ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '\(fresh)';
        CREATE USER IF NOT EXISTS 'root'@'::1' IDENTIFIED BY '\(fresh)';
        ALTER USER 'root'@'::1' IDENTIFIED BY '\(fresh)';
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1' WITH GRANT OPTION;
        DELETE FROM mysql.user WHERE User='';
        FLUSH PRIVILEGES;
        """

        services.stop(.mariadb, settings: settings)
        let stopDeadline = Date().addingTimeInterval(15)
        while Date() < stopDeadline && services.status(.mariadb, settings: settings) == .running {
            Thread.sleep(forTimeInterval: 0.25)
        }
        let socketDeadline = Date().addingTimeInterval(5)
        while Date() < socketDeadline && FileManager.default.fileExists(atPath: StackLayout.mysqlSocket.path) {
            Thread.sleep(forTimeInterval: 0.25)
        }

        let myCnf = StackLayout.conf.appendingPathComponent("my.cnf")
        let bootstrapResult = Shell.run(
            executable: server.path,
            arguments: [
                "--defaults-file=\(myCnf.path)",
                "--bootstrap",
            ],
            stdin: sql
        )
        guard bootstrapResult.status == 0 else {
            throw StackError.command("mariadbd --bootstrap", bootstrapResult.combined)
        }

        try services.start(.mariadb, settings: settings)
        try waitForDatabase(port: port)

        guard connect(port: port, password: fresh, useSocket: false) else {
            throw StackError.message("MariaDB password reset via bootstrap completed, but Camp could not connect with the new password.")
        }
        try KeychainStore.set(account: KeychainStore.databaseAccount, password: fresh)
        return fresh
    }

    private func grant(port: Int, password: String, current: String?, useSocket: Bool = false) throws {
        let sql = """
        ALTER USER 'root'@'localhost' IDENTIFIED BY '\(password)';
        CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '\(password)';
        ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '\(password)';
        CREATE USER IF NOT EXISTS 'root'@'::1' IDENTIFIED BY '\(password)';
        ALTER USER 'root'@'::1' IDENTIFIED BY '\(password)';
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1' WITH GRANT OPTION;
        DELETE FROM mysql.user WHERE User='';
        FLUSH PRIVILEGES;
        """
        var result = mysql(port: port, password: current, sql: sql, useSocket: useSocket)
        if result.status != 0 && !useSocket && FileManager.default.fileExists(atPath: StackLayout.mysqlSocket.path) {
            result = mysql(port: port, password: current, sql: sql, useSocket: true)
        }
        if result.status != 0 {
            throw StackError.command("mariadb", result.combined)
        }
    }

    private func connect(port: Int, password: String?, useSocket: Bool = false) -> Bool {
        mysql(port: port, password: password, sql: "SELECT 1", useSocket: useSocket).status == 0
    }

    private func mysql(port: Int, password: String?, sql: String, useSocket: Bool = false) -> ShellResult {
        guard let client = StackLayout.binary(["bin/mariadb", "bin/mysql"]) else {
            return ShellResult(status: 127, stdout: "", stderr: "mariadb client is missing")
        }
        let defaults = StackLayout.tmp.appendingPathComponent("client-\(UUID().uuidString).cnf")
        var text = "[client]\nuser=root\n"
        if useSocket {
            text += """
            socket=\(StackLayout.mysqlSocket.path)
            protocol=socket

            """
        } else {
            text += """
            host=127.0.0.1
            port=\(port)
            protocol=tcp

            """
        }
        if let password {
            text += "password=\(password)\n"
        }
        do {
            try text.write(to: defaults, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: defaults.path)
        } catch {
            return ShellResult(status: 1, stdout: "", stderr: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: defaults) }
        return Shell.run(executable: client.path, arguments: [
            "--defaults-file=\(defaults.path)",
            "-e",
            sql,
        ])
    }

    private func ensureBlowfish() throws -> String {
        if let existing = KeychainStore.get(account: KeychainStore.blowfishAccount) { return existing }
        let secret = try Secrets.password(length: 32)
        try KeychainStore.set(account: KeychainStore.blowfishAccount, password: secret)
        return secret
    }

    private func ensureFTPAccount() throws -> String? {
        let existing = KeychainStore.get(account: KeychainStore.ftpAccount)
        let password: String
        if let existing {
            password = existing
        } else {
            password = try Secrets.password(length: 32)
        }
        let passwd = StackLayout.conf.appendingPathComponent("ftpd.passwd")
        let group = StackLayout.conf.appendingPathComponent("ftpd.group")
        let uid = getuid()
        let gid = getgid()
        let hash = try ftpPasswordHash(password)
        let userLine = "camp:\(hash):\(uid):\(gid):Camp:\(StackLayout.ftp.path):/usr/bin/false\n"
        let groupLine = "camp:x:\(gid):camp\n"
        try userLine.write(to: passwd, atomically: true, encoding: .utf8)
        try groupLine.write(to: group, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwd.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: group.path)
        try KeychainStore.set(account: KeychainStore.ftpAccount, password: password)
        if existing == nil {
            return password
        }
        return nil
    }

    private func ftpPasswordHash(_ password: String) throws -> String {
        guard let htpasswd = StackLayout.binary(["bin/htpasswd"]) else {
            throw StackError.message("Apache htpasswd is missing; Camp cannot create a secure FTP password hash.")
        }
        let result = Shell.run(
            executable: htpasswd.path,
            arguments: ["-n", "-B", "-i", "-C", "12", "camp"],
            stdin: password + "\n"
        )
        guard result.status == 0,
              let separator = result.stdout.firstIndex(of: ":") else {
            throw StackError.command("htpasswd bcrypt", result.combined)
        }
        let hash = String(result.stdout[result.stdout.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard hash.hasPrefix("$2y$12$"), hash.utf8.count == 60 else {
            throw StackError.message("Apache htpasswd returned an unsupported FTP password hash.")
        }
        return hash
    }

    private func ensureCertificate() throws {
        let cert = StackLayout.conf.appendingPathComponent("server.crt")
        let key = StackLayout.conf.appendingPathComponent("server.key")
        if FileManager.default.fileExists(atPath: cert.path) && FileManager.default.fileExists(atPath: key.path) {
            return
        }
        guard let openssl = StackLayout.binary(["bin/openssl"]) else {
            throw StackError.message("openssl is not in the Camp prefix.")
        }
        // OpenSSL's compiled-in config points into the install prefix, but some
        // OpenSSL builds (including install_sw) do not install that config file.
        // Give `req` an explicit, self-contained config and include localhost
        // subject alternative names for current browser certificate checks.
        let requestConfig = StackLayout.conf.appendingPathComponent("localhost-cert.cnf")
        let config = """
        [req]
        prompt = no
        distinguished_name = subject
        x509_extensions = server

        [subject]
        CN = localhost

        [server]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = @names

        [names]
        DNS.1 = localhost
        IP.1 = 127.0.0.1
        """
        try config.write(to: requestConfig, atomically: true, encoding: .utf8)
        let result = Shell.run(executable: openssl.path, arguments: [
            "req", "-x509", "-nodes", "-newkey", "rsa:2048",
            "-config", requestConfig.path,
            "-extensions", "server",
            "-keyout", key.path,
            "-out", cert.path,
            "-days", "3650",
            "-subj", "/CN=localhost",
        ])
        if result.status != 0 {
            throw StackError.command("openssl", result.combined)
        }
    }
}
