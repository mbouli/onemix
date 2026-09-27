import SwiftUI

@main
struct OneMixApp: App {
    @State private var model = MixerViewModel()

    var body: some Scene {
        MenuBarExtra("OneMix", systemImage: "slider.vertical.3") {
            MixerPanel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
