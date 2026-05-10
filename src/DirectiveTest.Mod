MODULE DirectiveTest;
(* Unit checks for Directive.Mod. Each test sets up a fresh Buffer
   containing a directive header line, parses it, and inspects the
   resulting Directive AST. *)

  IMPORT Out, Buffer, Directive;

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

  PROCEDURE Load(b: Buffer.Buffer; s: ARRAY OF CHAR);
  (* Append s to the end of b. *)
    VAR i, pos: INTEGER;
  BEGIN
    pos := b.len; i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO
      Buffer.Insert(b, pos, s[i]); INC(pos); INC(i)
    END
  END Load;

  PROCEDURE TestNoArgs;
    VAR b: Buffer.Buffer; d: Directive.Directive; ok: BOOLEAN; ep: INTEGER;
  BEGIN
    Out.WriteString("@col():"); Out.Ln;
    b := Buffer.New(); Load(b, "@col()");
    Directive.Parse(b, 0, d, ok, ep);
    Expect(ok, "ok");
    Expect(StrEq(d.name, "col"), "name = col");
    Expect(d.narg = 0, "narg = 0");
    Expect(ep = 6, "endPos = 6")
  END TestNoArgs;

  PROCEDURE TestBareIdent;
    VAR b: Buffer.Buffer; d: Directive.Directive; ok: BOOLEAN; ep: INTEGER;
  BEGIN
    Out.WriteString("@col(name):"); Out.Ln;
    b := Buffer.New(); Load(b, "@col(name)");
    Directive.Parse(b, 0, d, ok, ep);
    Expect(ok, "ok");
    Expect(d.narg = 1, "narg = 1");
    Expect(d.args[0].kind = Directive.AIdent, "kind ident");
    Expect(~d.args[0].isBinding, "not binding");
    Expect(StrEq(d.args[0].str, "name"), "value = name")
  END TestBareIdent;

  PROCEDURE TestString;
    VAR b: Buffer.Buffer; d: Directive.Directive; ok: BOOLEAN; ep: INTEGER;
  BEGIN
    Out.WriteString("@col(...string-arg...):"); Out.Ln;
    b := Buffer.New();
    Load(b, "@col(");
    Buffer.Insert(b, b.len, 22X);                      (* opening quote *)
    Load(b, "hello");
    Buffer.Insert(b, b.len, 22X);                      (* closing quote *)
    Load(b, ")");
    Directive.Parse(b, 0, d, ok, ep);
    Expect(ok, "ok");
    Expect(d.narg = 1, "narg = 1");
    Expect(d.args[0].kind = Directive.AString, "kind string");
    Expect(StrEq(d.args[0].str, "hello"), "value = hello")
  END TestString;

  PROCEDURE TestInt;
    VAR b: Buffer.Buffer; d: Directive.Directive; ok: BOOLEAN; ep: INTEGER;
  BEGIN
    Out.WriteString("@col(80):"); Out.Ln;
    b := Buffer.New(); Load(b, "@col(80)");
    Directive.Parse(b, 0, d, ok, ep);
    Expect(ok, "ok");
    Expect(d.args[0].kind = Directive.AInt, "kind int");
    Expect(d.args[0].int = 80, "value = 80")
  END TestInt;

  PROCEDURE TestNegInt;
    VAR b: Buffer.Buffer; d: Directive.Directive; ok: BOOLEAN; ep: INTEGER;
  BEGIN
    Out.WriteString("@col(-3):"); Out.Ln;
    b := Buffer.New(); Load(b, "@col(-3)");
    Directive.Parse(b, 0, d, ok, ep);
    Expect(ok, "ok");
    Expect(d.args[0].kind = Directive.AInt, "kind int");
    Expect(d.args[0].int = -3, "value = -3")
  END TestNegInt;

  PROCEDURE TestBinding;
    VAR b: Buffer.Buffer; d: Directive.Directive; ok: BOOLEAN; ep: INTEGER;
  BEGIN
    Out.WriteString("@col(width=80):"); Out.Ln;
    b := Buffer.New(); Load(b, "@col(width=80)");
    Directive.Parse(b, 0, d, ok, ep);
    Expect(ok, "ok");
    Expect(d.narg = 1, "narg = 1");
    Expect(d.args[0].isBinding, "is binding");
    Expect(StrEq(d.args[0].key, "width"), "key = width");
    Expect(d.args[0].kind = Directive.AInt, "value kind int");
    Expect(d.args[0].int = 80, "value = 80")
  END TestBinding;

  PROCEDURE TestColumn;
  (* @column(name, "Label", text, 80) — the canonical schema entry. *)
    VAR b: Buffer.Buffer; d: Directive.Directive; ok: BOOLEAN; ep: INTEGER;
  BEGIN
    Out.WriteString("@column(name, ...Label..., text, 80):"); Out.Ln;
    b := Buffer.New();
    Load(b, "@column(name, ");
    Buffer.Insert(b, b.len, 22X);
    Load(b, "Label");
    Buffer.Insert(b, b.len, 22X);
    Load(b, ", text, 80)");
    Directive.Parse(b, 0, d, ok, ep);
    Expect(ok, "ok");
    Expect(StrEq(d.name, "column"), "name");
    Expect(d.narg = 4, "narg = 4");
    Expect(d.args[0].kind = Directive.AIdent, "0 ident");
    Expect(StrEq(d.args[0].str, "name"), "0 = name");
    Expect(d.args[1].kind = Directive.AString, "1 string");
    Expect(StrEq(d.args[1].str, "Label"), "1 = Label");
    Expect(d.args[2].kind = Directive.AIdent, "2 ident");
    Expect(StrEq(d.args[2].str, "text"), "2 = text");
    Expect(d.args[3].kind = Directive.AInt, "3 int");
    Expect(d.args[3].int = 80, "3 = 80")
  END TestColumn;

  PROCEDURE TestEscapedQuote;
  (* @col("she said \"hi\"") *)
    VAR b: Buffer.Buffer; d: Directive.Directive; ok: BOOLEAN; ep: INTEGER;
  BEGIN
    Out.WriteString("string with backslash-escaped quote:"); Out.Ln;
    b := Buffer.New();
    Load(b, "@col(");
    Buffer.Insert(b, b.len, 22X);                  (* open " *)
    Load(b, "she said ");
    Buffer.Insert(b, b.len, 5CX);                  (* \  *)
    Buffer.Insert(b, b.len, 22X);                  (* "  *)
    Load(b, "hi");
    Buffer.Insert(b, b.len, 5CX);
    Buffer.Insert(b, b.len, 22X);
    Buffer.Insert(b, b.len, 22X);                  (* closing " *)
    Load(b, ")");
    Directive.Parse(b, 0, d, ok, ep);
    Expect(ok, "ok");
    Expect(d.args[0].kind = Directive.AString, "string");
    Expect(d.args[0].str[0]  = "s", "starts s");
    Expect(d.args[0].str[9]  = 22X, "embedded quote");
    Expect(d.args[0].str[12] = 22X, "second quote");
    Expect(d.args[0].str[13] = 0X, "13 chars then null")
  END TestEscapedQuote;

  PROCEDURE TestWhitespace;
    VAR b: Buffer.Buffer; d: Directive.Directive; ok: BOOLEAN; ep: INTEGER;
  BEGIN
    Out.WriteString("  @col( a , b ):"); Out.Ln;
    b := Buffer.New(); Load(b, "  @col( a , b )");
    Directive.Parse(b, 0, d, ok, ep);
    Expect(ok, "ok");
    Expect(StrEq(d.name, "col"), "name");
    Expect(d.narg = 2, "narg = 2");
    Expect(StrEq(d.args[0].str, "a"), "0 = a");
    Expect(StrEq(d.args[1].str, "b"), "1 = b")
  END TestWhitespace;

  PROCEDURE TestErrorMissingParen;
    VAR b: Buffer.Buffer; d: Directive.Directive; ok: BOOLEAN; ep: INTEGER;
  BEGIN
    Out.WriteString("@col without parens:"); Out.Ln;
    b := Buffer.New(); Load(b, "@col");
    Directive.Parse(b, 0, d, ok, ep);
    Expect(~ok, "rejected")
  END TestErrorMissingParen;

  PROCEDURE TestErrorNoAt;
    VAR b: Buffer.Buffer; d: Directive.Directive; ok: BOOLEAN; ep: INTEGER;
  BEGIN
    Out.WriteString("missing leading @:"); Out.Ln;
    b := Buffer.New(); Load(b, "col(x)");
    Directive.Parse(b, 0, d, ok, ep);
    Expect(~ok, "rejected")
  END TestErrorNoAt;

  PROCEDURE TestErrorUnclosed;
    VAR b: Buffer.Buffer; d: Directive.Directive; ok: BOOLEAN; ep: INTEGER;
  BEGIN
    Out.WriteString("missing closing paren:"); Out.Ln;
    b := Buffer.New(); Load(b, "@col(a, b");
    Directive.Parse(b, 0, d, ok, ep);
    Expect(~ok, "rejected")
  END TestErrorUnclosed;

  PROCEDURE Run;
  BEGIN
    pass := 0; fail := 0;
    TestNoArgs;
    TestBareIdent;
    TestString;
    TestInt;
    TestNegInt;
    TestBinding;
    TestColumn;
    TestEscapedQuote;
    TestWhitespace;
    TestErrorMissingParen;
    TestErrorNoAt;
    TestErrorUnclosed;
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
END DirectiveTest.
