MODULE Viewers;
(* Registry of Viewers — open presentations on Docs. A Viewer is
   what the user sees in C-x C-b and switches between with C-x b.
   Multiple Viewers can share a single Doc; their cursor / viewport
   / mark state is per-Viewer.

   This module replaces the older Buffers.Mod which fused data and
   presentation in a single record. Viewer carries presentation
   only; Doc owns the bytes (see Doc.Mod). *)

  IMPORT Doc;

  CONST
    LabelLen = 96;        (* bigger than Doc.NameLen to allow suffixes
                             like "<text>" appended by raw-text view *)
    MaxViewers = 32;

    (* Viewer kinds. v1 only uses kText; the structured-data layer
       will add more values incrementally per the migration plan. *)
    KText*           = 0;
    KCollection*     = 1;
    KTableView*      = 2;
    KSpreadsheetView*= 3;
    KFormView*       = 4;
    KViewerList*     = 5;

  TYPE
    Viewer*    = POINTER TO ViewerDesc;
    ViewerDesc* = RECORD
      label*: ARRAY LabelLen OF CHAR;
      doc*:   Doc.Doc;
      kind*:  INTEGER;
      cur*:   INTEGER;
      top*:   INTEGER;
      mark*:  INTEGER
    END;

  VAR
    list: ARRAY MaxViewers OF Viewer;
    nv:   INTEGER;
    cur:  INTEGER;        (* index of current Viewer; -1 = none *)

  PROCEDURE strEq(VAR a, b: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (a[i] # 0X) & (a[i] = b[i]) DO INC(i) END;
    RETURN a[i] = b[i]
  END strEq;

  PROCEDURE KindOf*(VAR name: ARRAY OF CHAR): INTEGER;
  (* Map a filename to a Viewer kind by extension. The basename's
     last dot is the source of truth; paths like "/foo.col/bar" are
     classified by "bar"'s extension (none → kText), not "foo.col".
     Synthetic names like "*scratch*" have no dot → kText.

     Step 2 of the data-layer plan: every viewer is still functionally
     kText, but the kind field is populated correctly so per-kind
     dispatch can layer on without touching the open paths again. *)
    VAR i, dot, lastSlash, extLen, k: INTEGER;
  BEGIN
    i := 0; dot := -1; lastSlash := -1;
    WHILE (i < LEN(name)) & (name[i] # 0X) DO
      IF name[i] = "/" THEN lastSlash := i; dot := -1
      ELSIF name[i] = "." THEN dot := i
      END;
      INC(i)
    END;
    k := KText;
    IF (dot > lastSlash) & (dot >= 0) THEN
      extLen := i - dot - 1;
      IF extLen = 3 THEN
        IF    (name[dot+1] = "c") & (name[dot+2] = "o") & (name[dot+3] = "l") THEN k := KCollection
        ELSIF (name[dot+1] = "t") & (name[dot+2] = "b") & (name[dot+3] = "l") THEN k := KTableView
        ELSIF (name[dot+1] = "s") & (name[dot+2] = "s") & (name[dot+3] = "h") THEN k := KSpreadsheetView
        ELSIF (name[dot+1] = "f") & (name[dot+2] = "r") & (name[dot+3] = "m") THEN k := KFormView
        END
      END
    END;
    RETURN k
  END KindOf;

  PROCEDURE New*(label: ARRAY OF CHAR; d: Doc.Doc; kind: INTEGER): Viewer;
  (* Allocate a fresh Viewer wrapping doc d. Caller adds via Add. *)
    VAR v: Viewer; i: INTEGER;
  BEGIN
    NEW(v);
    i := 0;
    WHILE (i < LEN(v.label) - 1) & (i < LEN(label)) & (label[i] # 0X) DO
      v.label[i] := label[i]; INC(i)
    END;
    v.label[i] := 0X;
    v.doc  := d;
    v.kind := kind;
    v.cur  := 0;
    v.top  := 0;
    v.mark := -1;
    RETURN v
  END New;

  PROCEDURE Add*(v: Viewer);
  (* Add v to the registry. If a Viewer with the same label already
     exists, replace it. Silently no-op if the registry is full. *)
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < nv) & ~strEq(list[i].label, v.label) DO INC(i) END;
    IF i < nv THEN
      list[i] := v
    ELSIF nv < MaxViewers THEN
      list[nv] := v; INC(nv)
    END
  END Add;

  PROCEDURE Find*(VAR label: ARRAY OF CHAR): Viewer;
  (* Returns the Viewer with the given label, or NIL. *)
    VAR i: INTEGER; r: Viewer;
  BEGIN
    r := NIL; i := 0;
    WHILE (i < nv) & (r = NIL) DO
      IF strEq(list[i].label, label) THEN r := list[i] END;
      INC(i)
    END;
    RETURN r
  END Find;

  PROCEDURE FindByDocName*(VAR name: ARRAY OF CHAR): Viewer;
  (* Returns any Viewer whose Doc has the given canonical name, or
     NIL. Used by the open-file path: if a Doc for `name` already
     exists somewhere in the registry, reuse it. *)
    VAR i: INTEGER; r: Viewer;
  BEGIN
    r := NIL; i := 0;
    WHILE (i < nv) & (r = NIL) DO
      IF (list[i].doc # NIL) & strEq(list[i].doc.name, name) THEN
        r := list[i]
      END;
      INC(i)
    END;
    RETURN r
  END FindByDocName;

  PROCEDURE Current*(): Viewer;
    VAR r: Viewer;
  BEGIN
    IF (cur >= 0) & (cur < nv) THEN r := list[cur] ELSE r := NIL END;
    RETURN r
  END Current;

  PROCEDURE SetCurrent*(v: Viewer);
  (* Make v the current Viewer. No-op if v is not in the registry. *)
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < nv) & (list[i] # v) DO INC(i) END;
    IF i < nv THEN cur := i END
  END SetCurrent;

  PROCEDURE Kill*(v: Viewer);
  (* Remove v from the registry. If v was current, the new current
     is whichever entry now occupies its old slot, or the last
     entry, or none (-1) if the registry is empty. *)
    VAR i, j: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < nv) & (list[i] # v) DO INC(i) END;
    IF i < nv THEN
      j := i + 1;
      WHILE j < nv DO list[j-1] := list[j]; INC(j) END;
      DEC(nv);
      list[nv] := NIL;
      IF nv = 0 THEN cur := -1
      ELSIF cur > i THEN DEC(cur)
      ELSIF (cur = i) & (cur >= nv) THEN cur := nv - 1
      END
    END
  END Kill;

  PROCEDURE Count*(): INTEGER;
  BEGIN RETURN nv
  END Count;

  PROCEDURE At*(i: INTEGER): Viewer;
    VAR r: Viewer;
  BEGIN
    IF (i >= 0) & (i < nv) THEN r := list[i] ELSE r := NIL END;
    RETURN r
  END At;

BEGIN
  nv  := 0;
  cur := -1
END Viewers.
