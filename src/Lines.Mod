MODULE Lines;
(* Logical-line index over a Buffer.

   Maintains a table of line-start byte offsets so repeated (line ↔ pos)
   queries during a render frame don't re-walk the buffer. The owning
   editor calls Invalidate after every edit; the next query lazily
   rebuilds the table by walking the buffer once.

   Invariants when stale = FALSE:
     count     >= 1
     starts[0] = 0
     starts[i] = byte offset of the first char of logical line i
     For a buffer ending in '\n', an extra entry past it gives the
     position of the empty trailing line.

   Logical lines are separated by 0AX. Soft-wrap will eventually layer
   a "visual line" concept on top of this — same table, plus per-line
   wrap-point cache keyed by current viewport width. *)

  IMPORT Buffer;

  CONST
    MaxLines = 8192;        (* table cap; rebuild stops appending past this *)
    Newline  = 0AX;

  TYPE
    Lines* = POINTER TO LinesDesc;
    LinesDesc* = RECORD
      buf:    Buffer.Buffer;
      count:  INTEGER;
      stale:  BOOLEAN;
      starts: ARRAY MaxLines OF INTEGER
    END;

  PROCEDURE rebuild(L: Lines);
    VAR r: Buffer.Reader; ch: CHAR; pos: INTEGER;
  BEGIN
    L.count := 1;
    L.starts[0] := 0;
    Buffer.OpenReader(r, L.buf, 0);
    pos := 0;
    Buffer.Read(r, ch);
    WHILE ~r.eot DO
      INC(pos);
      IF (ch = Newline) & (L.count < MaxLines) THEN
        L.starts[L.count] := pos;
        INC(L.count)
      END;
      Buffer.Read(r, ch)
    END;
    L.stale := FALSE
  END rebuild;

  PROCEDURE New*(b: Buffer.Buffer): Lines;
  (* Returns a fresh index over b. The table is left stale; the first
     query rebuilds it. *)
    VAR L: Lines;
  BEGIN
    NEW(L);
    L.buf       := b;
    L.count     := 1;
    L.starts[0] := 0;
    L.stale     := TRUE;
    RETURN L
  END New;

  PROCEDURE Invalidate*(L: Lines);
  (* Mark the table stale. Call after any Buffer mutation. *)
  BEGIN L.stale := TRUE
  END Invalidate;

  PROCEDURE Count*(L: Lines): INTEGER;
  (* Number of logical lines. Always >= 1. *)
  BEGIN
    IF L.stale THEN rebuild(L) END;
    RETURN L.count
  END Count;

  PROCEDURE LineStart*(L: Lines; line: INTEGER): INTEGER;
  (* Byte offset of the first char of `line`. Clamps to [0, count-1]. *)
  BEGIN
    IF L.stale THEN rebuild(L) END;
    IF line < 0 THEN line := 0
    ELSIF line >= L.count THEN line := L.count - 1
    END;
    RETURN L.starts[line]
  END LineStart;

  PROCEDURE LineEnd*(L: Lines; line: INTEGER): INTEGER;
  (* Position one past the last non-newline char of `line`.
     For non-final lines this is the offset of that line's newline;
     for the final line, this is buf.len. *)
    VAR e: INTEGER;
  BEGIN
    IF L.stale THEN rebuild(L) END;
    IF line < 0 THEN line := 0
    ELSIF line >= L.count THEN line := L.count - 1
    END;
    IF line + 1 < L.count THEN
      e := L.starts[line + 1] - 1
    ELSE
      e := L.buf.len
    END;
    RETURN e
  END LineEnd;

  PROCEDURE LineLen*(L: Lines; line: INTEGER): INTEGER;
  (* Number of chars on `line`, excluding the trailing newline if any. *)
  BEGIN RETURN LineEnd(L, line) - LineStart(L, line)
  END LineLen;

  PROCEDURE Locate*(L: Lines; pos: INTEGER; VAR line, col: INTEGER);
  (* Decompose pos into (line, col). pos is clamped to [0, buf.len]. *)
    VAR lo, hi, mid: INTEGER;
  BEGIN
    IF L.stale THEN rebuild(L) END;
    IF pos < 0 THEN pos := 0
    ELSIF pos > L.buf.len THEN pos := L.buf.len
    END;
    (* Largest index i with starts[i] <= pos. (lo+hi+1) DIV 2 rounds up
       so single-step adjacency converges. *)
    lo := 0; hi := L.count - 1;
    WHILE lo < hi DO
      mid := (lo + hi + 1) DIV 2;
      IF L.starts[mid] <= pos THEN lo := mid ELSE hi := mid - 1 END
    END;
    line := lo;
    col  := pos - L.starts[line]
  END Locate;

END Lines.
