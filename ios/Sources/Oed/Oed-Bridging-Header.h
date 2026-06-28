/* Oed-Bridging-Header.h — exposes Oberon-emitted symbols to Swift.
 *
 * The oc compiler emits `<Module>__init()` for every Oberon module
 * (idempotent, transitively initializes imports). Calling
 * `Oed__init()` once at app launch boots the whole editor and
 * registers the TUI key handler via `TUI.SetKeyHandler` inside
 * Oed.Run. After that, keystrokes arrive via OberonRuntime's
 * `oc_dispatch_key`. */

#ifndef OED_BRIDGING_HEADER_H
#define OED_BRIDGING_HEADER_H

void Oed__init(void);

#endif /* OED_BRIDGING_HEADER_H */
