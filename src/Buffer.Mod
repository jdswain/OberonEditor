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

    (* Each region is a list of fixed-size chunks. Chunks are allocated
       on demand: an empty buffer holds zero data chunks, a region grows
       by one ChunkSize-byte allocation per ChunkSize bytes consumed.
       No realloc-and-copy on grow. *)
    ChunkSize = 4096;
    MaxChunks = 256;
    RegionCap = 1048576;          (* ChunkSize * MaxChunks = 1 MB per region *)

    Orig   = 0;               (* Piece.src tags *)
    Append = 1;

    (* Undo / redo ring. UndoCap is the number of slots in each
       direction; MaxEditLen caps the captured text we can carry for
       a single ActInsert entry (ActDelete carries no text — it's just
       pos + len).

       An entry's `kind` describes what to DO when applying it. The
       ring entries on the undo stack are inverses of the user's
       edits (Inserts pair with ActDelete entries, Deletes pair with
       ActInsert entries that hold the deleted bytes). Apply Undo
       runs the entry's action and pushes the symmetric inverse onto
       the redo stack; Redo runs and pushes onto undo. *)
    UndoCap    = 32;
    MaxEditLen = 4096;

    ActSkip   = 0;            (* too-large delete; cannot replay *)
    ActInsert = 1;            (* apply: Insert text at pos *)
    ActDelete = 2;            (* apply: Delete [pos, pos+len) *)

  TYPE
    Buffer* = POINTER TO BufferDesc;

    Chunk = POINTER TO ChunkDesc;
    ChunkDesc = RECORD
      bytes: ARRAY ChunkSize OF CHAR
    END;

    Region = POINTER TO RegionDesc;
    RegionDesc = RECORD
      len:    INTEGER;                    (* bytes used *)
      nch:    INTEGER;                    (* chunks allocated *)
      chunks: ARRAY MaxChunks OF Chunk
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

    (* One reversible edit recorded for undo / redo. Allocated on
       demand; ring slots hold POINTERs so unused slots cost only a
       pointer per buffer rather than MaxEditLen of text. *)
    Edit = POINTER TO EditDesc;
    EditDesc = RECORD
      kind: INTEGER;
      pos:  INTEGER;
      len:  INTEGER;
      text: ARRAY MaxEditLen OF CHAR   (* used only when kind = ActInsert *)
    END;

    BufferDesc* = RECORD
      len*:     INTEGER;     (* total character count *)
      changed*: BOOLEAN;     (* dirty since last Load/Save *)
      first:    Piece;       (* first iteration piece (= trailer when empty) *)
      trailer:  Piece;       (* end-of-chain sentinel; len = 0, next = NIL *)
      cache:    Piece;       (* last-found piece for FindPiece locality *)
      cacheOrg: INTEGER;     (* logical offset of cache piece's start *)
      orig:     Region;
      append:   Region;

      (* Undo / redo state. recording suppresses ring pushes while
         Undo / Redo is itself mutating the chain (otherwise the
         inverse op would push its own undo entry and infinite-loop). *)
      recording:  BOOLEAN;
      undoHead:   INTEGER;
      undoCount:  INTEGER;
      undoRing:   ARRAY UndoCap OF Edit;
      redoHead:   INTEGER;
      redoCount:  INTEGER;
      redoRing:   ARRAY UndoCap OF Edit
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
    RETURN r.chunks[off DIV ChunkSize].bytes[off MOD ChunkSize]
  END getByte;

  PROCEDURE appendByte(b: Buffer; ch: CHAR): INTEGER;
    VAR off, ci, bi: INTEGER;
  BEGIN
    off := b.append.len;
    ci  := off DIV ChunkSize;
    bi  := off MOD ChunkSize;
    IF ci >= b.append.nch THEN
      NEW(b.append.chunks[b.append.nch]); INC(b.append.nch)
    END;
    b.append.chunks[ci].bytes[bi] := ch;
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

  (* ---------------- Undo / redo (private helpers) ---------------- *)

  PROCEDURE byteAt(b: Buffer; pos: INTEGER): CHAR;
    VAR org: INTEGER; p: Piece; ch: CHAR;
  BEGIN
    IF (pos < 0) OR (pos >= b.len) THEN
      ch := 0X
    ELSE
      FindPiece(b, pos, org, p);
      ch := getByte(b, p.src, p.off + (pos - org))
    END;
    RETURN ch
  END byteAt;

  PROCEDURE clearRing(VAR ring: ARRAY OF Edit;
                      VAR head, count: INTEGER);
  BEGIN head := 0; count := 0
  END clearRing;

  (* Read len bytes from b at pos into out[0..len-1]. Used to capture
     deleted text before the actual chain mutation. *)
  PROCEDURE readInto(b: Buffer; pos, len: INTEGER;
                     VAR out: ARRAY OF CHAR);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE i < len DO out[i] := byteAt(b, pos + i); INC(i) END
  END readInto;

  (* Push entry into ring at the next slot. Reuses the slot's parked
     Edit record when present, otherwise allocates. *)
  PROCEDURE ringPush(VAR ring: ARRAY OF Edit;
                     VAR head, count: INTEGER;
                     kind, pos, len: INTEGER;
                     text: ARRAY OF CHAR; copyText: BOOLEAN);
    VAR slot, i: INTEGER; e: Edit;
  BEGIN
    IF count = 0 THEN
      slot := 0
    ELSE
      head := (head + 1) MOD UndoCap;
      slot := head
    END;
    e := ring[slot];
    IF e = NIL THEN NEW(e); ring[slot] := e END;
    e.kind := kind; e.pos := pos; e.len := len;
    IF copyText THEN
      i := 0;
      WHILE (i < len) & (i < MaxEditLen) DO
        e.text[i] := text[i]; INC(i)
      END
    END;
    IF count < UndoCap THEN INC(count) END
  END ringPush;

  PROCEDURE ringPop(VAR head, count: INTEGER);
  BEGIN
    DEC(count);
    IF count > 0 THEN head := (head - 1 + UndoCap) MOD UndoCap
    ELSE head := 0
    END
  END ringPop;

  (* User did Insert(pos, len chars). The undo action is the
     inverse — ActDelete [pos, pos+len). Coalesce with the head
     entry when adjacent: typing "hello" makes one ActDelete
     spanning all five chars, not five entries. *)
  PROCEDURE recordInsert(b: Buffer; pos, len: INTEGER);
    VAR head: Edit; empty: ARRAY 1 OF CHAR; coalesced: BOOLEAN;
  BEGIN
    IF b.recording THEN
      coalesced := FALSE;
      IF b.undoCount > 0 THEN
        head := b.undoRing[b.undoHead];
        IF (head.kind = ActDelete) & (head.pos + head.len = pos) THEN
          head.len := head.len + len;
          coalesced := TRUE
        END
      END;
      IF ~coalesced THEN
        empty[0] := 0X;
        ringPush(b.undoRing, b.undoHead, b.undoCount,
                 ActDelete, pos, len, empty, FALSE)
      END;
      clearRing(b.redoRing, b.redoHead, b.redoCount)
    END
  END recordInsert;

  (* User did Delete([pos, pos+len)). The undo action is the
     inverse — ActInsert with a copy of the bytes leaving the
     chain. Deletes larger than MaxEditLen get an ActSkip marker;
     undo of those is a no-op. *)
  PROCEDURE recordDelete(b: Buffer; pos, len: INTEGER);
    VAR buf: ARRAY MaxEditLen OF CHAR; empty: ARRAY 1 OF CHAR;
  BEGIN
    IF b.recording THEN
      IF len > MaxEditLen THEN
        empty[0] := 0X;
        ringPush(b.undoRing, b.undoHead, b.undoCount,
                 ActSkip, pos, len, empty, FALSE)
      ELSE
        readInto(b, pos, len, buf);
        ringPush(b.undoRing, b.undoHead, b.undoCount,
                 ActInsert, pos, len, buf, TRUE)
      END;
      clearRing(b.redoRing, b.redoHead, b.redoCount)
    END
  END recordDelete;

  (* ---------------- Construction ---------------- *)

  (* Drop any existing chain and reset to the empty state.
     Setting b.first first lets ARC cascade through the now-orphaned
     pieces; b.cache must follow so it doesn't pin a freed piece. *)
  PROCEDURE reset(b: Buffer);
  (* Allocate fresh, zero-chunk Regions. The previous regions become
     unreachable and ARC reclaims them, releasing every chunk in the
     process. Cheaper than walking and NIL-ing the chunk array. *)
  BEGIN
    NEW(b.orig);   b.orig.len := 0;   b.orig.nch := 0;
    NEW(b.append); b.append.len := 0; b.append.nch := 0;
    b.first      := b.trailer;
    b.cache      := b.trailer;
    b.cacheOrg   := 0;
    b.trailer.next := NIL;
    b.trailer.prev := NIL;
    b.len        := 0;
    b.changed    := FALSE;
    (* Loading / clearing the buffer invalidates any prior undo
       state: the chain those entries refer to is gone. *)
    clearRing(b.undoRing, b.undoHead, b.undoCount);
    clearRing(b.redoRing, b.redoHead, b.redoCount)
  END reset;

  PROCEDURE New*(): Buffer;
  (* Returns an empty buffer. *)
    VAR b: Buffer; t: Piece;
  BEGIN
    NEW(b);
    NEW(b.orig);   b.orig.len := 0;   b.orig.nch := 0;
    NEW(b.append); b.append.len := 0; b.append.nch := 0;
    NEW(t);
    t.src := Orig; t.off := 0; t.len := 0;
    b.trailer  := t;
    b.first    := t;
    b.cache    := t;
    b.cacheOrg := 0;
    b.len      := 0;
    b.changed  := FALSE;
    b.recording := TRUE;
    b.undoHead := 0; b.undoCount := 0;
    b.redoHead := 0; b.redoCount := 0;
    RETURN b
  END New;

  PROCEDURE Load*(b: Buffer; name: ARRAY OF CHAR; VAR res: INTEGER);
  (* Replace b's contents with the bytes of `name`.
     res = Ok on success and b.changed := FALSE.
     res = NotFound: b is left empty (treat as a fresh file named `name`).
     res = IOError:  b is left empty; details lost. *)
    VAR f: Files.File; r: Files.Rider;
        n, i, ci, bi: INTEGER; ch: CHAR; p: Piece;
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
          ci := i DIV ChunkSize;
          bi := i MOD ChunkSize;
          IF ci >= b.orig.nch THEN
            NEW(b.orig.chunks[b.orig.nch]); INC(b.orig.nch)
          END;
          Files.Read(r, ch);
          b.orig.chunks[ci].bytes[bi] := ch;
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
      (* Files.Register doesn't surface a status code; it can fail
         silently (rename into a missing directory, permission denied,
         disk full). Probe the filesystem to confirm the file
         actually appeared before clearing the dirty flag. Without
         this check a failed save would clear b.changed and the user
         could quit unprompted. *)
      IF Files.Exists(name) > 0 THEN
        b.changed := FALSE;
        res := Ok
      ELSE
        res := IOError
      END
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
    recordInsert(b, pos, 1);
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
      recordDelete(b, beg, end - beg);
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

  (* ---------------- Undo / redo (public) ---------------- *)

  (* Apply an entry to b. Returns the natural post-apply cursor
     position via `landing` — start of a deleted region, or end of
     an inserted one — and writes the inverse entry that should
     end up on the opposite stack into out{Kind,Pos,Len,Text}.
     Caller pushes the inverse and pops the source ring. *)
  PROCEDURE applyEdit(b: Buffer; e: Edit;
                      VAR landing: INTEGER;
                      VAR outKind, outLen: INTEGER;
                      VAR outText: ARRAY OF CHAR);
    VAR i: INTEGER;
  BEGIN
    outLen  := e.len;
    outKind := ActSkip;       (* default for the ActSkip branch *)
    IF e.kind = ActDelete THEN
      IF e.len <= MaxEditLen THEN
        readInto(b, e.pos, e.len, outText);
        outKind := ActInsert
      END;
      Delete(b, e.pos, e.pos + e.len);
      landing := e.pos
    ELSIF e.kind = ActInsert THEN
      i := 0;
      WHILE i < e.len DO
        Insert(b, e.pos + i, e.text[i]); INC(i)
      END;
      outKind := ActDelete;
      landing := e.pos + e.len
    ELSE  (* ActSkip — cannot apply *)
      landing := e.pos
    END
  END applyEdit;

  (* Pop the head of the undo stack, apply it, push the inverse
     onto the redo stack. Returns FALSE when the undo ring is empty.
     `pos` is the natural cursor landing position. *)
  PROCEDURE Undo*(b: Buffer; VAR pos: INTEGER): BOOLEAN;
    VAR e: Edit;
        text: ARRAY MaxEditLen OF CHAR;
        outKind, outLen: INTEGER;
        ok: BOOLEAN;
  BEGIN
    ok := b.undoCount > 0;
    IF ok THEN
      e := b.undoRing[b.undoHead];
      b.recording := FALSE;
      applyEdit(b, e, pos, outKind, outLen, text);
      ringPush(b.redoRing, b.redoHead, b.redoCount,
               outKind, e.pos, outLen, text, outKind = ActInsert);
      b.recording := TRUE;
      ringPop(b.undoHead, b.undoCount)
    END;
    RETURN ok
  END Undo;

  PROCEDURE Redo*(b: Buffer; VAR pos: INTEGER): BOOLEAN;
    VAR e: Edit;
        text: ARRAY MaxEditLen OF CHAR;
        outKind, outLen: INTEGER;
        ok: BOOLEAN;
  BEGIN
    ok := b.redoCount > 0;
    IF ok THEN
      e := b.redoRing[b.redoHead];
      b.recording := FALSE;
      applyEdit(b, e, pos, outKind, outLen, text);
      ringPush(b.undoRing, b.undoHead, b.undoCount,
               outKind, e.pos, outLen, text, outKind = ActInsert);
      b.recording := TRUE;
      ringPop(b.redoHead, b.redoCount)
    END;
    RETURN ok
  END Redo;

  PROCEDURE ResetHistory*(b: Buffer);
  BEGIN
    clearRing(b.undoRing, b.undoHead, b.undoCount);
    clearRing(b.redoRing, b.redoHead, b.redoCount)
  END ResetHistory;

  PROCEDURE SuspendRecording*(b: Buffer);
  BEGIN b.recording := FALSE
  END SuspendRecording;

  PROCEDURE ResumeRecording*(b: Buffer);
  BEGIN b.recording := TRUE
  END ResumeRecording;

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
