import AppKit
import SwiftUI

/// Bottom row: a gear menu with settings on the left, an ✕ menu with Quit on the right.
/// Both open native macOS menus.
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
            // A closed Menu's item shortcut isn't live (OneMix has no main menu), so keep
            // ⌘Q working while the panel is open with an invisible button.
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
