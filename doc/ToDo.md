# oed ToDo

Marking convention: `x` done, `/` in progress, blank or `-` open.

## Buffer / storage

x File size cap. `Region` is now a chunk list of 4 KB blocks, allocated on demand. Empty buffer holds zero data chunks; grows by one `NEW(Chunk)` per 4 KB of content. Cap is `MaxChunks * ChunkSize = 1 MB` per region (2 MB per buffer). No realloc-and-copy on grow.
- Extract storage to `Storage.Mod`. Current internal helpers `getByte` / `appendByte` plus `src: INTEGER` tag are sized for this lift; concrete backends (`MemStorage`, `FileStorage`, `ChunkedStorage`) extend `StorageDesc` and Piece's `src` becomes `Storage.Storage`. Public Buffer API stays unchanged.
- `Buffer.InsertBytes(b, pos, bytes, n)` batch primitive. Yank inserts char-by-char, each going through `FindPiece` + `SplitPiece`. Caches make this fast in practice but it's O(n·log) instead of O(n).
- Backup-on-save. Wirth's `Edit.Mod` renames the existing file to `.Bak` before writing; we don't.
- Cut/paste piece chain (Wirth-style `Texts.Buffer`). Originally deferred at design time; the kill ring at the editor level covers our current use case, but a piece-level `Clip` type would be a cleaner fit if we ever need region-typed cut/paste with richer than ASCII content.
- Bump `MaxChunks` to grow the per-region cap past 1 MB. For very large files we'd want a sparse chunk index (current is a flat array of 256 pointers per region = 2 KB overhead; bumping to e.g. 4096 chunks for 16 MB doubles the overhead).

## Lines

x Incremental update on edit. `Lines.Inserted(pos, count)` and `Lines.Deleted(beg, end)` now apply the delta to `starts[]` directly; full rebuild only happens on `Lines.Invalidate` (used by `Buffer.Load`). Equivalence with rebuild verified by 10 unit tests. Measured ~0.2 ms per keystroke roundtrip on a 1000-line buffer.
- `MaxLines = 8192` cap. Past that, `LineStart` for indices ≥ `MaxLines` is inaccurate. Documented; revisit if real files trip it.

## Editor (Oed)

- **Mark moves with edits incoherently.** Set mark at pos 10, delete chars 3–5: bytes that were at pos 10 are now at pos 7, but `mark` still says 10. Fix: hook mark updates into Buffer mutations, or invalidate mark on every edit.
- **Yank state desyncs on edit-between-yanks.** `yankStart` / `yankLen` are absolute. C-y, type a char, M-y currently errors via the `lastWasYank` reset (which fires for printable inserts) — defensive accident, not a designed safeguard.
- **Path expansion in minibuffer prompts.** Typed `~/notes.txt` is the literal name; `Files.Old` fails on `~`. Add tilde expansion plus a future tab-completion hook.
- **Tab completion in minibuffer.** Currently no-op. Hooks into a directory-scan helper.
- **Match highlighting in search.** Currently the cursor jumps to a match's end — accurate but invisible without context. Track match-start through `DrawBufferAndLocateCursor` and apply `TUI.SetAttr(AttrReverse)` for `qLen` chars.
- **Sentence-backward (`M-a`) is O(buffer.len)** every invocation — walks from byte 0. Could memoize alongside `Lines.Mod`.
- **`charAt` opens a fresh Reader per call.** Sequential walks are amortized O(1) via piece cache; random access still does the full FindPiece. Probably fine.

## TUI

- **Unrecognized Meta-X eats the followup char.** `ESC q` returns plain Esc, the `q` is consumed. Proper fix: pushback queue in TUI so unhandled bytes are returned on the next `ReadKey`.
- **Escape-sequence timeout is 100 ms.** Local PTY is fine. Slow ttys / high-latency SSH could split a real Meta press into bare Esc plus the printable.
- **C-Space sends NUL on most terminals but not all.** Documented in the `KeyCtrlSpace` constant. If it bites, fall back to `M-Space` or similar.

## Compiler bugs found & fixed

