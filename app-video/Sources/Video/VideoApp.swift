import SwiftUI

@main
struct VideoApp: App {
    var body: some Scene {
        WindowGroup("ClipFlow") {
            ContentView()
                .frame(minWidth: 560, minHeight: 520)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 620, height: 600)
    }
}
