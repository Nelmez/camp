import Foundation

@main
enum CampMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let commands: Set<String> = ["status", "bootstrap", "rewrite", "start", "stop", "passwords", "help"]
        if let command = arguments.first, commands.contains(command) {
            runCampCTL(arguments)
        }
        CampApp.main()
    }
}

private func runCampCTL(_ arguments: [String]) -> Never {
    let settings = CampSettings.load()
    let controller = ServiceController()
    let command = arguments.first ?? "help"

    func service(named name: String) -> CampService? {
        CampService(rawValue: name)
    }

    func printStatus() {
        for item in CampService.allCases {
            let state = controller.status(item, settings: settings)
            print("\(item.rawValue) \(state.rawValue)")
        }
        if let php = StackLayout.binary(["bin/php"]) {
            let version = Shell.run(executable: php.path, arguments: [
                "-c", StackLayout.conf.appendingPathComponent("php.ini").path,
                "-r", "echo PHP_VERSION;",
            ])
            print("php \(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let perl = StackLayout.binary(["bin/perl"]) {
            let version = Shell.run(executable: perl.path, arguments: ["-e", "print $^V"])
            print("perl \(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    do {
        switch command {
        case "status":
            printStatus()
        case "bootstrap":
            let report = try StackBootstrap().run(settings: settings)
            if let database = report.databasePassword { print("database \(database)") }
            if let ftp = report.ftpPassword { print("ftp \(ftp)") }
            print("bootstrapped")
        case "rewrite":
            try ConfigWriter().write(settings: try settings.validated())
            print("rewritten")
        case "start", "stop":
            let name = arguments.count > 1 ? arguments[1] : "all"
            let targets: [CampService] = name == "all" ? Array(CampService.allCases) : [service(named: name)].compactMap { $0 }
            if targets.isEmpty {
                fputs("Unknown service \(name)\n", stderr)
                exit(2)
            }
            if command == "start" {
                if !FileManager.default.fileExists(atPath: StackLayout.marker.path) {
                    _ = try StackBootstrap().run(settings: settings)
                }
                try ConfigWriter().write(settings: try settings.validated())
                for item in targets {
                    try controller.start(item, settings: settings)
                }
            } else {
                for item in targets {
                    controller.stop(item, settings: settings)
                }
            }
            printStatus()
        case "passwords":
            print("database \(KeychainStore.get(account: KeychainStore.databaseAccount) ?? "")")
            print("ftp \(KeychainStore.get(account: KeychainStore.ftpAccount) ?? "")")
        default:
            print("usage: Camp status|bootstrap|rewrite|start|stop|passwords")
        }
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        exit(1)
    }
    exit(0)
}
