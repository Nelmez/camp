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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw StackError.keychain(status) }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum Secrets {
    static func password(length: Int) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status != errSecSuccess {
            return String((0..<length).map { _ in alphabet.randomElement()! })
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    static func cryptHash(password: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./")
        let salt = String((0..<2).map { _ in alphabet.randomElement()! })
        guard let hashed = crypt(password, salt) else { return salt }
        return String(cString: hashed)
    }
}