x **Procedure values lowered to NIL.** `LoadItem` in `ORG.c` sent procedure-typed `ORB_Const` items through `ConstOfType`, which collapses any pointer type to `NULL`. Result: `var := someProc`, `Call(someProc)`, and any procedure-passed-as-parameter all silently became NIL. Fixed by short-circuiting in `LoadItem` to use `x->backend` when the type form is `ORB_Proc`. Repro: a one-liner `h := Foo` showed `store ptr null` instead of `store ptr @Foo` in the IR.

## Compiler quirks (workarounds in place)

- **`Piece*` and `PieceDesc*` exported from Buffer**, fields private. Workaround for an `oc` front-end crash: a hidden record-type with a `WEAK POINTER` self-reference, used as a field of an exported pointer type, segfaults the importer. Reproduced minimally; documented in Buffer.Mod.
- **`CHR(k)` doesn't truncate.** Passing `CHR(k)` directly to a CHAR-typed parameter (e.g. `TUI.Write`) emits an `i32` call to an `i8` formal and triggers an LLVM verifier warning. Workaround: assign `CHR(k)` to a CHAR local first, which forces the truncating store. Used in `TUITest`, `Oed.EntryKey`, `Mini.Prompt`.
- **String CONST as ARRAY OF CHAR argument is rejected** as "not an L-value". Workaround: inline the literal at the call site (we hit this twice — `Version` in `Oed.Mod`, `DefaultName` in the early Save plumbing).
- **Open-array value parameters are read-only** — can't be passed onward to `VAR ARRAY OF CHAR`. Workaround: declare the formal `VAR` (`Mini.Prompt(prompt: ARRAY OF CHAR; ...)` had to switch some helpers to VAR; `BufferTest`'s `Expect` and `StrEq` similarly).
- **Stub-as-weak requires "empty body or single RETURN".** A body with even `s[0] := 0X` produces a strong symbol that conflicts with the C runtime override. Verified in Env.Mod when `Arg`'s stub had to be stripped.
- **`RETURN` not allowed in proper procedures.** Restructure as `IF cond THEN body END` (hit in `Buffer.Delete` early-out and `Lines.LineToPos`).

## Compiler features (deferred but planned)

- **Java-style `Main(args)` detected by the compiler.** Currently a code-convention: the entry module calls `Main` from its `BEGIN` block, and `Env.Arg(i, VAR s)` reads argv from the runtime. The compiler-enforced version (auto-detect exported `Main*` and call after init, with a typed args parameter) is cleaner but needs an `ORP.c` patch and a runtime convention for marshalling argv.

## Test infrastructure

- **PTY scripted input gotcha** worth remembering: `\x1b[B` byte-by-byte ≠ Down arrow. The TUI escape-sequence decoder times out at 100 ms; in tests, send each escape sequence as one `os.write` call.
- **No tests for Mini.Mod or for the editor's interactive paths.** The TUI dependency makes it expensive to fixture; we rely on PTY smoke tests in conversation. A small "headless TUI" backend (writing into an in-memory framebuffer) would let us script tests properly.

## Performance backlog

x `PosToColRow` removed in favour of `Lines.Locate`.
x Status-bar and scroll calls now O(log lines) instead of O(buffer.len).
- Refresh paints the entire viewport every frame. For 65C816, region-dirty tracking would matter; for host PTY it's invisible.

## Feature ideas

- **Search-and-replace** (uses Mini for both prompts; reuses `Buffer.Find`).
- **Undo/redo** — wants a real change-log layer over Buffer (record Insert/Delete with their args; replay in reverse).
- **`M-d` / `M-Backspace`** kill-word-forward / kill-word-backward. Composes word motion + kill. The Meta plumbing is already warm.
- **`C-l`** (currently no-op) → recenter viewport on cursor.
- **Auto-indent** on Enter — copy leading whitespace from previous line.
- **Soft line wrapping.** When a buffer line exceeds `TUI.Cols`, wrap visually within the same logical line. Means Lines becomes width-aware and the render walk has to handle screen-row vs buffer-line separation.

# Tables (future feature, separate from above)

Tables are a view over a collection.
Filters and Ordering can be applied.
Table definitions include a list of Fields to display, including Format.
Parameters are header information that can be used in a table display (Cabinets!)

    @table("/Objects/Contact")
