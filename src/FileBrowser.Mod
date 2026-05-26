MODULE FileBrowser;
(* Miller-columns file browser, modal over the editor frame.

   Begin opens an initial directory column at the supplied path.
   Each key event flows through HandleKey: Up / Down move the
   selection in the active column, Tab / Enter / Right either
   descends into the selected directory (appending a column) or
   commits the selected file (closing the browser and invoking
   the supplied Done callback with the absolute path). Left moves
   back to the previous column without discarding the trail so a
   subsequent Right returns to where the user was. Esc cancels.

   Columns are painted left-to-right starting at screen column 0;
   when the active column would otherwise fall off the right edge
   the visible window pans rightward (leftPan increases). The
   message-line caller can ask for the current selection's full
   path via CurrentPath. *)

  IMPORT TUI, Controls, Files, Strings;

  CONST
    MaxCols*       = 8;
    MaxColEntries  = 256;
    ColWidth       = 24;
    PathLen        = 512;
    NameLen        = 256;

  TYPE
    Done* = PROCEDURE(path: ARRAY OF CHAR; ok: BOOLEAN);

    Column = RECORD
      path:  ARRAY PathLen OF CHAR;   (* dir whose contents are listed *)
      n:     INTEGER;
      names: ARRAY MaxColEntries OF ARRAY NameLen OF CHAR;
      isDir: ARRAY MaxColEntries OF BOOLEAN;
      list:  Controls.ListView
    END;

  VAR
    active:      BOOLEAN;
    nCols:       INTEGER;
    activeCol:   INTEGER;
    leftPan:     INTEGER;
    cols:        ARRAY MaxCols OF Column;
    doneCb:      Done;
    paintingCol: INTEGER;        (* set before each ListPaint call *)

  PROCEDURE Active*(): BOOLEAN; RETURN active END Active;

  (* CellSource the ListView calls back into. Since procedure types
     don't carry closures, the "which column" context is passed via
     the module-level `paintingCol`, set before each ListPaint. *)
  PROCEDURE cellSource(index: INTEGER; VAR c: Controls.Cell): BOOLEAN;
    VAR ok: BOOLEAN;
  BEGIN
    ok := (paintingCol >= 0) & (paintingCol < nCols)
        & (index >= 0) & (index < cols[paintingCol].n);
    IF ok THEN
      Strings.Copy(c.text, cols[paintingCol].names[index]);
      c.highlighted := cols[paintingCol].isDir[index]
    END;
    RETURN ok
  END cellSource;

  PROCEDURE strLen(s: ARRAY OF CHAR): INTEGER;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
    RETURN i
  END strLen;

  PROCEDURE joinPath(dir, name: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
    VAR i, j: INTEGER; needSep: BOOLEAN;
  BEGIN
    i := 0;
    WHILE (i < LEN(out) - 1) & (dir[i] # 0X) DO
      out[i] := dir[i]; INC(i)
    END;
    needSep := (i > 0) & (out[i-1] # "/");
    IF needSep & (i < LEN(out) - 1) THEN
      out[i] := "/"; INC(i)
    END;
    j := 0;
    WHILE (i < LEN(out) - 1) & (name[j] # 0X) DO
      out[i] := name[j]; INC(i); INC(j)
    END;
    out[i] := 0X
  END joinPath;

  (* Insertion-sort the column's parallel name / isDir arrays so dirs
     come first then files, alphabetical within each group. Most
     directories are small enough that an insertion sort is fine. *)
  PROCEDURE sortColumn(VAR c: Column);
    VAR i, j: INTEGER;
        keyName: ARRAY NameLen OF CHAR; keyDir: BOOLEAN;
        better: BOOLEAN;
  BEGIN
    i := 1;
    WHILE i < c.n DO
      Strings.Copy(keyName, c.names[i]);
      keyDir := c.isDir[i];
      j := i;
      better := TRUE;
      WHILE better & (j > 0) DO
        (* "key is better than c.names[j-1]" → swap left *)
        IF keyDir & ~c.isDir[j-1] THEN
          better := TRUE
        ELSIF ~keyDir & c.isDir[j-1] THEN
          better := FALSE
        ELSIF keyName < c.names[j-1] THEN
          better := TRUE
        ELSE
          better := FALSE
        END;
        IF better THEN
          Strings.Copy(c.names[j], c.names[j-1]);
          c.isDir[j] := c.isDir[j-1];
          DEC(j)
        END
      END;
      Strings.Copy(c.names[j], keyName);
      c.isDir[j] := keyDir;
      INC(i)
    END
  END sortColumn;

  (* Populate col with the entries of `path`. Returns FALSE if the
     directory can't be opened. *)
  PROCEDURE loadDir(VAR col: Column; path: ARRAY OF CHAR): BOOLEAN;
    VAR cookie, isDirInt: INTEGER;
        name: ARRAY NameLen OF CHAR;
        ok: BOOLEAN;
  BEGIN
    Strings.Copy(col.path, path);
    col.n := 0;
    IF path[0] = 0X THEN cookie := Files.OpenDir(".")
    ELSE cookie := Files.OpenDir(path)
    END;
    ok := cookie >= 0;
    IF ok THEN
      WHILE (col.n < MaxColEntries)
            & (Files.NextEntry(cookie, name, isDirInt) = 1) DO
        Strings.Copy(col.names[col.n], name);
        col.isDir[col.n] := isDirInt = 1;
        INC(col.n)
      END;
      Files.CloseDir(cookie);
      sortColumn(col)
    END;
    RETURN ok
  END loadDir;

  (* Configure the ListView for column i: position, size, source,
     cell count. Called whenever Paint runs (so window resizes
     reflow correctly). *)
  PROCEDURE layoutColumn(i: INTEGER);
    VAR v: Controls.View;
  BEGIN
    v.x := (i - leftPan) * ColWidth;
    v.y := 0;
    v.w := ColWidth;
    v.h := TUI.Rows - 2;
    IF v.h < 1 THEN v.h := 1 END;
    cols[i].list.view := v;
    cols[i].list.src := cellSource;
    cols[i].list.nCells := cols[i].n
  END layoutColumn;

  (* After activeCol changes, slide leftPan so the active column is
     visible. Right-pan first, then guard against negative leftPan. *)
  PROCEDURE adjustPan;
    VAR vis: INTEGER;
  BEGIN
    vis := TUI.Cols DIV ColWidth;
    IF vis < 1 THEN vis := 1 END;
    IF activeCol < leftPan THEN leftPan := activeCol END;
    IF activeCol >= leftPan + vis THEN leftPan := activeCol - vis + 1 END;
    IF leftPan < 0 THEN leftPan := 0 END
  END adjustPan;

  (* Split path at the last "/" into dir / basename. dir keeps the
     trailing slash; if path has no slash, dir is "" and base is the
     whole path. *)
  PROCEDURE splitPath(path: ARRAY OF CHAR;
                      VAR dir, base: ARRAY OF CHAR);
    VAR i, last, n: INTEGER;
  BEGIN
    n := strLen(path);
    last := -1; i := 0;
    WHILE i < n DO
      IF path[i] = "/" THEN last := i END;
      INC(i)
    END;
    IF last < 0 THEN
      dir[0] := 0X;
      i := 0;
      WHILE i < n DO base[i] := path[i]; INC(i) END;
      base[i] := 0X
    ELSE
      i := 0;
      WHILE i <= last DO dir[i] := path[i]; INC(i) END;
      dir[i] := 0X;
      i := last + 1;
      WHILE i < n DO base[i - last - 1] := path[i]; INC(i) END;
      base[n - last - 1] := 0X
    END
  END splitPath;

  (* If the column contains an entry with the given name, select it
     so the user lands on a familiar row instead of row 0. *)
  PROCEDURE preselect(VAR col: Column; name: ARRAY OF CHAR);
    VAR i: INTEGER; found: BOOLEAN;
  BEGIN
    IF name[0] # 0X THEN
      found := FALSE; i := 0;
      WHILE ~found & (i < col.n) DO
        IF col.names[i] = name THEN
          col.list.selected := i; found := TRUE
        END;
        INC(i)
      END
    END
  END preselect;

  (* Miller-columns preview: after any selection change in the
     active column, drop everything to its right, and if the new
     selection is a directory, load its contents into the next
     column. The user's activeCol stays put — Tab still has to
     happen to actually move there. *)
  PROCEDURE refreshPreview;
    VAR sel: INTEGER; newPath: ARRAY PathLen OF CHAR;
  BEGIN
    sel := cols[activeCol].list.selected;
    nCols := activeCol + 1;
    IF (sel >= 0) & (sel < cols[activeCol].n)
        & cols[activeCol].isDir[sel] & (activeCol + 1 < MaxCols) THEN
      joinPath(cols[activeCol].path, cols[activeCol].names[sel], newPath);
      IF loadDir(cols[activeCol + 1], newPath) THEN
        Controls.ListReset(cols[activeCol + 1].list);
        INC(nCols);
        layoutColumn(activeCol + 1)
      END
    END
  END refreshPreview;

  PROCEDURE descend(name: ARRAY OF CHAR);
    VAR newPath: ARRAY PathLen OF CHAR;
  BEGIN
    IF nCols < MaxCols THEN
      joinPath(cols[activeCol].path, name, newPath);
      IF loadDir(cols[nCols], newPath) THEN
        Controls.ListReset(cols[nCols].list);
        nCols := activeCol + 2;       (* truncate any rightward trail *)
        activeCol := nCols - 1;
        layoutColumn(activeCol);
        adjustPan
      END
    END
  END descend;

  PROCEDURE Begin*(initialPath: ARRAY OF CHAR; done: Done);
    VAR dir, base, probe: ARRAY PathLen OF CHAR; ok: BOOLEAN;
  BEGIN
    doneCb := done;
    nCols := 1; activeCol := 0; leftPan := 0;
    Strings.Copy(probe, initialPath);

    (* Try the path as a directory first; if that fails, fall back
       to its parent + preselect the basename. *)
    ok := loadDir(cols[0], probe);
    IF ~ok THEN
      splitPath(initialPath, dir, base);
      IF dir[0] = 0X THEN
        ok := loadDir(cols[0], ".")
      ELSE
        ok := loadDir(cols[0], dir)
      END;
      IF ok THEN
        layoutColumn(0);
        preselect(cols[0], base)
      END
    ELSE
      layoutColumn(0)
    END;
    IF ~ok THEN
      (* Empty / dot dir as last resort so the browser still shows
         something rather than no-op. *)
      cols[0].n := 0;
      Strings.Copy(cols[0].path, ".");
      layoutColumn(0)
    END;
    active := TRUE;
    refreshPreview                  (* show preview of the initial selection *)
  END Begin;


  PROCEDURE commit(name: ARRAY OF CHAR);
    VAR fullPath: ARRAY PathLen OF CHAR; cb: Done;
  BEGIN
    joinPath(cols[activeCol].path, name, fullPath);
    cb := doneCb; doneCb := NIL;
    active := FALSE;
    IF cb # NIL THEN cb(fullPath, TRUE) END
  END commit;

  PROCEDURE cancel;
    VAR cb: Done; empty: ARRAY 1 OF CHAR;
  BEGIN
    empty[0] := 0X;
    cb := doneCb; doneCb := NIL;
    active := FALSE;
    IF cb # NIL THEN cb(empty, FALSE) END
  END cancel;

  PROCEDURE HandleKey*(k: INTEGER);
    VAR ev, sel, oldSel: INTEGER;
  BEGIN
    IF active THEN
      IF k = TUI.KeyEscape THEN
        cancel
      ELSE
        paintingCol := activeCol;     (* defensive — only Paint uses src *)
        oldSel := cols[activeCol].list.selected;
        Controls.ListHandleKey(cols[activeCol].list, k, ev);
        IF ev = Controls.ListEventOpen THEN
          sel := cols[activeCol].list.selected;
          IF (sel >= 0) & (sel < cols[activeCol].n) THEN
            IF cols[activeCol].isDir[sel] THEN
              descend(cols[activeCol].names[sel])
            ELSE
              commit(cols[activeCol].names[sel])
            END
          END
        ELSIF ev = Controls.ListEventBack THEN
          IF activeCol > 0 THEN
            DEC(activeCol);
            adjustPan;
            refreshPreview            (* show preview of the now-active selection *)
          END
        ELSIF cols[activeCol].list.selected # oldSel THEN
          (* Up / Down / PageUp / PageDown / Home / End changed the
             selection — Miller-columns preview updates the right. *)
          refreshPreview
        END
      END
    END
  END HandleKey;

  PROCEDURE Paint*;
    VAR i, vis, rightX: INTEGER;
  BEGIN
    adjustPan;
    vis := TUI.Cols DIV ColWidth;
    IF vis < 1 THEN vis := 1 END;
    i := leftPan;
    WHILE (i < nCols) & (i < leftPan + vis) DO
      layoutColumn(i);
      paintingCol := i;
      Controls.ListPaint(cols[i].list);
      INC(i)
    END;
    (* Blank any leftover area to the right of the last column. *)
    rightX := (i - leftPan) * ColWidth;
    IF rightX < TUI.Cols THEN
      i := 0;
      WHILE i < TUI.Rows - 2 DO
        TUI.MoveTo(rightX, i);
        vis := rightX;
        WHILE vis < TUI.Cols DO TUI.Write(" "); INC(vis) END;
        INC(i)
      END
    END
  END Paint;

  (* Fill `out` with the path of the currently-selected entry —
     dir of the active column joined with the selected name. *)
  PROCEDURE CurrentPath*(VAR out: ARRAY OF CHAR);
    VAR sel: INTEGER;
  BEGIN
    out[0] := 0X;
    IF active & (activeCol >= 0) & (activeCol < nCols) THEN
      sel := cols[activeCol].list.selected;
      IF (sel >= 0) & (sel < cols[activeCol].n) THEN
        joinPath(cols[activeCol].path, cols[activeCol].names[sel], out)
      ELSE
        Strings.Copy(out, cols[activeCol].path)
      END
    END
  END CurrentPath;

BEGIN
  active := FALSE; nCols := 0; activeCol := 0; leftPan := 0;
  paintingCol := 0; doneCb := NIL
END FileBrowser.
