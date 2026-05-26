MODULE Mini;
(* Modal minibuffer prompt. Event-driven so the same code runs on
   posix (where the editor's top-level loop blocks reading the PTY)
   and on wasm (where the JS host dispatches one key at a time and
   the editor never gets to spin a polling loop).

   Usage:

       Mini.Prompt("Open: ", NIL, openDone);
       (* returns immediately; openDone fires on Enter / Esc *)

   The editor's top-level key dispatcher consults Active() each
   keystroke; if TRUE it routes the key to HandleKey instead of
   the normal editor binding. Refresh consults Active() too and
   paints the prompt line + cursor via Paint.

   Three completion shapes are exported:

       Prompt        free text, optional Tab-completer
       PromptEdit    same but pre-filled with `init`
       Confirm       single-key y/n / Esc

   Each takes a strongly-typed Done callback; the callback runs
   in editor-state context (just another top-level procedure) so
   it can read / mutate any module-level state synchronously. *)

  IMPORT TUI;

  CONST
    MaxText   = 256;
    MaxPrompt = 64;

  TYPE
    Completer*   = PROCEDURE(VAR text: ARRAY OF CHAR; VAR len: INTEGER);
    PromptDone*  = PROCEDURE(result: ARRAY OF CHAR; ok: BOOLEAN);
    ConfirmDone* = PROCEDURE(ok: BOOLEAN);

    (* Hand-off for Tab. When set, replaces the default completer
       behaviour: Mini deactivates and invokes the handler with the
       current text plus the prompt's done callback. The handler can
       then launch an alternative UI (e.g. a file browser) and
       eventually call `done(result, ok)` to commit. *)
    TabHandler*  = PROCEDURE(text: ARRAY OF CHAR; len: INTEGER;
                             done: PromptDone);

  VAR
    active:    BOOLEAN;
    isConfirm: BOOLEAN;
    promptStr: ARRAY MaxPrompt OF CHAR;
    text:      ARRAY MaxText   OF CHAR;
    len:       INTEGER;
    mbCur:     INTEGER;
    completer: Completer;
    promptCb:  PromptDone;
    confirmCb: ConfirmDone;
    tabHandler: TabHandler;

  PROCEDURE copyN(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(dst) - 1) & (i < LEN(src)) & (src[i] # 0X) DO
      dst[i] := src[i]; INC(i)
    END;
    dst[i] := 0X
  END copyN;

  PROCEDURE strLen(s: ARRAY OF CHAR): INTEGER;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
    RETURN i
  END strLen;

  PROCEDURE Active*(): BOOLEAN; RETURN active END Active;

  (* Paint the message-line area for the active prompt and place
     the cursor on the input position. Caller is responsible for
     TUI.Flush. *)
  PROCEDURE Paint*;
    VAR promptCols: INTEGER;
  BEGIN
    promptCols := strLen(promptStr);
    TUI.MoveTo(0, TUI.Rows - 1);
    TUI.ClearLine;
    TUI.WriteStr(promptStr);
    IF ~isConfirm THEN
      TUI.WriteStr(text);
      TUI.MoveTo(promptCols + mbCur, TUI.Rows - 1)
    END;
    TUI.ShowCursor
  END Paint;

  PROCEDURE Prompt*(prompt: ARRAY OF CHAR; complete: Completer;
                    done: PromptDone);
  BEGIN
    copyN(promptStr, prompt);
    text[0] := 0X; len := 0; mbCur := 0;
    completer := complete;
    promptCb  := done;
    confirmCb := NIL;
    isConfirm := FALSE;
    tabHandler := NIL;
    active    := TRUE
  END Prompt;

  PROCEDURE PromptEdit*(prompt: ARRAY OF CHAR; init: ARRAY OF CHAR;
                        complete: Completer; done: PromptDone);
    VAR i: INTEGER;
  BEGIN
    copyN(promptStr, prompt);
    i := 0;
    WHILE (i < MaxText - 1) & (i < LEN(init)) & (init[i] # 0X) DO
      text[i] := init[i]; INC(i)
    END;
    text[i] := 0X;
    len := i; mbCur := len;
    completer := complete;
    promptCb  := done;
    confirmCb := NIL;
    isConfirm := FALSE;
    tabHandler := NIL;
    active    := TRUE
  END PromptEdit;

  PROCEDURE Confirm*(prompt: ARRAY OF CHAR; done: ConfirmDone);
  BEGIN
    copyN(promptStr, prompt);
    text[0] := 0X; len := 0; mbCur := 0;
    completer := NIL;
    promptCb  := NIL;
    confirmCb := done;
    isConfirm := TRUE;
    tabHandler := NIL;
    active    := TRUE
  END Confirm;

  (* Install / clear a Tab handler for the active prompt. Cleared by
     each Prompt / PromptEdit / Confirm; callers wishing to use a
     custom Tab action must install AFTER the prompt call returns. *)
  PROCEDURE SetTabHandler*(h: TabHandler);
  BEGIN tabHandler := h
  END SetTabHandler;

  PROCEDURE finishPrompt(ok: BOOLEAN);
    VAR cb: PromptDone;
        result: ARRAY MaxText OF CHAR;
        i: INTEGER;
  BEGIN
    active := FALSE;
    cb := promptCb; promptCb := NIL;
    IF ok THEN
      i := 0;
      WHILE i < len DO result[i] := text[i]; INC(i) END;
      result[i] := 0X
    ELSE
      result[0] := 0X
    END;
    IF cb # NIL THEN cb(result, ok) END
  END finishPrompt;

  PROCEDURE finishConfirm(ok: BOOLEAN);
    VAR cb: ConfirmDone;
  BEGIN
    active := FALSE;
    cb := confirmCb; confirmCb := NIL;
    IF cb # NIL THEN cb(ok) END
  END finishConfirm;

  (* Process one keystroke against the active prompt. Commit /
     cancel fires the registered Done callback synchronously. *)
  PROCEDURE HandleKey*(k: INTEGER);
    VAR i: INTEGER; ch: CHAR;
  BEGIN
    IF active THEN
      IF isConfirm THEN
        IF (k = ORD("y")) OR (k = ORD("Y")) THEN
          finishConfirm(TRUE)
        ELSIF (k = ORD("n")) OR (k = ORD("N"))
            OR (k = TUI.KeyEscape) OR (k = TUI.KeyCtrlC) THEN
          finishConfirm(FALSE)
        END
      ELSE
        IF k = TUI.KeyEnter THEN
          finishPrompt(TRUE)
        ELSIF k = TUI.KeyEscape THEN
          finishPrompt(FALSE)
        ELSIF (k = TUI.KeyBackspace) OR (k = TUI.KeyCtrlH) THEN
          IF mbCur > 0 THEN
            i := mbCur;
            WHILE i < len DO text[i-1] := text[i]; INC(i) END;
            DEC(len); DEC(mbCur); text[len] := 0X
          END
        ELSIF k = TUI.KeyTab THEN
          IF tabHandler # NIL THEN
            (* Hand off entirely to the registered handler — it
               receives the same `done` callback Mini would have
               fired on Enter, so it can commit whatever value it
               likes (or call done(?, FALSE) to cancel). *)
            active := FALSE;
            tabHandler(text, len, promptCb);
            promptCb := NIL
          ELSIF completer # NIL THEN
            completer(text, len); mbCur := len
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
      END
    END
  END HandleKey;

BEGIN
  active := FALSE; isConfirm := FALSE;
  len := 0; mbCur := 0;
  completer := NIL; promptCb := NIL; confirmCb := NIL;
  tabHandler := NIL;
  promptStr[0] := 0X; text[0] := 0X
END Mini.
