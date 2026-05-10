MODULE CsvTest;
(* Unit checks for Csv.Mod. Each test sets up a fresh Buffer, drives
   Reader / Writer through expected scenarios, and prints PASS/FAIL.
   Module body runs all tests and prints a summary line. *)

  IMPORT Out, Buffer, Csv;

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

  PROCEDURE InsertStr(b: Buffer.Buffer; VAR pos: INTEGER; s: ARRAY OF CHAR);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO
      Buffer.Insert(b, pos, s[i]); INC(pos); INC(i)
    END
  END InsertStr;

  PROCEDURE DrainAll(b: Buffer.Buffer; VAR out: ARRAY OF CHAR);
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
  END DrainAll;

  PROCEDURE TestEmptyBuffer;
    VAR b: Buffer.Buffer; cr: Csv.Reader;
  BEGIN
    Out.WriteString("empty buffer:"); Out.Ln;
    b := Buffer.New();
    Csv.OpenReader(cr, b, 0);
    Expect(cr.eof, "eof immediately");
    Expect(~cr.eor, "eor not set yet")
  END TestEmptyBuffer;

  PROCEDURE TestSingleField;
    VAR b: Buffer.Buffer; cr: Csv.Reader; pos: INTEGER;
        f: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("single field 'hello':"); Out.Ln;
    b := Buffer.New();
    pos := 0; InsertStr(b, pos, "hello");
    Csv.OpenReader(cr, b, 0);
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "hello"), "field = 'hello'");
    Expect(cr.eor, "eor at end-of-file");
    Expect(cr.eof, "eof reached")
  END TestSingleField;

  PROCEDURE TestThreeFields;
    VAR b: Buffer.Buffer; cr: Csv.Reader; pos: INTEGER;
        f: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("three fields a,b,c:"); Out.Ln;
    b := Buffer.New();
    pos := 0; InsertStr(b, pos, "a,b,c");
    Csv.OpenReader(cr, b, 0);
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "a"), "field 0 = 'a'");
    Expect(~cr.eor, "after 'a' eor false");
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "b"), "field 1 = 'b'");
    Expect(~cr.eor, "after 'b' eor false");
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "c"), "field 2 = 'c'");
    Expect(cr.eor, "after 'c' eor true")
  END TestThreeFields;

  PROCEDURE TestTwoRows;
    VAR b: Buffer.Buffer; cr: Csv.Reader; pos: INTEGER;
        f: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("two rows a,b\\nc,d:"); Out.Ln;
    b := Buffer.New();
    pos := 0; InsertStr(b, pos, "a,b");
    Buffer.Insert(b, pos, 0AX); INC(pos);
    InsertStr(b, pos, "c,d");
    Csv.OpenReader(cr, b, 0);
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "a") & ~cr.eor, "row1 field 0 = 'a'");
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "b") & cr.eor, "row1 field 1 = 'b' eor");
    Expect(~cr.eof, "not yet eof");
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "c") & ~cr.eor, "row2 field 0 = 'c'");
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "d") & cr.eor, "row2 field 1 = 'd' eor");
    Expect(cr.eof, "eof after last row")
  END TestTwoRows;

  PROCEDURE TestEmptyFields;
    VAR b: Buffer.Buffer; cr: Csv.Reader; pos: INTEGER;
        f: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("empty fields ',a,':"); Out.Ln;
    b := Buffer.New();
    pos := 0; InsertStr(b, pos, ",a,");
    Csv.OpenReader(cr, b, 0);
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "") & ~cr.eor, "field 0 empty");
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "a") & ~cr.eor, "field 1 = 'a'");
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "") & cr.eor, "field 2 empty, eor")
  END TestEmptyFields;

  PROCEDURE TestQuoted;
    VAR b: Buffer.Buffer; cr: Csv.Reader; pos: INTEGER;
        f: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("quoted with embedded comma:"); Out.Ln;
    b := Buffer.New();
    pos := 0;
    Buffer.Insert(b, pos, 22X); INC(pos);
    InsertStr(b, pos, "a,b");
    Buffer.Insert(b, pos, 22X); INC(pos);
    InsertStr(b, pos, ",c");
    Csv.OpenReader(cr, b, 0);
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "a,b"), "field 0 = 'a,b'");
    Expect(~cr.eor, "still in row");
    Csv.ReadField(cr, f);
    Expect(StrEq(f, "c"), "field 1 = 'c'");
    Expect(cr.eor, "eor at end")
  END TestQuoted;

  PROCEDURE TestQuotedEscape;
    VAR b: Buffer.Buffer; cr: Csv.Reader; pos: INTEGER;
        f: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("quoted with doubled quote:"); Out.Ln;
    b := Buffer.New();
    pos := 0;
    Buffer.Insert(b, pos, 22X); INC(pos);   (* opening " *)
    Buffer.Insert(b, pos, "a");  INC(pos);
    Buffer.Insert(b, pos, 22X); INC(pos);   (* doubled "" *)
    Buffer.Insert(b, pos, 22X); INC(pos);
    Buffer.Insert(b, pos, "b");  INC(pos);
    Buffer.Insert(b, pos, 22X); INC(pos);   (* closing " *)
    Csv.OpenReader(cr, b, 0);
    Csv.ReadField(cr, f);
    Expect(f[0] = "a", "byte 0 = 'a'");
    Expect(f[1] = 22X, "byte 1 = quote");
    Expect(f[2] = "b", "byte 2 = 'b'");
    Expect(f[3] = 0X, "null-terminated at 3")
  END TestQuotedEscape;

  PROCEDURE TestQuotedNewline;
    VAR b: Buffer.Buffer; cr: Csv.Reader; pos: INTEGER;
        f: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("quoted with embedded newline:"); Out.Ln;
    b := Buffer.New();
    pos := 0;
    Buffer.Insert(b, pos, 22X); INC(pos);
    InsertStr(b, pos, "line1");
    Buffer.Insert(b, pos, 0AX); INC(pos);
    InsertStr(b, pos, "line2");
    Buffer.Insert(b, pos, 22X); INC(pos);
    Csv.OpenReader(cr, b, 0);
    Csv.ReadField(cr, f);
    Expect(f[0] = "l", "starts with l");
    Expect(f[5] = 0AX, "embedded newline at position 5");
    Expect(cr.eor, "eor after closing quote")
  END TestQuotedNewline;

  PROCEDURE TestWriteSimple;
    VAR b: Buffer.Buffer; pos: INTEGER;
        out: ARRAY 64 OF CHAR;
  BEGIN
    Out.WriteString("write simple row a,b,c:"); Out.Ln;
    b := Buffer.New(); pos := 0;
    Csv.WriteField(b, pos, "a");
    Csv.WriteSep(b, pos);
    Csv.WriteField(b, pos, "b");
    Csv.WriteSep(b, pos);
    Csv.WriteField(b, pos, "c");
    Csv.EndRow(b, pos);
    DrainAll(b, out);
    Expect(out[0]="a", "starts a");
    Expect(out[1]=",", "comma");
    Expect(out[2]="b", "b");
    Expect(out[4]="c", "c");
    Expect(out[5]=0AX, "ends with newline")
  END TestWriteSimple;

  PROCEDURE TestWriteQuoting;
  (* Field with comma must be quoted; field with quote gets the quote
     doubled. *)
    VAR b: Buffer.Buffer; pos: INTEGER;
        out: ARRAY 64 OF CHAR;
        in: ARRAY 8 OF CHAR;
  BEGIN
    Out.WriteString("write quoting:"); Out.Ln;
    b := Buffer.New(); pos := 0;
    Csv.WriteField(b, pos, "a,b");        (* needs quoting *)
    DrainAll(b, out);
    Expect(out[0] = 22X, "leading quote");
    Expect(out[1] = "a", "a");
    Expect(out[2] = ",", "embedded comma");
    Expect(out[3] = "b", "b");
    Expect(out[4] = 22X, "trailing quote");
    Expect(out[5] = 0X, "ends after 5 bytes");

    (* Build input "a\"b" as a CHAR array since literals can't span
       across CHR codes. *)
    in[0] := "a"; in[1] := 22X; in[2] := "b"; in[3] := 0X;
    b := Buffer.New(); pos := 0;
    Csv.WriteField(b, pos, in);           (* embedded quote *)
    DrainAll(b, out);
    Expect(out[0] = 22X, "wrap open");
    Expect(out[1] = "a", "a");
    Expect(out[2] = 22X, "doubled 1");
    Expect(out[3] = 22X, "doubled 2");
    Expect(out[4] = "b", "b");
    Expect(out[5] = 22X, "wrap close");
    Expect(out[6] = 0X, "ends after 6 bytes")
  END TestWriteQuoting;

  PROCEDURE TestRoundtrip;
  (* Write two rows with varied content, then read back and check
     each field. *)
    VAR b: Buffer.Buffer; cr: Csv.Reader; pos: INTEGER;
        f: ARRAY 64 OF CHAR;
        embedded: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("write/read round-trip:"); Out.Ln;
    (* Build "she said \"hi\"" — a string with embedded quotes. *)
    embedded[0]  := "s"; embedded[1] := "h"; embedded[2] := "e";
    embedded[3]  := " "; embedded[4] := "s"; embedded[5] := "a";
    embedded[6]  := "i"; embedded[7] := "d"; embedded[8] := " ";
    embedded[9]  := 22X; embedded[10] := "h"; embedded[11] := "i";
    embedded[12] := 22X; embedded[13] := 0X;

    b := Buffer.New(); pos := 0;
    Csv.WriteField(b, pos, "Alice"); Csv.WriteSep(b, pos);
    Csv.WriteField(b, pos, "30");    Csv.WriteSep(b, pos);
    Csv.WriteField(b, pos, embedded);
    Csv.EndRow(b, pos);
    Csv.WriteField(b, pos, "Bob");   Csv.WriteSep(b, pos);
    Csv.WriteField(b, pos, "25");    Csv.WriteSep(b, pos);
    Csv.WriteField(b, pos, "");
    Csv.EndRow(b, pos);

    Csv.OpenReader(cr, b, 0);
    Csv.ReadField(cr, f); Expect(StrEq(f, "Alice"), "Alice");
    Csv.ReadField(cr, f); Expect(StrEq(f, "30"), "30");
    Csv.ReadField(cr, f); Expect(StrEq(f, embedded), "embedded quote field round-trips");
    Expect(cr.eor, "row1 eor");
    Csv.ReadField(cr, f); Expect(StrEq(f, "Bob"), "Bob");
    Csv.ReadField(cr, f); Expect(StrEq(f, "25"), "25");
    Csv.ReadField(cr, f); Expect(StrEq(f, "") & cr.eor, "empty trailing field, eor");
    Expect(cr.eof, "round-trip ends at eof")
  END TestRoundtrip;

  PROCEDURE Run;
  BEGIN
    pass := 0; fail := 0;
    TestEmptyBuffer;
    TestSingleField;
    TestThreeFields;
    TestTwoRows;
    TestEmptyFields;
    TestQuoted;
    TestQuotedEscape;
    TestQuotedNewline;
    TestWriteSimple;
    TestWriteQuoting;
    TestRoundtrip;
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
END CsvTest.
