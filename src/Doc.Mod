MODULE Doc;
(* A loaded document in memory. Holds a Buffer (the bytes), a Lines
   index over those bytes, and a canonical name (typically a file
   path or the synthetic name like "*scratch*").

   Multiple Viewers can share a single Doc — opening the same file
   as a Table view and a raw-text view (C-x C-r) produces two
   Viewers pointing at one Doc. The Doc is reclaimed by ARC when
   the last Viewer drops its reference.

   This module owns nothing except the type and a small constructor
   that wires Buffer + Lines together. Persistence remains the
   province of Buffer.Save / Buffer.Load. *)

  IMPORT Buffer, Lines;

  CONST
    NameLen* = 128;

  TYPE
    Doc* = POINTER TO DocDesc;
    DocDesc* = RECORD
      name*:  ARRAY NameLen OF CHAR;     (* canonical path or synthetic name *)
      buf*:   Buffer.Buffer;
      lines*: Lines.Lines
    END;

  PROCEDURE New*(name: ARRAY OF CHAR): Doc;
    VAR d: Doc; i: INTEGER;
  BEGIN
    NEW(d);
    i := 0;
    WHILE (i < LEN(d.name) - 1) & (i < LEN(name)) & (name[i] # 0X) DO
      d.name[i] := name[i]; INC(i)
    END;
    d.name[i] := 0X;
    d.buf := Buffer.New();
    d.lines := Lines.New(d.buf);
    RETURN d
  END New;

END Doc.
