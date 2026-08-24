import SwiftUI

@main
struct BatteryScopeApp: App {
    @StateObject private var provider = BatteryDataProvider()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(provider)
                .onAppear { provider.refresh() }
                .preferredColorScheme(.light)
        }
    }
}
