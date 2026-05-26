MODULE Search;
(* Event-driven incremental search.

   Begin starts a session with an initial cursor position and a
   direction; the editor's top-level handleKey routes each key to
   HandleKey while Active(). On commit (Enter) the editor reads
   Cur() and assigns it to its own cur. On cancel (Esc) the editor
   reads OrigCur() to restore the pre-search position.

   The search updates `cur` incrementally on each typed character
   so the renderer paints intermediate matches between keystrokes.
   PaintStatus draws the I-search prompt line; the cursor stays on
   the buffer at the current match end.

   Semantics:
     printable      → extend query, search from anchor
     Ctrl-S         → forward to next match (cursor + 1)
     Ctrl-R         → backward to previous match (before cursor)
     Backspace/^H   → shorten query, re-search from anchor
     Enter          → commit
     Esc            → cancel
   The cursor sits at the END of the match while searching, so each
   additional typed char extends a continuing match. *)

  IMPORT TUI, Buffer, Strings;

  CONST
    MaxQ = 128;

  VAR
    active:    BOOLEAN;
    forward:   BOOLEAN;
    found:     BOOLEAN;
    cur:       INTEGER;     (* updated as user types *)
    anchor:    INTEGER;     (* search base for re-search on extend *)
    origCur:   INTEGER;     (* restore target on cancel *)
    qLen:      INTEGER;
    query:     ARRAY MaxQ OF CHAR;
    buf:       Buffer.Buffer;
    status:    ARRAY 96 OF CHAR;
    committed: BOOLEAN;     (* TRUE when Enter pressed, FALSE on Esc *)

  PROCEDURE Active*(): BOOLEAN; RETURN active END Active;
  PROCEDURE Cur*():    INTEGER; RETURN cur END Cur;
  PROCEDURE OrigCur*(): INTEGER; RETURN origCur END OrigCur;
  PROCEDURE Committed*(): BOOLEAN; RETURN committed END Committed;

  (* Final status to copy into the editor's status string when the
     session ends. *)
  PROCEDURE Status*(VAR s: ARRAY OF CHAR);
  BEGIN Strings.Copy(s, status)
  END Status;

  PROCEDURE Begin*(b: Buffer.Buffer; initialCur: INTEGER; goForward: BOOLEAN);
  BEGIN
    buf       := b;
    cur       := initialCur;
    anchor    := initialCur;
    origCur   := initialCur;
    forward   := goForward;
    qLen      := 0; query[0] := 0X;
    found     := TRUE;
    committed := FALSE;
    Strings.Copy(status, "");
    active    := TRUE
  END Begin;

  PROCEDURE PaintStatus*;
  BEGIN
    TUI.MoveTo(0, TUI.Rows - 1); TUI.ClearLine;
    IF forward THEN TUI.WriteStr("I-search: ")
    ELSE TUI.WriteStr("I-search backward: ")
    END;
    TUI.WriteStr(query);
    IF ~found & (qLen > 0) THEN TUI.WriteStr("  (not found)") END
  END PaintStatus;

  PROCEDURE finish(commit: BOOLEAN);
  BEGIN
    active    := FALSE;
    committed := commit;
    IF ~commit THEN
      cur := origCur;
      Strings.Copy(status, "Search cancelled")
    ELSIF ~found THEN
      Strings.Copy(status, "Search: not found")
    ELSE
      Strings.Copy(status, "")
    END
  END finish;

  PROCEDURE HandleKey*(k: INTEGER);
    VAR pos: INTEGER; ch: CHAR;
  BEGIN
    IF active THEN
      IF k = TUI.KeyEnter THEN
        finish(TRUE)
      ELSIF k = TUI.KeyEscape THEN
        finish(FALSE)
      ELSIF (k = TUI.KeyBackspace) OR (k = TUI.KeyCtrlH) THEN
        IF qLen > 0 THEN
          DEC(qLen); query[qLen] := 0X;
          IF qLen = 0 THEN
            cur := anchor; found := TRUE
          ELSE
            IF forward THEN found := Buffer.Find(buf, anchor, query, pos)
            ELSE found := Buffer.FindBack(buf, anchor, query, pos)
            END;
            IF found THEN cur := pos + qLen ELSE cur := anchor END
          END
        END
      ELSIF k = TUI.KeyCtrlS THEN
        forward := TRUE;
        IF qLen > 0 THEN
          IF Buffer.Find(buf, cur, query, pos) THEN
            found := TRUE; cur := pos + qLen
          ELSE
            found := FALSE
          END
        END
      ELSIF k = TUI.KeyCtrlR THEN
        forward := FALSE;
        IF qLen > 0 THEN
          IF Buffer.FindBack(buf, cur - qLen, query, pos) THEN
            found := TRUE; cur := pos + qLen
          ELSE
            found := FALSE
          END
        END
      ELSIF (k >= 32) & (k < 127) & (qLen < MaxQ - 1) THEN
        ch := CHR(k);
        query[qLen] := ch; INC(qLen); query[qLen] := 0X;
        IF forward THEN found := Buffer.Find(buf, anchor, query, pos)
        ELSE found := Buffer.FindBack(buf, anchor, query, pos)
        END;
        IF found THEN cur := pos + qLen END
      END
    END
  END HandleKey;

BEGIN
  active := FALSE; committed := FALSE
END Search.
