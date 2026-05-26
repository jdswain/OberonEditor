MODULE Oed;
(* Editor shell + dispatcher. Owns the per-buffer mutable state
   (buf, lines, cur, top, curCol, leftCol, dataDoc, name, mark,
   mode, running, status, ssCells) that mirrors the current
   Viewer's fields; attachCurrent / detachCurrent sync it with the
   registry on buffer switch.

   Most behaviour lives in dedicated modules:
     Strings    text / int helpers
     Motion     cursor movement (char, word, sentence, line, page)
     KillRing   mark + rotating kill ring + region ops
     Search     incremental search loop
     Render     word-wrap text renderer + markdown link styling
     FileOps    save / save-as / save-all
     BufList    *viewers* synthesis + buffer-name completer
   Oed.Mod itself keeps the per-kind entry-key dispatchers (Table
   / Form / Spreadsheet), the viewer-attach plumbing, the open
   chain (which creates Viewers and is tangled with refreshSchema /
   loadViewData), and the Run main loop.

   The Doc/Viewer split — bytes versus presentation — lives in
   Doc.Mod and Viewers.Mod, the first step of the data-layer plan
   in doc/DataDDR.md. *)

  IMPORT TUI, Buffer, Lines, Env, Mini, Files, Schema, Csv, Doc, Viewers, Project,
         Collection, Expr, TableView, FormView, SpreadsheetView, Strings, KillRing,
         Motion, Render, Search, BufList, FileOps, Links, History, FileBrowser;

  CONST
    ModeEntry   = 0;
    ModeCommand = 1;

    StatusLen    = 96;
    NameLen      = 64;

    Newline = 0AX;

  VAR
    buf:     Buffer.Buffer;
    lines:   Lines.Lines;
    cur:     INTEGER;          (* text: cursor pos; table: row index *)
    top:     INTEGER;          (* text: top-line pos; table: top-row index *)
    curCol:  INTEGER;          (* table: column index; ignored for text *)
    leftCol: INTEGER;          (* table/spreadsheet: first visible column;
                                  form: first visible char offset *)
    dataDoc: Doc.Doc;          (* table: backing data Doc; else NIL *)
    name:    ARRAY NameLen OF CHAR;
    mode:    INTEGER;
    running: BOOLEAN;
    status:  ARRAY StatusLen OF CHAR;
    mark:    INTEGER;          (* -1 when unset; mirrors v.mark via attach *)
    ssCells: SpreadsheetView.CellList;  (* re-parsed per spreadsheet refresh *)

    (* Pending state for continuation-passing prompt flows. Each
       prompt-initiating procedure stores any data it needs on commit
       here, and the corresponding done callback reads it back. Since
       the editor's globals (cur, curCol, buf, lines, name) are
       frozen while Mini is active — Mini.HandleKey routes all
       keystrokes to the prompt — most flows just consult those
       globals in their done callback rather than snapshotting. *)
    pendingKillTarget:    Viewers.Viewer;
    pendingRowKillTarget: Viewers.Viewer;
    pendingSaveDir:       ARRAY NameLen OF CHAR;
    pendingLinkUS:        INTEGER;
    pendingLinkUE:        INTEGER;
    pendingFileDone:      Mini.PromptDone;

  PROCEDURE SetStatus(s: ARRAY OF CHAR);
  BEGIN Strings.Copy(status, s)
  END SetStatus;

  (* ---------------- filename Tab → FileBrowser ---------------- *)

  (* Mini's Tab handler runs in two phases: launchBrowser stashes
     Mini's done callback into pendingFileDone (declared at the top
     of the module) and starts the browser; browserCommitDone fires
     when the user picks a file (or cancels), forwarding the chosen
     path back through the stashed done as if Enter had been
     pressed in Mini. *)

  PROCEDURE browserCommitDone(path: ARRAY OF CHAR; ok: BOOLEAN);
    VAR cb: Mini.PromptDone;
  BEGIN
    cb := pendingFileDone; pendingFileDone := NIL;
    IF cb # NIL THEN cb(path, ok) END
  END browserCommitDone;

  PROCEDURE launchFileBrowser(text: ARRAY OF CHAR; len: INTEGER;
                              done: Mini.PromptDone);
  BEGIN
    pendingFileDone := done;
    FileBrowser.Begin(text, browserCommitDone)
  END launchFileBrowser;

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

  (* ---------------- scrolling ---------------- *)

  PROCEDURE ScrollToCursor;
    VAR curLine, lineCol, topLine, topCol, viewportRows, dataRows: INTEGER;
        visible: INTEGER;
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
      IF top < 0 THEN top := 0 END;
      (* Horizontal scroll. For tables we ask the renderer how many
         columns fit starting at leftCol (their widths vary); for
         spreadsheets the column width is uniform. *)
      IF curCol < leftCol THEN leftCol := curCol END;
      IF leftCol < 0 THEN leftCol := 0 END;
      IF v.kind = Viewers.KSpreadsheetView THEN
        visible := SpreadsheetView.VisibleColumns(TUI.Cols);
        IF curCol >= leftCol + visible THEN
          leftCol := curCol - visible + 1
        END
      ELSE
        WHILE (v.doc.schema # NIL) & (curCol >= leftCol)
              & (curCol >= leftCol
                          + TableView.VisibleColumns(v.doc.schema, leftCol, TUI.Cols)) DO
          INC(leftCol)
        END
      END;
      IF leftCol < 0 THEN leftCol := 0 END
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
          Strings.Copy(nm, physPath);
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
      leftCol := v.leftCol;
      dataDoc := v.dataDoc;
      Strings.Copy(name, v.doc.name)
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
      v.cur     := cur;
      v.top     := top;
      v.mark    := mark;
      v.curCol  := curCol;
      v.leftCol := leftCol
    END
  END detachCurrent;

  PROCEDURE switchTo(target: Viewers.Viewer);
  BEGIN
    IF (target # NIL) & (target # Viewers.Current()) THEN
      detachCurrent;
      Viewers.SetCurrent(target);
      attachCurrent;
      (* Yank/kill chains are buffer-local; reset on switch. *)
      KillRing.Reset
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

  (* Switch wrapper used for navigation events (link follow, C-x b,
     C-x C-f). Records the current (viewer, cur, top) onto the back
     stack and clears the forward stack so the user can C-x , back
     to here. Plumbing switches (kill-buffer fall-through, attach
     after Run setup) use plain switchTo and do NOT push. *)
  PROCEDURE navTo(target: Viewers.Viewer);
    VAR cur0: Viewers.Viewer;
  BEGIN
    cur0 := Viewers.Current();
    IF (cur0 # NIL) & (target # cur0) THEN
      History.PushNav(cur0, cur, top)
    END;
    switchTo(target)
  END navTo;

  PROCEDURE goBack;
    VAR v, currV: Viewers.Viewer; savedCur, savedTop: INTEGER;
  BEGIN
    currV := Viewers.Current();
    IF History.Back(currV, cur, top, v, savedCur, savedTop) THEN
      v.cur := savedCur;
      v.top := savedTop;
      switchTo(v);
      SetStatus("Back")
    ELSE
      SetStatus("No prior location")
    END
  END goBack;

  PROCEDURE goForward;
    VAR v, currV: Viewers.Viewer; savedCur, savedTop: INTEGER;
  BEGIN
    currV := Viewers.Current();
    IF History.Forward(currV, cur, top, v, savedCur, savedTop) THEN
      v.cur := savedCur;
      v.top := savedTop;
      switchTo(v);
      SetStatus("Forward")
    ELSE
      SetStatus("No forward location")
    END
  END goForward;

  PROCEDURE switchBufferDone(result: ARRAY OF CHAR; ok: BOOLEAN);
    VAR target: Viewers.Viewer;
        n: ARRAY NameLen OF CHAR;
  BEGIN
    IF ok & (result[0] # 0X) THEN
      Strings.Copy(n, result);
      target := Viewers.Find(n);
      IF target # NIL THEN
        navTo(target);
        SetStatus("Switched")
      ELSE
        SetStatus("No such buffer")
      END
    ELSE
      SetStatus("Switch cancelled")
    END
  END switchBufferDone;

  PROCEDURE PromptSwitchBuffer;
  BEGIN
    Mini.Prompt("Switch to buffer: ", BufList.Completer, switchBufferDone)
  END PromptSwitchBuffer;

  PROCEDURE killBufferConfirmDone(ok: BOOLEAN);
    VAR scratchName: ARRAY NameLen OF CHAR; scratch: Viewers.Viewer;
  BEGIN
    IF ok THEN
      IF pendingKillTarget = Viewers.Current() THEN detachCurrent END;
      Viewers.Kill(pendingKillTarget);
      IF Viewers.Count() = 0 THEN
        Strings.Copy(scratchName, "*scratch*");
        scratch := makeViewer(scratchName);
        Viewers.Add(scratch);
        Viewers.SetCurrent(scratch)
      END;
      attachCurrent;
      KillRing.Reset;
      SetStatus("Buffer killed")
    ELSE
      SetStatus("Kill cancelled")
    END;
    pendingKillTarget := NIL
  END killBufferConfirmDone;

  PROCEDURE killBufferPromptDone(result: ARRAY OF CHAR; ok: BOOLEAN);
    VAR n: ARRAY NameLen OF CHAR;
  BEGIN
    IF ~ok THEN
      SetStatus("Kill cancelled")
    ELSE
      IF result[0] = 0X THEN
        pendingKillTarget := Viewers.Current()
      ELSE
        Strings.Copy(n, result);
        pendingKillTarget := Viewers.Find(n)
      END;
      IF pendingKillTarget = NIL THEN
        SetStatus("No such buffer")
      ELSIF pendingKillTarget.doc.buf.changed THEN
        Mini.Confirm("Buffer modified. Kill anyway? (y/n) ",
                     killBufferConfirmDone)
      ELSE
        killBufferConfirmDone(TRUE)
      END
    END
  END killBufferPromptDone;

  PROCEDURE PromptKillBuffer;
  (* Empty input kills the current buffer. Confirms before discarding
     unsaved changes. After kill, the registry's new current becomes
     active; if the registry is empty, a fresh *scratch* takes over. *)
  BEGIN
    Mini.Prompt("Kill buffer: ", BufList.Completer, killBufferPromptDone)
  END PromptKillBuffer;

  (* Find or create the *viewers* listing viewer; kind is forced to
     KViewerList and dataDoc points at itself so TableView.Render
     can walk the embedded CSV directly. *)
  PROCEDURE ensureViewersList(): Viewers.Viewer;
    VAR v: Viewers.Viewer; nm: ARRAY NameLen OF CHAR;
  BEGIN
    Strings.Copy(nm, "*viewers*");
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
    BufList.Rebuild(v.doc);
    v.cur := 0; v.top := 0; v.curCol := 0;
    switchTo(v);
    SetStatus("Viewer list — Enter to switch, k to kill")
  END ListBuffers;

  PROCEDURE openDone(result: ARRAY OF CHAR; ok: BOOLEAN);
    VAR target: Viewers.Viewer; res: INTEGER;
        fname: ARRAY NameLen OF CHAR;
  BEGIN
    IF ok & (result[0] # 0X) THEN
      Strings.Copy(fname, result);
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
      navTo(target)
    ELSE
      SetStatus("Open cancelled")
    END
  END openDone;

  PROCEDURE PromptOpen;
  (* Open creates a new Viewer (and Doc) for the file, or switches to
     an existing Viewer already visiting that filename. Current
     buffer's unsaved changes are preserved — they stay in their
     existing Viewer/Doc, just no longer the active one. *)
  BEGIN
    Mini.Prompt("Open: ", NIL, openDone);
    Mini.SetTabHandler(launchFileBrowser)
  END PromptOpen;

  PROCEDURE openTextDone(result: ARRAY OF CHAR; ok: BOOLEAN);
    VAR target, existing: Viewers.Viewer;
        textLabel: ARRAY 96 OF CHAR;
        fname: ARRAY NameLen OF CHAR;
        res: INTEGER;
  BEGIN
    IF ok & (result[0] # 0X) THEN
      Strings.Copy(fname, result);
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
        navTo(target)
      ELSIF existing.kind = Viewers.KText THEN
        navTo(existing);
        SetStatus("Switched to existing buffer")
      ELSE
        Project.Logical(existing.doc.name, textLabel);
        Strings.Append(textLabel, "<text>");
        target := Viewers.Find(textLabel);
        IF target = NIL THEN
          target := Viewers.New(textLabel, existing.doc, Viewers.KText);
          Viewers.Add(target)
        END;
        navTo(target);
        SetStatus("Opened as text")
      END
    ELSE
      SetStatus("Open cancelled")
    END
  END openTextDone;

  PROCEDURE PromptOpenRawText;
  (* C-x C-r: open as raw text regardless of extension. If a Doc for
     the path is already loaded by another (structured) Viewer, share
     the Doc and create a sibling kText Viewer with a "<text>" suffix
     in its label so the buffer list distinguishes the two. If the
     existing Viewer is already kText we just switch to it. *)
  BEGIN
    Mini.Prompt("Find file as text: ", NIL, openTextDone);
    Mini.SetTabHandler(launchFileBrowser)
  END PromptOpenRawText;

  (* ---------------- save chain ---------------- *)

  PROCEDURE saveDirConfirmDone(ok: BOOLEAN);
    VAR res: INTEGER;
  BEGIN
    IF ok THEN
      Files.MakeDir(pendingSaveDir, res);
      IF res = 0 THEN
        FileOps.WriteFile(buf, name, status)
      ELSE
        SetStatus("Could not create directory")
      END
    ELSE
      SetStatus("Save cancelled — directory missing")
    END
  END saveDirConfirmDone;

  (* Save the current buffer using `name`. If the target directory
     doesn't exist, offers to create it via Mini.Confirm; otherwise
     writes immediately. *)
  PROCEDURE saveWithName;
    VAR msg: ARRAY 192 OF CHAR;
  BEGIN
    Strings.DirOf(name, pendingSaveDir);
    IF (pendingSaveDir[0] # 0X) & (Files.Exists(pendingSaveDir) = 0) THEN
      Strings.Copy(msg, "Directory '");
      Strings.Append(msg, pendingSaveDir);
      Strings.Append(msg, "' does not exist. Create? (y/n) ");
      Mini.Confirm(msg, saveDirConfirmDone)
    ELSE
      FileOps.WriteFile(buf, name, status)
    END
  END saveWithName;

  PROCEDURE saveAsDone(result: ARRAY OF CHAR; ok: BOOLEAN);
    VAR v: Viewers.Viewer;
  BEGIN
    IF ok & (result[0] # 0X) THEN
      Strings.Copy(name, result);
      v := Viewers.Current();
      IF v # NIL THEN
        Strings.Copy(v.doc.name, name);
        Project.Logical(name, v.label);
        v.kind := Viewers.KindOf(name);
        refreshSchema(v)
      END;
      saveWithName
    ELSE
      SetStatus("Save cancelled")
    END
  END saveAsDone;

  PROCEDURE promptSaveAs;
  BEGIN
    Mini.Prompt("Save as: ", NIL, saveAsDone);
    Mini.SetTabHandler(launchFileBrowser)
  END promptSaveAs;

  PROCEDURE saveCurrent;
  BEGIN
    (* Buffers without a file (empty name) and synthetic "*foo*"
       buffers both need a real filename prompt. *)
    IF (name[0] = 0X) OR (name[0] = "*") THEN promptSaveAs
    ELSE saveWithName
    END
  END saveCurrent;

  (* ---------------- rendering ---------------- *)

  PROCEDURE DrawStatusBar;
    VAR line, col, dummy, i: INTEGER;
        displayName: ARRAY NameLen OF CHAR;
        v: Viewers.Viewer;
  BEGIN
    TUI.MoveTo(0, TUI.Rows - 2);
    (* Status bar: solid blue background with white text — a
       distinct band that the eye finds immediately and doesn't
       conflict with the buffer's normal reverse-video selection. *)
    TUI.SetAttr(TUI.AttrNormal);
    TUI.SetBg(TUI.ColorBlue);
    TUI.SetFg(TUI.ColorWhite);
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
    TUI.SetAttr(TUI.AttrNormal);
    TUI.SetFg(TUI.ColorDefault);
    TUI.SetBg(TUI.ColorDefault)
  END DrawStatusBar;

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
      IF v.kind = Viewers.KViewerList THEN BufList.Rebuild(v.doc) END
    END;
    IF (v # NIL)
        & ((v.kind = Viewers.KTableView) OR (v.kind = Viewers.KViewerList)) THEN
      TableView.Render(v.doc, v.dataDoc, top, leftCol, cur, curCol,
                       TUI.Rows - 2);
      cursRow := cur - top + 1;                  (* +1 for header row *)
      cursCol := TableView.ColumnX(v.doc.schema, curCol)
                  - TableView.ColumnX(v.doc.schema, leftCol)
    ELSIF (v # NIL) & (v.kind = Viewers.KFormView) THEN
      FormView.Render(v.doc, v.dataDoc, top, cur, TUI.Rows - 2,
                      cursRow, cursCol)
    ELSIF (v # NIL) & (v.kind = Viewers.KSpreadsheetView) THEN
      ssCells.n := 0;
      SpreadsheetView.Parse(v.doc.buf, v.doc.schema, ssRefPath, ssCells);
      SpreadsheetView.Render(v.doc, v.dataDoc, ssCells,
                             top, leftCol, cur, curCol, TUI.Rows - 2,
                             cursRow, cursCol)
    ELSE
      Render.DrawBuffer(buf, top, cur, cursRow, cursCol)
    END;
    DrawStatusBar
  END RefreshFrame;

  PROCEDURE Refresh;
    VAR cursRow, cursCol: INTEGER;
        pathBuf: ARRAY 256 OF CHAR;
  BEGIN
    IF FileBrowser.Active() THEN
      (* Browser is a modal overlay: it replaces the buffer area,
         keeps the status bar, and writes the current selection's
         path into the message line. *)
      TUI.Resize;
      TUI.HideCursor;
      FileBrowser.Paint;
      DrawStatusBar;
      FileBrowser.CurrentPath(pathBuf);
      Render.DrawMessageLine(pathBuf);
      TUI.Flush
    ELSE
      RefreshFrame(cursRow, cursCol);
      IF Mini.Active() THEN
        Mini.Paint
      ELSIF Search.Active() THEN
        Search.PaintStatus;
        IF cursCol >= TUI.Cols THEN cursCol := TUI.Cols - 1 END;
        TUI.MoveTo(cursCol, cursRow)
      ELSE
        Render.DrawMessageLine(status);
        IF cursCol >= TUI.Cols THEN cursCol := TUI.Cols - 1 END;
        TUI.MoveTo(cursCol, cursRow)
      END;
      TUI.ShowCursor;
      TUI.Flush
    END
  END Refresh;

  (* ---------------- input ---------------- *)

  (* On commit, re-resolve coll / row / dataCol from the current
     viewer and splice. cur and curCol are frozen while the prompt
     is up so the row/col we resolved before the prompt is still
     the right one. *)
  PROCEDURE editCellDone(result: ARRAY OF CHAR; ok: BOOLEAN);
    VAR v: Viewers.Viewer;
        coll: Collection.Collection;
        rowStart, dataCol: INTEGER;
        colName: ARRAY Schema.MaxName OF CHAR;
  BEGIN
    IF ~ok THEN
      SetStatus("Edit cancelled")
    ELSE
      v := Viewers.Current();
      IF (v # NIL) & (v.kind = Viewers.KTableView)
          & (v.dataDoc # NIL) & (v.doc.schema # NIL)
          & (curCol >= 0) & (curCol < v.doc.schema.ncol) THEN
        Strings.Copy(colName, v.doc.schema.cols[curCol].name);
        dataCol := Schema.Find(v.dataDoc.schema, colName);
        IF dataCol >= 0 THEN
          coll := Collection.Open(v.dataDoc);
          rowStart := Collection.FindRow(coll, cur);
          IF rowStart >= 0 THEN
            Collection.SetCell(coll, rowStart, dataCol, result);
            SetStatus("Cell updated")
          ELSE
            SetStatus("Row out of range")
          END
        ELSE
          SetStatus("Projection column not in data schema")
        END
      ELSE
        SetStatus("Cannot edit here")
      END
    END
  END editCellDone;

  (* Prompt for a new value for the current (cur, curCol) cell, pre-
     filled with the existing value, and on commit splice it into
     the backing collection. The data Doc's b.changed flips so a
     subsequent C-x s (or C-x C-s on the .col itself) persists. *)
  PROCEDURE EditCurrentCell;
    VAR v: Viewers.Viewer;
        coll: Collection.Collection;
        rowStart, dataCol: INTEGER;
        colName: ARRAY Schema.MaxName OF CHAR;
        cur0: ARRAY 256 OF CHAR;
        promptText: ARRAY 64 OF CHAR;
  BEGIN
    v := Viewers.Current();
    IF (v = NIL) OR (v.kind # Viewers.KTableView)
        OR (v.dataDoc = NIL) OR (v.doc.schema = NIL) THEN
      SetStatus("Cannot edit here")
    ELSIF (curCol < 0) OR (curCol >= v.doc.schema.ncol) THEN
      SetStatus("No column selected")
    ELSE
      Strings.Copy(colName, v.doc.schema.cols[curCol].name);
      dataCol := Schema.Find(v.dataDoc.schema, colName);
      IF dataCol < 0 THEN
        SetStatus("Projection column not in data schema")
      ELSE
        coll := Collection.Open(v.dataDoc);
        rowStart := Collection.FindRow(coll, cur);
        IF rowStart < 0 THEN
          SetStatus("Row out of range")
        ELSE
          Collection.GetCell(coll, rowStart, dataCol, cur0);
          Strings.Copy(promptText, "Edit ");
          Strings.Append(promptText, v.doc.schema.cols[curCol].label);
          Strings.Append(promptText, ": ");
          Mini.PromptEdit(promptText, cur0, NIL, editCellDone)
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

  PROCEDURE killRowConfirmDone(ok: BOOLEAN);
    VAR scratchName: ARRAY NameLen OF CHAR; scratch: Viewers.Viewer;
  BEGIN
    IF ok THEN
      IF pendingRowKillTarget = Viewers.Current() THEN detachCurrent END;
      Viewers.Kill(pendingRowKillTarget);
      IF Viewers.Count() = 0 THEN
        Strings.Copy(scratchName, "*scratch*");
        scratch := makeViewer(scratchName);
        Viewers.Add(scratch);
        Viewers.SetCurrent(scratch)
      END;
      attachCurrent;
      IF cur > 0 THEN DEC(cur) END;
      KillRing.Reset;
      SetStatus("Buffer killed")
    ELSE
      SetStatus("Kill cancelled")
    END;
    pendingRowKillTarget := NIL
  END killRowConfirmDone;

  PROCEDURE KillRowViewer;
    VAR target: Viewers.Viewer;
  BEGIN
    target := Viewers.At(cur);
    IF target = NIL THEN
      SetStatus("No such row")
    ELSIF target.doc.buf.changed THEN
      pendingRowKillTarget := target;
      Mini.Confirm("Buffer modified. Kill anyway? (y/n) ",
                   killRowConfirmDone)
    ELSE
      pendingRowKillTarget := target;
      killRowConfirmDone(TRUE)
    END
  END KillRowViewer;

  (* First open kFormView whose dataDoc matches d, or NIL. Used by
     the table-row → form Enter binding to find the card to show. *)
  PROCEDURE findFormFor(d: Doc.Doc): Viewers.Viewer;
    VAR i: INTEGER; v, found: Viewers.Viewer;
  BEGIN
    found := NIL; i := 0;
    WHILE (i < Viewers.Count()) & (found = NIL) DO
      v := Viewers.At(i);
      IF (v.kind = Viewers.KFormView) & (v.dataDoc = d) THEN
        found := v
      END;
      INC(i)
    END;
    RETURN found
  END findFormFor;

  (* Jump from the current table / collection row to the matching
     form's record. Pushes navigation history so C-x , returns to
     the table at the same row. The form's `top` is its current
     record index, so we set it to cur (which is the row index in
     kTableView / kCollection). *)
  PROCEDURE jumpToForm;
    VAR v, form: Viewers.Viewer; collDoc: Doc.Doc;
  BEGIN
    v := Viewers.Current();
    collDoc := NIL;
    IF v # NIL THEN
      IF v.kind = Viewers.KTableView THEN collDoc := v.dataDoc
      ELSIF v.kind = Viewers.KCollection THEN collDoc := v.doc
      END
    END;
    IF collDoc = NIL THEN
      SetStatus("No collection here to jump from")
    ELSE
      form := findFormFor(collDoc);
      IF form = NIL THEN
        SetStatus("No form view open for this collection — open one with C-x C-f")
      ELSE
        form.top := cur;
        navTo(form)
      END
    END
  END jumpToForm;

  (* Navigation for a kTableView. cur is the row index, top is the
     top visible row, curCol the column. Read-only motion;
     Enter jumps to the matching kFormView record (history-pushed
     so C-x , returns), C-x e edits the cell at point. For
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
      SetStatus("Ctrl-X: Ctrl-S save, Ctrl-W save-as, e edit, Ctrl-C quit")
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
        jumpToForm
      END
    ELSIF (k = ORD("k")) & (v.kind = Viewers.KViewerList) THEN
      KillRowViewer
    ELSE
      IF v.kind = Viewers.KViewerList THEN
        SetStatus("Enter switches to viewer, k kills it")
      ELSE
        SetStatus("Enter form, C-x e edit, C-x , back")
      END
    END
  END TableEntryKey;

  PROCEDURE editFieldDone(result: ARRAY OF CHAR; ok: BOOLEAN);
    VAR v: Viewers.Viewer;
        fl: FormView.Layout;
        coll: Collection.Collection;
        rowStart, dataCol: INTEGER;
        fname: ARRAY FormView.MaxFieldName OF CHAR;
  BEGIN
    IF ~ok THEN
      SetStatus("Edit cancelled")
    ELSE
      v := Viewers.Current();
      IF (v # NIL) & (v.kind = Viewers.KFormView)
          & (v.dataDoc # NIL) & (v.dataDoc.schema # NIL) THEN
        FormView.CollectFields(v.doc, fl);
        IF (cur >= 0) & (cur < fl.n) THEN
          Strings.Copy(fname, fl.fields[cur].name);
          dataCol := Schema.Find(v.dataDoc.schema, fname);
          IF dataCol >= 0 THEN
            coll := Collection.Open(v.dataDoc);
            rowStart := Collection.FindRow(coll, top);
            IF rowStart >= 0 THEN
              Collection.SetCell(coll, rowStart, dataCol, result);
              SetStatus("Field updated")
            ELSE
              SetStatus("Record out of range")
            END
          ELSE
            SetStatus("Field not in data schema")
          END
        ELSE
          SetStatus("No field selected")
        END
      ELSE
        SetStatus("Cannot edit here")
      END
    END
  END editFieldDone;

  (* Prompt for a new value for the current form field at the
     current record, pre-filled with its existing value. *)
  PROCEDURE EditCurrentField;
    VAR v: Viewers.Viewer;
        fl: FormView.Layout;
        coll: Collection.Collection;
        rowStart, dataCol: INTEGER;
        cur0: ARRAY 256 OF CHAR;
        promptText: ARRAY 64 OF CHAR;
        fname: ARRAY FormView.MaxFieldName OF CHAR;
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
        Strings.Copy(fname, fl.fields[cur].name);
        dataCol := Schema.Find(v.dataDoc.schema, fname);
        IF dataCol < 0 THEN
          SetStatus("Field not in data schema")
        ELSE
          coll := Collection.Open(v.dataDoc);
          rowStart := Collection.FindRow(coll, top);
          IF rowStart < 0 THEN
            SetStatus("Record out of range")
          ELSE
            Collection.GetCell(coll, rowStart, dataCol, cur0);
            Strings.Copy(promptText, "Edit ");
            Strings.Append(promptText, fname);
            Strings.Append(promptText, ": ");
            Mini.PromptEdit(promptText, cur0, NIL, editFieldDone)
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
          Strings.Copy(txt, cells.cells[i].formula);
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
  PROCEDURE editSpreadsheetDone(result: ARRAY OF CHAR; ok: BOOLEAN);
    VAR v: Viewers.Viewer;
        coll: Collection.Collection;
        rowStart, dataCols: INTEGER;
  BEGIN
    IF ~ok THEN
      SetStatus("Edit cancelled")
    ELSE
      v := Viewers.Current();
      IF (v # NIL) & (v.kind = Viewers.KSpreadsheetView)
          & (v.dataDoc # NIL) & (v.dataDoc.schema # NIL) THEN
        dataCols := v.dataDoc.schema.ncol;
        IF result[0] = "=" THEN
          SpreadsheetView.SetFormula(v.doc, curCol, cur, result);
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
            Collection.SetCell(coll, rowStart, curCol, result);
            SetStatus("Value stored")
          END
        END
      ELSE
        SetStatus("Cannot edit here")
      END
    END
  END editSpreadsheetDone;

  PROCEDURE EditSpreadsheetCell;
    VAR v: Viewers.Viewer;
        cur0: ARRAY 256 OF CHAR;
        promptText: ARRAY 64 OF CHAR;
        coord: ARRAY 8 OF CHAR;
        rowStr: ARRAY 8 OF CHAR;
  BEGIN
    v := Viewers.Current();
    IF (v = NIL) OR (v.kind # Viewers.KSpreadsheetView)
        OR (v.dataDoc = NIL) OR (v.dataDoc.schema = NIL) THEN
      SetStatus("Cannot edit here")
    ELSE
      currentSpreadsheetText(cur0);
      coord[0] := CHR(ORD("A") + curCol); coord[1] := 0X;
      Strings.IntStr(cur + 1, rowStr);
      Strings.Copy(promptText, "Edit ");
      Strings.Append(promptText, coord);
      Strings.Append(promptText, rowStr);
      Strings.Append(promptText, ": ");
      Mini.PromptEdit(promptText, cur0, NIL, editSpreadsheetDone)
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
        Strings.Copy(bold, "bold");
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
    | TUI.KeyArrowLeft:  Motion.Left(cur);            SetStatus("")
    | TUI.KeyArrowRight: Motion.Right(buf, cur);      SetStatus("")
    | TUI.KeyArrowUp:    Motion.Up(lines, cur);       SetStatus("")
    | TUI.KeyArrowDown:  Motion.Down(lines, cur);     SetStatus("")
    | TUI.KeyHome:       Motion.Home(lines, cur);     SetStatus("")
    | TUI.KeyEnd:        Motion.End(lines, cur);      SetStatus("")
    | TUI.KeyPageUp:     Motion.PageUp(lines, cur, TUI.Rows - 2);   SetStatus("")
    | TUI.KeyPageDown:   Motion.PageDown(lines, cur, TUI.Rows - 2); SetStatus("")
    | TUI.KeyEnter:
        IF ~Links.Follow(buf, cur, status, makeViewer, navTo) THEN
          InsertCh(Newline); SetStatus("")
        END
    | TUI.KeyBackspace, TUI.KeyCtrlH:
                         BackspaceCh; SetStatus("")
    | TUI.KeyDelete:     DeleteCh; SetStatus("")
    | TUI.KeyCtrlS:      Search.Begin(buf, cur, TRUE)
    | TUI.KeyCtrlR:      Search.Begin(buf, cur, FALSE)
    | TUI.KeyCtrlA:      Motion.Home(lines, cur);     SetStatus("")
    | TUI.KeyCtrlB:      Motion.Left(cur);            SetStatus("")
    | TUI.KeyCtrlD:      DeleteCh;  SetStatus("")
    | TUI.KeyCtrlE:      Motion.End(lines, cur);      SetStatus("")
    | TUI.KeyCtrlF:      Motion.Right(buf, cur);      SetStatus("")
    | TUI.KeyCtrlN:      Motion.Down(lines, cur);     SetStatus("")
    | TUI.KeyCtrlP:      Motion.Up(lines, cur);       SetStatus("")
    | TUI.KeyMetaLT:     Motion.BufStart(cur);        SetStatus("")
    | TUI.KeyMetaGT:     Motion.BufEnd(buf, cur);     SetStatus("")
    | TUI.KeyMetaF:      Motion.WordForward(buf, cur);  SetStatus("")
    | TUI.KeyMetaB:      Motion.WordBackward(buf, cur); SetStatus("")
    | TUI.KeyMetaA:      Motion.SentBackward(buf, cur); SetStatus("")
    | TUI.KeyMetaE:      Motion.SentForward(buf, cur);  SetStatus("")
    | TUI.KeyCtrlSpace:  KillRing.SetMark(cur, mark, status)
    | TUI.KeyCtrlW:      KillRing.KillRegion(buf, lines, cur, mark, status)
    | TUI.KeyCtrlY:      KillRing.Yank(buf, lines, cur, status)
    | TUI.KeyMetaW:      KillRing.CopyRegion(buf, cur, mark, status)
    | TUI.KeyMetaY:      KillRing.YankPop(buf, lines, cur, status)
    | TUI.KeyCtrlK:      KillRing.KillLine(buf, lines, cur, status)
    ELSE
      IF (k >= 32) & (k < 127) THEN
        ch := CHR(k);
        InsertCh(ch);
        SetStatus("")
      ELSE
        SetStatus("(unhandled key)")
      END
    END;
    IF ~isYankCmd THEN KillRing.ClearLastWasYank END;
    IF ~isKillCmd THEN KillRing.ClearLastWasKill END
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

  PROCEDURE quitConfirmDone(ok: BOOLEAN);
  BEGIN
    IF ok THEN running := FALSE
    ELSE SetStatus("Quit cancelled")
    END
  END quitConfirmDone;

  (* Edit the URL of the link at cur in place. Does NOT follow.
     Pending uS / uE remember the bracket positions so the done
     callback can splice the new URL without re-parsing. *)
  PROCEDURE editLinkDone(result: ARRAY OF CHAR; ok: BOOLEAN);
    VAR i, n: INTEGER;
  BEGIN
    IF ok THEN
      Buffer.Delete(buf, pendingLinkUS, pendingLinkUE);
      Lines.Deleted(lines, pendingLinkUS, pendingLinkUE);
      n := 0;
      WHILE (n < LEN(result)) & (result[n] # 0X) DO INC(n) END;
      i := 0;
      WHILE i < n DO
        Buffer.Insert(buf, pendingLinkUS + i, result[i]); INC(i)
      END;
      IF n > 0 THEN Lines.Inserted(lines, pendingLinkUS, n) END;
      IF cur > pendingLinkUS + n THEN cur := pendingLinkUS + n END;
      SetStatus("URL updated")
    ELSE
      SetStatus("URL edit cancelled")
    END
  END editLinkDone;

  PROCEDURE editLinkAtPoint;
    VAR op, tE, uS, uE, urlLen, i: INTEGER;
        url: ARRAY 256 OF CHAR;
  BEGIN
    IF Render.AtLink(buf, cur, op, tE, uS, uE) THEN
      pendingLinkUS := uS; pendingLinkUE := uE;
      urlLen := uE - uS;
      IF urlLen > LEN(url) - 1 THEN urlLen := LEN(url) - 1 END;
      i := 0;
      WHILE i < urlLen DO
        url[i] := Render.CharAt(buf, uS + i); INC(i)
      END;
      url[urlLen] := 0X;
      Mini.PromptEdit("Edit URL: ", url, NIL, editLinkDone)
    ELSE
      SetStatus("Not on a link")
    END
  END editLinkAtPoint;

  (* C-x e: edit the cell / field / spreadsheet cell at point. Used
     to be Enter in tables, but Enter is now table → form jump (in
     line with link Enter = follow). *)
  PROCEDURE oedUndo;
    VAR pos: INTEGER;
  BEGIN
    IF Buffer.Undo(buf, pos) THEN
      Lines.Invalidate(lines);
      cur := pos;
      IF cur > buf.len THEN cur := buf.len END;
      SetStatus("Undo")
    ELSE
      SetStatus("Nothing to undo")
    END
  END oedUndo;

  PROCEDURE oedRedo;
    VAR pos: INTEGER;
  BEGIN
    IF Buffer.Redo(buf, pos) THEN
      Lines.Invalidate(lines);
      cur := pos;
      IF cur > buf.len THEN cur := buf.len END;
      SetStatus("Redo")
    ELSE
      SetStatus("Nothing to redo")
    END
  END oedRedo;

  PROCEDURE editAtPoint;
    VAR v: Viewers.Viewer;
  BEGIN
    v := Viewers.Current();
    IF v = NIL THEN
      SetStatus("Nothing to edit")
    ELSIF v.kind = Viewers.KTableView THEN
      EditCurrentCell
    ELSIF v.kind = Viewers.KFormView THEN
      EditCurrentField
    ELSIF v.kind = Viewers.KSpreadsheetView THEN
      EditSpreadsheetCell
    ELSE
      SetStatus("No editable cell here")
    END
  END editAtPoint;

  PROCEDURE CommandKey(k: INTEGER);
  BEGIN
    IF k = TUI.KeyCtrlC THEN
      IF anyBufferDirty() THEN
        Mini.Confirm("Discard unsaved changes? (y/n) ", quitConfirmDone)
      ELSE
        running := FALSE
      END
    ELSIF k = TUI.KeyCtrlS THEN
      saveCurrent
    ELSIF k = TUI.KeyCtrlW THEN
      promptSaveAs
    ELSIF k = TUI.KeyCtrlF THEN
      PromptOpen
    ELSIF k = TUI.KeyCtrlR THEN
      PromptOpenRawText
    ELSIF k = ORD("b") THEN
      PromptSwitchBuffer
    ELSIF k = ORD("k") THEN
      PromptKillBuffer
    ELSIF k = ORD("s") THEN
      FileOps.SaveAll(status, detachCurrent)
    ELSIF k = TUI.KeyCtrlB THEN
      ListBuffers
    ELSIF k = ORD("e") THEN
      editAtPoint
    ELSIF k = ORD("l") THEN
      editLinkAtPoint
    ELSIF k = ORD("u") THEN
      oedUndo
    ELSIF k = ORD("U") THEN
      oedRedo
    ELSIF k = ORD(",") THEN
      goBack
    ELSIF k = ORD(".") THEN
      goForward
    ELSE
      SetStatus("Command cancelled")
    END;
    mode := ModeEntry
  END CommandKey;

  (* Per-keystroke handler used by both targets. On posix TUI.Run
     loops, calling this for each ReadKey result; on wasm the JS
     host invokes oc_dispatch_key per keydown event and that
     dispatches here.

     Routes keys in priority order:
       1. Mini active   → minibuffer prompt input
       2. Search active → incremental-search step; mirror cur back
       3. otherwise     → editor entry / command dispatch
     Then repaints or, if the user quit, tears down and signals
     TUI.Run to return. *)
  PROCEDURE handleKey(k: INTEGER);
  BEGIN
    IF FileBrowser.Active() THEN
      FileBrowser.HandleKey(k)
    ELSIF Mini.Active() THEN
      Mini.HandleKey(k)
    ELSIF Search.Active() THEN
      Search.HandleKey(k);
      cur := Search.Cur();
      IF ~Search.Active() THEN Search.Status(status) END
    ELSE
      IF mode = ModeEntry THEN EntryKey(k)
      ELSE CommandKey(k)
      END
    END;
    IF running THEN
      Refresh
    ELSE
      detachCurrent;
      TUI.Clear;
      TUI.Flush;
      TUI.Shutdown;
      TUI.Quit
    END
  END handleKey;

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
    Strings.Copy(scratchName, "*scratch*");
    scratch := makeViewer(scratchName);
    Viewers.Add(scratch);
    Viewers.SetCurrent(scratch);
    attachCurrent;

    KillRing.Init;
    mode        := ModeEntry;
    running     := TRUE;
    SetStatus("HELP: Ctrl-X then Ctrl-S save, Ctrl-W save-as, Ctrl-F open, b switch buffer, Ctrl-C quit");
    LoadInitialFile;
    Refresh;                       (* paint the initial frame *)
    TUI.SetKeyHandler(handleKey);
    TUI.Run                        (* posix: blocks dispatching ReadKey →
                                      handleKey; wasm: returns immediately
                                      and JS dispatches per keydown *)
  END Run;

BEGIN
  Run
END Oed.
