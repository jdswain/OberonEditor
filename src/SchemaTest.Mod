MODULE SchemaTest;

  IMPORT Out, Buffer, Schema;

  VAR pass, fail: INTEGER;

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

  PROCEDURE Append(b: Buffer.Buffer; s: ARRAY OF CHAR);
    VAR i, pos: INTEGER;
  BEGIN
    pos := b.len; i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO
      Buffer.Insert(b, pos, s[i]); INC(pos); INC(i)
    END
  END Append;

  PROCEDURE TestEmpty;
    VAR b: Buffer.Buffer; s: Schema.Schema;
  BEGIN
    Out.WriteString("empty buffer:"); Out.Ln;
    b := Buffer.New();
    s := Schema.New();
    Schema.Parse(b, s);
    Expect(s.ncol = 0, "no columns");
    Expect(s.headerEnd = 0, "headerEnd at 0")
  END TestEmpty;

  PROCEDURE TestOneColumn;
    VAR b: Buffer.Buffer; s: Schema.Schema;
  BEGIN
    Out.WriteString("one @column:"); Out.Ln;
    b := Buffer.New();
    Append(b, "@column(name)"); Append(b, "X");  (* no NL — header-only *)
    Buffer.Delete(b, b.len-1, b.len);              (* remove the X *)
    Append(b, "X");
    Buffer.Delete(b, b.len-1, b.len);              (* leave just the directive *)
    s := Schema.New();
    Schema.Parse(b, s);
    Expect(s.ncol = 1, "one column");
    Expect(StrEq(s.cols[0].name, "name"), "name = name");
    Expect(s.headerEnd = b.len, "headerEnd at end (no data)")
  END TestOneColumn;

  PROCEDURE TestThreeColumns;
    VAR b: Buffer.Buffer; s: Schema.Schema;
        nm1, nm2, nm3: ARRAY 16 OF CHAR;
  BEGIN
    Out.WriteString("three @column lines:"); Out.Ln;
    b := Buffer.New();
    Append(b, "@column(name)"); Buffer.Insert(b, b.len, 0AX);
    Append(b, "@column(age)");  Buffer.Insert(b, b.len, 0AX);
    Append(b, "@column(email)");Buffer.Insert(b, b.len, 0AX);
    s := Schema.New();
    Schema.Parse(b, s);
    Expect(s.ncol = 3, "three columns");
    nm1 := "name"; nm2 := "age"; nm3 := "email";
    Expect(StrEq(s.cols[0].name, nm1), "[0] name");
    Expect(StrEq(s.cols[1].name, nm2), "[1] age");
    Expect(StrEq(s.cols[2].name, nm3), "[2] email")
  END TestThreeColumns;

  PROCEDURE TestHeaderEnd;
  (* Header is two @column lines; data zone starts at the third
     line. headerEnd should point to start of the third line. *)
    VAR b: Buffer.Buffer; s: Schema.Schema;
        line1Len, line2Len: INTEGER;
  BEGIN
    Out.WriteString("header ends at first data line:"); Out.Ln;
    b := Buffer.New();
    Append(b, "@column(name)"); Buffer.Insert(b, b.len, 0AX);
    line1Len := b.len;
    Append(b, "@column(age)");  Buffer.Insert(b, b.len, 0AX);
    line2Len := b.len;
    Append(b, "Alice,30");      Buffer.Insert(b, b.len, 0AX);
    s := Schema.New();
    Schema.Parse(b, s);
    Expect(s.ncol = 2, "two columns");
    Expect(s.headerEnd = line2Len, "headerEnd at start of data row")
  END TestHeaderEnd;

  PROCEDURE TestCommentsAndBlanks;
    VAR b: Buffer.Buffer; s: Schema.Schema;
  BEGIN
    Out.WriteString("comments + blanks in header:"); Out.Ln;
    b := Buffer.New();
    Append(b, "# this is a comment"); Buffer.Insert(b, b.len, 0AX);
    Buffer.Insert(b, b.len, 0AX);                            (* blank line *)
    Append(b, "@column(x)"); Buffer.Insert(b, b.len, 0AX);
    Append(b, "  # indented comment"); Buffer.Insert(b, b.len, 0AX);
    Append(b, "@column(y)"); Buffer.Insert(b, b.len, 0AX);
    Append(b, "data"); Buffer.Insert(b, b.len, 0AX);
    s := Schema.New();
    Schema.Parse(b, s);
    Expect(s.ncol = 2, "two columns");
    Expect(StrEq(s.cols[0].name, "x"), "[0] = x");
    Expect(StrEq(s.cols[1].name, "y"), "[1] = y")
  END TestCommentsAndBlanks;

  PROCEDURE TestOtherDirectives;
  (* @filter / @prompt are not @column and should not produce columns,
     but they ARE directives so the parser shouldn't end the header
     on them. *)
    VAR b: Buffer.Buffer; s: Schema.Schema;
  BEGIN
    Out.WriteString("non-column directives ignored:"); Out.Ln;
    b := Buffer.New();
    Append(b, "@column(a)"); Buffer.Insert(b, b.len, 0AX);
    Append(b, "@filter(active)"); Buffer.Insert(b, b.len, 0AX);
    Append(b, "@column(b)"); Buffer.Insert(b, b.len, 0AX);
    Append(b, "row1"); Buffer.Insert(b, b.len, 0AX);
    s := Schema.New();
    Schema.Parse(b, s);
    Expect(s.ncol = 2, "two columns (filter ignored)");
    Expect(StrEq(s.cols[0].name, "a"), "[0] = a");
    Expect(StrEq(s.cols[1].name, "b"), "[1] = b")
  END TestOtherDirectives;

  PROCEDURE TestNoHeader;
  (* File starts with data — no header zone. *)
    VAR b: Buffer.Buffer; s: Schema.Schema;
  BEGIN
    Out.WriteString("no header zone:"); Out.Ln;
    b := Buffer.New();
    Append(b, "Alice,30"); Buffer.Insert(b, b.len, 0AX);
    Append(b, "Bob,25");
    s := Schema.New();
    Schema.Parse(b, s);
    Expect(s.ncol = 0, "no columns");
    Expect(s.headerEnd = 0, "headerEnd at start")
  END TestNoHeader;

  PROCEDURE TestMalformedDirective;
  (* @column without parens — Directive.Parse rejects; we should skip
     the line gracefully and keep going. *)
    VAR b: Buffer.Buffer; s: Schema.Schema;
  BEGIN
    Out.WriteString("malformed @column line skipped:"); Out.Ln;
    b := Buffer.New();
    Append(b, "@column"); Buffer.Insert(b, b.len, 0AX);     (* malformed *)
    Append(b, "@column(good)"); Buffer.Insert(b, b.len, 0AX);
    s := Schema.New();
    Schema.Parse(b, s);
    Expect(s.ncol = 1, "one good column");
    Expect(StrEq(s.cols[0].name, "good"), "[0] = good")
  END TestMalformedDirective;

  PROCEDURE Run;
  BEGIN
    pass := 0; fail := 0;
    TestEmpty;
    TestOneColumn;
    TestThreeColumns;
    TestHeaderEnd;
    TestCommentsAndBlanks;
    TestOtherDirectives;
    TestNoHeader;
    TestMalformedDirective;
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
END SchemaTest.
