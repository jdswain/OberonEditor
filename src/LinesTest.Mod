MODULE LinesTest;
(* Behavioral checks for Lines.Mod. Each test seeds a Buffer with
   known content and verifies the line index reports correct counts,
   line starts/ends, lengths, and (line, col) decompositions. *)

  IMPORT Out, Buffer, Lines;

  VAR
    pass, fail: INTEGER;

  PROCEDURE Expect(cond: BOOLEAN; VAR name: ARRAY OF CHAR);
  BEGIN
    IF cond THEN INC(pass); Out.WriteString("  pass  ")
    ELSE INC(fail); Out.WriteString("  FAIL  ")
    END;
    Out.WriteString(name); Out.Ln
  END Expect;

  PROCEDURE TestEmpty;
    VAR b: Buffer.Buffer; L: Lines.Lines; line, col: INTEGER;
  BEGIN
    Out.WriteString("empty buffer:"); Out.Ln;
    b := Buffer.New();
    L := Lines.New(b);
    Expect(Lines.Count(L) = 1, "count = 1");
    Expect(Lines.LineStart(L, 0) = 0, "line 0 start = 0");
    Expect(Lines.LineEnd(L, 0) = 0, "line 0 end = 0");
    Expect(Lines.LineLen(L, 0) = 0, "line 0 len = 0");
    Lines.Locate(L, 0, line, col);
    Expect((line = 0) & (col = 0), "Locate(0) = (0,0)")
  END TestEmpty;

  PROCEDURE TestSingleLineNoNewline;
    VAR b: Buffer.Buffer; L: Lines.Lines; line, col: INTEGER;
  BEGIN
    Out.WriteString("single line, no trailing newline:"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abcdef");
    L := Lines.New(b);
    Expect(Lines.Count(L) = 1, "count = 1");
    Expect(Lines.LineStart(L, 0) = 0, "line 0 start = 0");
    Expect(Lines.LineEnd(L, 0) = 6, "line 0 end = 6");
    Expect(Lines.LineLen(L, 0) = 6, "line 0 len = 6");
    Lines.Locate(L, 3, line, col);
    Expect((line = 0) & (col = 3), "Locate(3) = (0,3)");
    Lines.Locate(L, 6, line, col);
    Expect((line = 0) & (col = 6), "Locate(6) = (0,6) at end")
  END TestSingleLineNoNewline;

  PROCEDURE TestThreeLines;
    VAR b: Buffer.Buffer; L: Lines.Lines; line, col: INTEGER;
  BEGIN
    Out.WriteString("three lines (abc/def/ghi):"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abc");
    Buffer.Insert(b, 3, 0AX);
    Buffer.InsertStr(b, 4, "def");
    Buffer.Insert(b, 7, 0AX);
    Buffer.InsertStr(b, 8, "ghi");
    L := Lines.New(b);
    Expect(Lines.Count(L) = 3, "count = 3");
    Expect(Lines.LineStart(L, 0) = 0, "line 0 start = 0");
    Expect(Lines.LineStart(L, 1) = 4, "line 1 start = 4");
    Expect(Lines.LineStart(L, 2) = 8, "line 2 start = 8");
    Expect(Lines.LineEnd(L, 0) = 3, "line 0 end = 3");
    Expect(Lines.LineEnd(L, 1) = 7, "line 1 end = 7");
    Expect(Lines.LineEnd(L, 2) = 11, "line 2 end = 11");
    Expect(Lines.LineLen(L, 1) = 3, "line 1 len = 3");
    Lines.Locate(L, 5, line, col);
    Expect((line = 1) & (col = 1), "Locate(5) = (1,1)");
    Lines.Locate(L, 4, line, col);
    Expect((line = 1) & (col = 0), "Locate(4) = (1,0) at line start");
    Lines.Locate(L, 3, line, col);
    Expect((line = 0) & (col = 3), "Locate(3) = (0,3) at newline pos");
    Lines.Locate(L, 11, line, col);
    Expect((line = 2) & (col = 3), "Locate(11) = (2,3) at end")
  END TestThreeLines;

  PROCEDURE TestTrailingNewline;
    VAR b: Buffer.Buffer; L: Lines.Lines;
  BEGIN
    Out.WriteString("buffer ending in newline:"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abc");
    Buffer.Insert(b, 3, 0AX);
    L := Lines.New(b);
    Expect(Lines.Count(L) = 2, "count = 2 (the empty trailing line)");
    Expect(Lines.LineStart(L, 1) = 4, "line 1 start = 4");
    Expect(Lines.LineEnd(L, 1) = 4, "line 1 end = 4");
    Expect(Lines.LineLen(L, 1) = 0, "line 1 len = 0")
  END TestTrailingNewline;

  PROCEDURE TestRunOfNewlines;
    VAR b: Buffer.Buffer; L: Lines.Lines;
  BEGIN
    Out.WriteString("run of three newlines:"); Out.Ln;
    b := Buffer.New();
    Buffer.Insert(b, 0, 0AX);
    Buffer.Insert(b, 1, 0AX);
    Buffer.Insert(b, 2, 0AX);
    L := Lines.New(b);
    Expect(Lines.Count(L) = 4, "count = 4");
    Expect(Lines.LineLen(L, 0) = 0, "line 0 empty");
    Expect(Lines.LineLen(L, 1) = 0, "line 1 empty");
    Expect(Lines.LineLen(L, 2) = 0, "line 2 empty");
    Expect(Lines.LineLen(L, 3) = 0, "line 3 empty (trailing)")
  END TestRunOfNewlines;

  PROCEDURE TestInvalidate;
    VAR b: Buffer.Buffer; L: Lines.Lines;
  BEGIN
    Out.WriteString("Invalidate after edit:"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abc");
    L := Lines.New(b);
    Expect(Lines.Count(L) = 1, "before edit: 1 line");
    Expect(Lines.LineLen(L, 0) = 3, "before edit: len 3");

    Buffer.Insert(b, 3, 0AX);
    Buffer.InsertStr(b, 4, "def");
    Lines.Invalidate(L);
    Expect(Lines.Count(L) = 2, "after edit + Invalidate: 2 lines");
    Expect(Lines.LineLen(L, 0) = 3, "line 0 len 3");
    Expect(Lines.LineLen(L, 1) = 3, "line 1 len 3")
  END TestInvalidate;

  PROCEDURE TestStaleWithoutInvalidate;
  (* Without Invalidate, the index is allowed to be stale.
     This documents the invariant: the editor must call Invalidate. *)
    VAR b: Buffer.Buffer; L: Lines.Lines;
  BEGIN
    Out.WriteString("stale without Invalidate is unspecified"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abc");
    L := Lines.New(b);
    Expect(Lines.Count(L) = 1, "initial count = 1");
    Buffer.Insert(b, 3, 0AX);
    (* deliberately skipping Invalidate *)
    (* Count(L) returns the cached value; we don't assert what it is. *)
    Expect(TRUE, "no assertion — caller responsibility documented")
  END TestStaleWithoutInvalidate;

  PROCEDURE Run*;
  BEGIN
    pass := 0; fail := 0;
    TestEmpty;
    TestSingleLineNoNewline;
    TestThreeLines;
    TestTrailingNewline;
    TestRunOfNewlines;
    TestInvalidate;
    TestStaleWithoutInvalidate;
    Out.Ln;
    Out.WriteString("results: ");
    Out.WriteInt(pass);
    Out.WriteString(" pass, ");
    Out.WriteInt(fail);
    Out.WriteString(" fail");
    Out.Ln
  END Run;

BEGIN
  Run
END LinesTest.
