MODULE Mini;
(* Minibuffer prompts on the bottom-line.

   Two flavours:
     - Prompt: read a line of text; commit on Enter, cancel on Esc.
     - Confirm: read a single y/n keystroke; loops on anything else
       so a stray keypress can't accidentally answer.

   Both touch only the message line (TUI.Rows - 1) and the cursor;
   the rest of the screen is left as the calling editor last painted
   it. The caller is responsible for refreshing the main view after
   the prompt returns. *)

  IMPORT TUI;

  TYPE
    (* Tab-completion callback. The current input lives in
       text[0..len-1] (NUL-terminated). The implementation may extend
       it in place by writing more characters and increasing len. *)
    Completer* = PROCEDURE(VAR text: ARRAY OF CHAR; VAR len: INTEGER);

  PROCEDURE StrLen(s: ARRAY OF CHAR): INTEGER;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
    RETURN i
  END StrLen;

  (* Read a line of text from the user on the message line.
     Returns ok = TRUE with result NUL-terminated on Enter; ok = FALSE
     on Escape. Supports Backspace, Ctrl-H, arrow keys, Home, End.
     If `complete` is non-NIL, Tab invokes it for completion. *)
  PROCEDURE Prompt*(prompt: ARRAY OF CHAR; VAR result: ARRAY OF CHAR;
                    VAR ok: BOOLEAN; complete: Completer);
    CONST MaxText = 256;
    VAR text: ARRAY MaxText OF CHAR;
        len, mbCur: INTEGER;
        k, i, promptCols: INTEGER;
        ch: CHAR;
        done: BOOLEAN;
  BEGIN
    text[0] := 0X; len := 0; mbCur := 0;
    ok := FALSE; done := FALSE;
    promptCols := StrLen(prompt);
    WHILE ~done DO
      TUI.MoveTo(0, TUI.Rows - 1);
      TUI.ClearLine;
      TUI.WriteStr(prompt);
      TUI.WriteStr(text);
      TUI.MoveTo(promptCols + mbCur, TUI.Rows - 1);
      TUI.Flush;
      k := TUI.ReadKey();
      IF k = TUI.KeyEnter THEN
        ok := TRUE; done := TRUE
      ELSIF k = TUI.KeyEscape THEN
        ok := FALSE; done := TRUE
      ELSIF (k = TUI.KeyBackspace) OR (k = TUI.KeyCtrlH) THEN
        IF mbCur > 0 THEN
          i := mbCur;
          WHILE i < len DO text[i-1] := text[i]; INC(i) END;
          DEC(len); DEC(mbCur); text[len] := 0X
        END
      ELSIF k = TUI.KeyTab THEN
        IF complete # NIL THEN
          complete(text, len);
          mbCur := len
        END
      ELSIF k = TUI.KeyArrowLeft THEN
        IF mbCur > 0 THEN DEC(mbCur) END
      ELSIF k = TUI.KeyArrowRight THEN
        IF mbCur < len THEN INC(mbCur) END
      ELSIF k = TUI.KeyHome THEN mbCur := 0
      ELSIF k = TUI.KeyEnd  THEN mbCur := len
      ELSIF (k >= 32) & (k < 127) & (len < MaxText - 1) THEN
        i := len;
        WHILE i > mbCur DO text[i] := text[i-1]; DEC(i) END;
        ch := CHR(k);
        text[mbCur] := ch;
        INC(mbCur); INC(len); text[len] := 0X
      END
    END;
    IF ok THEN
      i := 0;
      WHILE (i < len) & (i < LEN(result) - 1) DO
        result[i] := text[i]; INC(i)
      END;
      result[i] := 0X
    ELSE
      result[0] := 0X
    END
  END Prompt;

  (* Same as Prompt but the initial input is `init` instead of
     empty. Useful for "edit cell" workflows where the user starts
     with the cell's current value and adjusts it. *)
  PROCEDURE PromptEdit*(prompt: ARRAY OF CHAR; init: ARRAY OF CHAR;
                        VAR result: ARRAY OF CHAR;
                        VAR ok: BOOLEAN; complete: Completer);
    CONST MaxText = 256;
    VAR text: ARRAY MaxText OF CHAR;
        len, mbCur: INTEGER;
        k, i, promptCols: INTEGER;
        ch: CHAR;
        done: BOOLEAN;
  BEGIN
    (* Pre-load text from init, copying up to MaxText-1 chars. *)
    i := 0;
    WHILE (i < MaxText - 1) & (i < LEN(init)) & (init[i] # 0X) DO
      text[i] := init[i]; INC(i)
    END;
    text[i] := 0X;
    len := i;
    mbCur := len;                  (* cursor at end so user can append *)
    ok := FALSE; done := FALSE;
    promptCols := StrLen(prompt);
    WHILE ~done DO
      TUI.MoveTo(0, TUI.Rows - 1);
      TUI.ClearLine;
      TUI.WriteStr(prompt);
      TUI.WriteStr(text);
      TUI.MoveTo(promptCols + mbCur, TUI.Rows - 1);
      TUI.Flush;
      k := TUI.ReadKey();
      IF k = TUI.KeyEnter THEN
        ok := TRUE; done := TRUE
      ELSIF k = TUI.KeyEscape THEN
        ok := FALSE; done := TRUE
      ELSIF (k = TUI.KeyBackspace) OR (k = TUI.KeyCtrlH) THEN
        IF mbCur > 0 THEN
          i := mbCur;
          WHILE i < len DO text[i-1] := text[i]; INC(i) END;
          DEC(len); DEC(mbCur); text[len] := 0X
        END
      ELSIF k = TUI.KeyTab THEN
        IF complete # NIL THEN
          complete(text, len);
          mbCur := len
        END
      ELSIF k = TUI.KeyArrowLeft THEN
        IF mbCur > 0 THEN DEC(mbCur) END
      ELSIF k = TUI.KeyArrowRight THEN
        IF mbCur < len THEN INC(mbCur) END
      ELSIF k = TUI.KeyHome THEN mbCur := 0
      ELSIF k = TUI.KeyEnd  THEN mbCur := len
      ELSIF (k >= 32) & (k < 127) & (len < MaxText - 1) THEN
        i := len;
        WHILE i > mbCur DO text[i] := text[i-1]; DEC(i) END;
        ch := CHR(k);
        text[mbCur] := ch;
        INC(mbCur); INC(len); text[len] := 0X
      END
    END;
    IF ok THEN
      i := 0;
      WHILE (i < len) & (i < LEN(result) - 1) DO
        result[i] := text[i]; INC(i)
      END;
      result[i] := 0X
    ELSE
      result[0] := 0X
    END
  END PromptEdit;

  (* Single-keystroke yes/no confirmation. Returns TRUE on y/Y,
     FALSE on n/N/Esc. Any other keystroke loops so a misfire
     cannot accidentally answer. *)
  PROCEDURE Confirm*(prompt: ARRAY OF CHAR): BOOLEAN;
    VAR k: INTEGER; ok, done: BOOLEAN;
  BEGIN
    ok := FALSE; done := FALSE;
    WHILE ~done DO
      TUI.MoveTo(0, TUI.Rows - 1);
      TUI.ClearLine;
      TUI.WriteStr(prompt);
      TUI.Flush;
      k := TUI.ReadKey();
      IF (k = ORD("y")) OR (k = ORD("Y")) THEN
        ok := TRUE; done := TRUE
      ELSIF (k = ORD("n")) OR (k = ORD("N")) OR (k = TUI.KeyEscape) THEN
        ok := FALSE; done := TRUE
      END
    END;
    RETURN ok
  END Confirm;

END Mini.
