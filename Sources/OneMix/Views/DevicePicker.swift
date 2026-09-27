import OneMixCore
import SwiftUI

struct DeviceLabel: View {
    let device: OutputDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.transport.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isSelected ? Color.blue : Color.white.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(device.transport.label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

struct DevicePicker: View {
    let devices: OutputDeviceManager
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(devices.devices) { device in
                Button {
                    devices.setDefaultOutput(device)
                    onPick()
                } label: {
                    DeviceLabel(device: device, isSelected: device.id == devices.defaultOutput?.id)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
