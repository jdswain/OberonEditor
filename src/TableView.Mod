MODULE TableView;
(* Read-only tabular rendering of a .tbl view definition over a
   .col data Doc.

   v1 scope: only `@column(name, "Label", width)` projections — the
   first arg is the *name* of a column in the backing collection.
   Computed columns (`@column(c[age]*12, ...)`) are reserved for
   when Expr-in-Directive is wired in.

   `@ref` accepts either an unquoted path (`@ref(/Notes/Contact)`)
   or a string literal (`@ref("/Notes/Contact")`). Project.Resolve
   maps the logical path to a physical base; the caller appends the
   .col extension (see Project.ResolveColl).

   Parsing (TableView.Parse) populates the .tbl Doc's schema with the
   projection columns and writes the @ref path into a separate out
   buffer. Oed.Mod resolves that path, finds or creates a kCollection
   viewer for the data file, and links it via Viewer.dataDoc.

   Rendering walks the data Doc's rows starting from topRow, drawing
   a fixed-width header from the projection's labels and one row per
   visible data row. The current (row, col) is highlighted via the
   reverse-video attribute. *)

  IMPORT Buffer, TUI, Directive, Schema, Csv, Doc, Collection;

  CONST
    MaxField*    = 256;       (* per-cell scratch when reading rows *)
    MaxRowFields = 32;        (* max columns expected in the data row *)
    NL           = 0AX;
    TAB          = 9X;

  TYPE
    rowBuf = ARRAY MaxRowFields OF ARRAY MaxField OF CHAR;

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

  PROCEDURE findRef(b: Buffer.Buffer; VAR refPath: ARRAY OF CHAR);
    VAR pos, content, ep: INTEGER;
        d: Directive.Directive;
        ok, found: BOOLEAN;
        ch: CHAR;
  BEGIN
    pos := 0; found := FALSE;
    WHILE (pos < b.len) & ~found DO
      content := firstNonWS(b, pos);
      IF content >= b.len THEN pos := content
      ELSE
        ch := byteAt(b, content);
        IF ch = "@" THEN
          Directive.Parse(b, content, d, ok, ep);
          IF ok & strEq(d.name, "ref") & (d.narg > 0)
              & ((d.args[0].kind = Directive.APath)
                 OR (d.args[0].kind = Directive.AString)) THEN
            copyStr(refPath, d.args[0].str);
            found := TRUE
          END;
          pos := skipToNL(b, ep)
        ELSE
          pos := skipToNL(b, content)
        END
      END
    END
  END findRef;

  PROCEDURE Parse*(b: Buffer.Buffer; sch: Schema.Schema;
                   VAR refPath: ARRAY OF CHAR);
  (* Walk the .tbl header zone. @column entries populate `sch` (the
     same way Schema.Parse handles a .col header); the first @ref's
     argument string is written to refPath. Other directives are
     silently ignored. *)
  BEGIN
    refPath[0] := 0X;
    Schema.Parse(b, sch);
    findRef(b, refPath)
  END Parse;

  (* ---------------- rendering ---------------- *)

  PROCEDURE drawCell(text: ARRAY OF CHAR; width: INTEGER; highlight: BOOLEAN);
    VAR i, n: INTEGER;
  BEGIN
    IF highlight THEN TUI.SetAttr(TUI.AttrReverse) END;
    n := strLen(text); i := 0;
    WHILE (i < n) & (i < width) DO TUI.Write(text[i]); INC(i) END;
    WHILE i < width DO TUI.Write(" "); INC(i) END;
    IF highlight THEN TUI.SetAttr(TUI.AttrNormal) END;
    TUI.Write(" ")            (* one-char separator between cells *)
  END drawCell;

  PROCEDURE columnWidth(c: Schema.Column): INTEGER;
    VAR w: INTEGER;
  BEGIN
    w := c.width;
    IF w <= 0 THEN w := strLen(c.label) + 2 END;
    IF w < 4 THEN w := 4 END;
    RETURN w
  END columnWidth;

  PROCEDURE ColumnX*(sch: Schema.Schema; col: INTEGER): INTEGER;
  (* Screen X coordinate of the column at index `col` in the
     projection's header row, accounting for separators between
     cells. *)
    VAR i, x: INTEGER;
  BEGIN
    x := 0; i := 0;
    WHILE (sch # NIL) & (i < col) & (i < sch.ncol) DO
      x := x + columnWidth(sch.cols[i]) + 1;
      INC(i)
    END;
    RETURN x
  END ColumnX;

  PROCEDURE drawHeader(sch: Schema.Schema; row: INTEGER);
    VAR i: INTEGER;
  BEGIN
    TUI.MoveTo(0, row); TUI.ClearLine;
    TUI.SetAttr(TUI.AttrReverse);
    i := 0;
    WHILE i < sch.ncol DO
      drawCell(sch.cols[i].label, columnWidth(sch.cols[i]), FALSE);
      INC(i)
    END;
    TUI.SetAttr(TUI.AttrNormal)
  END drawHeader;

  PROCEDURE readRowFields(VAR it: Collection.RowIter; VAR fields: rowBuf; VAR n: INTEGER);
    VAR last: BOOLEAN;
  BEGIN
    n := 0; last := FALSE;
    WHILE ~last & (n < MaxRowFields) DO
      Collection.Field(it, fields[n], last);
      INC(n)
    END
  END readRowFields;

  PROCEDURE drawRow(viewSch, dataSch: Schema.Schema;
                    VAR fields: rowBuf; nFields: INTEGER;
                    isCur: BOOLEAN; curCol: INTEGER);
    VAR j, idx: INTEGER; empty: ARRAY 4 OF CHAR;
  BEGIN
    j := 0;
    WHILE j < viewSch.ncol DO
      idx := Schema.Find(dataSch, viewSch.cols[j].name);
      IF (idx < 0) OR (idx >= nFields) THEN
        empty[0] := 0X;
        drawCell(empty, columnWidth(viewSch.cols[j]), isCur & (j = curCol))
      ELSE
        drawCell(fields[idx], columnWidth(viewSch.cols[j]), isCur & (j = curCol))
      END;
      INC(j)
    END
  END drawRow;

  PROCEDURE Render*(viewDoc, dataDoc: Doc.Doc;
                    topRow, curRow, curCol: INTEGER;
                    viewportRows: INTEGER);
  (* Draws the table from screen row 0 down. Caller manages the
     status bar / message line. dataDoc may be NIL — we then render
     a "data unavailable" notice. *)
    VAR c: Collection.Collection; it: Collection.RowIter;
        n, r: INTEGER;
        fields: rowBuf; nFields: INTEGER;
  BEGIN
    drawHeader(viewDoc.schema, 0);
    IF (dataDoc = NIL) OR (dataDoc.schema = NIL) THEN
      TUI.MoveTo(0, 1); TUI.ClearLine;
      TUI.WriteStr("  (no backing data — @ref not resolved)");
      r := 2;
      WHILE r < viewportRows DO
        TUI.MoveTo(0, r); TUI.ClearLine; TUI.Write("~");
        INC(r)
      END
    ELSE
      c := Collection.Open(dataDoc);
      Collection.OpenIter(c, it);

      (* Skip to topRow. *)
      n := 0;
      WHILE ~it.done & (n < topRow) DO
        Collection.NextRow(it); INC(n)
      END;

      r := 1;
      WHILE r < viewportRows DO
        TUI.MoveTo(0, r); TUI.ClearLine;
        IF it.done THEN
          TUI.Write("~")
        ELSE
          readRowFields(it, fields, nFields);
          drawRow(viewDoc.schema, dataDoc.schema, fields, nFields,
                  n = curRow, curCol);
          Collection.NextRow(it)
        END;
        INC(n); INC(r)
      END
    END
  END Render;

  PROCEDURE RowCount*(dataDoc: Doc.Doc): INTEGER;
  (* Convenience: how many data rows in the backing collection. *)
    VAR c: Collection.Collection; n: INTEGER;
  BEGIN
    IF dataDoc = NIL THEN n := 0
    ELSE
      c := Collection.Open(dataDoc);
      n := Collection.Count(c)
    END;
    RETURN n
  END RowCount;

END TableView.
