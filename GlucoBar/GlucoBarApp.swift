import SwiftUI
import AppKit

@main
struct GlucoBarApp: App {
    @StateObject private var service: LibreLinkUpService

    init() {
        #if DEBUG
        let demo = ProcessInfo.processInfo.arguments.contains("--demo")
        if demo { NSApplication.shared.setActivationPolicy(.regular) }
        _service = StateObject(wrappedValue: demo ? LibreLinkUpService.preview() : LibreLinkUpService())
        #else
        _service = StateObject(wrappedValue: LibreLinkUpService())
        #endif
    }

    var body: some Scene {
        #if GLUCOBAR_PREVIEW
            WindowGroup("GlucoBar Preview") {
                TabView {
                    MenuContent().tabItem { Text("Menu") }
                    SettingsView().tabItem { Text("Settings") }
                    HistoryView().tabItem { Text("History") }
                }
                .environmentObject(service)
                .frame(minWidth: 950, minHeight: 720)
            }
        #else
        appScenes
        #endif
    }

    @SceneBuilder private var appScenes: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(service)
        } label: {
            MenuBarLabelView(service: service)
        }
        .menuBarExtraStyle(.window)

        Window("Glucose History", id: "history") {
            HistoryView().environmentObject(service)
        }
        .defaultSize(width: 920, height: 650)

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
        HStack(spacing: service.compactMenu ? 2 : 5) {
            Circle()
                .fill(service.privacyMode ? .secondary : service.menuBarIndicatorColor)
                .frame(width: 6, height: 6)
            Text(service.menuBarDisplayText)
                .id(service.menuBarDisplayText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minWidth: service.compactMenu ? 0 : 54, alignment: .leading)
        }
        .accessibilityLabel(service.privacyMode ? "GlucoBar, privacy mode" : "Glucose \(service.menuBarValueText) \(service.displayUnitLabel), trend \(service.trendDescription)")
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
