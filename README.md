# oed — an Oberon text editor

A terminal text editor written in Oberon-07, built on top of the
[`oc`](https://github.com/jdswain/Oberon07Compiler) compiler. The editor is small and Emacs-flavoured; the
underlying buffer is a piece chain after the design of Wirth's
`Texts.Mod` from Project Oberon, adapted for plain ASCII and the
compiler's reference-counted runtime.

The project is a learning exercise in writing real software in
Oberon-07 on a modern host, with an eye toward eventually
cross-compiling to a 65C816. Performance and feature decisions favour
simplicity and code clarity over modern editor conveniences.

## Status

Working, single-buffer editor. Files up to 64 KB load and save; larger
files require the chunk-list storage refactor noted in `doc/ToDo.md`.
96 unit checks pass; the editor itself has been driven end-to-end
under a PTY at every wiring step.

## Features

- Argv-driven file open: `./bin/oed file.txt`.
- Loads existing files, treats missing paths as new-file-on-save.
- Single-buffer view with auto-scroll, status bar, and message line.
- Search: incremental, forward (`C-s`) and reverse (`C-r`).
- Kill ring with 8-slot rotation (`C-w`, `M-w`, `C-y`, `M-y`).
- Save / Save-As / Open via the minibuffer; discard-unsaved guard on
  Open and Quit.

## Build

Prerequisites: the [`oc` compiler](https://github.com/jdswain/Oberon07Compiler)
must be built and available at `../oc/bin/oc` (i.e. cloned as a
sibling to this repo). The compiler in turn depends on LLVM and a
C11 compiler — see its README. After that:

```
make           # builds bin/oed and the test binaries
make check     # runs the BufferTest and LinesTest suites
make run       # launches bin/oed on an empty buffer
make test      # launches the TUI exerciser
make clean     # removes generated files (keeps src/, bin/ goes away)
```

The compiler emits `.o` / `.ll` / `.smb` / `.deps` intermediates
alongside the `.Mod` sources in `src/`; they are git-ignored.

## Usage

```
./bin/oed                  # empty buffer
./bin/oed README.md        # open file (created on first save if absent)
```

## Key bindings

Modelled on Emacs. `C-` is Control, `M-` is Meta (sent as `ESC` then
the key on most terminals).

### Movement

| Key | Action |
|---|---|
| `C-f` / `→` | char forward |
| `C-b` / `←` | char backward |
| `C-n` / `↓` | line down |
| `C-p` / `↑` | line up |
| `C-a` / Home | line start |
| `C-e` / End | line end |
| `M-f` | end of word |
| `M-b` | start of word |
| `M-a` | start of sentence |
| `M-e` | end of sentence |
| `M-<` | start of buffer |
| `M->` | end of buffer |
| PgUp / PgDn | page up / page down |

### Editing

| Key | Action |
|---|---|
| printable | insert at point |
| Enter | newline |
| Backspace / `C-h` | delete char before point |
| `C-d` / Del | delete char at point |

### Search

| Key | Action |
|---|---|
| `C-s` | incremental forward search |
| `C-r` | incremental reverse search |
| (in search) printable | extend query |
| (in search) Backspace | shrink query |
| (in search) `C-s` / `C-r` | next / previous match |
| (in search) Enter | commit at current match |
| (in search) Esc | cancel, restore cursor |

### Kill ring (cut / copy / paste)

| Key | Action |
|---|---|
| `C-Space` | set mark |
| `C-w` | kill region (mark↔point) into kill ring |
| `M-w` | copy region into kill ring |
| `C-k` | kill from point to end of line (or the newline if already at EOL); successive `C-k` append to the same ring entry |
| `C-y` | yank most recent kill |
| `M-y` | yank-pop (after `C-y` or `M-y`): replace with next-older entry |

### Files / buffers / quit

The Ctrl-X prefix gates buffer- and file-level commands.

| Key | Action |
|---|---|
| `C-x C-s` | save (prompts for filename if buffer has none, or if its name is internal like `*scratch*`) |
| `C-x C-w` | save as (always prompts) |
| `C-x C-f` | open file in a new buffer (or switch to existing buffer for that file) |
| `C-x b`   | switch to a named buffer; Tab completes against the buffer list |
| `C-x k`   | kill a buffer (default current; confirms if dirty) |
| `C-x C-b` | list buffers in a `*buffers*` view |
| `C-x C-c` | quit (warns if any buffer has unsaved changes, not just the current one) |

## Architecture

Six modules, ~1200 lines of Oberon-07 plus a small C runtime sidecar
for the things the language can't reach (termios raw mode, byte I/O):

```
Oed   ──┬─►  Mini   ──►  TUI  ──►  TUI_rt.c  (termios, ANSI, escape decoder)
        ├─►  Buffer ──►  Files (oc runtime)
        ├─►  Lines  ──►  Buffer
        └─►  Env (oc runtime: argv pass-through)
```

- **`Buffer.Mod`** — piece-chain text storage. Two byte regions back
  the buffer (immutable `orig` from disk, growing `append` for edits);
  a doubly-linked Piece chain splices them into the logical text.
  `next` is strong, `prev` is `WEAK POINTER` so ARC reclaims a dropped
  chain in one pass. Insert coalesces with the left piece when typing
  is contiguous in `append`, so a typing burst of N chars produces one
  Piece, not N. Includes `Find` / `FindBack` substring search.
- **`Lines.Mod`** — cached table of line-start byte offsets, lazy
  rebuild via an `Invalidate` flag. `Locate` is a binary search;
  `LineStart` / `LineEnd` / `LineLen` are O(1) lookups.
- **`TUI.Mod`** + **`TUI_rt.c`** — terminal I/O. Raw-mode termios with
  `atexit` restore, buffered ANSI output, and a CSI / SS3 / Meta-X
  escape-sequence decoder.
- **`Mini.Mod`** — minibuffer prompts: text input (`Prompt`) and y/n
  confirmation (`Confirm`).
- **`Out.Mod`** + **`Out_rt.c`** — small stdout helper used by the
  test programs.
- **`Oed.Mod`** — the editor proper: cursor as a buffer position,
  scroll-to-cursor on every refresh, mode dispatch (entry / command),
  kill ring, search, file commands.

## Repo layout

```
.
├── Makefile
├── README.md
├── doc/
│   └── ToDo.md           # known issues, deferred work, future ideas
├── src/                  # all Oberon sources + project-local C runtimes
│   ├── Buffer.Mod        BufferTest.Mod
│   ├── Lines.Mod         LinesTest.Mod
│   ├── Mini.Mod
│   ├── Oed.Mod
│   ├── Out.Mod           Out_rt.c
│   └── TUI.Mod           TUI_rt.c           TUITest.Mod
└── bin/                  # generated executables (git-ignored)
    ├── oed               # the editor
    ├── tuitest           # interactive TUI exerciser
    ├── buftest           # Buffer unit checks (57)
    └── linestest         # Lines unit checks (39)
```

Argv pass-through lives in `Env.Mod` / `Env_rt.c`, which were promoted
into the `oc` compiler's runtime distribution (`oc/oberon/`) since
they're broadly useful and not editor-specific.

## Tests

```
make check
```

runs both `bin/buftest` (57 checks) and `bin/linestest` (39 checks).
The buffer tests cover the piece-chain primitives, coalescing,
Save/Load round-trip, and substring search; the line tests cover
empty/single/multi-line cases, trailing newlines, and the
invalidation cycle.

The editor itself (and its TUI) has no automated tests; it has been
driven end-to-end via PTY scripts at every step. A headless TUI
backend would be the natural enabler for proper editor tests; see
`doc/ToDo.md`.

## Roadmap

See `doc/ToDo.md` for known limitations, performance backlog, and
feature ideas (search-and-replace, undo/redo, soft-wrap, larger
files via chunked storage, etc.).

## Acknowledgements

The piece-chain design lifts from Niklaus Wirth's `Texts.Mod` in
Project Oberon — `FindPiece` and `SplitPiece` in particular are
direct ports with the styled-text and font/file machinery stripped.
