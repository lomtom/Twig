import AppKit
import SwiftUI

enum GitStrideStyle {
    static let accent = Color(red: 0.18, green: 0.46, blue: 0.36)
    static let added = Color(red: 0.27, green: 0.68, blue: 0.33)
    static let unversioned = Color(red: 0.93, green: 0.54, blue: 0.53)
    static let canvas = adaptive(
        light: NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1),
        dark: NSColor(calibratedRed: 0.075, green: 0.08, blue: 0.095, alpha: 1)
    )
    static let panel = adaptive(
        light: NSColor(calibratedWhite: 0.99, alpha: 1),
        dark: NSColor(calibratedRed: 0.125, green: 0.13, blue: 0.15, alpha: 1)
    )
    static let panelHeader = adaptive(
        light: NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.975, alpha: 1),
        dark: NSColor(calibratedRed: 0.15, green: 0.155, blue: 0.18, alpha: 1)
    )
    static let input = adaptive(
        light: NSColor(calibratedRed: 0.945, green: 0.955, blue: 0.97, alpha: 1),
        dark: NSColor(calibratedRed: 0.075, green: 0.078, blue: 0.09, alpha: 1)
    )
    static let panelBorder = adaptive(
        light: NSColor(calibratedWhite: 0.25, alpha: 0.24),
        dark: NSColor(calibratedWhite: 1, alpha: 0.10)
    )
    static let selection = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.31, alpha: 0.34)
        }
        return NSColor(calibratedRed: 0.82, green: 0.92, blue: 0.87, alpha: 1)
    })
    static let modified = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.37, green: 0.62, blue: 1.00, alpha: 1)
        }
        return NSColor(calibratedRed: 0.08, green: 0.29, blue: 0.62, alpha: 1)
    })
    static let subtleFill = adaptive(
        light: NSColor(calibratedWhite: 0.86, alpha: 1),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )
    static let hairline = panelBorder

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct CountBadge: View {
    let value: Int

    var body: some View {
        Text("\(value)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(GitStrideStyle.subtleFill, in: Capsule())
    }
}

struct StatusBadge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

extension View {
    func dashboardPanel(fill: Color = GitStrideStyle.panel) -> some View {
        background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.055), radius: 8, y: 2)
    }
}

struct WindowChromeConfigurator: NSViewRepresentable {
    var isWelcome: Bool

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.isWelcome = isWelcome
        return view
    }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.isWelcome = isWelcome
        view.configureWindow()
        // SwiftUI may install or update the toolbar after this view update.
        DispatchQueue.main.async { [weak view] in view?.configureWindow() }
    }

    final class ChromeView: NSView {
        var isWelcome = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
            DispatchQueue.main.async { [weak self] in self?.configureWindow() }
        }

        override func layout() {
            super.layout()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            if window.titlebarAppearsTransparent != isWelcome {
                window.titlebarAppearsTransparent = isWelcome
            }
            if window.toolbarStyle != .unified {
                window.toolbarStyle = .unified
            }
            if window.titlebarSeparatorStyle != .none {
                window.titlebarSeparatorStyle = .none
            }
            if let toolbar = window.toolbar, toolbar.showsBaselineSeparator {
                toolbar.showsBaselineSeparator = false
            }
        }
    }
}
