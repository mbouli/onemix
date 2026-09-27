import AppKit
import OneMixCore
import SwiftUI

struct MixerPanel: View {
    let model: MixerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SoundCard(devices: model.devices)

            Text("APPS")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .padding(.top, 4)

            appsSection

            FooterBar(model: model)
        }
        .padding(12)
        .frame(width: 320)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.panelDidOpen()
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        if model.permission == .denied {
            PermissionCard()
        } else if model.rows.isEmpty {
            Text(model.showAllApps ? "No running apps" : "No apps are playing audio")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.rows) { row in
                        AppRow(
                            row: row,
                            failed: model.controller.failedBundleIDs.contains(row.bundleID) || model.nativeFailedBundleIDs.contains(row.bundleID),
                            onVolume: { model.setVolume($0, for: row.bundleID) },
                            onToggleMute: { model.toggleMute(for: row.bundleID) }
                        )
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(model.rows.count) * (AppRow.height + 2), 400))
        }
    }
}
