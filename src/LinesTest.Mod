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

  (* Capture the table state via the public API and compare with what
     a forced rebuild would produce. Verifies incremental updates have
     not drifted from the rebuild's truth. *)
  PROCEDURE assertSameAsRebuild(b: Buffer.Buffer; L: Lines.Lines;
                                VAR name: ARRAY OF CHAR);
    CONST MaxCmp = 64;
    VAR cnt1, cnt2, i: INTEGER;
        starts1: ARRAY MaxCmp OF INTEGER;
        ok: BOOLEAN;
  BEGIN
    cnt1 := Lines.Count(L);
    i := 0;
    WHILE (i < cnt1) & (i < MaxCmp) DO
      starts1[i] := Lines.LineStart(L, i); INC(i)
    END;
    Lines.Invalidate(L);
    cnt2 := Lines.Count(L);
    ok := cnt1 = cnt2;
    i := 0;
    WHILE ok & (i < cnt1) & (i < MaxCmp) DO
      ok := starts1[i] = Lines.LineStart(L, i); INC(i)
    END;
    Expect(ok, name)
  END assertSameAsRebuild;

  PROCEDURE TestIncrementalInsert;
    VAR b: Buffer.Buffer; L: Lines.Lines; dummy: INTEGER;
  BEGIN
    Out.WriteString("Inserted (incremental):"); Out.Ln;
    b := Buffer.New();
    L := Lines.New(b);
    dummy := Lines.Count(L);                       (* prime: not stale *)
    Buffer.Insert(b, 0, "a");          Lines.Inserted(L, 0, 1);
    assertSameAsRebuild(b, L, "after 'a'");
    Buffer.Insert(b, 1, 0AX);          Lines.Inserted(L, 1, 1);
    assertSameAsRebuild(b, L, "after newline at end");
    Buffer.Insert(b, 2, "b");          Lines.Inserted(L, 2, 1);
    assertSameAsRebuild(b, L, "after 'b' on line 2");
    Buffer.Insert(b, 0, "Z");          Lines.Inserted(L, 0, 1);
    assertSameAsRebuild(b, L, "after 'Z' at start (shifts line 1)");
    Buffer.Insert(b, 2, 0AX);          Lines.Inserted(L, 2, 1);
    assertSameAsRebuild(b, L, "after splitting line 0 with newline")
  END TestIncrementalInsert;

  PROCEDURE TestIncrementalDelete;
  (* Each scenario builds the buffer fresh via InsertStr+Insert, primes
     the line table, applies a delete + Lines.Deleted, then compares
     against a forced rebuild. *)
    VAR b: Buffer.Buffer; L: Lines.Lines; dummy: INTEGER;
  BEGIN
    Out.WriteString("Deleted (incremental):"); Out.Ln;

    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abc"); Buffer.Insert(b, 3, 0AX);
    Buffer.InsertStr(b, 4, "def"); Buffer.Insert(b, 7, 0AX);
    Buffer.InsertStr(b, 8, "ghi");
    L := Lines.New(b); dummy := Lines.Count(L);
    Buffer.Delete(b, 1, 2);  Lines.Deleted(L, 1, 2);
    assertSameAsRebuild(b, L, "delete one char on line 0");

    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abc"); Buffer.Insert(b, 3, 0AX);
    Buffer.InsertStr(b, 4, "def");
    L := Lines.New(b); dummy := Lines.Count(L);
    Buffer.Delete(b, 3, 4);  Lines.Deleted(L, 3, 4);
    assertSameAsRebuild(b, L, "delete the newline (lines merge)");

    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abc"); Buffer.Insert(b, 3, 0AX);
    Buffer.InsertStr(b, 4, "def"); Buffer.Insert(b, 7, 0AX);
    Buffer.InsertStr(b, 8, "ghi");
    L := Lines.New(b); dummy := Lines.Count(L);
    Buffer.Delete(b, 0, 4);  Lines.Deleted(L, 0, 4);
    assertSameAsRebuild(b, L, "delete entire first line incl newline");

    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abc"); Buffer.Insert(b, 3, 0AX);
    Buffer.InsertStr(b, 4, "def"); Buffer.Insert(b, 7, 0AX);
    Buffer.InsertStr(b, 8, "ghi");
    L := Lines.New(b); dummy := Lines.Count(L);
    Buffer.Delete(b, 2, 9);  Lines.Deleted(L, 2, 9);
    assertSameAsRebuild(b, L, "delete spanning two newlines");

    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abc"); Buffer.Insert(b, 3, 0AX);
    Buffer.InsertStr(b, 4, "def");
    L := Lines.New(b); dummy := Lines.Count(L);
    Buffer.Delete(b, 0, 7);  Lines.Deleted(L, 0, 7);
    assertSameAsRebuild(b, L, "delete the entire buffer")
  END TestIncrementalDelete;

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
    TestIncrementalInsert;
    TestIncrementalDelete;
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
