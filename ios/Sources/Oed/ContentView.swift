// ContentView.swift — the single-view shell hosting the terminal.
//
// Scaffold version: full-bleed TerminalView. Keyboard input wiring
// (View.onKeyPress / UIKeyCommand → oc_dispatch_key) comes next; for
// now the terminal renders whatever Oed.Run paints at launch.

import SwiftUI
import OberonTUI

struct ContentView: View {
    var body: some View {
        TerminalView()
            .background(Color.black)
            .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
