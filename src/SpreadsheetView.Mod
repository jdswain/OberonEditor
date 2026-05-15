MODULE SpreadsheetView;
(* A1-grid spreadsheet rendering over a .col data file, with
   formula and (later) format overrides supplied by a sibling .ssh
   file as `@cell(coord, key=value)` directives.

   v1 scope:
     - Parse @ref + @cell directives (this commit).
     - A1-only addressing: single-letter columns (A..Z), 1-based row
       numbers. Multi-letter columns (AA..) are deferred.
     - Cell composition: if an override has `formula="=..."`, the
       formula is evaluated via Expr.Mod with a cell-resolving
       Scope; otherwise the cell value comes from the .col CSV at
       (col, row).
     - Read-only display + navigation. Cell-edit / `=`-routing /
       format directives land in the next step.

   Recursion through formulas is bounded by a small depth cap
   (`MaxDepth`) so cyclic refs terminate with an error rather than
   blowing the stack. *)

  IMPORT Buffer, Lines, TUI, Expr, Directive, Schema, Csv, Doc, Collection;

  CONST
    MaxCells*     = 256;
    MaxFormula*   = 256;
    MaxFormat*    = 32;
    MaxCellValue* = 256;
    MaxDepth      = 8;

    DefaultColW = 10;
    RowLabelW   = 4;
    NL          = 0AX;
    TAB         = 9X;

  TYPE
    Cell* = RECORD
      col*, row*: INTEGER;
      formula*: ARRAY MaxFormula OF CHAR;
      format*:  ARRAY MaxFormat OF CHAR
    END;

    CellList* = RECORD
      n*:     INTEGER;
      cells*: ARRAY MaxCells OF Cell
    END;

  VAR
    (* Re-used across formula evaluations. The Scope's `cell`
       callback (cellLookup) reads these globals to find the right
       override / data Doc / depth state. Spreadsheet rendering is
       single-threaded so global state is fine. *)
    evalView:  Doc.Doc;
    evalData:  Doc.Doc;
    evalCells: CellList;
    evalDepth: INTEGER;
    evalScope: Expr.Scope;

  PROCEDURE byteAt(b: Buffer.Buffer; pos: INTEGER): CHAR;
    VAR r: Buffer.Reader; ch: CHAR;
  BEGIN
    Buffer.OpenReader(r, b, pos);
    Buffer.Read(r, ch);
    IF r.eot THEN ch := 0X END;
    RETURN ch
  END byteAt;

  PROCEDURE skipToNL(b: Buffer.Buffer; pos: INTEGER): INTEGER;
  BEGIN
    WHILE (pos < b.len) & (byteAt(b, pos) # NL) DO INC(pos) END;
    IF pos < b.len THEN INC(pos) END;
    RETURN pos
  END skipToNL;

  PROCEDURE firstNonWS(b: Buffer.Buffer; pos: INTEGER): INTEGER;
    VAR ch: CHAR;
  BEGIN
    ch := byteAt(b, pos);
    WHILE (pos < b.len) & ((ch = " ") OR (ch = TAB)) DO
      INC(pos); ch := byteAt(b, pos)
    END;
    RETURN pos
  END firstNonWS;

  PROCEDURE copyStr(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(dst) - 1) & (i < LEN(src)) & (src[i] # 0X) DO
      dst[i] := src[i]; INC(i)
    END;
    dst[i] := 0X
  END copyStr;

  PROCEDURE strEq(a, b: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (a[i] # 0X) & (a[i] = b[i]) DO INC(i) END;
    RETURN a[i] = b[i]
  END strEq;

  PROCEDURE strLen(s: ARRAY OF CHAR): INTEGER;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
    RETURN i
  END strLen;

  PROCEDURE matchCoord(s: ARRAY OF CHAR; VAR col, row: INTEGER): BOOLEAN;
  (* Parse "A1" / "B12" → col 0/1, row 0/11. Returns FALSE if the
     ident doesn't match the v1 single-letter A1 pattern. *)
    VAR i: INTEGER; ok: BOOLEAN;
  BEGIN
    ok := (s[0] >= "A") & (s[0] <= "Z");
    IF ok THEN
      col := ORD(s[0]) - ORD("A");
      i := 1; row := 0;
      ok := (s[i] >= "0") & (s[i] <= "9");
      IF ok THEN
        WHILE (s[i] >= "0") & (s[i] <= "9") DO
          row := row * 10 + (ORD(s[i]) - ORD("0"));
          INC(i)
        END;
        ok := s[i] = 0X;
        IF ok THEN DEC(row) END    (* 1-based → 0-based *)
      END
    END;
    RETURN ok
  END matchCoord;

  PROCEDURE intToStr(n: INTEGER; VAR s: ARRAY OF CHAR);
    VAR digits: ARRAY 16 OF CHAR; i, j: INTEGER; neg: BOOLEAN;
  BEGIN
    neg := n < 0; IF neg THEN n := -n END;
    IF n = 0 THEN
      s[0] := "0"; s[1] := 0X
    ELSE
      i := 0;
      WHILE n > 0 DO
        digits[i] := CHR(ORD("0") + n MOD 10);
        n := n DIV 10; INC(i)
      END;
      j := 0;
      IF neg THEN s[j] := "-"; INC(j) END;
      WHILE i > 0 DO DEC(i); s[j] := digits[i]; INC(j) END;
      s[j] := 0X
    END
  END intToStr;

  PROCEDURE parseInt(s: ARRAY OF CHAR; VAR n: INTEGER): BOOLEAN;
    VAR i: INTEGER; ok, neg: BOOLEAN;
  BEGIN
    n := 0; neg := FALSE; i := 0;
    IF s[0] = "-" THEN neg := TRUE; INC(i) END;
    ok := (s[i] >= "0") & (s[i] <= "9");
    IF ok THEN
      WHILE (s[i] >= "0") & (s[i] <= "9") DO
        n := n * 10 + (ORD(s[i]) - ORD("0")); INC(i)
      END;
      ok := s[i] = 0X;
      IF ok & neg THEN n := -n END
    END;
    RETURN ok
  END parseInt;

  PROCEDURE findCell(VAR cells: CellList; col, row: INTEGER; VAR idx: INTEGER): BOOLEAN;
    VAR i: INTEGER; ok: BOOLEAN;
  BEGIN
    ok := FALSE; i := 0;
    WHILE (i < cells.n) & ~ok DO
      IF (cells.cells[i].col = col) & (cells.cells[i].row = row) THEN
        idx := i; ok := TRUE
      END;
      INC(i)
    END;
    RETURN ok
  END findCell;

  PROCEDURE findRef(b: Buffer.Buffer; VAR refPath: ARRAY OF CHAR;
                    VAR cells: CellList);
  (* Walk the header zone, recording @ref's path and every
     @cell(coord, formula=...) entry. Stops at the first
     non-directive line. *)
    VAR pos, content, ep, col, row: INTEGER;
        d: Directive.Directive;
        ok, refDone: BOOLEAN;
        ch: CHAR;
        i: INTEGER;
  BEGIN
    refPath[0] := 0X;
    cells.n := 0;
    refDone := FALSE;
    pos := 0;
    WHILE pos < b.len DO
      content := firstNonWS(b, pos);
      IF content >= b.len THEN pos := content
      ELSE
        ch := byteAt(b, content);
        IF (ch = NL) OR (ch = "#") THEN
          pos := skipToNL(b, content)
        ELSIF ch = "@" THEN
          Directive.Parse(b, content, d, ok, ep);
          IF ok THEN
            IF ~refDone & strEq(d.name, "ref") & (d.narg > 0)
                & ((d.args[0].kind = Directive.APath)
                   OR (d.args[0].kind = Directive.AString)) THEN
              copyStr(refPath, d.args[0].str);
              refDone := TRUE
            ELSIF strEq(d.name, "cell") & (d.narg >= 1)
                & (d.args[0].kind = Directive.AIdent)
                & matchCoord(d.args[0].str, col, row)
                & (cells.n < MaxCells) THEN
              cells.cells[cells.n].col := col;
              cells.cells[cells.n].row := row;
              cells.cells[cells.n].formula[0] := 0X;
              cells.cells[cells.n].format[0] := 0X;
              (* Walk remaining args for known bindings. Unknown
                 keys are silently dropped in v1 (DDR's
                 forwards-compat is a step-13e+ refinement). *)
              i := 1;
              WHILE i < d.narg DO
                IF d.args[i].isBinding
                    & (d.args[i].kind = Directive.AString) THEN
                  IF strEq(d.args[i].key, "formula") THEN
                    copyStr(cells.cells[cells.n].formula, d.args[i].str)
                  ELSIF strEq(d.args[i].key, "format") THEN
                    copyStr(cells.cells[cells.n].format, d.args[i].str)
                  END
                END;
                INC(i)
              END;
              INC(cells.n)
            END;
            pos := skipToNL(b, ep)
          ELSE
            pos := skipToNL(b, content)
          END
        ELSE
          pos := b.len             (* data zone — bail *)
        END
      END
    END
  END findRef;

  PROCEDURE Parse*(b: Buffer.Buffer; sch: Schema.Schema;
                   VAR refPath: ARRAY OF CHAR;
                   VAR cells: CellList);
  BEGIN
    Schema.Parse(b, sch);          (* mostly empty for .ssh *)
    findRef(b, refPath, cells)
  END Parse;

  PROCEDURE findCellLine(b: Buffer.Buffer; col, row: INTEGER;
                         VAR lineStart, lineEnd: INTEGER): BOOLEAN;
  (* Locate the `@cell(coord, ...)` line for (col, row), if any.
     lineStart points to the start of the line (including any
     leading whitespace) and lineEnd to one past its trailing
     newline, so the caller can splice over it. *)
    VAR pos, ls, content, ep: INTEGER;
        d: Directive.Directive;
        ok, found: BOOLEAN;
        ch: CHAR;
        c2, r2: INTEGER;
  BEGIN
    found := FALSE; pos := 0;
    WHILE (pos < b.len) & ~found DO
      ls := pos;
      content := firstNonWS(b, pos);
      IF content >= b.len THEN pos := content
      ELSE
        ch := byteAt(b, content);
        IF ch = "@" THEN
          Directive.Parse(b, content, d, ok, ep);
          IF ok & strEq(d.name, "cell") & (d.narg >= 1)
              & (d.args[0].kind = Directive.AIdent)
              & matchCoord(d.args[0].str, c2, r2)
              & (c2 = col) & (r2 = row) THEN
            lineStart := ls;
            lineEnd := skipToNL(b, ep);
            found := TRUE
          ELSE
            pos := skipToNL(b, ep)
          END
        ELSE
          pos := skipToNL(b, content)
        END
      END
    END;
    RETURN found
  END findCellLine;

  PROCEDURE appendBytes(b: Buffer.Buffer; VAR pos: INTEGER; s: ARRAY OF CHAR);
    VAR k: INTEGER;
  BEGIN
    k := 0;
    WHILE (k < LEN(s)) & (s[k] # 0X) DO
      Buffer.Insert(b, pos, s[k]); INC(pos); INC(k)
    END
  END appendBytes;

  PROCEDURE writeCoord(b: Buffer.Buffer; VAR pos: INTEGER; col, row: INTEGER);
    VAR rowStr: ARRAY 8 OF CHAR;
  BEGIN
    Buffer.Insert(b, pos, CHR(ORD("A") + col)); INC(pos);
    intToStr(row + 1, rowStr);
    appendBytes(b, pos, rowStr)
  END writeCoord;

  PROCEDURE writeQuoted(b: Buffer.Buffer; VAR pos: INTEGER;
                        key: ARRAY OF CHAR; val: ARRAY OF CHAR);
  (* Append `, key="val"` at pos. *)
  BEGIN
    appendBytes(b, pos, ", ");
    appendBytes(b, pos, key);
    appendBytes(b, pos, "=");
    Buffer.Insert(b, pos, 22X); INC(pos);
    appendBytes(b, pos, val);
    Buffer.Insert(b, pos, 22X); INC(pos)
  END writeQuoted;

  (* Write a full @cell(coord, formula="...", format="...") line at
     pos, including a trailing newline. Bindings with empty values
     are omitted. *)
  PROCEDURE writeCellLine(b: Buffer.Buffer; VAR pos: INTEGER;
                          col, row: INTEGER;
                          formula, format: ARRAY OF CHAR);
  BEGIN
    appendBytes(b, pos, "@cell(");
    writeCoord(b, pos, col, row);
    IF formula[0] # 0X THEN writeQuoted(b, pos, "formula", formula) END;
    IF format[0] # 0X THEN writeQuoted(b, pos, "format", format) END;
    Buffer.Insert(b, pos, ")"); INC(pos);
    Buffer.Insert(b, pos, NL); INC(pos)
  END writeCellLine;

  PROCEDURE ensureTrailingNL(b: Buffer.Buffer; VAR pos: INTEGER);
  BEGIN
    IF (pos > 0) & (byteAt(b, pos - 1) # NL) THEN
      Buffer.Insert(b, pos, NL); INC(pos)
    END
  END ensureTrailingNL;

  PROCEDURE existingBindings(b: Buffer.Buffer; col, row: INTEGER;
                             VAR formula, format: ARRAY OF CHAR);
  (* Pre-read an existing @cell's bindings so they can be preserved
     when updating just one of them. Empty strings if no such line.
     Implemented via a one-cell parse of the buffer. *)
    VAR pos, content, ep, c2, r2, i: INTEGER;
        d: Directive.Directive;
        ok, found: BOOLEAN;
        ch: CHAR;
  BEGIN
    formula[0] := 0X; format[0] := 0X;
    found := FALSE; pos := 0;
    WHILE (pos < b.len) & ~found DO
      content := firstNonWS(b, pos);
      IF content >= b.len THEN pos := content
      ELSE
        ch := byteAt(b, content);
        IF ch = "@" THEN
          Directive.Parse(b, content, d, ok, ep);
          IF ok & strEq(d.name, "cell") & (d.narg >= 1)
              & (d.args[0].kind = Directive.AIdent)
              & matchCoord(d.args[0].str, c2, r2)
              & (c2 = col) & (r2 = row) THEN
            i := 1;
            WHILE i < d.narg DO
              IF d.args[i].isBinding
                  & (d.args[i].kind = Directive.AString) THEN
                IF strEq(d.args[i].key, "formula") THEN
                  copyStr(formula, d.args[i].str)
                ELSIF strEq(d.args[i].key, "format") THEN
                  copyStr(format, d.args[i].str)
                END
              END;
              INC(i)
            END;
            found := TRUE
          ELSE
            pos := skipToNL(b, ep)
          END
        ELSE
          pos := skipToNL(b, content)
        END
      END
    END
  END existingBindings;

  PROCEDURE SetFormula*(viewDoc: Doc.Doc; col, row: INTEGER;
                        formula: ARRAY OF CHAR);
  (* Add or replace the formula= binding for (col, row). Any
     existing format= binding is preserved. *)
    VAR start, end, pos: INTEGER;
        oldFormula, oldFormat: ARRAY MaxFormat OF CHAR;
  BEGIN
    existingBindings(viewDoc.buf, col, row, oldFormula, oldFormat);
    IF findCellLine(viewDoc.buf, col, row, start, end) THEN
      Buffer.Delete(viewDoc.buf, start, end);
      pos := start
    ELSE
      pos := viewDoc.buf.len;
      ensureTrailingNL(viewDoc.buf, pos)
    END;
    writeCellLine(viewDoc.buf, pos, col, row, formula, oldFormat);
    Lines.Invalidate(viewDoc.lines)
  END SetFormula;

  PROCEDURE SetFormat*(viewDoc: Doc.Doc; col, row: INTEGER;
                       format: ARRAY OF CHAR);
  (* Set or clear the format= binding for (col, row). Empty `format`
     drops the binding; if no other bindings remain, removes the
     whole @cell line. Existing formula= is preserved. *)
    VAR start, end, pos: INTEGER;
        oldFormula, oldFormat: ARRAY MaxFormat OF CHAR;
  BEGIN
    existingBindings(viewDoc.buf, col, row, oldFormula, oldFormat);
    IF findCellLine(viewDoc.buf, col, row, start, end) THEN
      Buffer.Delete(viewDoc.buf, start, end);
      pos := start
    ELSE
      pos := viewDoc.buf.len;
      ensureTrailingNL(viewDoc.buf, pos)
    END;
    IF (oldFormula[0] # 0X) OR (format[0] # 0X) THEN
      writeCellLine(viewDoc.buf, pos, col, row, oldFormula, format)
    END;
    Lines.Invalidate(viewDoc.lines)
  END SetFormat;

  PROCEDURE ClearCell*(viewDoc: Doc.Doc; col, row: INTEGER);
  (* Remove any @cell override line for (col, row). No-op if none. *)
    VAR start, end: INTEGER;
  BEGIN
    IF findCellLine(viewDoc.buf, col, row, start, end) THEN
      Buffer.Delete(viewDoc.buf, start, end);
      Lines.Invalidate(viewDoc.lines)
    END
  END ClearCell;

  (* ---------------- composition + formula eval ---------------- *)

  PROCEDURE evalFormula(formula: ARRAY OF CHAR; VAR v: Expr.Value);
  (* `formula` should be the text after the leading `=`. Evaluates
     it in evalScope; returns VError on parse/eval failure. *)
    VAR b: Buffer.Buffer; i, ep: INTEGER;
  BEGIN
    b := Buffer.New();
    i := 0;
    WHILE (i < LEN(formula)) & (formula[i] # 0X) DO
      Buffer.Insert(b, i, formula[i]); INC(i)
    END;
    Expr.Eval(b, 0, evalScope, v, ep)
  END evalFormula;

  PROCEDURE cellLookup(col, row: INTEGER; VAR v: Expr.Value);
  (* Scope.cell hook. Look up the value at (col, row): if an
     override has a `=` formula, eval recursively; otherwise read
     the .col cell. Pushes / pops evalDepth, error on cap-hit. *)
    VAR idx, intVal: INTEGER;
        f: ARRAY MaxFormula OF CHAR;
        raw: ARRAY MaxCellValue OF CHAR;
        coll: Collection.Collection;
        rowStart: INTEGER;
        i: INTEGER;
  BEGIN
    IF evalDepth >= MaxDepth THEN
      v.kind := Expr.VError
    ELSE
      INC(evalDepth);
      IF findCell(evalCells, col, row, idx) THEN
        copyStr(f, evalCells.cells[idx].formula);
        IF f[0] = "=" THEN
          (* Strip leading `=` and evaluate. *)
          i := 0;
          WHILE f[i + 1] # 0X DO f[i] := f[i + 1]; INC(i) END;
          f[i] := 0X;
          evalFormula(f, v)
        ELSE
          (* Plain override — treat as literal. Try integer first. *)
          IF parseInt(f, intVal) THEN
            v.kind := Expr.VInt; v.int := intVal
          ELSE
            v.kind := Expr.VString;
            copyStr(v.str, f)
          END
        END
      ELSIF evalData # NIL THEN
        coll := Collection.Open(evalData);
        rowStart := Collection.FindRow(coll, row);
        IF rowStart < 0 THEN
          v.kind := Expr.VString; v.str[0] := 0X
        ELSE
          Collection.GetCell(coll, rowStart, col, raw);
          IF raw[0] = 0X THEN
            v.kind := Expr.VString; v.str[0] := 0X
          ELSIF parseInt(raw, intVal) THEN
            v.kind := Expr.VInt; v.int := intVal
          ELSE
            v.kind := Expr.VString; copyStr(v.str, raw)
          END
        END
      ELSE
        v.kind := Expr.VError
      END;
      DEC(evalDepth)
    END
  END cellLookup;

  PROCEDURE valueToStr(VAR v: Expr.Value; VAR s: ARRAY OF CHAR);
  BEGIN
    IF v.kind = Expr.VInt THEN intToStr(v.int, s)
    ELSIF v.kind = Expr.VBool THEN
      IF v.bool THEN copyStr(s, "true") ELSE copyStr(s, "false") END
    ELSIF v.kind = Expr.VString THEN copyStr(s, v.str)
    ELSIF v.kind = Expr.VNil THEN copyStr(s, "nil")
    ELSE copyStr(s, "#ERR")
    END
  END valueToStr;

  PROCEDURE composeCell(col, row: INTEGER; VAR display: ARRAY OF CHAR);
    VAR v: Expr.Value;
  BEGIN
    evalDepth := 0;
    cellLookup(col, row, v);
    valueToStr(v, display)
  END composeCell;

  (* ---------------- rendering ---------------- *)

  PROCEDURE drawSpaces(n: INTEGER);
    VAR i: INTEGER;
  BEGIN
    i := 0; WHILE i < n DO TUI.Write(" "); INC(i) END
  END drawSpaces;

  PROCEDURE drawCellText(text: ARRAY OF CHAR; width: INTEGER;
                         highlight, bold: BOOLEAN);
    VAR i, n: INTEGER;
  BEGIN
    IF highlight OR bold THEN TUI.SetAttr(TUI.AttrReverse) END;
    n := strLen(text); i := 0;
    WHILE (i < n) & (i < width) DO TUI.Write(text[i]); INC(i) END;
    WHILE i < width DO TUI.Write(" "); INC(i) END;
    IF highlight OR bold THEN TUI.SetAttr(TUI.AttrNormal) END;
    TUI.Write(" ")
  END drawCellText;

  PROCEDURE cellFormat(VAR cells: CellList; col, row: INTEGER;
                       VAR fmt: ARRAY OF CHAR);
    VAR i: INTEGER; done: BOOLEAN;
  BEGIN
    fmt[0] := 0X;
    i := 0; done := FALSE;
    WHILE (i < cells.n) & ~done DO
      IF (cells.cells[i].col = col) & (cells.cells[i].row = row) THEN
        copyStr(fmt, cells.cells[i].format);
        done := TRUE
      END;
      INC(i)
    END
  END cellFormat;

  PROCEDURE drawColLabel(col, width: INTEGER);
    VAR label: ARRAY 4 OF CHAR;
        i, pad: INTEGER;
  BEGIN
    label[0] := CHR(ORD("A") + col); label[1] := 0X;
    pad := (width - 1) DIV 2;
    drawSpaces(pad);
    TUI.WriteStr(label);
    i := pad + 1;
    WHILE i < width DO TUI.Write(" "); INC(i) END;
    TUI.Write(" ")
  END drawColLabel;

  PROCEDURE drawRowLabel(row, width: INTEGER);
    VAR label: ARRAY 8 OF CHAR; n, i: INTEGER;
  BEGIN
    intToStr(row + 1, label);
    n := strLen(label);
    i := n;
    WHILE i < width - 1 DO TUI.Write(" "); INC(i); INC(n) END;
    TUI.WriteStr(label);
    TUI.Write(" ")
  END drawRowLabel;

  PROCEDURE Render*(viewDoc, dataDoc: Doc.Doc;
                    VAR cells: CellList;
                    topRow, leftCol, curRow, curCol, viewportRows: INTEGER;
                    VAR cursRow, cursCol: INTEGER);
    VAR row, col, screenRow, visibleCols: INTEGER;
        val: ARRAY MaxCellValue OF CHAR;
        fmt: ARRAY MaxFormat OF CHAR;
        isCur, isBold: BOOLEAN;
  BEGIN
    (* Bind eval state for cellLookup. *)
    evalView  := viewDoc;
    evalData  := dataDoc;
    evalCells := cells;
    evalDepth := 0;
    evalScope.col := NIL;
    evalScope.prompt := NIL;
    evalScope.spreadsheet := TRUE;
    (* evalScope.cell is bound once in the module body. *)

    visibleCols := (TUI.Cols - RowLabelW - 1) DIV (DefaultColW + 1);
    IF visibleCols < 1 THEN visibleCols := 1 END;

    cursRow := 1; cursCol := RowLabelW;

    (* Header row. *)
    TUI.MoveTo(0, 0); TUI.ClearLine;
    TUI.SetAttr(TUI.AttrReverse);
    drawSpaces(RowLabelW);
    TUI.Write(" ");
    col := leftCol;
    WHILE col < leftCol + visibleCols DO
      drawColLabel(col, DefaultColW);
      INC(col)
    END;
    TUI.SetAttr(TUI.AttrNormal);

    (* Body rows. *)
    row := topRow; screenRow := 1;
    WHILE screenRow < viewportRows DO
      TUI.MoveTo(0, screenRow); TUI.ClearLine;
      drawRowLabel(row, RowLabelW);
      col := leftCol;
      WHILE col < leftCol + visibleCols DO
        composeCell(col, row, val);
        cellFormat(cells, col, row, fmt);
        isBold := strEq(fmt, "bold");
        isCur := (row = curRow) & (col = curCol);
        IF isCur THEN
          cursRow := screenRow;
          cursCol := RowLabelW + 1 + (col - leftCol) * (DefaultColW + 1)
        END;
        drawCellText(val, DefaultColW, isCur, isBold);
        INC(col)
      END;
      INC(row); INC(screenRow)
    END
  END Render;

  PROCEDURE ColumnWidth*(): INTEGER;
  BEGIN RETURN DefaultColW
  END ColumnWidth;

  PROCEDURE VisibleColumns*(screenCols: INTEGER): INTEGER;
  (* How many A1 columns fit on the screen, accounting for the row
     label gutter and per-column separator. *)
    VAR n: INTEGER;
  BEGIN
    n := (screenCols - RowLabelW - 1) DIV (DefaultColW + 1);
    IF n < 1 THEN n := 1 END;
    RETURN n
  END VisibleColumns;

BEGIN
  evalScope.cell := cellLookup;
  evalScope.col := NIL;
  evalScope.prompt := NIL;
  evalScope.spreadsheet := TRUE
END SpreadsheetView.
