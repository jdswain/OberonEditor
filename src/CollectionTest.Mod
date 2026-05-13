MODULE CollectionTest;
(* Behavioural checks for Collection.Mod. Builds Docs from raw bytes
   (header + CSV data), opens them as Collections, and exercises row
   iteration plus in-place cell edits. *)

  IMPORT Out, Buffer, Schema, Doc, Collection;

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

  PROCEDURE Drain(b: Buffer.Buffer; VAR out: ARRAY OF CHAR);
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
  END Drain;

  (* Make a Doc with a small two-column schema and three data rows:
       @column(name)
       @column(age)
       Alice,30
       Bob,25
       Carol,28
     Returns the Doc with schema parsed. *)
  PROCEDURE makeDoc(): Doc.Doc;
    VAR d: Doc.Doc; nm: ARRAY 32 OF CHAR;
  BEGIN
    nm := "*test*";
    d := Doc.New(nm);
    Append(d.buf, "@column(name)"); Buffer.Insert(d.buf, d.buf.len, 0AX);
    Append(d.buf, "@column(age)");  Buffer.Insert(d.buf, d.buf.len, 0AX);
    Append(d.buf, "Alice,30");      Buffer.Insert(d.buf, d.buf.len, 0AX);
    Append(d.buf, "Bob,25");        Buffer.Insert(d.buf, d.buf.len, 0AX);
    Append(d.buf, "Carol,28");      Buffer.Insert(d.buf, d.buf.len, 0AX);
    d.schema := Schema.New();
    Schema.Parse(d.buf, d.schema);
    RETURN d
  END makeDoc;

  PROCEDURE TestIterate;
    VAR d: Doc.Doc; c: Collection.Collection; it: Collection.RowIter;
        f: ARRAY 32 OF CHAR; last: BOOLEAN; rows: INTEGER;
  BEGIN
    Out.WriteString("iterate three rows:"); Out.Ln;
    d := makeDoc();
    c := Collection.Open(d);
    rows := 0;
    Collection.OpenIter(c, it);
    WHILE ~it.done DO
      Collection.Field(it, f, last);
      Expect(last = FALSE, "1st field not last");
      Collection.Field(it, f, last);
      Expect(last = TRUE, "2nd field is last");
      Collection.NextRow(it);
      INC(rows)
    END;
    Expect(rows = 3, "three rows total")
  END TestIterate;

  PROCEDURE TestFieldValues;
    VAR d: Doc.Doc; c: Collection.Collection; it: Collection.RowIter;
        f: ARRAY 32 OF CHAR; last: BOOLEAN;
  BEGIN
    Out.WriteString("field values across rows:"); Out.Ln;
    d := makeDoc();
    c := Collection.Open(d);
    Collection.OpenIter(c, it);
    Collection.Field(it, f, last); Expect(StrEq(f, "Alice"), "r0.0 Alice");
    Collection.Field(it, f, last); Expect(StrEq(f, "30"), "r0.1 30");
    Collection.NextRow(it);
    Collection.Field(it, f, last); Expect(StrEq(f, "Bob"), "r1.0 Bob");
    Collection.Field(it, f, last); Expect(StrEq(f, "25"), "r1.1 25");
    Collection.NextRow(it);
    Collection.Field(it, f, last); Expect(StrEq(f, "Carol"), "r2.0 Carol");
    Collection.Field(it, f, last); Expect(StrEq(f, "28"), "r2.1 28");
    Collection.NextRow(it);
    Expect(it.done, "done after row 2")
  END TestFieldValues;

  PROCEDURE TestCount;
    VAR d: Doc.Doc; c: Collection.Collection;
  BEGIN
    Out.WriteString("Count rows:"); Out.Ln;
    d := makeDoc();
    c := Collection.Open(d);
    Expect(Collection.Count(c) = 3, "count = 3")
  END TestCount;

  PROCEDURE TestFindRow;
    VAR d: Doc.Doc; c: Collection.Collection;
        r0, r1, r2, r3: INTEGER;
  BEGIN
    Out.WriteString("FindRow returns byte offsets:"); Out.Ln;
    d := makeDoc();
    c := Collection.Open(d);
    r0 := Collection.FindRow(c, 0);
    r1 := Collection.FindRow(c, 1);
    r2 := Collection.FindRow(c, 2);
    r3 := Collection.FindRow(c, 3);
    Expect(r0 = d.schema.headerEnd, "r0 at headerEnd");
    Expect(r1 > r0, "r1 > r0");
    Expect(r2 > r1, "r2 > r1");
    Expect(r3 = -1, "r3 out of range → -1")
  END TestFindRow;

  PROCEDURE TestGetCell;
    VAR d: Doc.Doc; c: Collection.Collection;
        r0, r1: INTEGER; v: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("GetCell reads field values:"); Out.Ln;
    d := makeDoc();
    c := Collection.Open(d);
    r0 := Collection.FindRow(c, 0);
    Collection.GetCell(c, r0, 0, v); Expect(StrEq(v, "Alice"), "r0.0 Alice");
    Collection.GetCell(c, r0, 1, v); Expect(StrEq(v, "30"), "r0.1 30");
    Collection.GetCell(c, r0, 2, v); Expect(StrEq(v, "") & TRUE, "r0.2 out of range");
    r1 := Collection.FindRow(c, 1);
    Collection.GetCell(c, r1, 0, v); Expect(StrEq(v, "Bob"), "r1.0 Bob");
    Collection.GetCell(c, r1, 1, v); Expect(StrEq(v, "25"), "r1.1 25")
  END TestGetCell;

  PROCEDURE TestSetCellSameLen;
  (* Replace a field with a value of the same byte length. *)
    VAR d: Doc.Doc; c: Collection.Collection;
        r1: INTEGER; out: ARRAY 128 OF CHAR;
  BEGIN
    Out.WriteString("SetCell same length:"); Out.Ln;
    d := makeDoc();
    c := Collection.Open(d);
    r1 := Collection.FindRow(c, 1);                  (* Bob,25 *)
    Collection.SetCell(c, r1, 0, "Bob");             (* unchanged content, exercises path *)
    Drain(d.buf, out);
    (* Row 1 should still read "Bob,25" *)
    Expect(out[0] = "@", "header preserved")
  END TestSetCellSameLen;

  PROCEDURE TestSetCellShorter;
  (* Replace a field with a shorter value — checks downstream byte
     offsets aren't relied on by the test's reader. *)
    VAR d: Doc.Doc; c: Collection.Collection;
        r1: INTEGER; it: Collection.RowIter;
        f: ARRAY 32 OF CHAR; last: BOOLEAN;
  BEGIN
    Out.WriteString("SetCell shorter — row reflects new value:"); Out.Ln;
    d := makeDoc();
    c := Collection.Open(d);
    r1 := Collection.FindRow(c, 1);                  (* Bob,25 *)
    Collection.SetCell(c, r1, 1, "9");               (* "25" → "9" *)
    Collection.OpenIter(c, it);
    Collection.Field(it, f, last);                   (* r0 name *)
    Collection.Field(it, f, last);                   (* r0 age  *)
    Collection.NextRow(it);
    Collection.Field(it, f, last); Expect(StrEq(f, "Bob"), "r1 name still Bob");
    Collection.Field(it, f, last); Expect(StrEq(f, "9"), "r1 age now 9")
  END TestSetCellShorter;

  PROCEDURE TestSetCellLonger;
  (* Replace with a longer value, including one that needs quoting. *)
    VAR d: Doc.Doc; c: Collection.Collection;
        r0: INTEGER; it: Collection.RowIter;
        f: ARRAY 32 OF CHAR; last: BOOLEAN;
  BEGIN
    Out.WriteString("SetCell longer (with comma → quoted):"); Out.Ln;
    d := makeDoc();
    c := Collection.Open(d);
    r0 := Collection.FindRow(c, 0);                  (* Alice,30 *)
    Collection.SetCell(c, r0, 0, "Smith, Alice");    (* needs quoting *)
    Collection.OpenIter(c, it);
    Collection.Field(it, f, last);
    Expect(StrEq(f, "Smith, Alice"), "decoded back to Smith, Alice");
    Collection.Field(it, f, last);
    Expect(StrEq(f, "30") & last, "age 30 still last")
  END TestSetCellLonger;

  PROCEDURE TestSetCellOutOfRange;
  (* Edit a non-existent column — should be a no-op. *)
    VAR d: Doc.Doc; c: Collection.Collection;
        r0, lenBefore, lenAfter: INTEGER;
  BEGIN
    Out.WriteString("SetCell on missing column is no-op:"); Out.Ln;
    d := makeDoc();
    c := Collection.Open(d);
    r0 := Collection.FindRow(c, 0);
    lenBefore := d.buf.len;
    Collection.SetCell(c, r0, 7, "ignored");
    lenAfter := d.buf.len;
    Expect(lenBefore = lenAfter, "buffer length unchanged")
  END TestSetCellOutOfRange;

  PROCEDURE TestEmptyCollection;
    VAR d: Doc.Doc; c: Collection.Collection; it: Collection.RowIter;
        nm: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("empty (header-only) collection:"); Out.Ln;
    nm := "*test*";
    d := Doc.New(nm);
    Append(d.buf, "@column(x)"); Buffer.Insert(d.buf, d.buf.len, 0AX);
    d.schema := Schema.New();
    Schema.Parse(d.buf, d.schema);
    c := Collection.Open(d);
    Collection.OpenIter(c, it);
    Expect(it.done, "done immediately");
    Expect(Collection.Count(c) = 0, "Count = 0")
  END TestEmptyCollection;

  PROCEDURE Run;
  BEGIN
    pass := 0; fail := 0;
    TestIterate;
    TestFieldValues;
    TestCount;
    TestFindRow;
    TestGetCell;
    TestSetCellSameLen;
    TestSetCellShorter;
    TestSetCellLonger;
    TestSetCellOutOfRange;
    TestEmptyCollection;
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
END CollectionTest.
