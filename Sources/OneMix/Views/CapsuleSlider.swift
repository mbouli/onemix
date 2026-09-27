import SwiftUI

/// Control Center-style capsule slider over 0...1, with a hit area of at least 20 pt.
struct CapsuleSlider: View {
    @Binding var value: Double
    var height: CGFloat
    var fill: Color
    var track: Color
    var symbol: String? = nil

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: max(height, width * value))
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: height * 0.42, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.55))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: height)
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                value = min(max(drag.location.x / width, 0), 1)
            })
        }
        .frame(height: max(height, 20))
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((value * 100).rounded())) percent"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.05, 1)
            case .decrement: value = max(value - 0.05, 0)
            @unknown default: break
            }
        }
    }
}
