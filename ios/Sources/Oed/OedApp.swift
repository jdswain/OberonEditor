// OedApp.swift — SwiftUI app entry.
//
// At app launch we stash a (no-op on iOS) argv via oc_set_args so
// the runtime sees a valid arg state from the very first module
// body. The Oberon-side init (Oed__init, which transitively runs
// every imported module's init and calls Oed.Run) is deferred to
// TerminalView's onReady callback — fired once after the terminal
// has measured its real cell dimensions. Otherwise the initial
// paint happens at the 24×80 default and gets resized away as
// SwiftUI lays out for real.

import SwiftUI
import OberonTUI
import OberonRuntime

@main
struct OedApp: App {
    init() {
        oc_set_args(0, nil)
        // Resolve relative paths under the app's Documents directory
        // (visible in the Files app — see Info.plist) so Oed.Old /
        // Oed.New write somewhere persistent and user-reachable.
        Env.useDocumentsDirectory()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }
}
