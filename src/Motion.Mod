MODULE Motion;
(* Cursor movement primitives for text Docs. Each operation takes
   cur as a VAR parameter; the caller decides which view's cursor to
   advance. Buf and Lines are read-only inputs.

   Word and sentence motion treat ASCII alphanumerics as word chars
   and "." / "!" / "?" as sentence-end punctuation — enough for the
   markdown / source-text use cases oed targets today. *)

  IMPORT Buffer, Lines;

  PROCEDURE Left*(VAR cur: INTEGER);
  BEGIN IF cur > 0 THEN DEC(cur) END
  END Left;

  PROCEDURE Right*(buf: Buffer.Buffer; VAR cur: INTEGER);
  BEGIN IF cur < buf.len THEN INC(cur) END
  END Right;

  PROCEDURE Home*(lines: Lines.Lines; VAR cur: INTEGER);
    VAR line, col: INTEGER;
  BEGIN
    Lines.Locate(lines, cur, line, col);
    cur := Lines.LineStart(lines, line)
  END Home;

  PROCEDURE End*(lines: Lines.Lines; VAR cur: INTEGER);
    VAR line, col: INTEGER;
  BEGIN
    Lines.Locate(lines, cur, line, col);
    cur := Lines.LineEnd(lines, line)
  END End;

  PROCEDURE Up*(lines: Lines.Lines; VAR cur: INTEGER);
    VAR line, col, newLen, newCol: INTEGER;
  BEGIN
    Lines.Locate(lines, cur, line, col);
    IF line > 0 THEN
      newLen := Lines.LineLen(lines, line - 1);
      IF col < newLen THEN newCol := col ELSE newCol := newLen END;
      cur := Lines.LineStart(lines, line - 1) + newCol
    END
  END Up;

  PROCEDURE Down*(lines: Lines.Lines; VAR cur: INTEGER);
    VAR line, col, newLen, newCol: INTEGER;
  BEGIN
    Lines.Locate(lines, cur, line, col);
    IF line + 1 < Lines.Count(lines) THEN
      newLen := Lines.LineLen(lines, line + 1);
      IF col < newLen THEN newCol := col ELSE newCol := newLen END;
      cur := Lines.LineStart(lines, line + 1) + newCol
    END
  END Down;

  PROCEDURE BufStart*(VAR cur: INTEGER);
  BEGIN cur := 0
  END BufStart;

  PROCEDURE BufEnd*(buf: Buffer.Buffer; VAR cur: INTEGER);
  BEGIN cur := buf.len
  END BufEnd;

  PROCEDURE PageUp*(lines: Lines.Lines; VAR cur: INTEGER; rows: INTEGER);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE i < rows DO Up(lines, cur); INC(i) END
  END PageUp;

  PROCEDURE PageDown*(lines: Lines.Lines; VAR cur: INTEGER; rows: INTEGER);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE i < rows DO Down(lines, cur); INC(i) END
  END PageDown;

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

  PROCEDURE charAt(buf: Buffer.Buffer; p: INTEGER): CHAR;
    VAR r: Buffer.Reader; ch: CHAR;
  BEGIN
    Buffer.OpenReader(r, buf, p);
    Buffer.Read(r, ch);
    IF r.eot THEN ch := 0X END;
    RETURN ch
  END charAt;

  (* Skip non-word chars then word chars; lands at first non-word
     char after the current/next word, or at buf.len. *)
  PROCEDURE WordForward*(buf: Buffer.Buffer; VAR cur: INTEGER);
    VAR r: Buffer.Reader; ch: CHAR; p: INTEGER;
  BEGIN
    Buffer.OpenReader(r, buf, cur);
    p := cur;
    Buffer.Read(r, ch);
    WHILE ~r.eot & ~isWord(ch) DO INC(p); Buffer.Read(r, ch) END;
    WHILE ~r.eot & isWord(ch)  DO INC(p); Buffer.Read(r, ch) END;
    cur := p
  END WordForward;

  (* Walk left over non-word then word chars; lands at the start of
     the current/previous word. *)
  PROCEDURE WordBackward*(buf: Buffer.Buffer; VAR cur: INTEGER);
    VAR p: INTEGER;
  BEGIN
    p := cur;
    WHILE (p > 0) & ~isWord(charAt(buf, p-1)) DO DEC(p) END;
    WHILE (p > 0) &  isWord(charAt(buf, p-1)) DO DEC(p) END;
    cur := p
  END WordBackward;

  (* Find next sentence-end punctuation followed by whitespace, land
     just after the punctuation. If none found, go to end of buffer. *)
  PROCEDURE SentForward*(buf: Buffer.Buffer; VAR cur: INTEGER);
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
  END SentForward;

  (* Walk from buffer start, recording each sentence-start position
     reached (first non-space at start, then first non-space after a
     sentence-end). Final lastStart < cur is the destination. If the
     cursor sits at a sentence start, this lands on the previous one. *)
  PROCEDURE SentBackward*(buf: Buffer.Buffer; VAR cur: INTEGER);
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
  END SentBackward;

END Motion.
