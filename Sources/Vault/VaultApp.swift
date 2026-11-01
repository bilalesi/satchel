import SwiftUI
import VaultCore

@main
struct VaultApp: App {
    var body: some Scene {
        WindowGroup(AppIdentity.name) {
            Text(AppIdentity.name)
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}
