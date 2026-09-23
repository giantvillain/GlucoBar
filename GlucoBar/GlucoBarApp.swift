import SwiftUI
import AppKit

@main
struct GlucoBarApp: App {
    @NSApplicationDelegateAdaptor(GlucoBarAppDelegate.self) private var appDelegate
    private var service: LibreLinkUpService { appDelegate.service }

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
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.menuBar?.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .appSettings) {
                    Button("Show Glucose") { appDelegate.menuBar?.showPanel() }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                }
            }
        #endif
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
