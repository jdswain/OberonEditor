MODULE KillRing;
(* Emacs-style mark + rotating kill ring. The ring storage and the
   yank / kill chain flags are module-level state because they are
   global across all viewers; the mark itself lives with the owning
   viewer and is passed in as a VAR parameter so attach / detach
   can save and restore it.

   Operations take buf, lines, cur and status as parameters so the
   editor's per-buffer state stays in one place (Oed.Mod) — this
   module just supplies the kill-ring data structure and the
   command-level orchestration around it. *)

  IMPORT Buffer, Lines, Strings;

  CONST
    KillCap*     = 4096;       (* upper bound on a single kill / copy *)
    KillRingSize = 8;          (* slots in the rotating kill ring *)

  VAR
    ring:        ARRAY KillRingSize OF ARRAY KillCap OF CHAR;
    lens:        ARRAY KillRingSize OF INTEGER;
    head:        INTEGER;      (* index of most recent entry *)
    count:       INTEGER;      (* valid entries 0..KillRingSize *)
    yankIndex:   INTEGER;      (* offset back from head for current yank *)
    yankStart:   INTEGER;      (* buffer pos where current yank text starts *)
    yankLen:     INTEGER;      (* length of current yank text *)
    lastWasYank: BOOLEAN;      (* was the previous command Yank or YankPop? *)
    lastWasKill: BOOLEAN;      (* successive C-k append to the same ring entry *)

  PROCEDURE LastWasYank*(): BOOLEAN; RETURN lastWasYank END LastWasYank;
  PROCEDURE LastWasKill*(): BOOLEAN; RETURN lastWasKill END LastWasKill;

  PROCEDURE ClearLastWasYank*; BEGIN lastWasYank := FALSE END ClearLastWasYank;
  PROCEDURE ClearLastWasKill*; BEGIN lastWasKill := FALSE END ClearLastWasKill;

  (* Reset both chain flags. Called on buffer switch / kill so
     successive C-k or C-y / M-y across a switch doesn't accidentally
     extend or reuse state from the other buffer. *)
  PROCEDURE Reset*;
  BEGIN lastWasYank := FALSE; lastWasKill := FALSE
  END Reset;

  PROCEDURE Init*;
  BEGIN
    head := 0; count := 0;
    yankIndex := 0; yankStart := 0; yankLen := 0;
    lastWasYank := FALSE; lastWasKill := FALSE
  END Init;

  (* Order mark and cur into [lo, hi). Returns FALSE when no mark is
     active or the region is empty. *)
  PROCEDURE rangeBounds(cur, mark: INTEGER; VAR lo, hi: INTEGER): BOOLEAN;
    VAR ok: BOOLEAN;
  BEGIN
    ok := mark >= 0;
    IF ok THEN
      IF mark < cur THEN lo := mark; hi := cur
      ELSE lo := cur; hi := mark
      END;
      ok := lo < hi
    END;
    RETURN ok
  END rangeBounds;

  (* Push [lo, hi) onto the head of the kill ring, capping at KillCap. *)
  PROCEDURE push(buf: Buffer.Buffer; lo, hi: INTEGER);
    VAR r: Buffer.Reader; ch: CHAR; n: INTEGER;
  BEGIN
    IF hi - lo > KillCap THEN hi := lo + KillCap END;
    IF count > 0 THEN head := (head + 1) MOD KillRingSize END;
    Buffer.OpenReader(r, buf, lo);
    n := 0;
    Buffer.Read(r, ch);
    WHILE ~r.eot & (lo + n < hi) DO
      ring[head][n] := ch; INC(n);
      Buffer.Read(r, ch)
    END;
    lens[head] := n;
    IF count < KillRingSize THEN INC(count) END
  END push;

  (* Append [lo, hi) onto the current head entry instead of pushing
     a new one. Used by successive C-k so a multi-line kill ends up in
     a single ring slot. *)
  PROCEDURE append(buf: Buffer.Buffer; lo, hi: INTEGER);
    VAR r: Buffer.Reader; ch: CHAR; n, room: INTEGER;
  BEGIN
    IF count = 0 THEN
      push(buf, lo, hi)
    ELSE
      n := lens[head];
      room := KillCap - n;
      IF hi - lo > room THEN hi := lo + room END;
      Buffer.OpenReader(r, buf, lo);
      Buffer.Read(r, ch);
      WHILE ~r.eot & (lo < hi) DO
        ring[head][n] := ch; INC(n);
        INC(lo);
        Buffer.Read(r, ch)
      END;
      lens[head] := n
    END
  END append;

  (* Index of the entry yi steps older than head. *)
  PROCEDURE ringSlot(yi: INTEGER): INTEGER;
  BEGIN
    RETURN ((head - yi) MOD KillRingSize + KillRingSize) MOD KillRingSize
  END ringSlot;

  (* Insert ring[slot] at cur. Common path for Yank and YankPop. *)
  PROCEDURE insertSlot(buf: Buffer.Buffer; lines: Lines.Lines;
                       VAR cur: INTEGER; slot: INTEGER);
    VAR i, n: INTEGER;
  BEGIN
    n := lens[slot];
    yankStart := cur;
    i := 0;
    WHILE i < n DO
      Buffer.Insert(buf, cur + i, ring[slot][i]);
      INC(i)
    END;
    cur := cur + n;
    yankLen := n;
    Lines.Inserted(lines, yankStart, n)
  END insertSlot;

  PROCEDURE SetMark*(cur: INTEGER; VAR mark: INTEGER;
                     VAR status: ARRAY OF CHAR);
  BEGIN
    mark := cur;
    Strings.Copy(status, "Mark set")
  END SetMark;

  PROCEDURE CopyRegion*(buf: Buffer.Buffer; cur, mark: INTEGER;
                        VAR status: ARRAY OF CHAR);
    VAR lo, hi: INTEGER;
  BEGIN
    IF rangeBounds(cur, mark, lo, hi) THEN
      push(buf, lo, hi);
      Strings.Copy(status, "Region copied")
    ELSE
      Strings.Copy(status, "No mark set")
    END
  END CopyRegion;

  PROCEDURE KillRegion*(buf: Buffer.Buffer; lines: Lines.Lines;
                        VAR cur, mark: INTEGER;
                        VAR status: ARRAY OF CHAR);
    VAR lo, hi: INTEGER;
  BEGIN
    IF rangeBounds(cur, mark, lo, hi) THEN
      push(buf, lo, hi);
      Buffer.Delete(buf, lo, hi);
      cur := lo;
      mark := -1;
      Lines.Deleted(lines, lo, hi);
      Strings.Copy(status, "Region killed")
    ELSE
      Strings.Copy(status, "No mark set")
    END
  END KillRegion;

  (* Kill from cursor to end of line. If already at end of line, kill
     the newline itself (joining with the next line). Successive C-k
     presses append to the head ring entry; any other command in
     between resets the chain. *)
  PROCEDURE KillLine*(buf: Buffer.Buffer; lines: Lines.Lines; cur: INTEGER;
                      VAR status: ARRAY OF CHAR);
    VAR line, col, lineEnd, killTo: INTEGER;
  BEGIN
    Lines.Locate(lines, cur, line, col);
    lineEnd := Lines.LineEnd(lines, line);
    IF cur < lineEnd THEN killTo := lineEnd
    ELSIF cur < buf.len THEN killTo := cur + 1
    ELSE killTo := cur
    END;
    IF killTo > cur THEN
      IF lastWasKill THEN append(buf, cur, killTo)
      ELSE push(buf, cur, killTo)
      END;
      Buffer.Delete(buf, cur, killTo);
      Lines.Deleted(lines, cur, killTo);
      lastWasKill := TRUE;
      Strings.Copy(status, "Line killed")
    ELSE
      Strings.Copy(status, "End of buffer")
    END
  END KillLine;

  PROCEDURE Yank*(buf: Buffer.Buffer; lines: Lines.Lines;
                  VAR cur: INTEGER; VAR status: ARRAY OF CHAR);
  BEGIN
    IF count = 0 THEN
      Strings.Copy(status, "Kill register empty");
      lastWasYank := FALSE
    ELSE
      yankIndex := 0;
      insertSlot(buf, lines, cur, head);
      lastWasYank := TRUE;
      Strings.Copy(status, "Yanked")
    END
  END Yank;

  (* Replace the previous yank with the next-older entry from the ring.
     Only valid immediately after a Yank or YankPop. *)
  PROCEDURE YankPop*(buf: Buffer.Buffer; lines: Lines.Lines;
                     VAR cur: INTEGER; VAR status: ARRAY OF CHAR);
  BEGIN
    IF ~lastWasYank THEN
      Strings.Copy(status, "Previous command was not a yank")
    ELSIF count = 0 THEN
      Strings.Copy(status, "Kill ring empty");
      lastWasYank := FALSE
    ELSE
      Buffer.Delete(buf, yankStart, yankStart + yankLen);
      Lines.Deleted(lines, yankStart, yankStart + yankLen);
      cur := yankStart;
      yankIndex := (yankIndex + 1) MOD count;
      insertSlot(buf, lines, cur, ringSlot(yankIndex));
      lastWasYank := TRUE;
      Strings.Copy(status, "Yank popped")
    END
  END YankPop;

BEGIN
  Init
END KillRing.
