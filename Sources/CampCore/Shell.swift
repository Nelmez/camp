import Darwin
import Foundation
import Security

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String

    var combined: String { stdout + stderr }
}

enum Shell {
    @discardableResult
    static func run(
        executable: String,
        arguments: [String] = [],
        directory: URL? = nil,
        stdin: String? = nil
    ) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        do {
            try process.run()
        } catch {
            return ShellResult(status: 127, stdout: "", stderr: error.localizedDescription)
        }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
        }
        input.fileHandleForWriting.closeFile()

        let group = DispatchGroup()
        var outData = Data()
        var errData = Data()
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        return ShellResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    @discardableResult
    static func stream(
        executable: String,
        arguments: [String] = [],
        onOutput: @escaping (String) -> Void
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            onOutput(text)
        }
        do {
            try process.run()
        } catch {
            onOutput(error.localizedDescription + "\n")
            return 127
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus
    }
}

enum KeychainStore {
    static let service = "com.nelmez.camp"
    static let databaseAccount = "mariadb-root"
    static let ftpAccount = "ftp-camp"
    static let blowfishAccount = "phpmyadmin-blowfish"

    static func set(account: String, password: String) throws {
        let savedFallback = saveFallback(account: account, password: password)
        var keychainError: Error?
        do {
            try setKeychainOnly(account: account, password: password)
        } catch {
            keychainError = error
        }
        if !savedFallback, let keychainError {
            throw keychainError
        }
    }

    static func get(account: String) -> String? {
        // 1. Try file fallback (.credentials) first: fastest, secure, never hangs on Keychain dialogs
        let fallback = loadFallbackCredentials()
        if let stored = fallback[account], !stored.isEmpty {
            return stored
        }

        // 2. Fallback for MariaDB root password: read from camp-web.php
        if account == databaseAccount, let webPassword = readDatabasePasswordFromWebConfig() {
            saveFallback(account: account, password: webPassword)
            return webPassword
        }

        // 3. Try Keychain with timeout to prevent hanging on macOS authorization dialogs
        if let keychainPassword = getFromKeychainWithTimeout(account: account, timeout: 0.5) {
            saveFallback(account: account, password: keychainPassword)
            return keychainPassword
        }

        return nil
    }

    private static func getFromKeychainWithTimeout(account: String, timeout: TimeInterval) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String? = nil

        DispatchQueue.global().async {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8), !password.isEmpty {
                result = password
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return nil
        }
        return result
    }

    private static func setKeychainOnly(account: String, password: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var status: OSStatus = errSecSuccess

        DispatchQueue.global().async {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
            var add = query
            add[kSecValueData as String] = Data(password.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 1.0) == .timedOut {
            return
        }
        guard status == errSecSuccess else { throw StackError.keychain(status) }
    }

    @discardableResult
    private static func saveFallback(account: String, password: String) -> Bool {
        var dict = loadFallbackCredentials()
        dict[account] = password
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        let url = StackLayout.credentials
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func loadFallbackCredentials() -> [String: String] {
        let url = StackLayout.credentials
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }

    private static func readDatabasePasswordFromWebConfig() -> String? {
        let web = StackLayout.conf.appendingPathComponent("camp-web.php")
        guard let content = try? String(contentsOf: web, encoding: .utf8) else { return nil }
        let pattern = #"'password'\s*=>\s*'([^']*)'"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: content) else {
            return nil
        }
        let password = String(content[range])
        return password.isEmpty ? nil : password
    }
}

enum Secrets {
    static func password(length: Int) throws -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        guard length > 0 else { return "" }
        let usableByteLimit = 256 - (256 % alphabet.count)
        var result = [Character]()
        result.reserveCapacity(length)
        while result.count < length {
            let needed = length - result.count
            var bytes = [UInt8](repeating: 0, count: max(16, needed * 2))
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                throw StackError.message("macOS could not provide secure random bytes for a Camp credential (\(status)).")
            }
            for byte in bytes where Int(byte) < usableByteLimit {
                result.append(alphabet[Int(byte) % alphabet.count])
                if result.count == length { break }
            }
        }
        return String(result)
    }
}
