# oed — iPad app

iOS / iPadOS port of oed, built from the same `src/*.Mod` sources
the posix and wasm targets use. SwiftUI shell that hosts the
generic terminal package from `oc/ios/` (`OberonTUI`), Oberon code
compiled with `oc -target arm64-apple-ios*` and linked in as a
static library.

## Layout

    ios/
      project.yml                  XcodeGen spec
      Sources/Oed/
        OedApp.swift               @main, boots Oberon side at launch
        ContentView.swift          full-bleed TerminalView
        Oed-Bridging-Header.h      exposes Oed__init to Swift
      Resources/
        Info.plist                 minimal app plist (iPhone + iPad)
      Scripts/
        build-oberon.sh            Xcode pre-build phase

## Build (one-time setup)

Requires:

- Xcode (with iOS SDK installed via Xcode > Settings > Components)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Sibling checkout of [oc](https://github.com/jdswain/Oberon07-llvm)
  at `../oc/` (the compiler + runtime + `OberonTUI` SPM package)

Generate the Xcode project from `project.yml`:

    cd ios
    xcodegen
    open Oed.xcodeproj

The project is regenerated each run — `ios/Oed.xcodeproj/` is
gitignored. Edit `project.yml` (not the generated project) when
adding sources or build settings.

## What happens at build time

The `Compile Oberon sources` pre-build phase runs
`Scripts/build-oberon.sh`. The script:

1. Resolves the iOS target triple from Xcode's `PLATFORM_NAME` and
   `ARCHS` (`arm64-apple-ios15.0` for device,
   `arm64-apple-ios15.0-simulator` for the Simulator).
2. Stamps that triple in `bin/.target` and clears stale `.smb` /
   `.o` files from `../oc/runtime/ios/` and `../src/` if the
   previous build was for a different target — mirrors the
   `posix-stamp` / `wasm-stamp` pattern in `oed/Makefile`.
3. Runs `oc -target <triple>` on each runtime stub
   (`oc/runtime/ios/{Out,Env,TUI,Files,Controls}.Mod`) and each
   oed module (`src/*.Mod`, skipping `*Test.Mod`).
4. Compiles the runtime C sidecars (`runtime.c`, `TUI_rt.c`,
   `Out_rt.c`, `Env_rt.c`) via the iOS clang against the active
   SDK.
5. Archives every `.o` into
   `$BUILT_PRODUCTS_DIR/liboed_oberon.a`. The Xcode link phase
   picks it up via `OTHER_LDFLAGS` (set in `project.yml`).

The Swift shim that provides `ios_tui_*`, `ios_out_*`, `ios_env_*`
ships from the `OberonTUI` SPM package in `oc/ios/`; the static
library plus the package fully resolve every runtime symbol oed
references.

## What works in this scaffold

- The script builds `liboed_oberon.a` for both device and simulator
  triples (~290 KB each).
- The SwiftUI app boots, calls `oc_set_args(0, nil)` and
  `Oed__init()` — which runs `Oed.Run`, registers the TUI key
  handler, and returns.
- `TerminalView` renders the cell grid (per-cell colour / attr
  styling and cursor painting are still scaffold-grade — see
  `oc/ios/README.md`).

## Known gaps

- **Keyboard input**: `oc_dispatch_key` is declared, but no
  SwiftUI input handler invokes it yet. Hooking
  `View.onKeyPress` (iOS 17+) plus a UIKit `UIKeyCommand` fallback
  for the soft keyboard is the next step.
- **File storage**: `Files.Mod`'s weak stubs make every file
  operation a no-op. Adding `Files_rt.c` in `oc/runtime/ios/` plus
  an `iCloudFiles.swift` shim in `oc/ios/` that maps the Files
  API onto the app's ubiquity-container Documents directory is
  stage 2.
- **One known compiler diagnostic**: `SpreadsheetView.Mod`
  triggers an `LLVM verification failed: Call parameter type does
  not match function signature!` warning during codegen but
  compiles past it. Same warning on posix/wasm — not iOS-specific.
- **App icon, launch screen, code-signing**: all using defaults.
  Wire up before shipping.
