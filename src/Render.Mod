MODULE Render;
(* Text-mode rendering for the editor frame.

   Recogniser framework. Each Recogniser is two procedures:

     try  — given a buffer position and an "at line start" flag,
            decides whether the recogniser claims a span starting
            here; on TRUE returns the span's end (exclusive).
     emit — paints the bytes in [spanStart, spanEnd) using TUI
            styling, advancing pos / row / col and tracking cur.

   DrawBuffer consults the registered recognisers at each step. The
   first one whose `try` succeeds owns that span; if none match the
   default word-wrap path runs. Two built-ins are registered in this
   module's body: markdown links and markdown headings.

   DrawMessageLine paints the final line. Status bar and frame
   orchestration stay in Oed.Mod since they branch on Viewer kind. *)

  IMPORT TUI, Buffer;

  CONST
    Newline = 0AX;
    MaxRecognisers = 8;

  TYPE
    TryProc*  = PROCEDURE(b: Buffer.Buffer; pos: INTEGER;
                          atLineStart: BOOLEAN;
                          VAR spanEnd: INTEGER): BOOLEAN;
    EmitProc* = PROCEDURE(b: Buffer.Buffer;
                          spanStart, spanEnd, cur, viewportRows: INTEGER;
                          VAR pos, row, col, cursRow, cursCol: INTEGER;
                          VAR done: BOOLEAN);
    Recogniser* = RECORD
      try*:  TryProc;
      emit*: EmitProc
    END;

  VAR
    recogs:  ARRAY MaxRecognisers OF Recogniser;
    nRecogs: INTEGER;

  PROCEDURE Register*(try: TryProc; emit: EmitProc);
  BEGIN
    IF nRecogs < MaxRecognisers THEN
      recogs[nRecogs].try  := try;
      recogs[nRecogs].emit := emit;
      INC(nRecogs)
    END
  END Register;

  PROCEDURE CharAt*(b: Buffer.Buffer; p: INTEGER): CHAR;
    VAR r: Buffer.Reader; ch: CHAR;
  BEGIN
    Buffer.OpenReader(r, b, p);
    Buffer.Read(r, ch);
    IF r.eot THEN ch := 0X END;
    RETURN ch
  END CharAt;

  (* Try to recognise a markdown link starting at op (which must
     point at "["). On success returns the byte offsets of the
     "]" (tE), the URL's first char (uS), and the closing ")" (uE)
     so the link's bytes span [op, uE]. Stops at newline. *)
  PROCEDURE TryParseLink*(b: Buffer.Buffer; op: INTEGER;
                          VAR tE, uS, uE: INTEGER): BOOLEAN;
    VAR r: Buffer.Reader; ch: CHAR; p: INTEGER; ok: BOOLEAN;
  BEGIN
    ok := FALSE;
    IF CharAt(b, op) = "[" THEN
      p := op + 1;
      Buffer.OpenReader(r, b, p);
      Buffer.Read(r, ch);
      WHILE ~r.eot & (ch # "]") & (ch # Newline) DO
        INC(p); Buffer.Read(r, ch)
      END;
      IF ~r.eot & (ch = "]") THEN
        tE := p;
        INC(p); Buffer.Read(r, ch);
        IF ~r.eot & (ch = "(") THEN
          INC(p); uS := p;
          Buffer.Read(r, ch);
          WHILE ~r.eot & (ch # ")") & (ch # Newline) DO
            INC(p); Buffer.Read(r, ch)
          END;
          IF ~r.eot & (ch = ")") THEN
            uE := p; ok := TRUE
          END
        END
      END
    END;
    RETURN ok
  END TryParseLink;

  (* True if cur is inside the visible text of a link starting at or
     before it. On success returns the link's open position, text
     end, url start, url end. Used by Links.{Follow, EditUrl}. *)
  PROCEDURE AtLink*(b: Buffer.Buffer; cur: INTEGER;
                    VAR op, tE, uS, uE: INTEGER): BOOLEAN;
    VAR p, t, s, e: INTEGER; found: BOOLEAN;
  BEGIN
    found := FALSE;
    p := cur;
    WHILE (p > 0) & ~found & (CharAt(b, p) # "[") DO DEC(p) END;
    IF CharAt(b, p) = "[" THEN
      IF TryParseLink(b, p, t, s, e) & (cur <= e) THEN
        op := p; tE := t; uS := s; uE := e;
        found := TRUE
      END
    END;
    RETURN found
  END AtLink;

  PROCEDURE peekWordLen(b: Buffer.Buffer; startPos: INTEGER): INTEGER;
    VAR r: Buffer.Reader; ch: CHAR; n: INTEGER;
  BEGIN
    Buffer.OpenReader(r, b, startPos);
    n := 0;
    Buffer.Read(r, ch);
    WHILE ~r.eot & (ch # Newline) & (ch # " ") & (ch # 9X) DO
      INC(n); Buffer.Read(r, ch)
    END;
    RETURN n
  END peekWordLen;

  (* Advance row / col on overflow. Sets done if we run off the
     bottom of the viewport. Shared between recogniser emit procs
     and the default word path. *)
  PROCEDURE wrapAtCol(viewportRows: INTEGER;
                      VAR row, col: INTEGER; VAR done: BOOLEAN);
  BEGIN
    IF col >= TUI.Cols THEN
      INC(row); col := 0;
      IF row >= viewportRows THEN done := TRUE
      ELSE TUI.MoveTo(0, row); TUI.ClearLine
      END
    END
  END wrapAtCol;

  (* ---------------- Link recogniser ---------------- *)

  PROCEDURE tryLink(b: Buffer.Buffer; pos: INTEGER;
                    atLineStart: BOOLEAN;
                    VAR spanEnd: INTEGER): BOOLEAN;
    VAR tE, uS, uE: INTEGER; ok: BOOLEAN;
  BEGIN
    ok := (CharAt(b, pos) = "[")
        & TryParseLink(b, pos, tE, uS, uE);
    IF ok THEN spanEnd := uE + 1 END;
    RETURN ok
  END tryLink;

  PROCEDURE emitLink(b: Buffer.Buffer;
                     spanStart, spanEnd, cur, viewportRows: INTEGER;
                     VAR pos, row, col, cursRow, cursCol: INTEGER;
                     VAR done: BOOLEAN);
    VAR r: Buffer.Reader; ch: CHAR;
        tE, uS, uE: INTEGER;
        inText, parsed: BOOLEAN;
  BEGIN
    parsed := TryParseLink(b, spanStart, tE, uS, uE);
    IF parsed THEN
      Buffer.OpenReader(r, b, spanStart);
      Buffer.Read(r, ch);
      WHILE ~done & (pos < spanEnd) & ~r.eot DO
        IF pos = cur THEN cursRow := row; cursCol := col END;
        inText := (pos > spanStart) & (pos < tE);
        (* SetAttr resets first ("\x1b[0m" then re-applies attrs), so
           SetFg must come AFTER SetAttr or the colour is wiped. *)
        IF inText THEN
          TUI.SetAttr(TUI.AttrUnderline); TUI.SetFg(TUI.ColorBlue)
        ELSE
          TUI.SetAttr(TUI.AttrNormal); TUI.SetFg(TUI.ColorDefault)
        END;
        TUI.Write(ch); INC(col); INC(pos);
        wrapAtCol(viewportRows, row, col, done);
        IF ~done THEN Buffer.Read(r, ch) END
      END
    END;
    TUI.SetAttr(TUI.AttrNormal); TUI.SetFg(TUI.ColorDefault)
  END emitLink;

  (* ---------------- Heading recogniser ---------------- *)

  (* Markdown ATX heading: one or more "#" at line start, optionally
     followed by content. We claim the whole rest of the logical
     line so the marker and the heading text both render in white. *)
  PROCEDURE tryHeading(b: Buffer.Buffer; pos: INTEGER;
                       atLineStart: BOOLEAN;
                       VAR spanEnd: INTEGER): BOOLEAN;
    VAR r: Buffer.Reader; ch: CHAR; p: INTEGER; ok: BOOLEAN;
  BEGIN
    ok := atLineStart & (CharAt(b, pos) = "#");
    IF ok THEN
      p := pos;
      Buffer.OpenReader(r, b, p);
      Buffer.Read(r, ch);
      WHILE ~r.eot & (ch # Newline) DO
        INC(p); Buffer.Read(r, ch)
      END;
      spanEnd := p
    END;
    RETURN ok
  END tryHeading;

  PROCEDURE emitHeading(b: Buffer.Buffer;
                        spanStart, spanEnd, cur, viewportRows: INTEGER;
                        VAR pos, row, col, cursRow, cursCol: INTEGER;
                        VAR done: BOOLEAN);
    VAR r: Buffer.Reader; ch: CHAR;
  BEGIN
    TUI.SetAttr(TUI.AttrBold); TUI.SetFg(TUI.ColorWhite);
    Buffer.OpenReader(r, b, spanStart);
    Buffer.Read(r, ch);
    WHILE ~done & (pos < spanEnd) & ~r.eot DO
      IF pos = cur THEN cursRow := row; cursCol := col END;
      TUI.Write(ch); INC(col); INC(pos);
      wrapAtCol(viewportRows, row, col, done);
      IF ~done THEN Buffer.Read(r, ch) END
    END;
    TUI.SetAttr(TUI.AttrNormal); TUI.SetFg(TUI.ColorDefault)
  END emitHeading;

  (* ---------------- DrawBuffer ---------------- *)

  (* Try each registered recogniser at pos. On match: emits the span,
     re-opens the outer reader past it, and returns TRUE. Sets done
     if the emit ran off the viewport. *)
  PROCEDURE applyRecogniser(buf: Buffer.Buffer; cur, viewportRows: INTEGER;
                            VAR r: Buffer.Reader; VAR ch: CHAR;
                            VAR pos, row, col, cursRow, cursCol: INTEGER;
                            VAR done: BOOLEAN): BOOLEAN;
    VAR i, spanEnd: INTEGER;
        atLineStart, handled: BOOLEAN;
  BEGIN
    atLineStart := (pos = 0) OR (CharAt(buf, pos - 1) = Newline);
    handled := FALSE; i := 0;
    WHILE ~handled & (i < nRecogs) DO
      IF recogs[i].try(buf, pos, atLineStart, spanEnd) & (spanEnd > pos) THEN
        IF (col > 0) & (col + spanEnd - pos > TUI.Cols) THEN
          INC(row); col := 0;
          IF row >= viewportRows THEN done := TRUE
          ELSE TUI.MoveTo(0, row); TUI.ClearLine
          END
        END;
        IF ~done THEN
          recogs[i].emit(buf, pos, spanEnd, cur, viewportRows,
                         pos, row, col, cursRow, cursCol, done);
          IF ~done THEN
            Buffer.OpenReader(r, buf, pos);
            Buffer.Read(r, ch)
          END
        END;
        handled := TRUE
      END;
      INC(i)
    END;
    RETURN handled
  END applyRecogniser;

  (* Word-wrap renderer for text-like Docs. Walks bytes from `top`,
     consults the recogniser registry at each step, otherwise
     emits bytes with word-wrap. Logical newlines flush to the next
     screen row regardless. Cursor screen position is written to
     cursRow / cursCol VAR params. *)
  PROCEDURE DrawBuffer*(buf: Buffer.Buffer; top, cur: INTEGER;
                        VAR cursRow, cursCol: INTEGER);
    VAR r: Buffer.Reader; ch: CHAR;
        pos, row, col, viewportRows, wordLen, j: INTEGER;
        done: BOOLEAN;
  BEGIN
    viewportRows := TUI.Rows - 2;
    IF viewportRows < 1 THEN viewportRows := 1 END;
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
        INC(row); col := 0;
        IF row >= viewportRows THEN
          done := TRUE
        ELSE
          TUI.MoveTo(0, row); TUI.ClearLine;
          INC(pos); Buffer.Read(r, ch)
        END
      ELSIF (ch = " ") OR (ch = 9X) THEN
        wrapAtCol(viewportRows, row, col, done);
        IF ~done THEN
          TUI.Write(ch); INC(col);
          INC(pos); Buffer.Read(r, ch)
        END
      ELSIF applyRecogniser(buf, cur, viewportRows, r, ch,
                            pos, row, col, cursRow, cursCol, done) THEN
        (* span emitted; r and ch updated by applyRecogniser *)
      ELSE
        wordLen := peekWordLen(buf, pos);
        IF (col > 0) & (col + wordLen > TUI.Cols) THEN
          INC(row); col := 0;
          IF row >= viewportRows THEN done := TRUE
          ELSE TUI.MoveTo(0, row); TUI.ClearLine
          END
        END;
        j := 0;
        WHILE ~done & (j < wordLen) DO
          IF pos = cur THEN cursRow := row; cursCol := col END;
          TUI.Write(ch); INC(col);
          wrapAtCol(viewportRows, row, col, done);
          INC(pos); INC(j);
          IF ~done THEN Buffer.Read(r, ch) END
        END
      END
    END;
    INC(row);
    WHILE row < viewportRows DO
      TUI.MoveTo(0, row); TUI.ClearLine; TUI.Write("~");
      INC(row)
    END
  END DrawBuffer;

  PROCEDURE DrawMessageLine*(status: ARRAY OF CHAR);
  BEGIN
    TUI.MoveTo(0, TUI.Rows - 1);
    TUI.ClearLine;
    TUI.WriteStr(status)
  END DrawMessageLine;

BEGIN
  nRecogs := 0;
  Register(tryLink,    emitLink);
  Register(tryHeading, emitHeading)
END Render.
