import SwiftUI

enum AppPreferenceKey {
    static let theme = "appTheme"
    static let restoreProjectsOnLaunch = "restoreProjectsOnLaunch"
    static let pullStrategy = "pullStrategy"
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum PullStrategy: String, CaseIterable, Identifiable {
    case fastForwardOnly, rebase, merge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fastForwardOnly: return "仅快进（推荐）"
        case .rebase: return "变基"
        case .merge: return "合并"
        }
    }
    var detail: String {
        switch self {
        case .fastForwardOnly: return "分支已分叉时停止，不自动创建提交。"
        case .rebase: return "将本地提交重放到远程提交之后。"
        case .merge: return "分支分叉时创建合并提交。"
        }
    }
}
