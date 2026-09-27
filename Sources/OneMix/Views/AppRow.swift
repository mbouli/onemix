import AppKit
import OneMixCore
import SwiftUI

struct AppRow: View {
    static let height: CGFloat = 56

    let row: AppRowData
    let failed: Bool
    let onVolume: (Float) -> Void
    let onToggleMute: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(pid: row.pid, bundleID: row.bundleID)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                            .help("OneMix couldn't control this app's audio")
                    }
                    Spacer(minLength: 4)
                    Text("\(Int((row.volume * 100).rounded()))%")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                CapsuleSlider(
                    value: Binding(get: { Double(row.volume) }, set: { onVolume(Float($0)) }),
                    height: 6,
                    fill: .white.opacity(0.6),
                    track: .white.opacity(0.14)
                )
                .opacity(row.isMuted ? 0.4 : 1)
            }

            Button(action: onToggleMute) {
                Image(systemName: row.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.isMuted ? "Unmute" : "Mute")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0))
        )
        .onHover { hovering = $0 }
    }
}

struct AppIcon: View {
    let pid: pid_t
    let bundleID: String

    var body: some View {
        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
    }

    private var icon: NSImage {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon { return icon }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
    }
}
