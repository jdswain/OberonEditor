MODULE Oed;
(* Editor shell wired to a Buffer. The viewport renders the buffer's
   plain-ASCII content from `top` for Rows-2 rows; the cursor lives
   as a buffer position `cur` and its screen coordinates are recovered
   during the render walk. Editing routes printable keys, Enter,
   Backspace and Delete through Buffer.Insert / Buffer.Delete.

   Line walking (LineToPos, PosToColRow, LineLenFrom) is inline here
   for now; it migrates to a separate Lines module once soft-wrap
   arrives, since wrap turns "screen row" and "buffer line" into
   different concepts. *)

  IMPORT TUI, Buffer, Lines, Env, Mini;

  CONST
    ModeEntry   = 0;
    ModeCommand = 1;

    StatusLen    = 96;
    NameLen      = 64;
    KillCap      = 4096;       (* upper bound on a single kill / copy *)
    KillRingSize = 8;          (* slots in the rotating kill ring *)

    Newline = 0AX;

  VAR
    buf:     Buffer.Buffer;
    lines:   Lines.Lines;
    cur:     INTEGER;          (* cursor as buffer position *)
    top:     INTEGER;          (* buffer pos of first visible line's start *)
    name:    ARRAY NameLen OF CHAR;
    mode:    INTEGER;
    running: BOOLEAN;
    status:  ARRAY StatusLen OF CHAR;
    mark:        INTEGER;      (* -1 when unset *)
    killRing:    ARRAY KillRingSize OF ARRAY KillCap OF CHAR;
    killLens:    ARRAY KillRingSize OF INTEGER;
    killHead:    INTEGER;      (* index of most recent entry *)
    killCount:   INTEGER;      (* valid entries 0..KillRingSize *)
    yankIndex:   INTEGER;      (* offset back from killHead for current yank *)
    yankStart:   INTEGER;      (* buffer pos where current yank text starts *)
    yankLen:     INTEGER;      (* length of current yank text *)
    lastWasYank: BOOLEAN;      (* was the previous command Yank or YankPop? *)

  (* ---------------- string helpers ---------------- *)

  PROCEDURE CopyStr(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(dst) - 1) & (i < LEN(src)) & (src[i] # 0X) DO
      dst[i] := src[i]; INC(i)
    END;
    dst[i] := 0X
  END CopyStr;

  PROCEDURE SetStatus(s: ARRAY OF CHAR);
  BEGIN CopyStr(status, s)
  END SetStatus;

  (* ---------------- editing ---------------- *)

  PROCEDURE InsertCh(ch: CHAR);
  BEGIN
    Buffer.Insert(buf, cur, ch); INC(cur);
    Lines.Invalidate(lines)
  END InsertCh;

  PROCEDURE BackspaceCh;
  BEGIN
    IF cur > 0 THEN
      Buffer.Delete(buf, cur - 1, cur); DEC(cur);
      Lines.Invalidate(lines)
    END
  END BackspaceCh;

  PROCEDURE DeleteCh;
  BEGIN
    IF cur < buf.len THEN
      Buffer.Delete(buf, cur, cur + 1);
      Lines.Invalidate(lines)
    END
  END DeleteCh;

  (* ---------------- mark / kill ring ---------------- *)

  PROCEDURE SetMark;
  BEGIN
    mark := cur;
    SetStatus("Mark set")
  END SetMark;

  (* Order mark and cur into [lo, hi). Returns FALSE when no mark is
     active or the region is empty. *)
  PROCEDURE rangeBounds(VAR lo, hi: INTEGER): BOOLEAN;
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
  PROCEDURE pushKill(lo, hi: INTEGER);
    VAR r: Buffer.Reader; ch: CHAR; n: INTEGER;
  BEGIN
    IF hi - lo > KillCap THEN hi := lo + KillCap END;
    IF killCount > 0 THEN killHead := (killHead + 1) MOD KillRingSize END;
    Buffer.OpenReader(r, buf, lo);
    n := 0;
    Buffer.Read(r, ch);
    WHILE ~r.eot & (lo + n < hi) DO
      killRing[killHead][n] := ch; INC(n);
      Buffer.Read(r, ch)
    END;
    killLens[killHead] := n;
    IF killCount < KillRingSize THEN INC(killCount) END
  END pushKill;

  (* Index of the entry yankIndex steps older than killHead. *)
  PROCEDURE ringSlot(yi: INTEGER): INTEGER;
  BEGIN
    RETURN ((killHead - yi) MOD KillRingSize + KillRingSize) MOD KillRingSize
  END ringSlot;

  (* Insert killRing[slot] at cur. Common path for Yank and YankPop. *)
  PROCEDURE insertSlot(slot: INTEGER);
    VAR i, n: INTEGER;
  BEGIN
    n := killLens[slot];
    yankStart := cur;
    i := 0;
    WHILE i < n DO
      Buffer.Insert(buf, cur + i, killRing[slot][i]);
      INC(i)
    END;
    cur := cur + n;
    yankLen := n;
    Lines.Invalidate(lines)
  END insertSlot;

  PROCEDURE CopyRegion;
    VAR lo, hi: INTEGER;
  BEGIN
    IF rangeBounds(lo, hi) THEN
      pushKill(lo, hi);
      SetStatus("Region copied")
    ELSE
      SetStatus("No mark set")
    END
  END CopyRegion;

  PROCEDURE KillRegion;
    VAR lo, hi: INTEGER;
  BEGIN
    IF rangeBounds(lo, hi) THEN
      pushKill(lo, hi);
      Buffer.Delete(buf, lo, hi);
      cur := lo;
      mark := -1;
      Lines.Invalidate(lines);
      SetStatus("Region killed")
    ELSE
      SetStatus("No mark set")
    END
  END KillRegion;

  PROCEDURE Yank;
  BEGIN
    IF killCount = 0 THEN
      SetStatus("Kill register empty");
      lastWasYank := FALSE
    ELSE
      yankIndex := 0;
      insertSlot(killHead);
      lastWasYank := TRUE;
      SetStatus("Yanked")
    END
  END Yank;

  (* Replace the previous yank with the next-older entry from the ring.
     Only valid immediately after a Yank or YankPop. *)
  PROCEDURE YankPop;
  BEGIN
    IF ~lastWasYank THEN
      SetStatus("Previous command was not a yank")
    ELSIF killCount = 0 THEN
      SetStatus("Kill ring empty");
      lastWasYank := FALSE
    ELSE
      Buffer.Delete(buf, yankStart, yankStart + yankLen);
      cur := yankStart;
      yankIndex := (yankIndex + 1) MOD killCount;
      insertSlot(ringSlot(yankIndex));
      lastWasYank := TRUE;
      SetStatus("Yank popped")
    END
  END YankPop;

  (* ---------------- movement ---------------- *)

  PROCEDURE MoveLeft;
  BEGIN IF cur > 0 THEN DEC(cur) END
  END MoveLeft;

  PROCEDURE MoveRight;
  BEGIN IF cur < buf.len THEN INC(cur) END
  END MoveRight;

  PROCEDURE MoveHome;
    VAR line, col: INTEGER;
  BEGIN
    Lines.Locate(lines, cur, line, col);
    cur := Lines.LineStart(lines, line)
  END MoveHome;

  PROCEDURE MoveEnd;
    VAR line, col: INTEGER;
  BEGIN
    Lines.Locate(lines, cur, line, col);
    cur := Lines.LineEnd(lines, line)
  END MoveEnd;

  PROCEDURE MoveUp;
    VAR line, col, newLen, newCol: INTEGER;
  BEGIN
    Lines.Locate(lines, cur, line, col);
    IF line > 0 THEN
      newLen := Lines.LineLen(lines, line - 1);
      IF col < newLen THEN newCol := col ELSE newCol := newLen END;
      cur := Lines.LineStart(lines, line - 1) + newCol
    END
  END MoveUp;

  PROCEDURE MoveDown;
    VAR line, col, newLen, newCol: INTEGER;
  BEGIN
    Lines.Locate(lines, cur, line, col);
    IF line + 1 < Lines.Count(lines) THEN
      newLen := Lines.LineLen(lines, line + 1);
      IF col < newLen THEN newCol := col ELSE newCol := newLen END;
      cur := Lines.LineStart(lines, line + 1) + newCol
    END
  END MoveDown;

  (* ---- character classes for word / sentence motion ---- *)

  PROCEDURE isWord(ch: CHAR): BOOLEAN;
  BEGIN
    RETURN ((ch >= "0") & (ch <= "9"))
        OR ((ch >= "A") & (ch <= "Z"))
        OR ((ch >= "a") & (ch <= "z"))
  END isWord;

  PROCEDURE isSpace(ch: CHAR): BOOLEAN;
  BEGIN
    RETURN (ch = " ") OR (ch = 9X) OR (ch = 0AX) OR (ch = 0DX)
  END isSpace;

  PROCEDURE isSentEnd(ch: CHAR): BOOLEAN;
  BEGIN RETURN (ch = ".") OR (ch = "!") OR (ch = "?")
  END isSentEnd;

  (* Random-access char read; OpenReader is amortized O(1) via
     Buffer's piece cache. Returns 0X past end-of-text. *)
  PROCEDURE charAt(p: INTEGER): CHAR;
    VAR r: Buffer.Reader; ch: CHAR;
  BEGIN
    Buffer.OpenReader(r, buf, p);
    Buffer.Read(r, ch);
    IF r.eot THEN ch := 0X END;
    RETURN ch
  END charAt;

  PROCEDURE MoveWordForward;
  (* Skip non-word chars then word chars; lands at first non-word
     char after the current/next word, or at b.len. *)
    VAR r: Buffer.Reader; ch: CHAR; p: INTEGER;
  BEGIN
    Buffer.OpenReader(r, buf, cur);
    p := cur;
    Buffer.Read(r, ch);
    WHILE ~r.eot & ~isWord(ch) DO INC(p); Buffer.Read(r, ch) END;
    WHILE ~r.eot & isWord(ch)  DO INC(p); Buffer.Read(r, ch) END;
    cur := p
  END MoveWordForward;

  PROCEDURE MoveWordBackward;
  (* Walk left over non-word then word chars; lands at the start of
     the current/previous word. *)
    VAR p: INTEGER;
  BEGIN
    p := cur;
    WHILE (p > 0) & ~isWord(charAt(p-1)) DO DEC(p) END;
    WHILE (p > 0) &  isWord(charAt(p-1)) DO DEC(p) END;
    cur := p
  END MoveWordBackward;

  PROCEDURE MoveSentForward;
  (* Find next sentence-end punctuation followed by whitespace, land
     just after the punctuation. If none found, go to end of buffer. *)
    VAR r: Buffer.Reader; ch: CHAR; p: INTEGER;
        pendingEnd, found: BOOLEAN;
  BEGIN
    Buffer.OpenReader(r, buf, cur);
    p := cur; pendingEnd := FALSE; found := FALSE;
    Buffer.Read(r, ch);
    WHILE ~r.eot & ~found DO
      IF pendingEnd & isSpace(ch) THEN
        cur := p; found := TRUE
      ELSE
        IF isSentEnd(ch) THEN pendingEnd := TRUE
        ELSIF ~isSpace(ch) THEN pendingEnd := FALSE
        END;
        INC(p);
        Buffer.Read(r, ch)
      END
    END;
    IF ~found THEN cur := buf.len END
  END MoveSentForward;

  PROCEDURE MoveSentBackward;
  (* Walk from buffer start, recording each sentence-start position
     reached (first non-space at start, then first non-space after a
     sentence-end). Final lastStart < cur is the destination. If the
     cursor sits at a sentence start, this lands on the previous one. *)
    VAR r: Buffer.Reader; ch: CHAR;
        p, lastStart: INTEGER;
        pendingEnd, started: BOOLEAN;
  BEGIN
    IF cur > 0 THEN
      Buffer.OpenReader(r, buf, 0);
      p := 0; lastStart := 0;
      pendingEnd := FALSE; started := FALSE;
      Buffer.Read(r, ch);
      WHILE ~r.eot & (p < cur) DO
        IF ~started & ~isSpace(ch) THEN
          lastStart := p; started := TRUE
        ELSIF pendingEnd & ~isSpace(ch) THEN
          lastStart := p
        END;
        IF isSentEnd(ch) THEN pendingEnd := TRUE
        ELSIF ~isSpace(ch) THEN pendingEnd := FALSE
        END;
        INC(p);
        Buffer.Read(r, ch)
      END;
      cur := lastStart
    END
  END MoveSentBackward;

  PROCEDURE MoveBufStart;
  BEGIN cur := 0
  END MoveBufStart;

  PROCEDURE MoveBufEnd;
  BEGIN cur := buf.len
  END MoveBufEnd;

  PROCEDURE MovePageUp;
    VAR i, viewportRows: INTEGER;
  BEGIN
    viewportRows := TUI.Rows - 2;
    i := 0;
    WHILE i < viewportRows DO MoveUp; INC(i) END
  END MovePageUp;

  PROCEDURE MovePageDown;
    VAR i, viewportRows: INTEGER;
  BEGIN
    viewportRows := TUI.Rows - 2;
    i := 0;
    WHILE i < viewportRows DO MoveDown; INC(i) END
  END MovePageDown;

  (* ---------------- scrolling ---------------- *)

  PROCEDURE ScrollToCursor;
    VAR curLine, curCol, topLine, topCol, viewportRows: INTEGER;
  BEGIN
    viewportRows := TUI.Rows - 2;
    IF viewportRows < 1 THEN viewportRows := 1 END;
    Lines.Locate(lines, cur, curLine, curCol);
    Lines.Locate(lines, top, topLine, topCol);
    IF curLine < topLine THEN
      top := Lines.LineStart(lines, curLine)
    ELSIF curLine >= topLine + viewportRows THEN
      top := Lines.LineStart(lines, curLine - viewportRows + 1)
    END
  END ScrollToCursor;

  (* ---------------- file commands ---------------- *)

  PROCEDURE DoSave;
    VAR res: INTEGER;
  BEGIN
    Buffer.Save(buf, name, res);
    IF res = Buffer.Ok THEN SetStatus("Saved")
    ELSE SetStatus("Save failed")
    END
  END DoSave;

  PROCEDURE PromptSaveAs;
    VAR fname: ARRAY NameLen OF CHAR; ok: BOOLEAN;
  BEGIN
    Mini.Prompt("Save as: ", fname, ok);
    IF ok & (fname[0] # 0X) THEN
      CopyStr(name, fname);
      DoSave
    ELSE
      SetStatus("Save cancelled")
    END
  END PromptSaveAs;

  PROCEDURE Save;
  BEGIN
    IF name[0] = 0X THEN PromptSaveAs ELSE DoSave END
  END Save;

  PROCEDURE PromptOpen;
    VAR fname: ARRAY NameLen OF CHAR; ok: BOOLEAN; res: INTEGER;
        proceed: BOOLEAN;
  BEGIN
    IF buf.changed THEN proceed := Mini.Confirm("Discard unsaved changes? (y/n) ")
    ELSE proceed := TRUE
    END;
    IF proceed THEN
      Mini.Prompt("Open: ", fname, ok);
      IF ok & (fname[0] # 0X) THEN
        Buffer.Load(buf, fname, res);
        Lines.Invalidate(lines);
        cur := 0; top := 0;
        IF res = Buffer.Ok THEN
          CopyStr(name, fname); SetStatus("Opened")
        ELSIF res = Buffer.NotFound THEN
          CopyStr(name, fname); SetStatus("(new file)")
        ELSE
          name[0] := 0X; SetStatus("Open failed")
        END
      ELSE
        SetStatus("Open cancelled")
      END
    ELSE
      SetStatus("Open cancelled")
    END
  END PromptOpen;

  (* ---------------- rendering ---------------- *)

  PROCEDURE DrawBufferAndLocateCursor(VAR cursRow, cursCol: INTEGER);
    VAR r: Buffer.Reader; ch: CHAR;
        pos, row, col, viewportRows: INTEGER;
        done: BOOLEAN;
  BEGIN
    viewportRows := TUI.Rows - 2;
    Buffer.OpenReader(r, buf, top);
    pos := top; row := 0; col := 0;
    cursRow := 0; cursCol := 0;
    done := FALSE;
    TUI.MoveTo(0, 0); TUI.ClearLine;
    Buffer.Read(r, ch);
    WHILE ~done DO
      IF pos = cur THEN cursRow := row; cursCol := col END;
      IF r.eot THEN
        done := TRUE
      ELSIF ch = Newline THEN
        INC(row);
        IF row >= viewportRows THEN
          done := TRUE
        ELSE
          TUI.MoveTo(0, row); TUI.ClearLine;
          col := 0;
          INC(pos);
          Buffer.Read(r, ch)
        END
      ELSE
        IF col < TUI.Cols THEN TUI.Write(ch) END;
        INC(col); INC(pos);
        Buffer.Read(r, ch)
      END
    END;
    (* Tilde-fill remaining rows. row holds the last row touched
       (or one past the last newline written into); fill from row+1. *)
    INC(row);
    WHILE row < viewportRows DO
      TUI.MoveTo(0, row); TUI.ClearLine; TUI.Write("~");
      INC(row)
    END
  END DrawBufferAndLocateCursor;

  PROCEDURE DrawStatusBar;
    VAR line, col, dummy: INTEGER;
        displayName: ARRAY NameLen OF CHAR;
  BEGIN
    TUI.MoveTo(0, TUI.Rows - 2);
    TUI.SetAttr(TUI.AttrReverse);
    TUI.WriteStr(" oed 0.1  ");
    IF name[0] = 0X THEN
      displayName := "[No File]"
    ELSE
      displayName := name
    END;
    TUI.WriteStr(displayName);
    IF buf.changed THEN TUI.WriteStr(" *") END;
    TUI.WriteStr("    ");
    Lines.Locate(lines, cur, line, col);
    TUI.WriteStr("L:"); TUI.WriteInt(line + 1);
    TUI.WriteStr(" C:"); TUI.WriteInt(col + 1);
    dummy := 0;
    WHILE dummy < TUI.Cols DO TUI.Write(" "); INC(dummy) END;
    TUI.SetAttr(TUI.AttrNormal)
  END DrawStatusBar;

  PROCEDURE DrawMessageLine;
  BEGIN
    TUI.MoveTo(0, TUI.Rows - 1);
    TUI.ClearLine;
    TUI.WriteStr(status)
  END DrawMessageLine;

  (* Paint everything except the message line and cursor placement.
     Returns the cursor's screen position so the caller can either
     leave it on the buffer (normal Refresh) or override the message
     line and re-place the cursor (interactive search). *)
  PROCEDURE RefreshFrame(VAR cursRow, cursCol: INTEGER);
  BEGIN
    TUI.Resize;
    ScrollToCursor;
    TUI.HideCursor;
    DrawBufferAndLocateCursor(cursRow, cursCol);
    DrawStatusBar
  END RefreshFrame;

  PROCEDURE Refresh;
    VAR cursRow, cursCol: INTEGER;
  BEGIN
    RefreshFrame(cursRow, cursCol);
    DrawMessageLine;
    IF cursCol >= TUI.Cols THEN cursCol := TUI.Cols - 1 END;
    TUI.MoveTo(cursCol, cursRow);
    TUI.ShowCursor;
    TUI.Flush
  END Refresh;

  (* ---------------- search ---------------- *)

  (* Emacs-style incremental search.
       printable      → extend query, search from anchor
       Ctrl-S         → forward to next match (cursor + 1)
       Ctrl-R         → backward to previous match (before cursor)
       Backspace/^H   → shorten query, re-search from anchor
       Enter          → commit, leave cursor at the match
       Esc            → cancel, restore cursor to where search started
     The cursor sits at the END of the match while searching, so each
     additional typed char naturally extends a continuing match. *)
  PROCEDURE SearchInteractive(forward: BOOLEAN);
    CONST MaxQ = 128;
    VAR query: ARRAY MaxQ OF CHAR;
        qLen, k, i, anchor, origCur, pos: INTEGER;
        cursRow, cursCol: INTEGER;
        ch: CHAR;
        found, done, cancelled: BOOLEAN;
  BEGIN
    query[0] := 0X; qLen := 0;
    origCur := cur;
    anchor := cur;
    found := TRUE;
    cancelled := FALSE; done := FALSE;
    WHILE ~done DO
      RefreshFrame(cursRow, cursCol);
      TUI.MoveTo(0, TUI.Rows - 1); TUI.ClearLine;
      IF forward THEN TUI.WriteStr("I-search: ")
      ELSE TUI.WriteStr("I-search backward: ")
      END;
      TUI.WriteStr(query);
      IF ~found & (qLen > 0) THEN TUI.WriteStr("  (not found)") END;
      IF cursCol >= TUI.Cols THEN cursCol := TUI.Cols - 1 END;
      TUI.MoveTo(cursCol, cursRow);
      TUI.ShowCursor;
      TUI.Flush;
      k := TUI.ReadKey();
      IF k = TUI.KeyEnter THEN
        done := TRUE
      ELSIF k = TUI.KeyEscape THEN
        cancelled := TRUE; done := TRUE
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
          (* cur sits at end of current match; searching from cur finds
             the next non-overlapping match. *)
          IF Buffer.Find(buf, cur, query, pos) THEN
            found := TRUE; cur := pos + qLen
          ELSE
            found := FALSE
          END
        END
      ELSIF k = TUI.KeyCtrlR THEN
        forward := FALSE;
        IF qLen > 0 THEN
          (* cur - qLen is the current match's start; FindBack with that
             ceiling returns the previous non-overlapping match. *)
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
    END;
    IF cancelled THEN
      cur := origCur;
      SetStatus("Search cancelled")
    ELSIF ~found THEN
      SetStatus("Search: not found")
    ELSE
      SetStatus("")
    END
  END SearchInteractive;

  (* ---------------- input ---------------- *)

  PROCEDURE EntryKey(k: INTEGER);
    VAR ch: CHAR; isYankCmd: BOOLEAN;
  BEGIN
    isYankCmd := (k = TUI.KeyCtrlY) OR (k = TUI.KeyMetaY);
    CASE k OF
      TUI.KeyCtrlX:
        mode := ModeCommand;
        SetStatus("Ctrl-X: Ctrl-S save, Ctrl-W save-as, Ctrl-F open, Ctrl-C quit")
    | TUI.KeyCtrlL:
        SetStatus("")
    | TUI.KeyArrowLeft:  MoveLeft;  SetStatus("")
    | TUI.KeyArrowRight: MoveRight; SetStatus("")
    | TUI.KeyArrowUp:    MoveUp;    SetStatus("")
    | TUI.KeyArrowDown:  MoveDown;  SetStatus("")
    | TUI.KeyHome:       MoveHome;  SetStatus("")
    | TUI.KeyEnd:        MoveEnd;   SetStatus("")
    | TUI.KeyPageUp:     MovePageUp;   SetStatus("")
    | TUI.KeyPageDown:   MovePageDown; SetStatus("")
    | TUI.KeyEnter:      InsertCh(Newline); SetStatus("")
    | TUI.KeyBackspace, TUI.KeyCtrlH:
                         BackspaceCh; SetStatus("")
    | TUI.KeyDelete:     DeleteCh; SetStatus("")
    | TUI.KeyCtrlS:      SearchInteractive(TRUE)
    | TUI.KeyCtrlR:      SearchInteractive(FALSE)
    | TUI.KeyCtrlA:      MoveHome;  SetStatus("")
    | TUI.KeyCtrlB:      MoveLeft;  SetStatus("")
    | TUI.KeyCtrlD:      DeleteCh;  SetStatus("")
    | TUI.KeyCtrlE:      MoveEnd;   SetStatus("")
    | TUI.KeyCtrlF:      MoveRight; SetStatus("")
    | TUI.KeyMetaLT:     MoveBufStart; SetStatus("")
    | TUI.KeyMetaGT:     MoveBufEnd;   SetStatus("")
    | TUI.KeyMetaF:      MoveWordForward;  SetStatus("")
    | TUI.KeyMetaB:      MoveWordBackward; SetStatus("")
    | TUI.KeyMetaA:      MoveSentBackward; SetStatus("")
    | TUI.KeyMetaE:      MoveSentForward;  SetStatus("")
    | TUI.KeyCtrlSpace:  SetMark
    | TUI.KeyCtrlW:      KillRegion
    | TUI.KeyCtrlY:      Yank
    | TUI.KeyMetaW:      CopyRegion
    | TUI.KeyMetaY:      YankPop
    ELSE
      IF (k >= 32) & (k < 127) THEN
        ch := CHR(k);
        InsertCh(ch);
        SetStatus("")
      ELSE
        SetStatus("(unhandled key)")
      END
    END;
    IF ~isYankCmd THEN lastWasYank := FALSE END
  END EntryKey;

  PROCEDURE CommandKey(k: INTEGER);
  BEGIN
    IF k = TUI.KeyCtrlC THEN
      IF ~buf.changed OR Mini.Confirm("Discard unsaved changes? (y/n) ") THEN
        running := FALSE
      ELSE
        SetStatus("Quit cancelled")
      END
    ELSIF k = TUI.KeyCtrlS THEN
      Save
    ELSIF k = TUI.KeyCtrlW THEN
      PromptSaveAs
    ELSIF k = TUI.KeyCtrlF THEN
      PromptOpen
    ELSE
      SetStatus("Command cancelled")
    END;
    mode := ModeEntry
  END CommandKey;

  PROCEDURE Process;
    VAR k: INTEGER;
  BEGIN
    k := TUI.ReadKey();
    IF mode = ModeEntry THEN EntryKey(k)
    ELSE CommandKey(k)
    END
  END Process;

  PROCEDURE LoadInitialFile;
  (* If argv[1] was given, open it as the editor's initial buffer.
     Treat NotFound the same as Open does: keep the name so the next
     save creates the file, and report it on the message line. *)
    VAR fname: ARRAY NameLen OF CHAR; res: INTEGER;
  BEGIN
    IF Env.ArgCount() > 1 THEN
      Env.Arg(1, fname);
      IF fname[0] # 0X THEN
        Buffer.Load(buf, fname, res);
        Lines.Invalidate(lines);
        IF res = Buffer.Ok THEN
          CopyStr(name, fname); SetStatus("Opened")
        ELSIF res = Buffer.NotFound THEN
          CopyStr(name, fname); SetStatus("(new file)")
        ELSE
          SetStatus("Open failed")
        END
      END
    END
  END LoadInitialFile;

  PROCEDURE Run;
  BEGIN
    TUI.Init;
    buf     := Buffer.New();
    lines   := Lines.New(buf);
    cur     := 0;
    top     := 0;
    name[0] := 0X;
    mark        := -1;
    killHead    := 0;
    killCount   := 0;
    yankIndex   := 0;
    yankStart   := 0;
    yankLen     := 0;
    lastWasYank := FALSE;
    mode        := ModeEntry;
    running := TRUE;
    SetStatus("HELP: Ctrl-X then Ctrl-S save, Ctrl-W save-as, Ctrl-F open, Ctrl-C quit");
    LoadInitialFile;
    WHILE running DO
      Refresh;
      Process
    END;
    TUI.Clear;
    TUI.Flush;
    TUI.Shutdown
  END Run;

BEGIN
  Run
END Oed.
