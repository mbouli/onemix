import AppKit
import OneMixCore
import SwiftUI

struct PermissionCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Audio access needed", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .semibold))
            Text("To change each app's volume, OneMix needs System Audio Recording access. Audio never leaves your Mac.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                NSWorkspace.shared.open(AudioCapturePermission.settingsURL)
            }
            .buttonStyle(.glass)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
