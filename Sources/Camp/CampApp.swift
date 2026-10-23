import SwiftUI

struct CampApp: App {
    @StateObject private var model = CampModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 920, height: 620)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.anyRunning ? "server.rack" : "power")
        }
        .menuBarExtraStyle(.menu)
    }
}
