MODULE Buffers;
(* Registry of named buffers, with a "current" pointer.

   A BufRec bundles per-buffer state: the Buffer.Buffer holding the
   text, the Lines.Lines line index over it, plus the editor's
   per-buffer cursor / viewport-top / mark positions. The editor
   keeps these positions in sync via attach/detach when switching.

   The list is a fixed-size array of BufRec pointers. Add replaces
   any existing entry with the same name (so reopening a file
   doesn't double-list it). *)

  IMPORT Buffer, Lines;

  CONST
    NameLen = 64;
    MaxBufs = 32;

  TYPE
    BufRec*    = POINTER TO BufRecDesc;
    BufRecDesc* = RECORD
      name*:  ARRAY NameLen OF CHAR;
      buf*:   Buffer.Buffer;
      lines*: Lines.Lines;
      cur*:   INTEGER;       (* cursor position in buffer *)
      top*:   INTEGER;       (* viewport top *)
      mark*:  INTEGER        (* -1 when unset *)
    END;

  VAR
    list: ARRAY MaxBufs OF BufRec;
    nbuf: INTEGER;
    cur:  INTEGER;          (* index of current buffer; -1 = none *)

  PROCEDURE strEq(VAR a, b: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (a[i] # 0X) & (a[i] = b[i]) DO INC(i) END;
    RETURN a[i] = b[i]
  END strEq;

  PROCEDURE New*(name: ARRAY OF CHAR): BufRec;
  (* Allocate a fresh BufRec with the given name. Caller fills in
     buf/lines and adds via Add. *)
    VAR b: BufRec; i: INTEGER;
  BEGIN
    NEW(b);
    i := 0;
    WHILE (i < LEN(b.name) - 1) & (i < LEN(name)) & (name[i] # 0X) DO
      b.name[i] := name[i]; INC(i)
    END;
    b.name[i] := 0X;
    b.cur  := 0;
    b.top  := 0;
    b.mark := -1;
    RETURN b
  END New;

  PROCEDURE Add*(b: BufRec);
  (* Add b to the registry. If a buffer with the same name already
     exists, replace it. Silently no-op if the registry is full. *)
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < nbuf) & ~strEq(list[i].name, b.name) DO INC(i) END;
    IF i < nbuf THEN
      list[i] := b
    ELSIF nbuf < MaxBufs THEN
      list[nbuf] := b; INC(nbuf)
    END
  END Add;

  PROCEDURE Find*(VAR name: ARRAY OF CHAR): BufRec;
  (* Returns the buffer with the given name, or NIL. *)
    VAR i: INTEGER; r: BufRec;
  BEGIN
    r := NIL; i := 0;
    WHILE (i < nbuf) & (r = NIL) DO
      IF strEq(list[i].name, name) THEN r := list[i] END;
      INC(i)
    END;
    RETURN r
  END Find;

  PROCEDURE Current*(): BufRec;
    VAR r: BufRec;
  BEGIN
    IF (cur >= 0) & (cur < nbuf) THEN r := list[cur] ELSE r := NIL END;
    RETURN r
  END Current;

  PROCEDURE SetCurrent*(b: BufRec);
  (* Make b the current buffer. No-op if b is not in the registry. *)
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < nbuf) & (list[i] # b) DO INC(i) END;
    IF i < nbuf THEN cur := i END
  END SetCurrent;

  PROCEDURE Kill*(b: BufRec);
  (* Remove b from the registry. If b was the current buffer, the new
     current becomes whichever entry now occupies its old slot, or
     the last entry if the killed one was last, or none (-1) if the
     registry is now empty. *)
    VAR i, j: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < nbuf) & (list[i] # b) DO INC(i) END;
    IF i < nbuf THEN
      j := i + 1;
      WHILE j < nbuf DO list[j-1] := list[j]; INC(j) END;
      DEC(nbuf);
      list[nbuf] := NIL;
      IF nbuf = 0 THEN cur := -1
      ELSIF cur > i THEN DEC(cur)
      ELSIF (cur = i) & (cur >= nbuf) THEN cur := nbuf - 1
      END
    END
  END Kill;

  PROCEDURE Count*(): INTEGER;
  BEGIN RETURN nbuf
  END Count;

  PROCEDURE At*(i: INTEGER): BufRec;
    VAR r: BufRec;
  BEGIN
    IF (i >= 0) & (i < nbuf) THEN r := list[i] ELSE r := NIL END;
    RETURN r
  END At;

BEGIN
  nbuf := 0;
  cur  := -1
END Buffers.
