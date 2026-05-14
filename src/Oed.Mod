MODULE Oed;
(* Editor shell. Globals mirror the current Viewer's state: buf,
   lines and name come from the Viewer's Doc; cur, top and mark are
   per-Viewer presentation state. The Doc/Viewer split — bytes
   versus presentation — lives in Doc.Mod and Viewers.Mod, the first
   step of the data-layer plan in doc/DataDDR.md. *)

  IMPORT TUI, Buffer, Lines, Env, Mini, Files, Schema, Csv, Doc, Viewers, Project,
         Collection, Expr, TableView, FormView, SpreadsheetView;

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
    cur:     INTEGER;          (* text: cursor pos; table: row index *)
    top:     INTEGER;          (* text: top-line pos; table: top-row index *)
    curCol:  INTEGER;          (* table: column index; ignored for text *)
    dataDoc: Doc.Doc;          (* table: backing data Doc; else NIL *)
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
    lastWasKill: BOOLEAN;      (* successive C-k append to the same ring entry *)
    ssCells:     SpreadsheetView.CellList;  (* re-parsed per spreadsheet refresh *)

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

  PROCEDURE AppendStr(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
    VAR i, j: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(dst) - 1) & (dst[i] # 0X) DO INC(i) END;
    j := 0;
    WHILE (i < LEN(dst) - 1) & (j < LEN(src)) & (src[j] # 0X) DO
      dst[i] := src[j]; INC(i); INC(j)
    END;
    dst[i] := 0X
  END AppendStr;

  (* Copy the directory portion of path into dir, including the
     trailing slash. dir = "" when path has no slash (cwd). *)
  PROCEDURE DirOf(path: ARRAY OF CHAR; VAR dir: ARRAY OF CHAR);
    VAR i, last: INTEGER;
  BEGIN
    last := -1; i := 0;
    WHILE (i < LEN(path)) & (path[i] # 0X) DO
      IF path[i] = "/" THEN last := i END;
      INC(i)
    END;
    IF last < 0 THEN
      dir[0] := 0X
    ELSE
      i := 0;
      WHILE (i <= last) & (i < LEN(dir) - 1) DO
        dir[i] := path[i]; INC(i)
      END;
      dir[i] := 0X
    END
  END DirOf;

  PROCEDURE SetStatus(s: ARRAY OF CHAR);
  BEGIN CopyStr(status, s)
  END SetStatus;

  (* ---------------- editing ---------------- *)

  PROCEDURE InsertCh(ch: CHAR);
  BEGIN
    Buffer.Insert(buf, cur, ch);
    Lines.Inserted(lines, cur, 1);
    INC(cur)
  END InsertCh;

  PROCEDURE BackspaceCh;
  BEGIN
    IF cur > 0 THEN
      Buffer.Delete(buf, cur - 1, cur);
      Lines.Deleted(lines, cur - 1, cur);
      DEC(cur)
    END
  END BackspaceCh;

  PROCEDURE DeleteCh;
  BEGIN
    IF cur < buf.len THEN
      Buffer.Delete(buf, cur, cur + 1);
      Lines.Deleted(lines, cur, cur + 1)
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

  (* Append [lo, hi) onto the current head entry instead of pushing
     a new one. Used by successive C-k so a multi-line kill ends up in
     a single ring slot. *)
  PROCEDURE appendKill(lo, hi: INTEGER);
    VAR r: Buffer.Reader; ch: CHAR; n, room: INTEGER;
  BEGIN
    IF killCount = 0 THEN
      pushKill(lo, hi)
    ELSE
      n := killLens[killHead];
      room := KillCap - n;
      IF hi - lo > room THEN hi := lo + room END;
      Buffer.OpenReader(r, buf, lo);
      Buffer.Read(r, ch);
      WHILE ~r.eot & (lo < hi) DO
        killRing[killHead][n] := ch; INC(n);
        INC(lo);
        Buffer.Read(r, ch)
      END;
      killLens[killHead] := n
    END
  END appendKill;

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
    Lines.Inserted(lines, yankStart, n)
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
      Lines.Deleted(lines, lo, hi);
      SetStatus("Region killed")
    ELSE
      SetStatus("No mark set")
    END
  END KillRegion;

  (* Kill from cursor to end of line. If already at end of line, kill
     the newline itself (joining with the next line). Successive C-k
     presses append to the head ring entry; any other command in
     between resets the chain. *)
  PROCEDURE KillLine;
    VAR line, col, lineEnd, killTo: INTEGER;
  BEGIN
    Lines.Locate(lines, cur, line, col);
    lineEnd := Lines.LineEnd(lines, line);
    IF cur < lineEnd THEN killTo := lineEnd
    ELSIF cur < buf.len THEN killTo := cur + 1
    ELSE killTo := cur
    END;
    IF killTo > cur THEN
      IF lastWasKill THEN appendKill(cur, killTo)
      ELSE pushKill(cur, killTo)
      END;
      Buffer.Delete(buf, cur, killTo);
      Lines.Deleted(lines, cur, killTo);
      lastWasKill := TRUE;
      SetStatus("Line killed")
    ELSE
      SetStatus("End of buffer")
    END
  END KillLine;

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
      Lines.Deleted(lines, yankStart, yankStart + yankLen);
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
    VAR curLine, lineCol, topLine, topCol, viewportRows, dataRows: INTEGER;
        v: Viewers.Viewer;
  BEGIN
    viewportRows := TUI.Rows - 2;
    IF viewportRows < 1 THEN viewportRows := 1 END;
    v := Viewers.Current();
    IF (v # NIL)
        & ((v.kind = Viewers.KTableView) OR (v.kind = Viewers.KViewerList)
           OR (v.kind = Viewers.KSpreadsheetView)) THEN
      dataRows := viewportRows - 1;            (* minus the header row *)
      IF dataRows < 1 THEN dataRows := 1 END;
      IF cur < top THEN top := cur
      ELSIF cur >= top + dataRows THEN top := cur - dataRows + 1
      END;
      IF top < 0 THEN top := 0 END
    ELSE
      Lines.Locate(lines, cur, curLine, lineCol);
      Lines.Locate(lines, top, topLine, topCol);
      IF curLine < topLine THEN
        top := Lines.LineStart(lines, curLine)
      ELSIF curLine >= topLine + viewportRows THEN
        top := Lines.LineStart(lines, curLine - viewportRows + 1)
      END
    END
  END ScrollToCursor;

  (* ---------------- file commands ---------------- *)

  (* Parse the @column header for kinds that need a Schema. Both
     kCollection (the schema OF the data) and kTableView (the
     projection columns) populate doc.schema the same way. The
     schema goes stale on edit (acceptable for v1). *)
  PROCEDURE refreshSchema(v: Viewers.Viewer);
  BEGIN
    IF v # NIL THEN
      IF (v.kind = Viewers.KCollection) OR (v.kind = Viewers.KTableView)
          OR (v.kind = Viewers.KFormView)
          OR (v.kind = Viewers.KSpreadsheetView) THEN
        IF v.doc.schema = NIL THEN v.doc.schema := Schema.New() END;
        Schema.Parse(v.doc.buf, v.doc.schema)
      END
    END
  END refreshSchema;

  (* For a kTableView or kFormView, parse the view definition's
     @ref directive, resolve to a physical .col path, and find or
     load a sibling kCollection viewer for the data. v.dataDoc
     ends up pointing at that viewer's Doc so the view renders
     against shared bytes (edits to either view show in the
     other). *)
  PROCEDURE loadViewData(v: Viewers.Viewer);
    VAR refPath, physPath: ARRAY 256 OF CHAR;
        sch: Schema.Schema;
        data: Viewers.Viewer;
        d: Doc.Doc;
        res: INTEGER;
        nm: ARRAY NameLen OF CHAR;
  BEGIN
    IF (v # NIL)
        & ((v.kind = Viewers.KTableView) OR (v.kind = Viewers.KFormView)
           OR (v.kind = Viewers.KSpreadsheetView)) THEN
      sch := v.doc.schema;
      IF sch = NIL THEN sch := Schema.New(); v.doc.schema := sch END;
      IF v.kind = Viewers.KTableView THEN
        TableView.Parse(v.doc.buf, sch, refPath)
      ELSIF v.kind = Viewers.KFormView THEN
        FormView.Parse(v.doc.buf, sch, refPath)
      ELSE
        ssCells.n := 0;
        SpreadsheetView.Parse(v.doc.buf, sch, refPath, ssCells)
      END;
      IF refPath[0] # 0X THEN
        Project.ResolveColl(refPath, physPath);
        data := Viewers.FindByDocName(physPath);
        IF data = NIL THEN
          CopyStr(nm, physPath);
          d := Doc.New(nm);
          Buffer.Load(d.buf, physPath, res);
          Lines.Invalidate(d.lines);
          d.schema := Schema.New();
          Schema.Parse(d.buf, d.schema);
          (* Register a viewer so the data file is also browsable. *)
          Project.Logical(physPath, nm);
          data := Viewers.New(nm, d, Viewers.KCollection);
          Viewers.Add(data)
        END;
        v.dataDoc := data.doc
      END
    END
  END loadViewData;

  (* Save without any checks. Used after the directory pre-flight
     in DoSave has confirmed the target dir exists (or just created
     it on the user's behalf). *)
  PROCEDURE writeFile;
    VAR res: INTEGER;
  BEGIN
    Buffer.Save(buf, name, res);
    IF res = Buffer.Ok THEN SetStatus("Saved")
    ELSE SetStatus("Save failed")
    END
  END writeFile;

  (* Pre-flight check: if the target directory of `name` doesn't
     exist, offer to create it. Otherwise the underlying
     Files.Register would fail and Buffer.Save now leaves
     b.changed = TRUE so the user gets the discard prompt on quit. *)
  PROCEDURE DoSave;
    VAR dir: ARRAY NameLen OF CHAR;
        msg: ARRAY 192 OF CHAR;
        res: INTEGER;
  BEGIN
    DirOf(name, dir);
    IF (dir[0] # 0X) & (Files.Exists(dir) = 0) THEN
      CopyStr(msg, "Directory '");
      AppendStr(msg, dir);
      AppendStr(msg, "' does not exist. Create? (y/n) ");
      IF Mini.Confirm(msg) THEN
        Files.MakeDir(dir, res);
        IF res = 0 THEN
          writeFile
        ELSE
          SetStatus("Could not create directory")
        END
      ELSE
        SetStatus("Save cancelled — directory missing")
      END
    ELSE
      writeFile
    END
  END DoSave;

  PROCEDURE PromptSaveAs;
    VAR fname: ARRAY NameLen OF CHAR; ok: BOOLEAN; v: Viewers.Viewer;
  BEGIN
    Mini.Prompt("Save as: ", fname, ok, NIL);
    IF ok & (fname[0] # 0X) THEN
      CopyStr(name, fname);
      v := Viewers.Current();
      IF v # NIL THEN
        CopyStr(v.doc.name, name);     (* canonical Doc name *)
        Project.Logical(name, v.label);(* refresh display label *)
        v.kind := Viewers.KindOf(name);(* extension may have changed *)
        refreshSchema(v)               (* re-parse if kind became kCollection *)
      END;
      DoSave
    ELSE
      SetStatus("Save cancelled")
    END
  END PromptSaveAs;

  PROCEDURE Save;
  BEGIN
    (* Buffers without a file (empty name) and "internal" buffers
       conventionally named *foo* both need a real filename prompt. *)
    IF (name[0] = 0X) OR (name[0] = "*") THEN PromptSaveAs
    ELSE DoSave
    END
  END Save;

  (* ---------------- multi-viewer plumbing ---------------- *)

  (* Sync globals from the registry's current Viewer. The Doc owns
     buf/lines/name; the Viewer owns cur/top/mark. *)
  PROCEDURE attachCurrent;
    VAR v: Viewers.Viewer;
  BEGIN
    v := Viewers.Current();
    IF v # NIL THEN
      buf     := v.doc.buf;
      lines   := v.doc.lines;
      cur     := v.cur;
      top     := v.top;
      mark    := v.mark;
      curCol  := v.curCol;
      dataDoc := v.dataDoc;
      CopyStr(name, v.doc.name)
    END
  END attachCurrent;

  (* Push the editor's cur/top/mark globals back into the current
     Viewer so a subsequent attach restores them. The Doc fields
     (buf/lines/name) are reference-shared and need no write-back. *)
  PROCEDURE detachCurrent;
    VAR v: Viewers.Viewer;
  BEGIN
    v := Viewers.Current();
    IF v # NIL THEN
      v.cur    := cur;
      v.top    := top;
      v.mark   := mark;
      v.curCol := curCol
    END
  END detachCurrent;

  PROCEDURE switchTo(target: Viewers.Viewer);
  BEGIN
    IF (target # NIL) & (target # Viewers.Current()) THEN
      detachCurrent;
      Viewers.SetCurrent(target);
      attachCurrent;
      (* Yank/kill chains are buffer-local; reset on switch. *)
      lastWasYank := FALSE;
      lastWasKill := FALSE
    END
  END switchTo;

  (* Make a fresh Doc and a Viewer wrapping it. Doc keeps the
     physical (canonical) path as its name; the Viewer's label is
     the project-logical abbreviation when the file lives under the
     root (e.g. "/Objects/Foo.col"), or the physical path otherwise.
     Synthetic "*foo*" names pass through unchanged. *)
  PROCEDURE makeViewer(VAR n: ARRAY OF CHAR): Viewers.Viewer;
    VAR d: Doc.Doc; label: ARRAY NameLen OF CHAR;
  BEGIN
    d := Doc.New(n);
    Project.Logical(n, label);
    RETURN Viewers.New(label, d, Viewers.KindOf(n))
  END makeViewer;

  (* Tab-completion source for the buffer-switch prompt. Extends
     `text` to the longest prefix shared by all viewer labels that
     start with text[0..len-1]. *)
  PROCEDURE bufferCompleter(VAR text: ARRAY OF CHAR; VAR len: INTEGER);
    VAR i, k, commonLen: INTEGER;
        v: Viewers.Viewer;
        first, matches: BOOLEAN;
        common: ARRAY 64 OF CHAR;
  BEGIN
    first := TRUE; commonLen := 0;
    i := 0;
    WHILE i < Viewers.Count() DO
      v := Viewers.At(i);
      (* prefix match: v.label[0..len-1] = text[0..len-1] *)
      matches := TRUE;
      k := 0;
      WHILE matches & (k < len) DO
        IF v.label[k] # text[k] THEN matches := FALSE END;
        INC(k)
      END;
      IF matches THEN
        IF first THEN
          CopyStr(common, v.label);
          commonLen := 0;
          WHILE (commonLen < LEN(common)) & (common[commonLen] # 0X) DO
            INC(commonLen)
          END;
          first := FALSE
        ELSE
          k := 0;
          WHILE (k < commonLen) & (common[k] = v.label[k]) DO INC(k) END;
          commonLen := k
        END
      END;
      INC(i)
    END;
    IF ~first & (commonLen > len) THEN
      k := 0;
      WHILE k < commonLen DO text[k] := common[k]; INC(k) END;
      text[commonLen] := 0X;
      len := commonLen
    END
  END bufferCompleter;

  PROCEDURE PromptSwitchBuffer;
    VAR n: ARRAY NameLen OF CHAR; ok: BOOLEAN;
        target: Viewers.Viewer;
  BEGIN
    Mini.Prompt("Switch to buffer: ", n, ok, bufferCompleter);
    IF ok & (n[0] # 0X) THEN
      target := Viewers.Find(n);
      IF target # NIL THEN
        switchTo(target);
        SetStatus("Switched")
      ELSE
        SetStatus("No such buffer")
      END
    ELSE
      SetStatus("Switch cancelled")
    END
  END PromptSwitchBuffer;

  PROCEDURE PromptKillBuffer;
  (* Empty input kills the current buffer. Confirms before discarding
     unsaved changes. After kill, the registry's new current becomes
     active; if the registry is empty, a fresh *scratch* takes over. *)
    VAR n, scratchName: ARRAY NameLen OF CHAR;
        ok, killing: BOOLEAN;
        target, scratch: Viewers.Viewer;
  BEGIN
    Mini.Prompt("Kill buffer: ", n, ok, bufferCompleter);
    IF ok THEN
      IF n[0] = 0X THEN target := Viewers.Current()
      ELSE target := Viewers.Find(n)
      END;
      IF target = NIL THEN
        SetStatus("No such buffer")
      ELSE
        killing := TRUE;
        IF target.doc.buf.changed THEN
          killing := Mini.Confirm("Buffer modified. Kill anyway? (y/n) ")
        END;
        IF killing THEN
          IF target = Viewers.Current() THEN detachCurrent END;
          Viewers.Kill(target);
          IF Viewers.Count() = 0 THEN
            CopyStr(scratchName, "*scratch*");
            scratch := makeViewer(scratchName);
            Viewers.Add(scratch);
            Viewers.SetCurrent(scratch)
          END;
          attachCurrent;
          lastWasYank := FALSE; lastWasKill := FALSE;
          SetStatus("Buffer killed")
        ELSE
          SetStatus("Kill cancelled")
        END
      END
    ELSE
      SetStatus("Kill cancelled")
    END
  END PromptKillBuffer;

  (* Decimal int → string. Right-pads result with NUL. *)
  PROCEDURE IntStr(n: INTEGER; VAR s: ARRAY OF CHAR);
    VAR digits: ARRAY 16 OF CHAR; i, j: INTEGER; ch: CHAR;
  BEGIN
    IF n < 0 THEN n := -n END;
    IF n = 0 THEN
      s[0] := "0"; s[1] := 0X
    ELSE
      i := 0;
      WHILE n > 0 DO
        ch := CHR(ORD("0") + n MOD 10);
        digits[i] := ch;
        n := n DIV 10;
        INC(i)
      END;
      j := 0;
      WHILE i > 0 DO
        DEC(i);
        s[j] := digits[i];
        INC(j)
      END;
      s[j] := 0X
    END
  END IntStr;

  (* Append literal bytes from s to b at pos, advancing pos. *)
  PROCEDURE appendBytes(b: Buffer.Buffer; VAR pos: INTEGER; s: ARRAY OF CHAR);
    VAR k: INTEGER;
  BEGIN
    k := 0;
    WHILE (k < LEN(s)) & (s[k] # 0X) DO
      Buffer.Insert(b, pos, s[k]); INC(pos); INC(k)
    END
  END appendBytes;

  PROCEDURE kindName(k: INTEGER; VAR s: ARRAY OF CHAR);
  (* Short label for Viewer.kind, used in the *viewers* table. *)
  BEGIN
    IF    k = Viewers.KText            THEN CopyStr(s, "text")
    ELSIF k = Viewers.KCollection      THEN CopyStr(s, "coll")
    ELSIF k = Viewers.KTableView       THEN CopyStr(s, "table")
    ELSIF k = Viewers.KSpreadsheetView THEN CopyStr(s, "sheet")
    ELSIF k = Viewers.KFormView        THEN CopyStr(s, "form")
    ELSIF k = Viewers.KViewerList      THEN CopyStr(s, "list")
    ELSE                                    CopyStr(s, "?")
    END
  END kindName;

  (* (Re)populate the *viewers* synthetic Doc with one CSV row per
     registered Viewer, behind a small @column header that drives
     the table layout. The Doc is owned by the *viewers* Viewer
     (`listV` below); its bytes are regenerated on every Refresh
     while *viewers* is current, so the listing always reflects the
     registry's current state. *)
  PROCEDURE rebuildViewersDoc(d: Doc.Doc);
    VAR pos, i: INTEGER;
        v: Viewers.Viewer;
        sizeStr, kStr: ARRAY 16 OF CHAR;
  BEGIN
    Buffer.Delete(d.buf, 0, d.buf.len);
    pos := 0;
    appendBytes(d.buf, pos, "@column(label, 32)");
    Buffer.Insert(d.buf, pos, 0AX); INC(pos);
    appendBytes(d.buf, pos, "@column(kind, 6)");
    Buffer.Insert(d.buf, pos, 0AX); INC(pos);
    appendBytes(d.buf, pos, "@column(size, 6)");
    Buffer.Insert(d.buf, pos, 0AX); INC(pos);
    appendBytes(d.buf, pos, "@column(dirty, 2)");
    Buffer.Insert(d.buf, pos, 0AX); INC(pos);

    i := 0;
    WHILE i < Viewers.Count() DO
      v := Viewers.At(i);
      Csv.WriteField(d.buf, pos, v.label); Csv.WriteSep(d.buf, pos);
      kindName(v.kind, kStr);
      Csv.WriteField(d.buf, pos, kStr);    Csv.WriteSep(d.buf, pos);
      IntStr(v.doc.buf.len, sizeStr);
      Csv.WriteField(d.buf, pos, sizeStr); Csv.WriteSep(d.buf, pos);
      IF v.doc.buf.changed THEN Csv.WriteField(d.buf, pos, "*")
      ELSE Csv.WriteField(d.buf, pos, "")
      END;
      Csv.EndRow(d.buf, pos);
      INC(i)
    END;

    Lines.Invalidate(d.lines);
    d.buf.changed := FALSE;
    IF d.schema = NIL THEN d.schema := Schema.New() END;
    Schema.Parse(d.buf, d.schema)
  END rebuildViewersDoc;

  PROCEDURE ensureViewersList(): Viewers.Viewer;
  (* Find or create the *viewers* listing viewer; kind is forced to
     KViewerList and dataDoc points at itself so TableView.Render
     can walk the embedded CSV directly. *)
    VAR v: Viewers.Viewer; nm: ARRAY NameLen OF CHAR;
  BEGIN
    CopyStr(nm, "*viewers*");
    v := Viewers.Find(nm);
    IF v = NIL THEN
      v := makeViewer(nm);
      v.kind := Viewers.KViewerList;
      v.dataDoc := v.doc;
      Viewers.Add(v)
    END;
    RETURN v
  END ensureViewersList;

  PROCEDURE ListBuffers;
  (* C-x C-b — switch to *viewers*. The Doc is rebuilt here and
     every subsequent Refresh while *viewers* is current. *)
    VAR v: Viewers.Viewer;
  BEGIN
    v := ensureViewersList();
    rebuildViewersDoc(v.doc);
    v.cur := 0; v.top := 0; v.curCol := 0;
    switchTo(v);
    SetStatus("Viewer list — Enter to switch, k to kill")
  END ListBuffers;

  (* C-x s: save every dirty buffer that has a real filename. Skips
     internal/*-named buffers and any with no name. Reports the
     count, plus any failures. *)
  PROCEDURE SaveAll;
    VAR i, saved, failed, res: INTEGER;
        v: Viewers.Viewer;
        msg: ARRAY 96 OF CHAR;
        countStr: ARRAY 16 OF CHAR;
  BEGIN
    detachCurrent;          (* flush cur/top/mark to current Viewer *)
    saved := 0; failed := 0;
    i := 0;
    WHILE i < Viewers.Count() DO
      v := Viewers.At(i);
      IF v.doc.buf.changed & (v.doc.name[0] # 0X) & (v.doc.name[0] # "*") THEN
        Buffer.Save(v.doc.buf, v.doc.name, res);
        IF res = Buffer.Ok THEN INC(saved) ELSE INC(failed) END
      END;
      INC(i)
    END;
    CopyStr(msg, "Saved ");
    IntStr(saved, countStr); AppendStr(msg, countStr);
    IF failed > 0 THEN
      AppendStr(msg, ", ");
      IntStr(failed, countStr); AppendStr(msg, countStr);
      AppendStr(msg, " failed")
    END;
    SetStatus(msg)
  END SaveAll;

  PROCEDURE PromptOpen;
  (* Open creates a new Viewer (and Doc) for the file, or switches to
     an existing Viewer already visiting that filename. Current
     buffer's unsaved changes are preserved — they stay in their
     existing Viewer/Doc, just no longer the active one. *)
    VAR fname: ARRAY NameLen OF CHAR; ok: BOOLEAN; res: INTEGER;
        target: Viewers.Viewer;
  BEGIN
    Mini.Prompt("Open: ", fname, ok, NIL);
    IF ok & (fname[0] # 0X) THEN
      target := Viewers.FindByDocName(fname);
      IF target = NIL THEN
        target := makeViewer(fname);
        Buffer.Load(target.doc.buf, fname, res);
        Lines.Invalidate(target.doc.lines);
        refreshSchema(target);
        Viewers.Add(target);
        loadViewData(target);
        IF res = Buffer.Ok THEN SetStatus("Opened")
        ELSIF res = Buffer.NotFound THEN SetStatus("(new file)")
        ELSE SetStatus("Open failed")
        END
      ELSE
        SetStatus("Switched to existing buffer")
      END;
      switchTo(target)
    ELSE
      SetStatus("Open cancelled")
    END
  END PromptOpen;

  PROCEDURE PromptOpenRawText;
  (* C-x C-r: open as raw text regardless of extension. If a Doc for
     the path is already loaded by another (structured) Viewer, share
     the Doc and create a sibling kText Viewer with a "<text>" suffix
     in its label so the buffer list distinguishes the two. If the
     existing Viewer is already kText we just switch to it. *)
    VAR fname: ARRAY NameLen OF CHAR; ok: BOOLEAN; res: INTEGER;
        target, existing: Viewers.Viewer;
        textLabel: ARRAY 96 OF CHAR;
  BEGIN
    Mini.Prompt("Find file as text: ", fname, ok, NIL);
    IF ok & (fname[0] # 0X) THEN
      existing := Viewers.FindByDocName(fname);
      IF existing = NIL THEN
        Project.Logical(fname, textLabel);
        target := Viewers.New(textLabel, Doc.New(fname), Viewers.KText);
        Buffer.Load(target.doc.buf, fname, res);
        Lines.Invalidate(target.doc.lines);
        Viewers.Add(target);
        IF res = Buffer.Ok THEN SetStatus("Opened as text")
        ELSIF res = Buffer.NotFound THEN SetStatus("(new file)")
        ELSE SetStatus("Open failed")
        END;
        switchTo(target)
      ELSIF existing.kind = Viewers.KText THEN
        switchTo(existing);
        SetStatus("Switched to existing buffer")
      ELSE
        Project.Logical(existing.doc.name, textLabel);
        AppendStr(textLabel, "<text>");
        target := Viewers.Find(textLabel);
        IF target = NIL THEN
          target := Viewers.New(textLabel, existing.doc, Viewers.KText);
          Viewers.Add(target)
        END;
        switchTo(target);
        SetStatus("Opened as text")
      END
    ELSE
      SetStatus("Open cancelled")
    END
  END PromptOpenRawText;

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
    VAR line, col, dummy, i: INTEGER;
        displayName: ARRAY NameLen OF CHAR;
        v: Viewers.Viewer;
  BEGIN
    TUI.MoveTo(0, TUI.Rows - 2);
    TUI.SetAttr(TUI.AttrReverse);
    TUI.WriteStr(" oed 0.1  ");
    IF name[0] = 0X THEN
      displayName := "[No File]"
    ELSE
      Project.Logical(name, displayName)
    END;
    TUI.WriteStr(displayName);
    IF buf.changed THEN TUI.WriteStr(" *") END;
    TUI.WriteStr("    ");
    v := Viewers.Current();
    IF (v # NIL)
        & ((v.kind = Viewers.KTableView) OR (v.kind = Viewers.KViewerList)
           OR (v.kind = Viewers.KSpreadsheetView)) THEN
      TUI.WriteStr("R:"); TUI.WriteInt(cur + 1);
      TUI.WriteStr(" C:"); TUI.WriteInt(curCol + 1)
    ELSIF (v # NIL) & (v.kind = Viewers.KFormView) THEN
      TUI.WriteStr("Rec:"); TUI.WriteInt(top + 1);
      TUI.WriteStr(" Fld:"); TUI.WriteInt(cur + 1)
    ELSE
      Lines.Locate(lines, cur, line, col);
      TUI.WriteStr("L:"); TUI.WriteInt(line + 1);
      TUI.WriteStr(" C:"); TUI.WriteInt(col + 1)
    END;
    IF (v # NIL) & (v.kind = Viewers.KCollection) & (v.doc.schema # NIL) THEN
      TUI.WriteStr("  [");
      TUI.WriteInt(v.doc.schema.ncol); TUI.WriteStr(" cols");
      i := 0;
      WHILE (i < v.doc.schema.ncol) & (i < 4) DO
        IF i = 0 THEN TUI.WriteStr(": ") ELSE TUI.WriteStr(", ") END;
        TUI.WriteStr(v.doc.schema.cols[i].name);
        INC(i)
      END;
      IF v.doc.schema.ncol > 4 THEN TUI.WriteStr(", ...") END;
      TUI.WriteStr("]")
    END;
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
    VAR v: Viewers.Viewer;
        ssRefPath: ARRAY 256 OF CHAR;
  BEGIN
    TUI.Resize;
    ScrollToCursor;
    TUI.HideCursor;
    v := Viewers.Current();
    IF v # NIL THEN
      IF v.kind = Viewers.KViewerList THEN rebuildViewersDoc(v.doc) END
    END;
    IF (v # NIL)
        & ((v.kind = Viewers.KTableView) OR (v.kind = Viewers.KViewerList)) THEN
      TableView.Render(v.doc, v.dataDoc, top, cur, curCol, TUI.Rows - 2);
      cursRow := cur - top + 1;                  (* +1 for header row *)
      cursCol := TableView.ColumnX(v.doc.schema, curCol)
    ELSIF (v # NIL) & (v.kind = Viewers.KFormView) THEN
      FormView.Render(v.doc, v.dataDoc, top, cur, TUI.Rows - 2,
                      cursRow, cursCol)
    ELSIF (v # NIL) & (v.kind = Viewers.KSpreadsheetView) THEN
      ssCells.n := 0;
      SpreadsheetView.Parse(v.doc.buf, v.doc.schema, ssRefPath, ssCells);
      SpreadsheetView.Render(v.doc, v.dataDoc, ssCells,
                             top, 0, cur, curCol, TUI.Rows - 2,
                             cursRow, cursCol)
    ELSE
      DrawBufferAndLocateCursor(cursRow, cursCol)
    END;
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

  (* Prompt for a new value for the current (cur, curCol) cell, pre-
     filled with the existing value, and on commit splice it into
     the backing collection. The data Doc's b.changed flips so a
     subsequent C-x s (or C-x C-s on the .col itself) persists. *)
  PROCEDURE EditCurrentCell;
    VAR v: Viewers.Viewer;
        viewSch, dataSch: Schema.Schema;
        coll: Collection.Collection;
        rowStart, dataCol: INTEGER;
        colName: ARRAY Schema.MaxName OF CHAR;
        cur0, newVal: ARRAY 256 OF CHAR;
        ok: BOOLEAN;
        promptText: ARRAY 64 OF CHAR;
  BEGIN
    v := Viewers.Current();
    IF (v = NIL) OR (v.kind # Viewers.KTableView)
        OR (v.dataDoc = NIL) OR (v.doc.schema = NIL) THEN
      SetStatus("Cannot edit here")
    ELSE
      viewSch := v.doc.schema;
      dataSch := v.dataDoc.schema;
      IF (curCol < 0) OR (curCol >= viewSch.ncol) THEN
        SetStatus("No column selected")
      ELSE
        CopyStr(colName, viewSch.cols[curCol].name);
        dataCol := Schema.Find(dataSch, colName);
        IF dataCol < 0 THEN
          SetStatus("Projection column not in data schema")
        ELSE
          coll := Collection.Open(v.dataDoc);
          rowStart := Collection.FindRow(coll, cur);
          IF rowStart < 0 THEN
            SetStatus("Row out of range")
          ELSE
            Collection.GetCell(coll, rowStart, dataCol, cur0);
            CopyStr(promptText, "Edit ");
            AppendStr(promptText, viewSch.cols[curCol].label);
            AppendStr(promptText, ": ");
            Mini.PromptEdit(promptText, cur0, newVal, ok, NIL);
            IF ok THEN
              Collection.SetCell(coll, rowStart, dataCol, newVal);
              SetStatus("Cell updated")
            ELSE
              SetStatus("Edit cancelled")
            END
          END
        END
      END
    END
  END EditCurrentCell;

  (* The *viewers* listing assigns row N to Viewers.At(N). Enter on
     a row switches to that viewer; k kills it. Both clamp via
     Viewers.At which returns NIL out-of-range. *)
  PROCEDURE SwitchToRowViewer;
    VAR target: Viewers.Viewer;
  BEGIN
    target := Viewers.At(cur);
    IF target = NIL THEN SetStatus("No such row")
    ELSIF target = Viewers.Current() THEN SetStatus("Already current")
    ELSE
      switchTo(target);
      SetStatus("Switched")
    END
  END SwitchToRowViewer;

  PROCEDURE KillRowViewer;
    VAR target: Viewers.Viewer;
        killing: BOOLEAN;
        scratchName: ARRAY NameLen OF CHAR;
        scratch: Viewers.Viewer;
  BEGIN
    target := Viewers.At(cur);
    IF target = NIL THEN SetStatus("No such row")
    ELSE
      killing := TRUE;
      IF target.doc.buf.changed THEN
        killing := Mini.Confirm("Buffer modified. Kill anyway? (y/n) ")
      END;
      IF killing THEN
        IF target = Viewers.Current() THEN detachCurrent END;
        Viewers.Kill(target);
        IF Viewers.Count() = 0 THEN
          CopyStr(scratchName, "*scratch*");
          scratch := makeViewer(scratchName);
          Viewers.Add(scratch);
          Viewers.SetCurrent(scratch)
        END;
        attachCurrent;
        IF cur > 0 THEN DEC(cur) END;
        lastWasYank := FALSE; lastWasKill := FALSE;
        SetStatus("Buffer killed")
      ELSE
        SetStatus("Kill cancelled")
      END
    END
  END KillRowViewer;

  (* Navigation for a kTableView. cur is the row index, top is the
     top visible row, curCol the column. Read-only motion for now;
     Enter opens an in-place edit (EditCurrentCell). For
     KViewerList, Enter switches to the row's viewer and k kills
     it. *)
  PROCEDURE TableEntryKey(k: INTEGER);
    VAR v: Viewers.Viewer;
        nRows, nCols, viewportRows: INTEGER;
  BEGIN
    v := Viewers.Current();
    IF v.doc.schema = NIL THEN nCols := 0
    ELSE nCols := v.doc.schema.ncol
    END;
    nRows := TableView.RowCount(v.dataDoc);
    viewportRows := TUI.Rows - 3;
    IF viewportRows < 1 THEN viewportRows := 1 END;
    IF k = TUI.KeyCtrlX THEN
      mode := ModeCommand;
      SetStatus("Ctrl-X: Ctrl-S save, Ctrl-W save-as, Ctrl-F open, Ctrl-C quit")
    ELSIF (k = TUI.KeyArrowLeft) OR (k = TUI.KeyCtrlB) THEN
      IF curCol > 0 THEN DEC(curCol) END; SetStatus("")
    ELSIF (k = TUI.KeyArrowRight) OR (k = TUI.KeyCtrlF) THEN
      IF curCol < nCols - 1 THEN INC(curCol) END; SetStatus("")
    ELSIF (k = TUI.KeyArrowUp) OR (k = TUI.KeyCtrlP) THEN
      IF cur > 0 THEN DEC(cur) END; SetStatus("")
    ELSIF (k = TUI.KeyArrowDown) OR (k = TUI.KeyCtrlN) THEN
      IF cur < nRows - 1 THEN INC(cur) END; SetStatus("")
    ELSIF (k = TUI.KeyHome) OR (k = TUI.KeyCtrlA) THEN
      curCol := 0; SetStatus("")
    ELSIF (k = TUI.KeyEnd) OR (k = TUI.KeyCtrlE) THEN
      IF nCols > 0 THEN curCol := nCols - 1 END; SetStatus("")
    ELSIF k = TUI.KeyMetaLT THEN
      cur := 0; top := 0; SetStatus("")
    ELSIF k = TUI.KeyMetaGT THEN
      IF nRows > 0 THEN cur := nRows - 1 END; SetStatus("")
    ELSIF k = TUI.KeyPageUp THEN
      cur := cur - viewportRows;
      IF cur < 0 THEN cur := 0 END;
      SetStatus("")
    ELSIF k = TUI.KeyPageDown THEN
      cur := cur + viewportRows;
      IF cur >= nRows THEN cur := nRows - 1 END;
      IF cur < 0 THEN cur := 0 END;
      SetStatus("")
    ELSIF k = TUI.KeyCtrlL THEN
      SetStatus("")
    ELSIF k = TUI.KeyEnter THEN
      IF v.kind = Viewers.KViewerList THEN
        SwitchToRowViewer
      ELSE
        EditCurrentCell
      END
    ELSIF (k = ORD("k")) & (v.kind = Viewers.KViewerList) THEN
      KillRowViewer
    ELSE
      IF v.kind = Viewers.KViewerList THEN
        SetStatus("Enter switches to viewer, k kills it")
      ELSE
        SetStatus("Press Enter to edit")
      END
    END
  END TableEntryKey;

  (* Prompt for a new value for the current form field at the
     current record, pre-filled with its existing value. On commit,
     Collection.SetCell writes it back. *)
  PROCEDURE EditCurrentField;
    VAR v: Viewers.Viewer;
        fl: FormView.Layout;
        coll: Collection.Collection;
        rowStart, dataCol: INTEGER;
        cur0, newVal: ARRAY 256 OF CHAR;
        ok: BOOLEAN;
        promptText: ARRAY 64 OF CHAR;
        name: ARRAY FormView.MaxFieldName OF CHAR;
  BEGIN
    v := Viewers.Current();
    IF (v = NIL) OR (v.kind # Viewers.KFormView)
        OR (v.dataDoc = NIL) OR (v.dataDoc.schema = NIL) THEN
      SetStatus("Cannot edit here")
    ELSE
      FormView.CollectFields(v.doc, fl);
      IF (cur < 0) OR (cur >= fl.n) THEN
        SetStatus("No field selected")
      ELSE
        CopyStr(name, fl.fields[cur].name);
        dataCol := Schema.Find(v.dataDoc.schema, name);
        IF dataCol < 0 THEN
          SetStatus("Field not in data schema")
        ELSE
          coll := Collection.Open(v.dataDoc);
          rowStart := Collection.FindRow(coll, top);
          IF rowStart < 0 THEN
            SetStatus("Record out of range")
          ELSE
            Collection.GetCell(coll, rowStart, dataCol, cur0);
            CopyStr(promptText, "Edit ");
            AppendStr(promptText, name);
            AppendStr(promptText, ": ");
            Mini.PromptEdit(promptText, cur0, newVal, ok, NIL);
            IF ok THEN
              Collection.SetCell(coll, rowStart, dataCol, newVal);
              SetStatus("Field updated")
            ELSE
              SetStatus("Edit cancelled")
            END
          END
        END
      END
    END
  END EditCurrentField;

  (* Navigation for a kFormView. cur is the current field index,
     top is the current record index. M-n / M-p step records, Tab
     cycles fields, Enter opens an in-place edit. *)
  PROCEDURE FormEntryKey(k: INTEGER);
    VAR v: Viewers.Viewer;
        nRecords, nFields: INTEGER;
        fl: FormView.Layout;
  BEGIN
    v := Viewers.Current();
    nRecords := FormView.RecordCount(v.dataDoc);
    FormView.CollectFields(v.doc, fl);
    nFields := fl.n;
    IF k = TUI.KeyCtrlX THEN
      mode := ModeCommand;
      SetStatus("Ctrl-X: Ctrl-S save, Ctrl-W save-as, Ctrl-F open, Ctrl-C quit")
    ELSIF (k = TUI.KeyMetaP) OR (k = TUI.KeyArrowUp) OR (k = TUI.KeyCtrlP) THEN
      IF top > 0 THEN DEC(top) END; SetStatus("")
    ELSIF (k = TUI.KeyMetaN) OR (k = TUI.KeyArrowDown) OR (k = TUI.KeyCtrlN) THEN
      IF top < nRecords - 1 THEN INC(top) END; SetStatus("")
    ELSIF k = TUI.KeyTab THEN
      IF nFields > 0 THEN cur := (cur + 1) MOD nFields END;
      SetStatus("")
    ELSIF k = TUI.KeyMetaLT THEN
      top := 0; SetStatus("")
    ELSIF k = TUI.KeyMetaGT THEN
      IF nRecords > 0 THEN top := nRecords - 1 END; SetStatus("")
    ELSIF k = TUI.KeyEnter THEN
      EditCurrentField
    ELSIF k = TUI.KeyCtrlL THEN
      SetStatus("")
    ELSE
      SetStatus("M-n/M-p record, Tab field, Enter edit")
    END
  END FormEntryKey;

  (* Build a string showing the literal user-facing value at
     (curCol, cur) for use as the edit prompt's initial. For
     spreadsheets that means: if an @cell override exists at this
     coord, show its formula (= form); otherwise show the .col
     cell value. *)
  PROCEDURE currentSpreadsheetText(VAR txt: ARRAY OF CHAR);
    VAR v: Viewers.Viewer;
        coll: Collection.Collection;
        rowStart: INTEGER;
        cells: SpreadsheetView.CellList;
        refPath: ARRAY 256 OF CHAR;
        i: INTEGER;
        found: BOOLEAN;
  BEGIN
    txt[0] := 0X;
    v := Viewers.Current();
    IF v # NIL THEN
      cells.n := 0;
      SpreadsheetView.Parse(v.doc.buf, v.doc.schema, refPath, cells);
      found := FALSE; i := 0;
      WHILE (i < cells.n) & ~found DO
        IF (cells.cells[i].col = curCol) & (cells.cells[i].row = cur) THEN
          CopyStr(txt, cells.cells[i].formula);
          found := TRUE
        END;
        INC(i)
      END;
      IF ~found & (v.dataDoc # NIL) THEN
        coll := Collection.Open(v.dataDoc);
        rowStart := Collection.FindRow(coll, cur);
        IF rowStart >= 0 THEN
          Collection.GetCell(coll, rowStart, curCol, txt)
        END
      END
    END
  END currentSpreadsheetText;

  (* Cell editing for kSpreadsheetView. Prompts pre-filled with the
     current value (formula text if overridden, .col value
     otherwise). Routing:
       - new value starts with "=" → SpreadsheetView.SetFormula on
         the .ssh.
       - else if the cell had a formula override but the new value
         is plain, drop the override and write a literal value to
         the .col.
       - else → Collection.SetCell on the .col, extending the data
         with empty rows if needed.
       - empty new value → clears the cell on whichever side it
         currently lives. *)
  PROCEDURE EditSpreadsheetCell;
    VAR v: Viewers.Viewer;
        coll: Collection.Collection;
        rowStart, dataCols: INTEGER;
        cur0, newVal: ARRAY 256 OF CHAR;
        ok: BOOLEAN;
        promptText: ARRAY 64 OF CHAR;
        coord: ARRAY 8 OF CHAR;
        rowStr: ARRAY 8 OF CHAR;
  BEGIN
    v := Viewers.Current();
    IF (v = NIL) OR (v.kind # Viewers.KSpreadsheetView)
        OR (v.dataDoc = NIL) OR (v.dataDoc.schema = NIL) THEN
      SetStatus("Cannot edit here")
    ELSE
      dataCols := v.dataDoc.schema.ncol;
      currentSpreadsheetText(cur0);
      coord[0] := CHR(ORD("A") + curCol); coord[1] := 0X;
      IntStr(cur + 1, rowStr);
      CopyStr(promptText, "Edit ");
      AppendStr(promptText, coord);
      AppendStr(promptText, rowStr);
      AppendStr(promptText, ": ");
      Mini.PromptEdit(promptText, cur0, newVal, ok, NIL);
      IF ok THEN
        IF newVal[0] = "=" THEN
          (* Formulas can live in any cell — no data-column restriction. *)
          SpreadsheetView.SetFormula(v.doc, curCol, cur, newVal);
          SetStatus("Formula stored")
        ELSIF (curCol < 0) OR (curCol >= dataCols) THEN
          SetStatus("Column out of data range (use = for formulas)")
        ELSE
          SpreadsheetView.ClearCell(v.doc, curCol, cur);
          coll := Collection.Open(v.dataDoc);
          Collection.EnsureRow(coll, cur);
          rowStart := Collection.FindRow(coll, cur);
          IF rowStart < 0 THEN
            SetStatus("Failed to extend data")
          ELSE
            Collection.SetCell(coll, rowStart, curCol, newVal);
            SetStatus("Value stored")
          END
        END
      ELSE
        SetStatus("Edit cancelled")
      END
    END
  END EditSpreadsheetCell;

  (* Toggle a `format="bold"` binding on the @cell at (curCol, cur).
     If the cell is currently bold, drop the format= binding;
     otherwise set it. Round-trip preserves the formula= binding. *)
  PROCEDURE ToggleCellBold;
    VAR v: Viewers.Viewer;
        cells: SpreadsheetView.CellList;
        refPath: ARRAY 256 OF CHAR;
        empty: ARRAY 8 OF CHAR;
        bold: ARRAY 8 OF CHAR;
        i: INTEGER; isBold: BOOLEAN;
  BEGIN
    v := Viewers.Current();
    IF (v = NIL) OR (v.kind # Viewers.KSpreadsheetView) THEN
      SetStatus("Cannot format here")
    ELSE
      cells.n := 0;
      SpreadsheetView.Parse(v.doc.buf, v.doc.schema, refPath, cells);
      isBold := FALSE; i := 0;
      WHILE (i < cells.n) & ~isBold DO
        IF (cells.cells[i].col = curCol) & (cells.cells[i].row = cur)
            & (cells.cells[i].format[0] = "b")
            & (cells.cells[i].format[1] = "o")
            & (cells.cells[i].format[2] = "l")
            & (cells.cells[i].format[3] = "d")
            & (cells.cells[i].format[4] = 0X) THEN
          isBold := TRUE
        END;
        INC(i)
      END;
      IF isBold THEN
        empty[0] := 0X;
        SpreadsheetView.SetFormat(v.doc, curCol, cur, empty);
        SetStatus("Bold cleared")
      ELSE
        CopyStr(bold, "bold");
        SpreadsheetView.SetFormat(v.doc, curCol, cur, bold);
        SetStatus("Bold set")
      END
    END
  END ToggleCellBold;

  (* Navigation + editing across an A1 grid. cur = row, curCol =
     column. Enter opens an in-place edit that routes by =-prefix
     to either the .ssh (formula) or the .col (literal value).
     M-b toggles a `format="bold"` override on the current cell. *)
  PROCEDURE SpreadsheetEntryKey(k: INTEGER);
    VAR v: Viewers.Viewer; nCols: INTEGER;
  BEGIN
    v := Viewers.Current();
    nCols := 26;                         (* v1: single-letter columns *)
    IF k = TUI.KeyCtrlX THEN
      mode := ModeCommand;
      SetStatus("Ctrl-X: Ctrl-S save, Ctrl-W save-as, Ctrl-F open, Ctrl-C quit")
    ELSIF (k = TUI.KeyArrowLeft) OR (k = TUI.KeyCtrlB) THEN
      IF curCol > 0 THEN DEC(curCol) END; SetStatus("")
    ELSIF (k = TUI.KeyArrowRight) OR (k = TUI.KeyCtrlF) THEN
      IF curCol < nCols - 1 THEN INC(curCol) END; SetStatus("")
    ELSIF (k = TUI.KeyArrowUp) OR (k = TUI.KeyCtrlP) THEN
      IF cur > 0 THEN DEC(cur) END; SetStatus("")
    ELSIF (k = TUI.KeyArrowDown) OR (k = TUI.KeyCtrlN) THEN
      INC(cur); SetStatus("")
    ELSIF (k = TUI.KeyHome) OR (k = TUI.KeyCtrlA) THEN
      curCol := 0; SetStatus("")
    ELSIF (k = TUI.KeyEnd) OR (k = TUI.KeyCtrlE) THEN
      curCol := nCols - 1; SetStatus("")
    ELSIF k = TUI.KeyMetaLT THEN
      cur := 0; top := 0; SetStatus("")
    ELSIF k = TUI.KeyPageUp THEN
      cur := cur - 10; IF cur < 0 THEN cur := 0 END; SetStatus("")
    ELSIF k = TUI.KeyPageDown THEN
      cur := cur + 10; SetStatus("")
    ELSIF k = TUI.KeyCtrlL THEN
      SetStatus("")
    ELSIF k = TUI.KeyEnter THEN
      EditSpreadsheetCell
    ELSIF k = TUI.KeyMetaB THEN
      ToggleCellBold
    ELSE
      SetStatus("Enter edit, M-b bold; =-prefix routes to .ssh")
    END
  END SpreadsheetEntryKey;

  PROCEDURE TextEntryKey(k: INTEGER);
    VAR ch: CHAR; isYankCmd, isKillCmd: BOOLEAN;
  BEGIN
    isYankCmd := (k = TUI.KeyCtrlY) OR (k = TUI.KeyMetaY);
    isKillCmd := k = TUI.KeyCtrlK;
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
    | TUI.KeyCtrlN:      MoveDown;  SetStatus("")
    | TUI.KeyCtrlP:      MoveUp;    SetStatus("")
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
    | TUI.KeyCtrlK:      KillLine
    ELSE
      IF (k >= 32) & (k < 127) THEN
        ch := CHR(k);
        InsertCh(ch);
        SetStatus("")
      ELSE
        SetStatus("(unhandled key)")
      END
    END;
    IF ~isYankCmd THEN lastWasYank := FALSE END;
    IF ~isKillCmd THEN lastWasKill := FALSE END
  END TextEntryKey;

  PROCEDURE EntryKey(k: INTEGER);
    VAR v: Viewers.Viewer;
  BEGIN
    v := Viewers.Current();
    IF (v # NIL)
        & ((v.kind = Viewers.KTableView) OR (v.kind = Viewers.KViewerList)) THEN
      TableEntryKey(k)
    ELSIF (v # NIL) & (v.kind = Viewers.KFormView) THEN
      FormEntryKey(k)
    ELSIF (v # NIL) & (v.kind = Viewers.KSpreadsheetView) THEN
      SpreadsheetEntryKey(k)
    ELSE
      TextEntryKey(k)
    END
  END EntryKey;

  (* Any viewer in the registry whose Doc has unsaved changes? Used
     by the quit guard so unsaved work in a non-current viewer still
     warns. *)
  PROCEDURE anyBufferDirty(): BOOLEAN;
    VAR i: INTEGER; dirty: BOOLEAN; v: Viewers.Viewer;
  BEGIN
    detachCurrent;       (* flush cur/top/mark; .changed is on the Doc's Buffer *)
    dirty := FALSE; i := 0;
    WHILE ~dirty & (i < Viewers.Count()) DO
      v := Viewers.At(i);
      IF v.doc.buf.changed THEN dirty := TRUE END;
      INC(i)
    END;
    RETURN dirty
  END anyBufferDirty;

  PROCEDURE CommandKey(k: INTEGER);
  BEGIN
    IF k = TUI.KeyCtrlC THEN
      IF ~anyBufferDirty() OR Mini.Confirm("Discard unsaved changes? (y/n) ") THEN
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
    ELSIF k = TUI.KeyCtrlR THEN
      PromptOpenRawText
    ELSIF k = ORD("b") THEN
      PromptSwitchBuffer
    ELSIF k = ORD("k") THEN
      PromptKillBuffer
    ELSIF k = ORD("s") THEN
      SaveAll
    ELSIF k = TUI.KeyCtrlB THEN
      ListBuffers
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
  (* If argv[1] was given, open it as a new Viewer (or switch to one
     already visiting that file) and switch to it. *)
    VAR fname: ARRAY NameLen OF CHAR; res: INTEGER;
        target: Viewers.Viewer;
  BEGIN
    IF Env.ArgCount() > 1 THEN
      Env.Arg(1, fname);
      IF fname[0] # 0X THEN
        target := Viewers.FindByDocName(fname);
        IF target = NIL THEN
          target := makeViewer(fname);
          Buffer.Load(target.doc.buf, fname, res);
          Lines.Invalidate(target.doc.lines);
          refreshSchema(target);
          Viewers.Add(target);
          loadViewData(target);
          IF res = Buffer.Ok THEN SetStatus("Opened")
          ELSIF res = Buffer.NotFound THEN SetStatus("(new file)")
          ELSE SetStatus("Open failed")
          END
        END;
        switchTo(target)
      END
    END
  END LoadInitialFile;

  PROCEDURE Run;
    VAR scratch: Viewers.Viewer;
        scratchName, initStart: ARRAY NameLen OF CHAR;
  BEGIN
    TUI.Init;
    (* Establish project root before any file open: walks up from
       dirname(argv[1]) (or cwd if no argv) looking for a .oed/
       marker. *)
    IF Env.ArgCount() > 1 THEN
      Env.Arg(1, initStart)
    ELSE
      initStart[0] := 0X
    END;
    Project.Init(initStart);

    (* Always start with a *scratch* viewer so the editor has a
       current viewer even with no argv. argv-driven Open layers on
       top. *)
    CopyStr(scratchName, "*scratch*");
    scratch := makeViewer(scratchName);
    Viewers.Add(scratch);
    Viewers.SetCurrent(scratch);
    attachCurrent;

    killHead    := 0;
    killCount   := 0;
    yankIndex   := 0;
    yankStart   := 0;
    yankLen     := 0;
    lastWasYank := FALSE;
    lastWasKill := FALSE;
    mode        := ModeEntry;
    running     := TRUE;
    SetStatus("HELP: Ctrl-X then Ctrl-S save, Ctrl-W save-as, Ctrl-F open, b switch buffer, Ctrl-C quit");
    LoadInitialFile;
    WHILE running DO
      Refresh;
      Process
    END;
    detachCurrent;
    TUI.Clear;
    TUI.Flush;
    TUI.Shutdown
  END Run;

BEGIN
  Run
END Oed.
