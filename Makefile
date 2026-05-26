# Makefile for oed - Oberon-07 terminal text editor.
#
# Layout:
#   src/   Oberon-07 source modules + their C runtime sidecars
#   bin/   linked executables
# The compiler emits intermediate .o / .ll / .smb / .deps files alongside
# the .Mod sources in src/; `make clean` removes them along with bin/.
#
# Env.Mod (argv access), Out.Mod (stdout test helper), and TUI.Mod
# (terminal I/O) live in ../oc/runtime/posix/ — the compiler's
# standard runtime location — so any program that imports them
# picks them up automatically without listing the corresponding
# _rt.c file as an extra.

OC  ?= ../oc/bin/oc
SRC := src
BIN := bin
STAMP := $(BIN)/.target

.PHONY: all run test check clean wasm posix-stamp wasm-stamp

# Source-file list shared by both targets — listed once.
OED_DEPS := $(SRC)/Oed.Mod $(SRC)/Buffer.Mod $(SRC)/Lines.Mod $(SRC)/Mini.Mod \
            $(SRC)/Doc.Mod $(SRC)/Viewers.Mod $(SRC)/Project.Mod $(SRC)/Schema.Mod \
            $(SRC)/Directive.Mod $(SRC)/Collection.Mod $(SRC)/Csv.Mod $(SRC)/Expr.Mod \
            $(SRC)/TableView.Mod $(SRC)/FormView.Mod $(SRC)/SpreadsheetView.Mod \
            $(SRC)/Strings.Mod $(SRC)/KillRing.Mod $(SRC)/Motion.Mod $(SRC)/Render.Mod \
            $(SRC)/Search.Mod $(SRC)/BufList.Mod $(SRC)/FileOps.Mod $(SRC)/Links.Mod \
            $(SRC)/History.Mod $(SRC)/FileBrowser.Mod

all: posix-stamp $(BIN)/oed $(BIN)/tuitest $(BIN)/buftest $(BIN)/linestest $(BIN)/csvtest $(BIN)/directivetest $(BIN)/schematest $(BIN)/colltest $(BIN)/exprtest

# Web target. Builds oed.wasm against the wasm runtime from
# ../oc/runtime/wasm/. The compiler emits .o / .smb / .deps
# alongside each source; those are target-specific. The
# posix-stamp / wasm-stamp helpers clear stale intermediates when
# the target changes so `make` and `make wasm` alternate cleanly.
wasm: wasm-stamp $(BIN)/oed.wasm

# Stamp-based target tracking. If the last recorded target doesn't
# match the one we're about to build, wipe the per-source artifacts
# so the compiler doesn't see a .smb fingerprint from the other
# triple. Always run via .PHONY, so this fires on every make.
posix-stamp: | $(BIN)
	@if [ ! -f $(STAMP) ] || [ "$$(cat $(STAMP))" != "posix" ]; then \
	  echo "[oed] target = posix (clearing src/*.o,.ll,.smb,.deps)"; \
	  rm -f $(SRC)/*.o $(SRC)/*.ll $(SRC)/*.smb $(SRC)/*.deps $(SRC)/*.tmp; \
	  echo posix > $(STAMP); \
	fi

wasm-stamp: | $(BIN)
	@if [ ! -f $(STAMP) ] || [ "$$(cat $(STAMP))" != "wasm" ]; then \
	  echo "[oed] target = wasm  (clearing src/*.o,.ll,.smb,.deps)"; \
	  rm -f $(SRC)/*.o $(SRC)/*.ll $(SRC)/*.smb $(SRC)/*.deps $(SRC)/*.tmp; \
	  echo wasm > $(STAMP); \
	fi

$(BIN)/oed.wasm: $(OED_DEPS) | $(BIN)
	$(OC) -target wasm32 -o $@ $(SRC)/Oed.Mod

$(BIN):
	mkdir -p $(BIN)

$(BIN)/oed: $(OED_DEPS) | $(BIN)
	$(OC) -o $@ $(SRC)/Oed.Mod

$(BIN)/tuitest: $(SRC)/TUITest.Mod | $(BIN)
	$(OC) -o $@ $(SRC)/TUITest.Mod

$(BIN)/buftest: $(SRC)/BufferTest.Mod $(SRC)/Buffer.Mod | $(BIN)
	$(OC) -o $@ $(SRC)/BufferTest.Mod

$(BIN)/linestest: $(SRC)/LinesTest.Mod $(SRC)/Lines.Mod $(SRC)/Buffer.Mod | $(BIN)
	$(OC) -o $@ $(SRC)/LinesTest.Mod

$(BIN)/csvtest: $(SRC)/CsvTest.Mod $(SRC)/Csv.Mod $(SRC)/Buffer.Mod | $(BIN)
	$(OC) -o $@ $(SRC)/CsvTest.Mod

$(BIN)/directivetest: $(SRC)/DirectiveTest.Mod $(SRC)/Directive.Mod $(SRC)/Buffer.Mod | $(BIN)
	$(OC) -o $@ $(SRC)/DirectiveTest.Mod

$(BIN)/schematest: $(SRC)/SchemaTest.Mod $(SRC)/Schema.Mod $(SRC)/Directive.Mod $(SRC)/Buffer.Mod | $(BIN)
	$(OC) -o $@ $(SRC)/SchemaTest.Mod

$(BIN)/colltest: $(SRC)/CollectionTest.Mod $(SRC)/Collection.Mod $(SRC)/Csv.Mod $(SRC)/Lines.Mod $(SRC)/Doc.Mod $(SRC)/Schema.Mod $(SRC)/Directive.Mod $(SRC)/Buffer.Mod | $(BIN)
	$(OC) -o $@ $(SRC)/CollectionTest.Mod

$(BIN)/exprtest: $(SRC)/ExprTest.Mod $(SRC)/Expr.Mod $(SRC)/Buffer.Mod | $(BIN)
	$(OC) -o $@ $(SRC)/ExprTest.Mod

run: $(BIN)/oed
	$(BIN)/oed

test: $(BIN)/tuitest
	$(BIN)/tuitest

check: $(BIN)/buftest $(BIN)/linestest $(BIN)/csvtest $(BIN)/directivetest $(BIN)/schematest $(BIN)/colltest $(BIN)/exprtest
	$(BIN)/buftest && $(BIN)/linestest && $(BIN)/csvtest && $(BIN)/directivetest && $(BIN)/schematest && $(BIN)/colltest && $(BIN)/exprtest

clean:
	rm -f $(SRC)/*.o $(SRC)/*.ll $(SRC)/*.smb $(SRC)/*.deps $(SRC)/*.tmp
	rm -rf $(BIN)
