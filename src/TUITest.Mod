MODULE TUITest;
(* Visual exercise of TUI.Mod.

   Phase 1 — text output: paint a bordered frame, an attribute sample
   row and a coordinate grid. The user inspects the result and presses
   any key to advance.

   Phase 2 — keyboard input: enter a key-echo loop. Each press is
   reported by name (where known) and by numeric code. Ctrl-Q exits. *)

  IMPORT TUI;

  PROCEDURE WriteAt(col, row: INTEGER; s: ARRAY OF CHAR);
  BEGIN
    TUI.MoveTo(col, row);
    TUI.WriteStr(s)
  END WriteAt;

  PROCEDURE DrawBorder;
    VAR x, y: INTEGER;
  BEGIN
    TUI.MoveTo(0, 0);
    x := 0;
    WHILE x < TUI.Cols DO TUI.Write("-"); INC(x) END;
    TUI.MoveTo(0, TUI.Rows - 1);
    x := 0;
    WHILE x < TUI.Cols DO TUI.Write("-"); INC(x) END;
    y := 1;
    WHILE y < TUI.Rows - 1 DO
      TUI.MoveTo(0, y);              TUI.Write("|");
      TUI.MoveTo(TUI.Cols - 1, y);   TUI.Write("|");
      INC(y)
    END
  END DrawBorder;

  PROCEDURE TextOutputDemo;
  BEGIN
    TUI.Clear;
    DrawBorder;

    WriteAt(2, 1, "TUI text-output demo");
    WriteAt(2, 2, "terminal is ");
    TUI.WriteInt(TUI.Cols);
    TUI.WriteStr(" cols x ");
    TUI.WriteInt(TUI.Rows);
    TUI.WriteStr(" rows");

    TUI.MoveTo(2, 4); TUI.WriteStr("normal text");
    TUI.MoveTo(2, 5); TUI.SetAttr(TUI.AttrReverse); TUI.WriteStr("reverse text"); TUI.SetAttr(TUI.AttrNormal);
    TUI.MoveTo(2, 6); TUI.SetAttr(TUI.AttrBold);    TUI.WriteStr("bold text");    TUI.SetAttr(TUI.AttrNormal);
    TUI.MoveTo(2, 7);
    TUI.SetAttr(TUI.AttrBold + TUI.AttrReverse);
    TUI.WriteStr("bold + reverse");
    TUI.SetAttr(TUI.AttrNormal);

    WriteAt(2, 9, "coordinate probes:");
    WriteAt(2, 10, "  (10,10) -> ");  TUI.MoveTo(10, 10); TUI.Write("X");
    WriteAt(2, 11, "  (30,11) -> ");  TUI.MoveTo(30, 11); TUI.Write("X");
    TUI.MoveTo(TUI.Cols - 5, TUI.Rows - 3); TUI.Write("X");

    WriteAt(2, TUI.Rows - 2, "press any key to continue...");
    TUI.Flush
  END TextOutputDemo;

  PROCEDURE KeyName(k: INTEGER; VAR name: ARRAY OF CHAR);
  BEGIN
    CASE k OF
      TUI.KeyArrowUp:    name := "ArrowUp"
    | TUI.KeyArrowDown:  name := "ArrowDown"
    | TUI.KeyArrowLeft:  name := "ArrowLeft"
    | TUI.KeyArrowRight: name := "ArrowRight"
    | TUI.KeyHome:       name := "Home"
    | TUI.KeyEnd:        name := "End"
    | TUI.KeyPageUp:     name := "PageUp"
    | TUI.KeyPageDown:   name := "PageDown"
    | TUI.KeyDelete:     name := "Delete"
    | TUI.KeyEnter:      name := "Enter"
    | TUI.KeyTab:        name := "Tab"
    | TUI.KeyEscape:     name := "Escape"
    | TUI.KeyBackspace:  name := "Backspace"
    | TUI.KeyMetaLT:     name := "Meta-<"
    | TUI.KeyMetaGT:     name := "Meta->"
    ELSE
      IF (k >= 1) & (k <= 26) THEN name := "Ctrl+letter"
      ELSIF (k >= 32) & (k < 127) THEN name := "printable"
      ELSE name := "?"
      END
    END
  END KeyName;

  PROCEDURE ShowKey(row: INTEGER; k: INTEGER);
    VAR name: ARRAY 32 OF CHAR; ch: CHAR;
  BEGIN
    TUI.MoveTo(2, row);
    TUI.ClearLine;
    TUI.WriteStr("key code ");
    TUI.WriteInt(k);
    TUI.WriteStr("  name=");
    KeyName(k, name);
    TUI.WriteStr(name);
    IF (k >= 32) & (k < 127) THEN
      ch := CHR(k);
      TUI.WriteStr("  char='");
      TUI.Write(ch);
      TUI.WriteStr("'")
    END
  END ShowKey;

  PROCEDURE KeyInputDemo;
    VAR k, row, wipe: INTEGER; running: BOOLEAN;
  BEGIN
    TUI.Clear;
    DrawBorder;
    WriteAt(2, 1, "TUI key-input demo");
    WriteAt(2, 2, "press keys to see their decoded codes");
    WriteAt(2, 3, "Ctrl-Q to quit");

    row := 5;
    running := TRUE;
    TUI.Flush;
    WHILE running DO
      k := TUI.ReadKey();
      ShowKey(row, k);
      INC(row);
      IF row >= TUI.Rows - 2 THEN
        wipe := 5;
        WHILE wipe < TUI.Rows - 1 DO
          TUI.MoveTo(1, wipe);
          TUI.SetAttr(TUI.AttrNormal);
          TUI.ClearLine;
          TUI.MoveTo(TUI.Cols - 1, wipe); TUI.Write("|");
          INC(wipe)
        END;
        row := 5
      END;
      TUI.Flush;
      IF k = TUI.KeyCtrlQ THEN running := FALSE END
    END
  END KeyInputDemo;

  PROCEDURE Run;
    VAR k: INTEGER;
  BEGIN
    TUI.Init;
    TextOutputDemo;
    k := TUI.ReadKey();
    IF k # TUI.KeyCtrlQ THEN KeyInputDemo END;
    TUI.Clear;
    TUI.Flush;
    TUI.Shutdown
  END Run;

BEGIN
  Run
END TUITest.
