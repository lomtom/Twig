import SwiftUI

struct SettingsView: View {
    @AppStorage(AppPreferenceKey.theme) private var theme = AppTheme.system.rawValue
    @AppStorage(AppPreferenceKey.restoreProjectsOnLaunch) private var restoreProjectsOnLaunch = true
    @AppStorage(AppPreferenceKey.pullStrategy) private var pullStrategy = PullStrategy.fastForwardOnly.rawValue

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section("项目") {
                Toggle("启动时恢复上次未关闭的项目", isOn: $restoreProjectsOnLaunch)
            }
            Section("拉取") {
                Picker("默认拉取方式", selection: $pullStrategy) {
                    ForEach(PullStrategy.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text(PullStrategy(rawValue: pullStrategy)?.detail ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }
}
