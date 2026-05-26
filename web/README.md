# oed in the browser

Web target for oed. Reuses the wasm runtime, JS shims, and Go file-API
server from the [oc](../../oc/) project. The Go server serves the
static page, redirects `/oed.wasm` to the build output, and proxies
file I/O to a local FileStore directory.

## Build the wasm

From the repo root:

```
make wasm
```

This produces `bin/oed.wasm` against the wasm runtime in
`../oc/runtime/wasm/`.

## Run

Start the shared oc server, pointing it at this `web/` dir (for
`index.html`), at `bin/` (for `oed.wasm`), and at a FileStore root
that holds the documents you want to edit:

```
cd ../oc/server && go build
./server -web ../../oed/web -wasm ../../oed/bin -store /path/to/files
```

Open `http://localhost:8080/`. The page loads `oed.wasm`; the editor
grid renders into `<div id="term">`. The `dist/` and `fonts/`
directories alongside `index.html` are symlinks back into
`../../oc/web/` so the JS shims and the 3270 webfont stay shared.

## Status

Both targets share the same source. The top-level dispatch is
event-driven: `TUI.SetKeyHandler(handleKey)` then `TUI.Run`. Each
keystroke flows through one of three modes — Mini.Active (minibuffer
prompt), Search.Active (incremental search), or normal editor — and
the handler repaints between events. On posix `TUI.Run` blocks
reading the PTY and dispatches per ReadKey; on wasm it returns and
the JS host calls `oc_dispatch_key` from the browser keydown event.

What works:

- Editor: motion (arrows, Ctrl-{A,B,E,F,N,P}, Meta-{f,b,a,e,<,>}, Home, End, PageUp/Down), text insertion, backspace / delete / Ctrl-D, kill-region (Ctrl-W) and yank (Ctrl-Y / Meta-y), markdown link / heading rendering, status bar, frame refresh.
- Minibuffer prompts: open (Ctrl-X Ctrl-F), save (Ctrl-X Ctrl-S), save-as (Ctrl-X Ctrl-W), switch buffer (Ctrl-X b), kill buffer (Ctrl-X k), edit link URL (Ctrl-X l), open-as-text (Ctrl-X Ctrl-R), confirms (quit, dirty-kill, create-missing-dir).
- Incremental search (Ctrl-S / Ctrl-R) — extend, re-search, backspace, Enter to commit, Esc to cancel.
- History (Ctrl-X , back, Ctrl-X . forward) — link follow, switch buffer, and open all push onto the back stack; back / forward walk it.
- File I/O on wasm rides the `Files.Mod` shim → `/api/files/<projectBase>/<path>` on the server.
- Tab completion in filename prompts (`C-x C-f`, `C-x C-s` save-as, etc.) — works on both targets via `Files.OpenDir` / `Files.NextEntry` / `Files.CloseDir`. On wasm the JS shim translates these to a single sync `GET /api/files/<dir>?list=1`, caches the response, and replays it through next_entry.

## How it works

`Mini.Mod` and `Search.Mod` are event-driven modal handlers. Each
exports `Active()` / `HandleKey(k)` / paint helpers. The editor's
top-level handler:

```
PROCEDURE handleKey(k: INTEGER);
BEGIN
  IF Mini.Active() THEN
    Mini.HandleKey(k)                    (* commit fires done callback *)
  ELSIF Search.Active() THEN
    Search.HandleKey(k);
    cur := Search.Cur()                  (* live cursor as user types *)
  ELSE
    IF mode = ModeEntry THEN EntryKey(k) ELSE CommandKey(k) END
  END;
  IF running THEN Refresh ELSE …teardown… END
END handleKey;
```

`Mini.Prompt(prompt, completer, done)` registers a `PromptDone` and
returns immediately. `Mini.HandleKey` accumulates characters; on
Enter / Esc it invokes `done(result, ok)` synchronously. The done
callback can chain further prompts — e.g. `Save` posts a
`Mini.Confirm` from inside the `Save-as` done if the target
directory is missing. Pending state for those chains (kill-target,
save-dir, link byte ranges) lives in module-level vars in
`Oed.Mod`. Since procedures in Oberon-07 aren't closures, the done
callbacks read those globals plus the editor's own (`cur`, `curCol`,
`buf`, `lines`, `name`) directly. Keys never reach the editor while
a prompt is active, so those globals stay frozen for the duration
of the prompt and the done can safely reuse them.
