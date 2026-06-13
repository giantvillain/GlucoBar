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
        HStack(spacing: 4) {
            Circle()
                .fill(service.errorMessage != nil ? Color.red : (service.isDataStale ? Color.orange : Color.secondary))
                .frame(width: 6, height: 6)
            Text(service.menuBarDisplayText)
                .id(service.menuBarDisplayText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minWidth: 54, alignment: .leading)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct AnimatedTrendArrow: View {
    let symbol: String
    let animationID: Int

    @State private var rotation = 0.0

    var body: some View {
        Text(symbol)
            .fixedSize(horizontal: true, vertical: false)
            .rotationEffect(.degrees(rotation))
            .onChange(of: animationID) { _, _ in
                withAnimation(.easeInOut(duration: 0.65)) {
                    rotation += 360
                }
            }
    }
}
