import SwiftUI
import AppKit

@main
struct TwigApp: App {
    @StateObject private var model = RepositoryModel()
    @AppStorage(AppPreferenceKey.theme) private var theme = AppTheme.system.rawValue

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        Window("Twig", id: "main") {
            MainWorkspaceView().environmentObject(model)
                .frame(minWidth: 1040, minHeight: 640)
                .preferredColorScheme((AppTheme(rawValue: theme) ?? .system).colorScheme)
                .background(WindowChromeConfigurator(isWelcome: model.state == nil && !model.isRestoringLastRepository).frame(width: 0, height: 0))
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1200, height: 790)
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { model.chooseRepository() }.keyboardShortcut("o").disabled(model.busy)
                Button("Clone Repository…") { model.showClone = true }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.busy)
            }
            CommandMenu("仓库") {
                Button("Refresh") { model.refresh() }.keyboardShortcut("r").disabled(model.state == nil || model.busy)
                Button("Fetch Remote Status") { model.refresh(fetch: true) }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.state == nil || model.busy)
                Divider()
                Button("Commit Selected Files") { model.commit() }.keyboardShortcut(.return, modifiers: .command).disabled(!model.canCommit)
                Button("Pull") { model.pull() }.keyboardShortcut("t").disabled(!model.canSync || model.state?.upstream == nil)
                Button("Push") { model.push() }.keyboardShortcut("k", modifiers: [.command, .shift]).disabled(!model.canSync || model.state?.hasHEAD != true)
                Divider()
                Button("Show in Finder") { model.revealRepository() }.disabled(model.state == nil)
                Button("Open in Terminal") { model.openTerminal() }.disabled(model.state == nil)
            }
        }
    }
}
