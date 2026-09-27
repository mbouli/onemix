import AppKit
import SwiftUI

/// Panel footer with the settings and quit menus.
struct FooterBar: View {
    let model: MixerViewModel

    var body: some View {
        HStack {
            Menu {
                Toggle("Show All Running Apps", isOn: Binding(
                    get: { model.showAllApps }, set: { model.setShowAllApps($0) }))
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            } label: {
                FooterIcon(systemName: "gearshape.fill")
            }
            .help("Settings")

            Spacer()

            Menu {
                Button("Quit OneMix") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                FooterIcon(systemName: "xmark")
            }
            .help("Quit")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 2)
        .background {
            // Menu item shortcuts only fire while the menu is open, and there is no main
            // menu, so a hidden button keeps ⌘Q working.
            Button("Quit OneMix") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct FooterIcon: View {
    let systemName: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}
