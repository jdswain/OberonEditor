MODULE Buffer;
(* Piece-chain text storage, after Wirth's Texts.Mod (Project Oberon)
   but plain ASCII only and decoupled from the styled-text file format.

   Two byte regions back the buffer:
     - orig:   bytes loaded from disk; immutable for the buffer's life
     - append: bytes appended by edits; grows on demand
   A doubly-linked Piece chain with an end sentinel (trailer) splices
   the regions into the logical text. Insert/Delete are pointer surgery
   on the chain — characters never move once written. Reads walk the
   chain with a one-piece cache for locality.

   Chain shape (linear, not circular, so ARC reclaims cleanly):
     buffer.first → piece1 → piece2 → … → pieceN → trailer → NIL
   piece.next is strong, piece.prev is WEAK.  buffer.first and
   buffer.trailer are both strong; for an empty buffer, first = trailer.

   Storage is private. When a pluggable storage layer is wanted, the
   internal getByte / appendByte helpers lift into a separate Storage
   module with extensible StorageDesc, and Piece's src: INTEGER becomes
   src: Storage.Storage. The public API stays unchanged. *)

  IMPORT Files;

  CONST
    Ok*       = 0;            (* result codes for Load / Save *)
    NotFound* = 1;
    IOError*  = 2;

    RegionCap = 65536;        (* fixed cap per region for v1 *)

    Orig   = 0;               (* Piece.src tags *)
    Append = 1;

  TYPE
    Buffer* = POINTER TO BufferDesc;

    Region = POINTER TO RegionDesc;
    RegionDesc = RECORD
      len:   INTEGER;
      bytes: ARRAY RegionCap OF CHAR
    END;

    (* Piece is exported as a type name only — no fields are exported.
       A workaround for a compiler bug where importing a module that
       contains a hidden record-with-WEAK-self-ref crashes the front
       end while emitting symbol-file metadata for downstream records
       referencing the enclosing exported pointer type. *)
    Piece* = POINTER TO PieceDesc;
    PieceDesc* = RECORD
      src:  INTEGER;
      off:  INTEGER;
      len:  INTEGER;
      next: Piece;
      prev: WEAK POINTER TO PieceDesc
    END;

    BufferDesc* = RECORD
      len*:     INTEGER;     (* total character count *)
      changed*: BOOLEAN;     (* dirty since last Load/Save *)
      first:    Piece;       (* first iteration piece (= trailer when empty) *)
      trailer:  Piece;       (* end-of-chain sentinel; len = 0, next = NIL *)
      cache:    Piece;       (* last-found piece for FindPiece locality *)
      cacheOrg: INTEGER;     (* logical offset of cache piece's start *)
      orig:     Region;
      append:   Region
    END;

    Reader* = RECORD
      eot*: BOOLEAN;
      buf:  Buffer;
      ref:  Piece;           (* current piece *)
      org:  INTEGER;         (* logical offset of ref's start *)
      off:  INTEGER          (* offset within ref *)
    END;

  (* ---------------- Storage helpers (private) ---------------- *)

  PROCEDURE getByte(b: Buffer; src, off: INTEGER): CHAR;
    VAR r: Region;
  BEGIN
    IF src = Orig THEN r := b.orig ELSE r := b.append END;
    RETURN r.bytes[off]
  END getByte;

  PROCEDURE appendByte(b: Buffer; ch: CHAR): INTEGER;
    VAR off: INTEGER;
  BEGIN
    off := b.append.len;
    b.append.bytes[off] := ch;
    INC(b.append.len);
    RETURN off
  END appendByte;

  (* ---------------- Chain primitives (private) ---------------- *)

  (* Locate the piece containing position pos. Returns the piece in pce
     and the logical offset of that piece's start in org, so that
     pos - org is the offset within the piece. For pos = b.len the
     trailer is returned with org = b.len. The cache is updated.

     Walks forward or backward from b.cache depending on which side of
     the cache pos lies — the locality assumption being that successive
     Find calls cluster near a moving cursor. *)
  PROCEDURE FindPiece(b: Buffer; pos: INTEGER; VAR org: INTEGER; VAR pce: Piece);
    VAR p: Piece; porg: INTEGER;
  BEGIN
    p := b.cache; porg := b.cacheOrg;
    IF pos >= porg THEN
      WHILE (p # b.trailer) & (pos >= porg + p.len) DO
        INC(porg, p.len); p := p.next
      END
    ELSE
      p := p.prev; DEC(porg, p.len);
      WHILE pos < porg DO p := p.prev; DEC(porg, p.len) END
    END;
    b.cache := p; b.cacheOrg := porg;
    pce := p; org := porg
  END FindPiece;

  (* If off is in the open interval (0, p.len), split p so its left half
     keeps len = off and a fresh right half q is spliced in after it,
     covering the same source bytes from p.off + off onward. pr is set
     to the right half (or to p itself when off = 0, i.e. no split).
     SplitPiece is never called with off = p.len — FindPiece's loop
     advances past pieces whose range ends exactly at pos. *)
  PROCEDURE SplitPiece(p: Piece; off: INTEGER; VAR pr: Piece);
    VAR q: Piece;
  BEGIN
    IF off > 0 THEN
      NEW(q);
      q.src := p.src;
      q.off := p.off + off;
      q.len := p.len - off;
      p.len := off;
      q.next := p.next;
      p.next := q;
      q.prev := p;
      q.next.prev := q;
      pr := q
    ELSE
      pr := p
    END
  END SplitPiece;

  (* ---------------- Construction ---------------- *)

  (* Drop any existing chain and reset to the empty state.
     Setting b.first first lets ARC cascade through the now-orphaned
     pieces; b.cache must follow so it doesn't pin a freed piece. *)
  PROCEDURE reset(b: Buffer);
  BEGIN
    b.orig.len   := 0;
    b.append.len := 0;
    b.first      := b.trailer;
    b.cache      := b.trailer;
    b.cacheOrg   := 0;
    b.trailer.next := NIL;
    b.trailer.prev := NIL;
    b.len        := 0;
    b.changed    := FALSE
  END reset;

  PROCEDURE New*(): Buffer;
  (* Returns an empty buffer. *)
    VAR b: Buffer; t: Piece;
  BEGIN
    NEW(b);
    NEW(b.orig);   b.orig.len := 0;
    NEW(b.append); b.append.len := 0;
    NEW(t);
    t.src := Orig; t.off := 0; t.len := 0;
    b.trailer  := t;
    b.first    := t;
    b.cache    := t;
    b.cacheOrg := 0;
    b.len      := 0;
    b.changed  := FALSE;
    RETURN b
  END New;

  PROCEDURE Load*(b: Buffer; name: ARRAY OF CHAR; VAR res: INTEGER);
  (* Replace b's contents with the bytes of `name`.
     res = Ok on success and b.changed := FALSE.
     res = NotFound: b is left empty (treat as a fresh file named `name`).
     res = IOError:  b is left empty; details lost. *)
    VAR f: Files.File; r: Files.Rider;
        n, i: INTEGER; ch: CHAR; p: Piece;
  BEGIN
    reset(b);
    f := Files.Old(name);
    IF f = NIL THEN
      res := NotFound
    ELSE
      n := Files.Length(f);
      IF n > RegionCap THEN
        res := IOError
      ELSE
        Files.Set(r, f, 0);
        i := 0;
        WHILE i < n DO
          Files.Read(r, ch);
          b.orig.bytes[i] := ch;
          INC(i)
        END;
        b.orig.len := n;
        IF n > 0 THEN
          NEW(p);
          p.src := Orig; p.off := 0; p.len := n;
          p.next := b.trailer;
          p.prev := NIL;
          b.trailer.prev := p;
          b.first := p;
          b.cache := p; b.cacheOrg := 0
        END;
        b.len := n;
        res := Ok
      END;
      Files.Close(f)
    END
  END Load;

  PROCEDURE Save*(b: Buffer; name: ARRAY OF CHAR; VAR res: INTEGER);
  (* Write b to `name`. On Ok, b.changed := FALSE. *)
    VAR f: Files.File; r: Files.Rider;
        p: Piece; i: INTEGER; ch: CHAR;
  BEGIN
    f := Files.New(name);
    IF f = NIL THEN
      res := IOError
    ELSE
      Files.Set(r, f, 0);
      p := b.first;
      WHILE p # b.trailer DO
        i := 0;
        WHILE i < p.len DO
          ch := getByte(b, p.src, p.off + i);
          Files.Write(r, ch);
          INC(i)
        END;
        p := p.next
      END;
      Files.Register(f);
      b.changed := FALSE;
      res := Ok
    END
  END Save;

  (* ---------------- Editing ---------------- *)

  PROCEDURE Insert*(b: Buffer; pos: INTEGER; ch: CHAR);
  (* Insert one character at pos. pos clamped to [0, b.len].
     If the byte just appended is contiguous with the piece immediately
     to the left (same source, abutting offsets), that piece is extended
     in place — no new Piece is allocated. This is the typing case. *)
    VAR org, appendOff, plOrg: INTEGER;
        p, pr, pl, q: Piece;
  BEGIN
    IF pos < 0 THEN pos := 0
    ELSIF pos > b.len THEN pos := b.len
    END;
    appendOff := appendByte(b, ch);
    FindPiece(b, pos, org, p);
    SplitPiece(p, pos - org, pr);
    pl := pr.prev;
    (* Snapshot pl's start before any mutation. After coalesce extends
       pl.len, "pos - pl.len" no longer gives pl's start. *)
    IF pl # NIL THEN plOrg := pos - pl.len ELSE plOrg := 0 END;
    IF (pl # NIL) & (pl.src = Append) & (pl.off + pl.len = appendOff) THEN
      INC(pl.len)
    ELSE
      NEW(q);
      q.src := Append; q.off := appendOff; q.len := 1;
      q.next := pr;
      q.prev := pl;
      pr.prev := q;
      IF pl = NIL THEN b.first := q
      ELSE pl.next := q
      END
    END;
    INC(b.len);
    b.changed := TRUE;
    IF b.cacheOrg >= org THEN
      IF pl # NIL THEN
        b.cache := pl; b.cacheOrg := plOrg
      ELSE
        b.cache := b.first; b.cacheOrg := 0
      END
    END
  END Insert;

  PROCEDURE InsertStr*(b: Buffer; pos: INTEGER; s: ARRAY OF CHAR);
  (* Insert all chars of s up to the first 0X. pos clamped to [0, b.len].
     Coalescing makes this O(n): the first char allocates a piece, each
     subsequent char extends that piece in place. *)
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO
      Insert(b, pos + i, s[i]);
      INC(i)
    END
  END InsertStr;

  PROCEDURE Delete*(b: Buffer; beg, end: INTEGER);
  (* Remove the half-open range [beg, end). Range clamped to [0, b.len]. *)
    VAR orgb, orge: INTEGER;
        pb, pbr, pe, per, pl: Piece;
  BEGIN
    IF beg < 0 THEN beg := 0 END;
    IF end > b.len THEN end := b.len END;
    IF beg < end THEN
      FindPiece(b, beg, orgb, pb); SplitPiece(pb, beg - orgb, pbr);
      FindPiece(b, end, orge, pe); SplitPiece(pe, end - orge, per);
      pl := pbr.prev;
      (* Splice [pbr, per) out of the chain. The unlinked
         pbr->...->per.prev segment becomes unreachable; ARC reclaims
         it when pl.next is reassigned below — the old pbr loses its
         sole strong holder, cascading through the segment's
         next-chain. *)
      per.prev := pl;
      IF pl = NIL THEN b.first := per
      ELSE pl.next := per
      END;
      b.len := b.len - (end - beg);
      b.changed := TRUE;
      IF b.cacheOrg >= orgb THEN
        IF pl # NIL THEN
          b.cache := pl; b.cacheOrg := beg - pl.len
        ELSE
          b.cache := b.first; b.cacheOrg := 0
        END
      END
    END
  END Delete;

  (* ---------------- Sequential read ---------------- *)

  PROCEDURE OpenReader*(VAR r: Reader; b: Buffer; pos: INTEGER);
  (* Position r at pos. pos clamped to [0, b.len]. *)
    VAR org: INTEGER; p: Piece;
  BEGIN
    IF pos < 0 THEN pos := 0
    ELSIF pos > b.len THEN pos := b.len
    END;
    FindPiece(b, pos, org, p);
    r.buf := b;
    r.ref := p;
    r.org := org;
    r.off := pos - org;
    r.eot := FALSE
  END OpenReader;

  PROCEDURE Read*(VAR r: Reader; VAR ch: CHAR);
  (* Reads the character at the reader's position and advances by one.
     If the reader is already at end-of-text (ref = trailer), sets eot
     and returns 0X without consuming anything. The pattern
       Read(r, ch); WHILE ~r.eot DO use(ch); Read(r, ch) END
     thus visits every real character exactly once. *)
  BEGIN
    IF r.ref = r.buf.trailer THEN
      r.eot := TRUE; ch := 0X
    ELSE
      ch := getByte(r.buf, r.ref.src, r.ref.off + r.off);
      INC(r.off);
      IF r.off >= r.ref.len THEN
        r.org := r.org + r.ref.len;
        r.off := 0;
        r.ref := r.ref.next
      END
    END
  END Read;

  PROCEDURE Pos*(VAR r: Reader): INTEGER;
  BEGIN RETURN r.org + r.off
  END Pos;

  (* ---------------- Search ---------------- *)

  PROCEDURE patLen(pat: ARRAY OF CHAR): INTEGER;
    VAR m: INTEGER;
  BEGIN
    m := 0;
    WHILE (m < LEN(pat)) & (pat[m] # 0X) DO INC(m) END;
    RETURN m
  END patLen;

  PROCEDURE matchAt(b: Buffer; p, m: INTEGER; VAR pat: ARRAY OF CHAR): BOOLEAN;
    VAR r: Reader; ch: CHAR; i: INTEGER; ok: BOOLEAN;
  BEGIN
    OpenReader(r, b, p);
    i := 0; Read(r, ch);
    WHILE (i < m) & ~r.eot & (ch = pat[i]) DO
      INC(i); Read(r, ch)
    END;
    ok := i = m;
    RETURN ok
  END matchAt;

  PROCEDURE Find*(b: Buffer; from: INTEGER; VAR pat: ARRAY OF CHAR;
                  VAR pos: INTEGER): BOOLEAN;
  (* Search forward for `pat` starting at byte position `from`.
     On match: pos := match-start, returns TRUE.
     Empty pattern matches at `from`. *)
    VAR m, p: INTEGER; matched: BOOLEAN;
  BEGIN
    m := patLen(pat);
    matched := FALSE;
    IF m = 0 THEN
      pos := from; matched := TRUE
    ELSE
      IF from < 0 THEN from := 0 END;
      p := from;
      WHILE ~matched & (p + m <= b.len) DO
        IF matchAt(b, p, m, pat) THEN matched := TRUE; pos := p
        ELSE INC(p)
        END
      END
    END;
    RETURN matched
  END Find;

  PROCEDURE FindBack*(b: Buffer; from: INTEGER; VAR pat: ARRAY OF CHAR;
                      VAR pos: INTEGER): BOOLEAN;
  (* Search backward for `pat` such that the match's end is at or before
     `from`. On match: pos := match-start, returns TRUE.
     Empty pattern matches at `from`. *)
    VAR m, p: INTEGER; matched: BOOLEAN;
  BEGIN
    m := patLen(pat);
    matched := FALSE;
    IF m = 0 THEN
      pos := from; matched := TRUE
    ELSE
      IF from > b.len THEN from := b.len END;
      p := from - m;
      WHILE ~matched & (p >= 0) DO
        IF matchAt(b, p, m, pat) THEN matched := TRUE; pos := p
        ELSE DEC(p)
        END
      END
    END;
    RETURN matched
  END FindBack;

  (* ---------------- Introspection ---------------- *)

  PROCEDURE PieceCount*(b: Buffer): INTEGER;
  (* Number of real pieces in the chain (excludes the trailer). *)
    VAR n: INTEGER; p: Piece;
  BEGIN
    n := 0; p := b.first;
    WHILE p # b.trailer DO INC(n); p := p.next END;
    RETURN n
  END PieceCount;

END Buffer.
