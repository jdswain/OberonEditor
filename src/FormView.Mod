MODULE FormView;
(* Single-record card rendering of a .frm view definition over a
   .col data Doc.

   A .frm file has a directive header (typically @ref plus, in
   future, @prompt and @filter), a single blank line, then layout
   text that is rendered verbatim except that `@field(name)` or
   `@field(c[name])` placeholders are substituted with the named
   column's value from the *current* record.

   v1 scope:
     - Only @ref from the header is interpreted; @prompt and
       @filter are reserved.
     - `@field(...)` accepts a bare ident or the `c[name]` form. No
       parameters / formatting yet — the value is emitted inline.
     - One screen page; no scrolling.

   Pagination, field cycling, and editing live in Oed.Mod and call
   into CollectFields / Render / cell access. *)

  IMPORT Buffer, Schema, Directive, Doc, TUI, Csv, Collection;

  CONST
    MaxFields*    = 32;
    MaxFieldName* = 32;
    MaxCellValue* = 256;
    NL  = 0AX;
    TAB = 9X;

  TYPE
    FieldRef* = RECORD
      name*: ARRAY MaxFieldName OF CHAR
    END;

    Layout* = RECORD
      n*:      INTEGER;
      fields*: ARRAY MaxFields OF FieldRef
    END;

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

  PROCEDURE isIdent(ch: CHAR): BOOLEAN;
  BEGIN
    RETURN ((ch >= "A") & (ch <= "Z"))
        OR ((ch >= "a") & (ch <= "z"))
        OR ((ch >= "0") & (ch <= "9"))
        OR (ch = "_")
  END isIdent;

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
  (* Populate sch with any @column directives (typically empty for
     forms — only kCollection / kTableView use them) and refPath
     with the first @ref. headerEnd marks the start of the layout
     zone. *)
  BEGIN
    refPath[0] := 0X;
    Schema.Parse(b, sch);
    findRef(b, refPath)
  END Parse;

  (* Match "@field(" starting at pos. Returns -1 if no match;
     otherwise the position right after the matched prefix. *)
  PROCEDURE matchFieldStart(b: Buffer.Buffer; pos: INTEGER): INTEGER;
    VAR p: INTEGER;
        ok: BOOLEAN;
  BEGIN
    p := -1;
    IF (byteAt(b, pos) = "@")
        & (byteAt(b, pos + 1) = "f") & (byteAt(b, pos + 2) = "i")
        & (byteAt(b, pos + 3) = "e") & (byteAt(b, pos + 4) = "l")
        & (byteAt(b, pos + 5) = "d") & (byteAt(b, pos + 6) = "(") THEN
      p := pos + 7
    END;
    RETURN p
  END matchFieldStart;

  (* Parse "name)" or "c[name])" starting at pos. Sets name and
     returns position after ")", or -1 on parse failure. *)
  PROCEDURE parseFieldName(b: Buffer.Buffer; pos: INTEGER;
                           VAR name: ARRAY OF CHAR): INTEGER;
    VAR i: INTEGER; p, result: INTEGER;
        afterIdent: INTEGER;
  BEGIN
    p := firstNonWS(b, pos);
    (* Optional `c[` prefix. *)
    IF (byteAt(b, p) = "c") & (byteAt(b, p + 1) = "[") THEN
      p := p + 2
    END;
    i := 0;
    WHILE (i < LEN(name) - 1) & isIdent(byteAt(b, p)) DO
      name[i] := byteAt(b, p); INC(i); INC(p)
    END;
    name[i] := 0X;
    afterIdent := p;
    IF byteAt(b, p) = "]" THEN INC(p) END;
    p := firstNonWS(b, p);
    IF (i > 0) & (byteAt(b, p) = ")") THEN
      result := p + 1
    ELSE
      result := -1
    END;
    RETURN result
  END parseFieldName;

  PROCEDURE CollectFields*(viewDoc: Doc.Doc; VAR fl: Layout);
  (* Walk the layout text, recording each @field(...)'s column name
     in order of appearance. *)
    VAR pos, layoutStart, p2: INTEGER;
        afterAt: INTEGER;
  BEGIN
    fl.n := 0;
    IF viewDoc.schema = NIL THEN layoutStart := 0
    ELSE layoutStart := viewDoc.schema.headerEnd
    END;
    pos := layoutStart;
    WHILE (pos < viewDoc.buf.len) & (fl.n < MaxFields) DO
      afterAt := matchFieldStart(viewDoc.buf, pos);
      IF afterAt >= 0 THEN
        p2 := parseFieldName(viewDoc.buf, afterAt, fl.fields[fl.n].name);
        IF p2 >= 0 THEN
          INC(fl.n);
          pos := p2
        ELSE
          INC(pos)
        END
      ELSE
        INC(pos)
      END
    END
  END CollectFields;

  (* Read a single cell value from the data at (rowStart, dataCol).
     Empty string if out-of-range. *)
  PROCEDURE getCell(dataDoc: Doc.Doc; rowStart, dataCol: INTEGER;
                    VAR val: ARRAY OF CHAR);
    VAR c: Collection.Collection;
  BEGIN
    IF dataDoc = NIL THEN val[0] := 0X
    ELSE
      c := Collection.Open(dataDoc);
      Collection.GetCell(c, rowStart, dataCol, val)
    END
  END getCell;

  PROCEDURE drawValue(val: ARRAY OF CHAR; highlight: BOOLEAN; VAR col: INTEGER);
    VAR i, n: INTEGER;
  BEGIN
    IF highlight THEN TUI.SetAttr(TUI.AttrReverse) END;
    n := strLen(val); i := 0;
    WHILE (i < n) & (col < TUI.Cols) DO
      TUI.Write(val[i]); INC(i); INC(col)
    END;
    IF highlight THEN TUI.SetAttr(TUI.AttrNormal) END
  END drawValue;

  PROCEDURE Render*(viewDoc, dataDoc: Doc.Doc;
                    recordIdx, curField: INTEGER;
                    viewportRows: INTEGER;
                    VAR cursRow, cursCol: INTEGER);
  (* Renders the form. cursRow/cursCol are set to the screen
     position of the current field's substituted value. *)
    VAR pos, layoutStart, row, col, fieldSeen: INTEGER;
        ch: CHAR;
        afterAt, afterName: INTEGER;
        name: ARRAY MaxFieldName OF CHAR;
        val: ARRAY MaxCellValue OF CHAR;
        rowStart, dataCol: INTEGER;
        c: Collection.Collection;
        sch: Schema.Schema;
  BEGIN
    cursRow := 0; cursCol := 0;
    IF viewDoc.schema = NIL THEN layoutStart := 0
    ELSE layoutStart := viewDoc.schema.headerEnd
    END;
    IF (dataDoc # NIL) THEN
      c := Collection.Open(dataDoc);
      rowStart := Collection.FindRow(c, recordIdx);
      sch := dataDoc.schema
    ELSE
      rowStart := -1;
      sch := NIL
    END;

    pos := layoutStart; row := 0; col := 0; fieldSeen := 0;
    TUI.MoveTo(0, 0); TUI.ClearLine;
    WHILE (pos < viewDoc.buf.len) & (row < viewportRows) DO
      afterAt := matchFieldStart(viewDoc.buf, pos);
      IF afterAt >= 0 THEN
        afterName := parseFieldName(viewDoc.buf, afterAt, name);
        IF afterName >= 0 THEN
          IF (sch # NIL) & (rowStart >= 0) THEN
            dataCol := Schema.Find(sch, name);
            IF dataCol >= 0 THEN
              getCell(dataDoc, rowStart, dataCol, val)
            ELSE
              val[0] := "?"; val[1] := 0X
            END
          ELSE
            val[0] := "?"; val[1] := 0X
          END;
          IF fieldSeen = curField THEN
            cursRow := row; cursCol := col
          END;
          drawValue(val, fieldSeen = curField, col);
          INC(fieldSeen);
          pos := afterName
        ELSE
          IF col < TUI.Cols THEN TUI.Write(byteAt(viewDoc.buf, pos)) END;
          INC(col); INC(pos)
        END
      ELSE
        ch := byteAt(viewDoc.buf, pos);
        IF ch = NL THEN
          INC(row);
          IF row < viewportRows THEN
            TUI.MoveTo(0, row); TUI.ClearLine
          END;
          col := 0; INC(pos)
        ELSE
          IF col < TUI.Cols THEN TUI.Write(ch) END;
          INC(col); INC(pos)
        END
      END
    END;
    INC(row);
    WHILE row < viewportRows DO
      TUI.MoveTo(0, row); TUI.ClearLine; TUI.Write("~");
      INC(row)
    END
  END Render;

  PROCEDURE RecordCount*(dataDoc: Doc.Doc): INTEGER;
    VAR c: Collection.Collection; n: INTEGER;
  BEGIN
    IF dataDoc = NIL THEN n := 0
    ELSE c := Collection.Open(dataDoc); n := Collection.Count(c)
    END;
    RETURN n
  END RecordCount;

END FormView.
