MODULE Schema;
(* Minimal schema captured from the @column directives in a Doc's
   header zone. v1 records column NAMES only; labels and types come
   in step 6 along with the typed Collection wrapper.

   The header zone is the prefix of the file consisting of blank
   lines, comment lines (`# ...`), and directive lines (`@...`). The
   first line that is none of these begins the data zone; its byte
   position is recorded in `headerEnd` so a Collection reader can
   start there.

   This module is purely passive — Schema.New + Schema.Parse populate
   the record; nobody mutates it after. When the user edits the
   header, the schema becomes stale; re-parsing on edit is the data
   layer's job, not ours. *)

  IMPORT Buffer, Directive;

  CONST
    MaxColumns* = 32;
    MaxName*    = 32;
    MaxLabel*   = 64;
    NL          = 0AX;
    TAB         = 9X;

  TYPE
    Column* = RECORD
      name*:  ARRAY MaxName  OF CHAR;    (* identifier — `c[name]` access *)
      label*: ARRAY MaxLabel OF CHAR;    (* display string, defaults to name *)
      type*:  ARRAY MaxName  OF CHAR;    (* type name as written; "text" by default *)
      width*: INTEGER                    (* render-width hint; 0 = unset *)
    END;

    Schema* = POINTER TO SchemaDesc;
    SchemaDesc* = RECORD
      ncol*:      INTEGER;
      cols*:      ARRAY MaxColumns OF Column;
      headerEnd*: INTEGER         (* byte position of first data byte *)
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

  (* Fill column from a parsed @column directive. arg[0] is the name
     (required ident). Remaining args are matched positionally by
     kind: string → label; ident → type; int → width. This lets
     users write any of:
       @column(name)
       @column(name, "Label")
       @column(name, integer)
       @column(name, "Label", integer, 6)
     in any partial order. *)
  PROCEDURE fillColumn(VAR col: Column; VAR d: Directive.Directive);
    VAR i: INTEGER;
  BEGIN
    copyStr(col.name, d.args[0].str);
    copyStr(col.label, d.args[0].str);   (* label defaults to name *)
    copyStr(col.type, "text");           (* DDR default *)
    col.width := 0;
    i := 1;
    WHILE i < d.narg DO
      IF d.args[i].kind = Directive.AString THEN
        copyStr(col.label, d.args[i].str)
      ELSIF d.args[i].kind = Directive.AIdent THEN
        copyStr(col.type, d.args[i].str)
      ELSIF d.args[i].kind = Directive.AInt THEN
        col.width := d.args[i].int
      END;
      INC(i)
    END
  END fillColumn;

  PROCEDURE Find*(s: Schema; name: ARRAY OF CHAR): INTEGER;
  (* Returns the index of the column with this name, or -1. *)
    VAR i, found: INTEGER;
  BEGIN
    found := -1; i := 0;
    WHILE (i < s.ncol) & (found < 0) DO
      IF strEq(s.cols[i].name, name) THEN found := i END;
      INC(i)
    END;
    RETURN found
  END Find;

  PROCEDURE New*(): Schema;
    VAR s: Schema;
  BEGIN
    NEW(s);
    s.ncol := 0;
    s.headerEnd := 0;
    RETURN s
  END New;

  PROCEDURE Parse*(b: Buffer.Buffer; sch: Schema);
  (* Walks the header zone of b, populating sch with @column entries.
     headerEnd is set to the byte offset of the first data row, or
     b.len if the file is header-only. *)
    VAR pos, lineStart, content: INTEGER;
        ch: CHAR;
        d: Directive.Directive;
        ok: BOOLEAN;
        ep: INTEGER;
        done: BOOLEAN;
  BEGIN
    sch.ncol := 0;
    pos := 0;
    done := FALSE;
    WHILE (pos < b.len) & ~done DO
      lineStart := pos;
      content := firstNonWS(b, pos);
      IF content >= b.len THEN
        pos := content                        (* trailing whitespace, stop *)
      ELSE
        ch := byteAt(b, content);
        IF ch = NL THEN
          pos := skipToNL(b, content)         (* blank line *)
        ELSIF ch = "#" THEN
          pos := skipToNL(b, content)         (* comment line *)
        ELSIF ch = "@" THEN
          Directive.Parse(b, content, d, ok, ep);
          IF ok THEN
            IF strEq(d.name, "column")
                & (d.narg > 0)
                & (d.args[0].kind = Directive.AIdent)
                & (sch.ncol < MaxColumns) THEN
              fillColumn(sch.cols[sch.ncol], d);
              INC(sch.ncol)
            END;
            pos := skipToNL(b, ep)
          ELSE
            pos := skipToNL(b, content)       (* malformed — skip *)
          END
        ELSE
          sch.headerEnd := lineStart;         (* data zone starts here *)
          done := TRUE
        END
      END
    END;
    IF ~done THEN sch.headerEnd := b.len END
  END Parse;

END Schema.
