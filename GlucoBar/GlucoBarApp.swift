import SwiftUI

@main
struct GlucoBarApp: App {
    @StateObject private var service = LibreLinkUpService()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(service)
        } label: {
            MenuBarLabelView(service: service)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(service)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct MenuBarLabelView: View {
    @ObservedObject var service: LibreLinkUpService

    var body: some View {
        Text(service.menuBarDisplayText)
            .id(service.menuBarDisplayText)
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}
