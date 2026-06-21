import SwiftUI

/// HAVM Connect exists solely to let Xcode generate a provisioning profile
/// for the `ch.ingmar.havm` bundle identifier. The CLI (`havm`) piggybacks
/// on this profile to enable `com.apple.developer.accessory-access.usb`.
///
/// Build this project in Xcode once to create the profile, then quit.
/// The profile is picked up automatically by `scripts/build.sh`.

@main
struct HavmConnectApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("HAVM Connect")
                    .font(.title)
                Text("This app exists to provide a provisioning profile for havm.")
                    .foregroundStyle(.secondary)
                Text("You can quit it now.")
                    .foregroundStyle(.tertiary)
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .frame(width: 350, height: 200)
        }
    }
}
