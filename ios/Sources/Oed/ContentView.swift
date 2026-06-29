// ContentView.swift — the single-view shell hosting the terminal.
//
// Hands TerminalView an onReady block that boots the Oberon side
// after the terminal has measured its real cell dimensions. Calling
// Oed__init earlier would paint at the default 24×80 grid before
// SwiftUI's layout pass settled on the real size, and the resize
// would wipe the paint. (TerminalState.resize now preserves cells
// across resizes too, but deferring init is the cleaner pattern —
// it also matches the wasm port, where Oed__init runs once after
// the DOM grid is sized.)

import SwiftUI
import OberonTUI

struct ContentView: View {
    var body: some View {
        TerminalView(onReady: { Oed__init() })
            // Black extends edge-to-edge (under status bar + rounded
            // corners), but the terminal's own content stays inside
            // the safe area so the first row isn't clipped by the
            // notch / status bar / home indicator.
            .background(Color.black.ignoresSafeArea())
    }
}

#Preview {
    ContentView()
}
