# Makefile for oed - Oberon-07 terminal text editor.
#
# Layout:
#   src/   Oberon-07 source modules + their C runtime sidecars
#   bin/   linked executables
# The compiler emits intermediate .o / .ll / .smb / .deps files alongside
# the .Mod sources in src/; `make clean` removes them along with bin/.
#
# Env.Mod (argv access) lives in ../oc/oberon/ — the compiler's standard
# runtime location — so any program that imports it picks it up
# automatically without listing Env_rt.c as an extra.

OC  ?= ../oc/bin/oc
SRC := src
BIN := bin

RUNTIMES := $(SRC)/TUI_rt.c

.PHONY: all run test check clean

all: $(BIN)/oed $(BIN)/tuitest $(BIN)/buftest $(BIN)/linestest $(BIN)/csvtest $(BIN)/directivetest $(BIN)/schematest $(BIN)/colltest $(BIN)/exprtest

$(BIN):
	mkdir -p $(BIN)

$(BIN)/oed: $(SRC)/Oed.Mod $(SRC)/TUI.Mod $(SRC)/Buffer.Mod $(SRC)/Lines.Mod $(SRC)/Mini.Mod $(SRC)/Doc.Mod $(SRC)/Viewers.Mod $(SRC)/Project.Mod $(SRC)/Schema.Mod $(SRC)/Directive.Mod $(SRC)/Collection.Mod $(SRC)/Csv.Mod $(SRC)/TableView.Mod $(SRC)/TUI_rt.c | $(BIN)
	$(OC) -o $@ $(SRC)/Oed.Mod $(RUNTIMES)

$(BIN)/tuitest: $(SRC)/TUITest.Mod $(SRC)/TUI.Mod $(SRC)/TUI_rt.c | $(BIN)
	$(OC) -o $@ $(SRC)/TUITest.Mod $(RUNTIMES)

$(BIN)/buftest: $(SRC)/BufferTest.Mod $(SRC)/Buffer.Mod $(SRC)/Out.Mod $(SRC)/Out_rt.c | $(BIN)
	$(OC) -o $@ $(SRC)/BufferTest.Mod $(SRC)/Out_rt.c

$(BIN)/linestest: $(SRC)/LinesTest.Mod $(SRC)/Lines.Mod $(SRC)/Buffer.Mod $(SRC)/Out.Mod $(SRC)/Out_rt.c | $(BIN)
	$(OC) -o $@ $(SRC)/LinesTest.Mod $(SRC)/Out_rt.c

$(BIN)/csvtest: $(SRC)/CsvTest.Mod $(SRC)/Csv.Mod $(SRC)/Buffer.Mod $(SRC)/Out.Mod $(SRC)/Out_rt.c | $(BIN)
	$(OC) -o $@ $(SRC)/CsvTest.Mod $(SRC)/Out_rt.c

$(BIN)/directivetest: $(SRC)/DirectiveTest.Mod $(SRC)/Directive.Mod $(SRC)/Buffer.Mod $(SRC)/Out.Mod $(SRC)/Out_rt.c | $(BIN)
	$(OC) -o $@ $(SRC)/DirectiveTest.Mod $(SRC)/Out_rt.c

$(BIN)/schematest: $(SRC)/SchemaTest.Mod $(SRC)/Schema.Mod $(SRC)/Directive.Mod $(SRC)/Buffer.Mod $(SRC)/Out.Mod $(SRC)/Out_rt.c | $(BIN)
	$(OC) -o $@ $(SRC)/SchemaTest.Mod $(SRC)/Out_rt.c

$(BIN)/colltest: $(SRC)/CollectionTest.Mod $(SRC)/Collection.Mod $(SRC)/Csv.Mod $(SRC)/Lines.Mod $(SRC)/Doc.Mod $(SRC)/Schema.Mod $(SRC)/Directive.Mod $(SRC)/Buffer.Mod $(SRC)/Out.Mod $(SRC)/Out_rt.c | $(BIN)
	$(OC) -o $@ $(SRC)/CollectionTest.Mod $(SRC)/Out_rt.c

$(BIN)/exprtest: $(SRC)/ExprTest.Mod $(SRC)/Expr.Mod $(SRC)/Buffer.Mod $(SRC)/Out.Mod $(SRC)/Out_rt.c | $(BIN)
	$(OC) -o $@ $(SRC)/ExprTest.Mod $(SRC)/Out_rt.c

run: $(BIN)/oed
	$(BIN)/oed

test: $(BIN)/tuitest
	$(BIN)/tuitest

check: $(BIN)/buftest $(BIN)/linestest $(BIN)/csvtest $(BIN)/directivetest $(BIN)/schematest $(BIN)/colltest $(BIN)/exprtest
	$(BIN)/buftest && $(BIN)/linestest && $(BIN)/csvtest && $(BIN)/directivetest && $(BIN)/schematest && $(BIN)/colltest && $(BIN)/exprtest

clean:
	rm -f $(SRC)/*.o $(SRC)/*.ll $(SRC)/*.smb $(SRC)/*.deps $(SRC)/*.tmp
	rm -rf $(BIN)
