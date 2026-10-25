import Foundation
import Security

// Self-contained test suite for Camp core components and system integrity.

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String) {
    if condition {
        passed += 1
        print("  ✓ \(message)")
    } else {
        failed += 1
        print("  ✗ FAILED: \(message)")
    }
}

func testCampSettings() {
    print("\n--- Test: CampSettings ---")
    var settings = CampSettings.standard
    assert(settings.apachePort == 8080, "Default Apache port is 8080")
    assert(settings.mariadbPort == 3306, "Default MariaDB port is 3306")
    assert(settings.ftpPort == 2121, "Default FTP port is 2121")
    assert(!settings.bindAllInterfaces, "bindAllInterfaces defaults to false")

    // Validation edge case: duplicate ports
    settings.apachePort = 3306
    var threw = false
    do {
        _ = try settings.validated()
    } catch {
        threw = true
    }
    assert(threw, "Rejects duplicate service ports")

    // Validation edge case: privileged ports
    settings.apachePort = 80
    settings.mariadbPort = 3306
    threw = false
    do {
        _ = try settings.validated()
    } catch {
        threw = true
    }
    assert(threw, "Rejects ports below 1024 without usePrivilegedPorts")

    // Validation edge case: out of bounds port
    settings.apachePort = 70000
    threw = false
    do {
        _ = try settings.validated()
    } catch {
        threw = true
    }
    assert(threw, "Rejects ports > 65535")
}

func testTemplateStore() {
    print("\n--- Test: TemplateStore & Config Rendering ---")
    let templates = [
        "my.cnf.tmpl",
        "php.ini.tmpl",
        "httpd.conf.tmpl",
        "proftpd.conf.tmpl",
        "phpmyadmin.config.inc.php.tmpl",
        "hello.cgi.tmpl",
        "index.php.tmpl",
    ]
    for tmpl in templates {
        do {
            let content = try TemplateStore.text(tmpl)
            assert(!content.isEmpty, "Template \(tmpl) is readable and non-empty")
        } catch {
            assert(false, "Failed to read template \(tmpl): \(error)")
        }
    }

    // Verify php.ini template has socket configuration
    if let phpIni = try? TemplateStore.text("php.ini.tmpl") {
        assert(phpIni.contains("mysqli.default_socket = \"{{SOCKET}}\""), "php.ini contains mysqli.default_socket")
        assert(phpIni.contains("pdo_mysql.default_socket = \"{{SOCKET}}\""), "php.ini contains pdo_mysql.default_socket")
    } else {
        assert(false, "Could not load php.ini.tmpl")
    }

    // Verify my.cnf template has skip-name-resolve
    if let myCnf = try? TemplateStore.text("my.cnf.tmpl") {
        assert(myCnf.contains("skip-name-resolve"), "my.cnf contains skip-name-resolve")
        assert(myCnf.contains("[client]"), "my.cnf contains [client] section")
    } else {
        assert(false, "Could not load my.cnf.tmpl")
    }
}

func testSecrets() {
    print("\n--- Test: Secrets Generator ---")
    do {
        let empty = try Secrets.password(length: 0)
        assert(empty.isEmpty, "Zero length generates empty password")

        let pass20 = try Secrets.password(length: 20)
        assert(pass20.count == 20, "Generates 20 character password")

        let pass32 = try Secrets.password(length: 32)
        assert(pass32.count == 32, "Generates 32 character password")

        // Ensure randomness across multiple invocations
        let anotherPass = try Secrets.password(length: 20)
        assert(pass20 != anotherPass, "Consecutive generated passwords are distinct")
    } catch {
        assert(false, "Secrets generation threw error: \(error)")
    }
}

func testKeychainAndFallbackStore() {
    print("\n--- Test: KeychainStore & Fallback Store ---")
    let testAccount = "camp-test-\(UUID().uuidString)"
    let testSecret = "test-secret-\(UUID().uuidString)"

    do {
        try KeychainStore.set(account: testAccount, password: testSecret)
        let retrieved = KeychainStore.get(account: testAccount)
        assert(retrieved == testSecret, "Retrieved password matches stored password")

        // Check fallback file attributes
        let attrs = try FileManager.default.attributesOfItem(atPath: StackLayout.credentials.path)
        if let perms = attrs[.posixPermissions] as? NSNumber {
            assert(perms.intValue == 0o600, ".credentials file permissions are strictly 0600 (got \(String(perms.intValue, radix: 8)))")
        } else {
            assert(false, "Could not read .credentials permissions")
        }
    } catch {
        assert(false, "KeychainStore operations threw error: \(error)")
    }
}

