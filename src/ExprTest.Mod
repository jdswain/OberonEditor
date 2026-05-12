MODULE ExprTest;
(* Behavioural checks for Expr.Mod. Each test builds a Buffer with
   the expression text, evaluates it (sometimes with a test scope
   that resolves a couple of columns / prompts), and asserts on the
   resulting Value. *)

  IMPORT Out, Buffer, Expr;

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

  PROCEDURE Append(b: Buffer.Buffer; s: ARRAY OF CHAR);
    VAR i, pos: INTEGER;
  BEGIN
    pos := b.len; i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO
      Buffer.Insert(b, pos, s[i]); INC(pos); INC(i)
    END
  END Append;

  PROCEDURE AppendQ(b: Buffer.Buffer; s: ARRAY OF CHAR);
  (* Append s as a quoted string literal — wraps with " on each side. *)
  BEGIN
    Buffer.Insert(b, b.len, 22X);
    Append(b, s);
    Buffer.Insert(b, b.len, 22X)
  END AppendQ;

  PROCEDURE StrEq(VAR a, b: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (a[i] # 0X) & (a[i] = b[i]) DO INC(i) END;
    RETURN a[i] = b[i]
  END StrEq;

  (* Test scope: column "x" → 5, "y" → "hello"; prompt "name" → "Alice". *)

  PROCEDURE testCol(name: ARRAY OF CHAR; VAR v: Expr.Value);
  BEGIN
    IF (name[0] = "x") & (name[1] = 0X) THEN
      v.kind := Expr.VInt; v.int := 5
    ELSIF (name[0] = "y") & (name[1] = 0X) THEN
      v.kind := Expr.VString;
      v.str[0] := "h"; v.str[1] := "e"; v.str[2] := "l";
      v.str[3] := "l"; v.str[4] := "o"; v.str[5] := 0X
    ELSE
      v.kind := Expr.VError
    END
  END testCol;

  PROCEDURE testPrompt(name: ARRAY OF CHAR; VAR v: Expr.Value);
  BEGIN
    IF (name[0] = "n") & (name[1] = "a") & (name[2] = "m") & (name[3] = "e")
        & (name[4] = 0X) THEN
      v.kind := Expr.VString;
      v.str[0] := "A"; v.str[1] := "l"; v.str[2] := "i";
      v.str[3] := "c"; v.str[4] := "e"; v.str[5] := 0X
    ELSE
      v.kind := Expr.VError
    END
  END testPrompt;

  (* Build a Buffer from expr, evaluate (no scope), return the Value. *)
  PROCEDURE evalNoScope(expr: ARRAY OF CHAR; VAR v: Expr.Value);
    VAR b: Buffer.Buffer; ep: INTEGER; sc: Expr.Scope;
  BEGIN
    b := Buffer.New();
    Append(b, expr);
    sc.col := NIL; sc.prompt := NIL;
    Expr.Eval(b, 0, sc, v, ep)
  END evalNoScope;

  PROCEDURE evalWithScope(VAR b: Buffer.Buffer; VAR v: Expr.Value);
    VAR ep: INTEGER; sc: Expr.Scope;
  BEGIN
    sc.col := testCol; sc.prompt := testPrompt;
    Expr.Eval(b, 0, sc, v, ep)
  END evalWithScope;

  PROCEDURE expectInt(expr: ARRAY OF CHAR; want: INTEGER; VAR name: ARRAY OF CHAR);
    VAR v: Expr.Value;
  BEGIN
    evalNoScope(expr, v);
    Expect((v.kind = Expr.VInt) & (v.int = want), name)
  END expectInt;

  PROCEDURE expectBool(expr: ARRAY OF CHAR; want: BOOLEAN; VAR name: ARRAY OF CHAR);
    VAR v: Expr.Value;
  BEGIN
    evalNoScope(expr, v);
    Expect((v.kind = Expr.VBool) & (v.bool = want), name)
  END expectBool;

  PROCEDURE expectError(expr: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
    VAR v: Expr.Value;
  BEGIN
    evalNoScope(expr, v);
    Expect(v.kind = Expr.VError, name)
  END expectError;

  PROCEDURE TestLiterals;
    VAR v: Expr.Value; lbl: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("literals:"); Out.Ln;
    lbl := "42";    expectInt("42", 42, lbl);
    lbl := "0";     expectInt("0", 0, lbl);
    lbl := "true";  expectBool("true", TRUE, lbl);
    lbl := "false"; expectBool("false", FALSE, lbl);
    evalNoScope("nil", v);
    lbl := "nil";   Expect(v.kind = Expr.VNil, lbl)
  END TestLiterals;

  PROCEDURE TestArith;
    VAR lbl: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("arithmetic:"); Out.Ln;
    lbl := "1 + 2";       expectInt("1 + 2", 3, lbl);
    lbl := "10 - 3";      expectInt("10 - 3", 7, lbl);
    lbl := "2 * 3";       expectInt("2 * 3", 6, lbl);
    lbl := "10 / 3";      expectInt("10 / 3", 3, lbl);
    lbl := "1 + 2 * 3";   expectInt("1 + 2 * 3", 7, lbl);
    lbl := "(1+2) * 3";   expectInt("(1 + 2) * 3", 9, lbl);
    lbl := "-5";          expectInt("-5", -5, lbl);
    lbl := "-3 + 4";      expectInt("-3 + 4", 1, lbl);
    lbl := "10 / 0 → err";expectError("10 / 0", lbl)
  END TestArith;

  PROCEDURE TestCompare;
    VAR lbl: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("comparison:"); Out.Ln;
    lbl := "1 = 1";      expectBool("1 = 1", TRUE, lbl);
    lbl := "1 = 2";      expectBool("1 = 2", FALSE, lbl);
    lbl := "1 # 2";      expectBool("1 # 2", TRUE, lbl);
    lbl := "1 < 2";      expectBool("1 < 2", TRUE, lbl);
    lbl := "2 < 2";      expectBool("2 < 2", FALSE, lbl);
    lbl := "2 <= 2";     expectBool("2 <= 2", TRUE, lbl);
    lbl := "3 > 2";      expectBool("3 > 2", TRUE, lbl);
    lbl := "3 >= 3";     expectBool("3 >= 3", TRUE, lbl);
    lbl := "2 >= 3";     expectBool("2 >= 3", FALSE, lbl)
  END TestCompare;

  PROCEDURE TestLogic;
    VAR lbl: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("logic:"); Out.Ln;
    lbl := "true and false";   expectBool("true and false", FALSE, lbl);
    lbl := "true and true";    expectBool("true and true", TRUE, lbl);
    lbl := "true or false";    expectBool("true or false", TRUE, lbl);
    lbl := "false or false";   expectBool("false or false", FALSE, lbl);
    lbl := "not true";         expectBool("not true", FALSE, lbl);
    lbl := "not false";        expectBool("not false", TRUE, lbl);
    lbl := "compound chain";   expectBool("(1<2) and (3>1) or false", TRUE, lbl)
  END TestLogic;

  PROCEDURE TestBuiltins;
    VAR b: Buffer.Buffer; v: Expr.Value; ep: INTEGER; sc: Expr.Scope;
        lbl: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("built-ins:"); Out.Ln;
    lbl := "if(true, 1, 2)";   expectInt("if(true, 1, 2)", 1, lbl);
    lbl := "if(false, 1, 2)";  expectInt("if(false, 1, 2)", 2, lbl);
    lbl := "not(true)";        expectBool("not(true)", FALSE, lbl);

    sc.col := NIL; sc.prompt := NIL;
    b := Buffer.New();
    Append(b, "len("); AppendQ(b, "hello"); Append(b, ")");
    Expr.Eval(b, 0, sc, v, ep);
    lbl := "len(...) = 5"; Expect((v.kind = Expr.VInt) & (v.int = 5), lbl);

    b := Buffer.New();
    Append(b, "concat(");
    AppendQ(b, "Hello, "); Append(b, ", "); AppendQ(b, "World");
    Append(b, ")");
    Expr.Eval(b, 0, sc, v, ep);
    lbl := "concat result";
    Expect((v.kind = Expr.VString)
           & (v.str[0]="H") & (v.str[6]=" ") & (v.str[11]="d") & (v.str[12]=0X),
           lbl);

    b := Buffer.New();
    Append(b, "int("); AppendQ(b, "42"); Append(b, ")");
    Expr.Eval(b, 0, sc, v, ep);
    lbl := "int(...string) = 42";
    Expect((v.kind = Expr.VInt) & (v.int = 42), lbl);

    b := Buffer.New();
    Append(b, "int("); AppendQ(b, "x42"); Append(b, ")");
    Expr.Eval(b, 0, sc, v, ep);
    lbl := "int(bad) → err";
    Expect(v.kind = Expr.VError, lbl)
  END TestBuiltins;

  PROCEDURE TestColRef;
    VAR b: Buffer.Buffer; v: Expr.Value;
        lbl: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("column refs:"); Out.Ln;
    b := Buffer.New(); Append(b, "x + 1");
    evalWithScope(b, v);
    lbl := "x + 1 = 6";
    Expect((v.kind = Expr.VInt) & (v.int = 6), lbl);

    b := Buffer.New(); Append(b, "c[x] * 2");
    evalWithScope(b, v);
    lbl := "c[x] * 2 = 10";
    Expect((v.kind = Expr.VInt) & (v.int = 10), lbl);

    b := Buffer.New(); Append(b, "z");
    evalWithScope(b, v);
    lbl := "undefined → err";
    Expect(v.kind = Expr.VError, lbl);

    (* Reserved-word column accessed via c[true] *)
    b := Buffer.New(); Append(b, "c[true]");
    evalWithScope(b, v);
    lbl := "c[true] → undefined → err";
    Expect(v.kind = Expr.VError, lbl)
  END TestColRef;

  PROCEDURE TestPromptRef;
    VAR b: Buffer.Buffer; v: Expr.Value;
        lbl: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("prompt refs:"); Out.Ln;
    b := Buffer.New(); Append(b, "$name");
    evalWithScope(b, v);
    lbl := "$name = Alice";
    Expect((v.kind = Expr.VString)
           & (v.str[0]="A") & (v.str[4]="e") & (v.str[5]=0X),
           lbl);

    b := Buffer.New(); Append(b, "$missing");
    evalWithScope(b, v);
    lbl := "$missing → err";
    Expect(v.kind = Expr.VError, lbl)
  END TestPromptRef;

  PROCEDURE TestStringCompare;
    VAR b: Buffer.Buffer; v: Expr.Value;
        lbl: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("string compare:"); Out.Ln;
    b := Buffer.New();
    AppendQ(b, "abc"); Append(b, " = "); AppendQ(b, "abc");
    evalNoScope("placeholder", v);          (* warm up *)
    evalWithScope(b, v);
    lbl := "abc = abc";
    Expect((v.kind = Expr.VBool) & v.bool, lbl);

    b := Buffer.New();
    AppendQ(b, "abc"); Append(b, " < "); AppendQ(b, "abd");
    evalWithScope(b, v);
    lbl := "abc < abd";
    Expect((v.kind = Expr.VBool) & v.bool, lbl)
  END TestStringCompare;

  PROCEDURE TestErrorPropagation;
    VAR lbl: ARRAY 32 OF CHAR;
  BEGIN
    Out.WriteString("error propagation:"); Out.Ln;
    lbl := "true + 1 → err";     expectError("true + 1", lbl);
    lbl := "1 = true → err";     expectError("1 = true", lbl);
    lbl := "unmatched paren";    expectError("(1+2", lbl);
    lbl := "lone +";             expectError("+", lbl)
  END TestErrorPropagation;

  PROCEDURE Run;
  BEGIN
    pass := 0; fail := 0;
    TestLiterals;
    TestArith;
    TestCompare;
    TestLogic;
    TestBuiltins;
    TestColRef;
    TestPromptRef;
    TestStringCompare;
    TestErrorPropagation;
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
END ExprTest.
