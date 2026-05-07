MODULE BufferTest;
(* Behavioral checks for Buffer.Mod.
   Each test sets up a fresh buffer, runs a handful of expectations,
   and prints PASS/FAIL via Out. The module body runs all tests and
   prints a summary line. *)

  IMPORT Out, Buffer;

  VAR
    pass, fail: INTEGER;

  PROCEDURE Expect(cond: BOOLEAN; VAR name: ARRAY OF CHAR);
  BEGIN
    IF cond THEN
      INC(pass); Out.WriteString("  pass  ")
    ELSE
      INC(fail); Out.WriteString("  FAIL  ")
    END;
    Out.WriteString(name); Out.Ln
  END Expect;

  PROCEDURE StrEq(VAR a, b: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (a[i] # 0X) & (a[i] = b[i]) DO INC(i) END;
    RETURN a[i] = b[i]
  END StrEq;

  (* Drain the buffer into a NUL-terminated char array via Reader. *)
  PROCEDURE ReadAll(b: Buffer.Buffer; VAR out: ARRAY OF CHAR);
    VAR r: Buffer.Reader; ch: CHAR; i: INTEGER;
  BEGIN
    Buffer.OpenReader(r, b, 0);
    i := 0;
    Buffer.Read(r, ch);
    WHILE ~r.eot & (i < LEN(out) - 1) DO
      out[i] := ch; INC(i);
      Buffer.Read(r, ch)
    END;
    out[i] := 0X
  END ReadAll;

  PROCEDURE TestEmpty;
    VAR b: Buffer.Buffer; r: Buffer.Reader; ch: CHAR;
        buf: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("empty buffer:"); Out.Ln;
    b := Buffer.New();
    Expect(b.len = 0, "len = 0");
    Expect(~b.changed, "not dirty");
    Expect(Buffer.PieceCount(b) = 0, "no real pieces");
    Buffer.OpenReader(r, b, 0);
    Buffer.Read(r, ch);
    Expect(r.eot, "eot at start");
    Expect(ch = 0X, "ch is 0X");
    ReadAll(b, buf);
    Expect(StrEq(buf, ""), "ReadAll empty")
  END TestEmpty;

  PROCEDURE TestInsertStrCoalesces;
    VAR b: Buffer.Buffer; buf: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("InsertStr coalesces typing:"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "Hello, world!");
    Expect(b.len = 13, "len = 13");
    Expect(b.changed, "dirty");
    Expect(Buffer.PieceCount(b) = 1, "one piece");
    ReadAll(b, buf);
    Expect(StrEq(buf, "Hello, world!"), "content matches")
  END TestInsertStrCoalesces;

  PROCEDURE TestInsertAtZero;
    VAR b: Buffer.Buffer; buf: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("Insert at pos 0 (no left piece):"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abc");
    Buffer.Insert(b, 0, "*");
    Expect(b.len = 4, "len = 4");
    Expect(Buffer.PieceCount(b) = 2, "two pieces");
    ReadAll(b, buf);
    Expect(StrEq(buf, "*abc"), "content '*abc'")
  END TestInsertAtZero;

  PROCEDURE TestInsertMidSplit;
    VAR b: Buffer.Buffer; buf: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("mid-buffer Insert splits + adds:"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abcdef");
    Buffer.Insert(b, 3, "X");
    Expect(b.len = 7, "len = 7");
    Expect(Buffer.PieceCount(b) = 3, "three pieces (left | new | right)");
    ReadAll(b, buf);
    Expect(StrEq(buf, "abcXdef"), "content 'abcXdef'");

    (* Continuing to type at the cursor should coalesce with the new piece. *)
    Buffer.Insert(b, 4, "Y");
    Expect(b.len = 8, "len = 8 after second insert");
    Expect(Buffer.PieceCount(b) = 3, "still three pieces (coalesced)");
    ReadAll(b, buf);
    Expect(StrEq(buf, "abcXYdef"), "content 'abcXYdef'")
  END TestInsertMidSplit;

  PROCEDURE TestDeleteRange;
    VAR b: Buffer.Buffer; buf: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("Delete interior range:"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abcdef");
    Buffer.Delete(b, 2, 4);
    Expect(b.len = 4, "len = 4");
    ReadAll(b, buf);
    Expect(StrEq(buf, "abef"), "content 'abef'")
  END TestDeleteRange;

  PROCEDURE TestDeleteAll;
    VAR b: Buffer.Buffer; buf: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("Delete everything:"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abc");
    Buffer.Delete(b, 0, 3);
    Expect(b.len = 0, "len = 0");
    Expect(Buffer.PieceCount(b) = 0, "zero pieces");
    ReadAll(b, buf);
    Expect(StrEq(buf, ""), "content empty");
    (* Buffer must remain usable after total delete. *)
    Buffer.InsertStr(b, 0, "again");
    ReadAll(b, buf);
    Expect(StrEq(buf, "again"), "reuse after empty")
  END TestDeleteAll;

  PROCEDURE TestReadCrossesPieces;
    VAR b: Buffer.Buffer; buf: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("Reader crosses piece boundaries:"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abcdef");
    Buffer.Insert(b, 3, "X");
    (* 3 pieces; ReadAll must walk all of them in order. *)
    Expect(Buffer.PieceCount(b) = 3, "three pieces");
    ReadAll(b, buf);
    Expect(StrEq(buf, "abcXdef"), "joined content")
  END TestReadCrossesPieces;

  PROCEDURE TestCursorJump;
  (* Read at end (sets cache to trailer), then read at start — exercises
     FindPiece's backward walk. *)
    VAR b: Buffer.Buffer; r: Buffer.Reader; ch: CHAR;
  BEGIN
    Out.WriteString("cache walks both directions:"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "abcdef");
    Buffer.Insert(b, 3, "X");           (* now 3 pieces *)
    Buffer.OpenReader(r, b, b.len);     (* puts cache at trailer *)
    Buffer.Read(r, ch);
    Expect(r.eot, "eot at end");
    Buffer.OpenReader(r, b, 0);         (* backward find from trailer *)
    Buffer.Read(r, ch);
    Expect(ch = "a", "first char 'a'");
    Buffer.OpenReader(r, b, 4);         (* mid-piece find *)
    Buffer.Read(r, ch);
    Expect(ch = "d", "char at pos 4 is 'd'")
  END TestCursorJump;

  PROCEDURE TestSaveLoadRoundtrip;
    VAR b1, b2: Buffer.Buffer; res: INTEGER; buf: ARRAY 64 OF CHAR;
        path: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("Save / Load round-trip:"); Out.Ln;
    path := "buftest.tmp";
    b1 := Buffer.New();
    Buffer.InsertStr(b1, 0, "round trip!");
    Buffer.Save(b1, path, res);
    Expect(res = Buffer.Ok, "Save returns Ok");
    Expect(~b1.changed, "saved buffer not dirty");

    b2 := Buffer.New();
    Buffer.Load(b2, path, res);
    Expect(res = Buffer.Ok, "Load returns Ok");
    Expect(b2.len = 11, "loaded len = 11");
    Expect(~b2.changed, "loaded buffer not dirty");
    Expect(Buffer.PieceCount(b2) = 1, "loaded as one Orig piece");
    ReadAll(b2, buf);
    Expect(StrEq(buf, "round trip!"), "loaded content matches");

    (* Edit and save again to verify Load resets cleanly. *)
    Buffer.InsertStr(b2, 11, " again");
    Buffer.Save(b2, path, res);
    Expect(res = Buffer.Ok, "second Save Ok");
    Buffer.Load(b1, path, res);
    Expect(res = Buffer.Ok, "reload into b1 Ok");
    Expect(b1.len = 17, "reloaded len = 17");
    ReadAll(b1, buf);
    Expect(StrEq(buf, "round trip! again"), "edited content persisted")
  END TestSaveLoadRoundtrip;

  PROCEDURE TestLoadMissing;
    VAR b: Buffer.Buffer; res: INTEGER; buf: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("Load of missing file:"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "stale");
    Buffer.Load(b, "no_such_file.xyz", res);
    Expect(res = Buffer.NotFound, "res = NotFound");
    Expect(b.len = 0, "buffer reset to empty");
    Expect(Buffer.PieceCount(b) = 0, "no pieces");
    ReadAll(b, buf);
    Expect(StrEq(buf, ""), "content empty")
  END TestLoadMissing;

  PROCEDURE TestSaveEmpty;
    VAR b1, b2: Buffer.Buffer; res: INTEGER; buf: ARRAY 16 OF CHAR;
        path: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("Save empty buffer:"); Out.Ln;
    path := "buftest_empty.tmp";
    b1 := Buffer.New();
    Buffer.Save(b1, path, res);
    Expect(res = Buffer.Ok, "save empty Ok");
    b2 := Buffer.New();
    Buffer.Load(b2, path, res);
    Expect(res = Buffer.Ok, "load empty Ok");
    Expect(b2.len = 0, "len = 0");
    Expect(Buffer.PieceCount(b2) = 0, "no pieces");
    ReadAll(b2, buf);
    Expect(StrEq(buf, ""), "content empty")
  END TestSaveEmpty;

  PROCEDURE TestFind;
    VAR b: Buffer.Buffer; pat: ARRAY 16 OF CHAR;
        pos: INTEGER; ok: BOOLEAN;
  BEGIN
    Out.WriteString("Find / FindBack:"); Out.Ln;
    b := Buffer.New();
    Buffer.InsertStr(b, 0, "the quick brown fox jumps over the lazy dog");
    pat := "quick";
    ok := Buffer.Find(b, 0, pat, pos);
    Expect(ok & (pos = 4), "Find 'quick' at 4");
    pat := "the";
    ok := Buffer.Find(b, 0, pat, pos);
    Expect(ok & (pos = 0), "Find first 'the' at 0");
    ok := Buffer.Find(b, 1, pat, pos);
    Expect(ok & (pos = 31), "Find next 'the' at 31");
    pat := "missing";
    ok := Buffer.Find(b, 0, pat, pos);
    Expect(~ok, "Find 'missing' fails");
    pat := "the";
    ok := Buffer.FindBack(b, 30, pat, pos);
    Expect(ok & (pos = 0), "FindBack 'the' before 30 = 0");
    ok := Buffer.FindBack(b, 43, pat, pos);
    Expect(ok & (pos = 31), "FindBack 'the' before 43 = 31");
    pat := "dog";
    ok := Buffer.FindBack(b, 43, pat, pos);
    Expect(ok & (pos = 40), "FindBack 'dog' at end = 40")
  END TestFind;

  PROCEDURE Run*;
  BEGIN
    pass := 0; fail := 0;
    TestEmpty;
    TestInsertStrCoalesces;
    TestInsertAtZero;
    TestInsertMidSplit;
    TestDeleteRange;
    TestDeleteAll;
    TestReadCrossesPieces;
    TestCursorJump;
    TestSaveLoadRoundtrip;
    TestLoadMissing;
    TestSaveEmpty;
    TestFind;
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
END BufferTest.