func testMachOExternalDependencies() {
    print("\n--- Test: Mach-O External Dependency Audit ---")
    let roots = ["/opt/camp/bin", "/opt/camp/sbin", "/opt/camp/lib", "/opt/camp/modules"]
    var violations = [String]()

    for root in roots {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { continue }
        while let rel = enumerator.nextObject() as? String {
            let fullPath = (root as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }
            // Skip symlinks
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: fullPath)) != nil {
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: fullPath)) else { continue }
            let data = handle.readData(ofLength: 4)
            try? handle.close()
            guard data.count == 4 else { continue }
            let bytes = [UInt8](data)
            let isMachO = (bytes == [0xfe, 0xed, 0xfa, 0xce] ||
                           bytes == [0xfe, 0xed, 0xfa, 0xcf] ||
                           bytes == [0xca, 0xfe, 0xba, 0xbe] ||
                           bytes == [0xcf, 0xfa, 0xed, 0xfe] ||
                           bytes == [0xce, 0xfa, 0xed, 0xfe])
            if isMachO {
                let res = Shell.run(executable: "/usr/bin/otool", arguments: ["-L", fullPath])
                for line in res.stdout.components(separatedBy: "\n").dropFirst() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.contains("/opt/homebrew") || trimmed.contains("/usr/local") {
                        violations.append("\(fullPath) -> \(trimmed)")
                    }
                }
            }
        }
    }

    assert(violations.isEmpty, "Zero binaries in /opt/camp depend on /opt/homebrew or /usr/local")
    if !violations.isEmpty {
        for v in violations {
            print("    Violating binary: \(v)")
        }
    }
}

func testStackLayoutAndBinaries() {
    print("\n--- Test: StackLayout & Binaries ---")
    assert(StackLayout.installed, "StackLayout reports stack is installed")
    assert(StackLayout.binary(["bin/httpd"]) != nil, "Found bin/httpd")
    assert(StackLayout.binary(["bin/php"]) != nil, "Found bin/php")
    assert(StackLayout.binary(["bin/perl"]) != nil, "Found bin/perl")
    assert(StackLayout.binary(["sbin/mariadbd", "bin/mariadbd"]) != nil, "Found mariadbd")
    assert(StackLayout.binary(["sbin/proftpd", "bin/proftpd"]) != nil, "Found proftpd")
    assert(StackLayout.binary(["bin/openssl"]) != nil, "Found bin/openssl")
}

func testServiceControllerIdempotence() {
    print("\n--- Test: ServiceController Idempotence ---")
    let controller = ServiceController()
    let settings = CampSettings.load()
    let initialStatus = controller.status(.mariadb, settings: settings)
    print("  Initial MariaDB status: \(initialStatus.rawValue)")

    // Test calling start on already running or stopped service
    do {
        try controller.start(.mariadb, settings: settings)
        assert(controller.status(.mariadb, settings: settings) == .running, "MariaDB is running after start")
        // Calling start again must be a clean no-op and not fail
        try controller.start(.mariadb, settings: settings)
        assert(controller.status(.mariadb, settings: settings) == .running, "MariaDB remains running after redundant start")
        controller.stop(.mariadb, settings: settings)
        assert(controller.status(.mariadb, settings: settings) == .stopped, "MariaDB is stopped after stop")
    } catch {
        assert(false, "ServiceController threw error: \(error)")
    }
}

@main
enum CampTests {
    static func main() {
        testCampSettings()
        testTemplateStore()
        testSecrets()
        testKeychainAndFallbackStore()
        testMachOExternalDependencies()
        testStackLayoutAndBinaries()
        testServiceControllerIdempotence()

        print("\n===============================")
        print("Summary: \(passed) passed, \(failed) failed")
        print("===============================\n")

        if failed > 0 {
            exit(1)
        } else {
            exit(0)
        }
    }
}
