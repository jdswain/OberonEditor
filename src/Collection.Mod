MODULE Collection;
(* Typed wrapper over a Doc that holds a kCollection's CSV data.
   The Collection couples a Doc's bytes with its Schema and offers:

     - row iteration: walk data rows starting from schema.headerEnd
     - per-row field access: read fields one at a time
     - in-place cell edits: rewrite a single field by byte range

   Edits go straight through Buffer.Insert / Buffer.Delete on the
   underlying Doc, and invalidate the line cache so the editor's
   viewport re-renders correctly. The Schema is not re-parsed on
   data edits (only header edits would change it); that's the
   caller's concern. *)

  IMPORT Buffer, Lines, Schema, Csv, Doc;

  CONST
    MaxField* = 1024;            (* per-call scratch size *)

  TYPE
    Collection* = POINTER TO CollDesc;
    CollDesc* = RECORD
      doc*:    Doc.Doc;
      schema*: Schema.Schema      (* alias of doc.schema; nilable *)
    END;

    RowIter* = RECORD
      coll:      Collection;
      csv:       Csv.Reader;
      rowStart*: INTEGER;         (* byte offset of current row's start *)
      done*:     BOOLEAN;         (* no more rows to iterate *)
      consumed:  BOOLEAN          (* current row's last field has been read *)
    END;

  PROCEDURE Open*(d: Doc.Doc): Collection;
  (* Wrap d as a Collection. d.schema may be NIL — iteration will
     simply walk from byte 0 in that case. *)
    VAR c: Collection;
  BEGIN
    NEW(c);
    c.doc := d;
    c.schema := d.schema;
    RETURN c
  END Open;

  PROCEDURE dataStart(c: Collection): INTEGER;
    VAR p: INTEGER;
  BEGIN
    IF c.schema = NIL THEN p := 0
    ELSE p := c.schema.headerEnd
    END;
    RETURN p
  END dataStart;

  PROCEDURE OpenIter*(c: Collection; VAR it: RowIter);
  (* Position iterator at the first data row. *)
    VAR start: INTEGER;
  BEGIN
    it.coll := c;
    start := dataStart(c);
    it.rowStart := start;
    Csv.OpenReader(it.csv, c.doc.buf, start);
    it.done := it.csv.eof;
    it.consumed := FALSE
  END OpenIter;

  PROCEDURE Field*(VAR it: RowIter; VAR val: ARRAY OF CHAR; VAR last: BOOLEAN);
  (* Read the next field of the current row. `last` is TRUE iff this
     field closed the row (next op should be NextRow). After the
     last field is read, the Csv reader is already positioned at the
     start of the following row, and the iterator's consumed flag is
     set so NextRow doesn't double-drain. *)
  BEGIN
    IF it.done THEN
      val[0] := 0X; last := TRUE
    ELSE
      Csv.ReadField(it.csv, val);
      last := it.csv.eor OR it.csv.eof;
      IF last THEN it.consumed := TRUE END
    END
  END Field;

  PROCEDURE NextRow*(VAR it: RowIter);
  (* Advance to the next row. If the caller hasn't fully drained the
     current row, drain it (read at least one field, then until the
     row terminator is consumed). Sets `done` when no further rows
     exist. *)
    VAR scrap: ARRAY MaxField OF CHAR;
  BEGIN
    IF ~it.done THEN
      IF ~it.consumed THEN
        REPEAT
          Csv.ReadField(it.csv, scrap)
        UNTIL it.csv.eor OR it.csv.eof
      END;
      IF it.csv.eof THEN
        it.done := TRUE;
        it.rowStart := it.coll.doc.buf.len
      ELSE
        it.rowStart := it.csv.pos;
        IF it.rowStart >= it.coll.doc.buf.len THEN it.done := TRUE END
      END;
      it.consumed := FALSE
    END
  END NextRow;

  PROCEDURE Count*(c: Collection): INTEGER;
  (* Number of data rows. Walks the buffer once; O(buf.len). *)
    VAR it: RowIter; n: INTEGER;
  BEGIN
    n := 0;
    OpenIter(c, it);
    WHILE ~it.done DO
      INC(n);
      NextRow(it)
    END;
    RETURN n
  END Count;

  PROCEDURE FindRow*(c: Collection; rowIndex: INTEGER): INTEGER;
  (* Returns the byte offset of the row at index rowIndex (0-based),
     or -1 if no such row exists. *)
    VAR it: RowIter; i, found: INTEGER;
  BEGIN
    found := -1; i := 0;
    OpenIter(c, it);
    WHILE ~it.done & (found < 0) DO
      IF i = rowIndex THEN found := it.rowStart END;
      INC(i);
      NextRow(it)
    END;
    RETURN found
  END FindRow;

  PROCEDURE GetCell*(c: Collection; rowStart: INTEGER;
                     col: INTEGER; VAR val: ARRAY OF CHAR);
  (* Reads the value of the col'th field in the row starting at
     rowStart. Returns "" if the row has fewer than col+1 fields. *)
    VAR cr: Csv.Reader;
        scrap: ARRAY MaxField OF CHAR;
        i: INTEGER; rowEnded: BOOLEAN;
  BEGIN
    Csv.OpenReader(cr, c.doc.buf, rowStart);
    i := 0; rowEnded := FALSE;
    WHILE (i < col) & ~rowEnded DO
      Csv.ReadField(cr, scrap);
      IF cr.eor OR cr.eof THEN rowEnded := TRUE END;
      INC(i)
    END;
    IF rowEnded THEN val[0] := 0X
    ELSE Csv.ReadField(cr, val)
    END
  END GetCell;

  PROCEDURE lastByte(b: Buffer.Buffer): CHAR;
    VAR r: Buffer.Reader; ch: CHAR;
  BEGIN
    IF b.len = 0 THEN ch := 0X
    ELSE
      Buffer.OpenReader(r, b, b.len - 1);
      Buffer.Read(r, ch)
    END;
    RETURN ch
  END lastByte;

  PROCEDURE AppendEmptyRow*(c: Collection);
  (* Append one empty row to the data zone: schema.ncol-1 commas
     plus a trailing newline. Ensures the previous row ends with
     a newline first. *)
    VAR pos, i, ncols: INTEGER;
  BEGIN
    IF (c # NIL) & (c.schema # NIL) THEN
      pos := c.doc.buf.len;
      IF (pos > 0) & (lastByte(c.doc.buf) # 0AX) THEN
        Buffer.Insert(c.doc.buf, pos, 0AX); INC(pos)
      END;
      ncols := c.schema.ncol;
      IF ncols < 1 THEN ncols := 1 END;
      i := 0;
      WHILE i < ncols - 1 DO
        Buffer.Insert(c.doc.buf, pos, ","); INC(pos); INC(i)
      END;
      Buffer.Insert(c.doc.buf, pos, 0AX); INC(pos);
      Lines.Invalidate(c.doc.lines)
    END
  END AppendEmptyRow;

  PROCEDURE EnsureRow*(c: Collection; row: INTEGER);
  (* Extend the data zone with empty rows so that row index `row`
     exists. No-op if row already exists. *)
    VAR n: INTEGER;
  BEGIN
    n := Count(c);
    WHILE n <= row DO
      AppendEmptyRow(c); INC(n)
    END
  END EnsureRow;

  PROCEDURE SetCell*(c: Collection; rowStart: INTEGER;
                     col: INTEGER; val: ARRAY OF CHAR);
  (* Replace the col'th field of the row starting at rowStart with
     `val` (CSV-encoded as needed). No-op if the row has fewer than
     col+1 fields. *)
    VAR cr: Csv.Reader;
        scrap: ARRAY MaxField OF CHAR;
        i, oldStart, oldEnd, writePos: INTEGER;
        truncated: BOOLEAN;
  BEGIN
    Csv.OpenReader(cr, c.doc.buf, rowStart);
    i := 0; truncated := FALSE;
    WHILE (i < col) & ~cr.eof & ~truncated DO
      Csv.ReadField(cr, scrap);
      IF cr.eor THEN truncated := TRUE          (* row too short *)
      ELSE INC(i)
      END
    END;
    IF (i = col) & ~cr.eof & ~truncated THEN
      oldStart := cr.pos;
      Csv.ReadField(cr, scrap);
      oldEnd := cr.fieldEnd;
      Buffer.Delete(c.doc.buf, oldStart, oldEnd);
      writePos := oldStart;
      Csv.WriteField(c.doc.buf, writePos, val);
      Lines.Invalidate(c.doc.lines)
    END
  END SetCell;

END Collection.
