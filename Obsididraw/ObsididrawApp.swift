import SwiftUI

@main
struct ObsididrawApp: App {
    @State private var store = VaultStore()
    @AppStorage("appearance") private var appearance = AppAppearance.system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
