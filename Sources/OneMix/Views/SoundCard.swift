import OneMixCore
import SwiftUI

struct SoundCard: View {
    let devices: OutputDeviceManager
    @State private var showsPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sound").font(.system(size: 15, weight: .semibold))

            CapsuleSlider(
                value: Binding(
                    get: { devices.isMuted ? 0 : Double(devices.volume) },
                    set: { devices.setVolume(Float($0)) }
                ),
                height: 28,
                fill: .white,
                track: .white.opacity(0.16),
                symbol: masterSymbol
            )
            .disabled(!devices.hasVolumeControl)
            .opacity(devices.hasVolumeControl ? 1 : 0.4)

            if let output = devices.defaultOutput {
                Button {
                    withAnimation(.snappy) { showsPicker.toggle() }
                } label: {
                    HStack {
                        DeviceLabel(device: output, isSelected: true)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showsPicker ? 90 : 0))
                    }
                }
                .buttonStyle(.plain)
            }

            if showsPicker {
                DevicePicker(devices: devices) {
                    withAnimation(.snappy) { showsPicker = false }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var masterSymbol: String {
        if devices.isMuted || devices.volume == 0 { return "speaker.slash.fill" }
        switch devices.volume {
        case ..<0.33: return "speaker.wave.1.fill"
        case ..<0.66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
