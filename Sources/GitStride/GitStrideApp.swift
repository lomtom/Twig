import SwiftUI
import AppKit

@main
struct TwigApp: App {
    @StateObject private var model = RepositoryModel()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        Window("Twig", id: "main") {
            ContentView().environmentObject(model)
                .frame(minWidth: 1040, minHeight: 640)
                .background(WindowChromeConfigurator(isWelcome: model.state == nil && !model.isRestoringLastRepository).frame(width: 0, height: 0))
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1200, height: 790)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开仓库…") { model.chooseRepository() }.keyboardShortcut("o").disabled(model.busy)
                Button("克隆仓库…") { model.showClone = true }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.busy)
            }
            CommandMenu("仓库") {
                Button("刷新") { model.refresh() }.keyboardShortcut("r").disabled(model.state == nil || model.busy)
                Button("获取远程状态") { model.refresh(fetch: true) }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.state == nil || model.busy)
                Divider()
                Button("提交所选文件") { model.commit() }.keyboardShortcut(.return, modifiers: .command).disabled(!model.canCommit)
                Button("拉取") { model.pull() }.keyboardShortcut("t").disabled(!model.canSync || model.state?.upstream == nil)
                Button("推送") { model.push() }.keyboardShortcut("k", modifiers: [.command, .shift]).disabled(!model.canSync || model.state?.hasHEAD != true)
                Divider()
                Button("在 Finder 中显示") { model.revealRepository() }.disabled(model.state == nil)
                Button("在终端中打开") { model.openTerminal() }.disabled(model.state == nil)
            }
        }
    }
}
