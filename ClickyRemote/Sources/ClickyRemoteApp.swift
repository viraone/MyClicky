import SwiftUI

@main
struct ClickyRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            NumpadView()
                .preferredColorScheme(.dark)
        }
    }
}
