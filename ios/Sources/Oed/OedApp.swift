// OedApp.swift — SwiftUI app entry.
//
// Drives the Oberon side at launch: oc_set_args (no argv on iOS) and
// then Oed__init, which transitively initialises every imported
// module and runs Oed.Run — which in turn registers the TUI key
// handler and returns immediately (iOS / wasm event-driven path).
// Once init has returned, the SwiftUI hierarchy owns the lifecycle:
// keystrokes are dispatched into the Oberon handler via
// oc_dispatch_key from TerminalView's key bindings, and the
// terminal redraws when TerminalState publishes a new frame.

import SwiftUI
import OberonTUI
import OberonRuntime

@main
struct OedApp: App {
    init() {
        oc_set_args(0, nil)
        Oed__init()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }
}
