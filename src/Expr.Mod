MODULE Expr;
(* Expression parser + evaluator. Walks a Buffer.Buffer at a given
   byte offset, parses and evaluates the smallest expression the
   grammar will accept, and writes the result into a Value record.

   Grammar (subset of DDR §5; selector chains, cell refs, and range
   refs are reserved for later steps):

       expr     = orExpr
       orExpr   = andExpr  { 'or' andExpr }
       andExpr  = relExpr  { 'and' relExpr }
       relExpr  = addExpr  [ relop addExpr ]
       addExpr  = mulExpr  { ('+' | '-') mulExpr }
       mulExpr  = unary    { ('*' | '/') unary }
       unary    = ['-' | 'not'] factor
       factor   = literal | colExpr | promptref | funcCall | '(' expr ')'
       relop    = '=' | '#' | '<' | '<=' | '>' | '>='
       colExpr  = name | 'c' '[' name ']'
       promptref= '$' name
       funcCall = name '(' [ expr { ',' expr } ] ')'

   `and`, `or`, `not`, `true`, `false`, `nil` are reserved. To use one
   of these names as a column, the caller must write `c[name]`.

   Identifiers / prompts resolve via a Scope callback bundle. A NIL
   field in Scope means "no resolver" — references then evaluate to
   VError. Built-in functions are dispatched internally. *)

  IMPORT Buffer;

  CONST
    VInt*     = 0;
    VString*  = 1;
    VBool*    = 2;
    VNil*     = 3;
    VError*   = 4;

    MaxStr*   = 256;

    MaxIdent       = 64;
    MaxBuiltinArgs = 8;

    (* token kinds *)
    TEOF       = 0;
    TInt       = 1;  TString   = 2;  TIdent    = 3;
    TLParen    = 4;  TRParen   = 5;
    TLBrack    = 6;  TRBrack   = 7;
    TComma     = 8;
    TPlus      = 10; TMinus    = 11; TStar     = 12; TSlash = 13;
    TEq        = 14; THash     = 15;
    TLess      = 16; TLessEq   = 17; TGreater  = 18; TGreaterEq = 19;
    TAnd       = 20; TOr       = 21; TNot      = 22;
    TTrue      = 23; TFalse    = 24; TNil      = 25;
    TDollar    = 26;
    TErr       = 27;

    NL     = 0AX;
    TAB    = 9X;
    QUOTE  = 22X;
    BACKSL = 5CX;

  TYPE
    Value* = RECORD
      kind*: INTEGER;
      int*:  INTEGER;
      str*:  ARRAY MaxStr OF CHAR;
      bool*: BOOLEAN
    END;

    Resolver* = PROCEDURE(name: ARRAY OF CHAR; VAR v: Value);

    Scope* = RECORD
      col*:    Resolver;
      prompt*: Resolver
    END;

    state = RECORD
      r:       Buffer.Reader;
      ch:      CHAR;
      pos:     INTEGER;
      eof:     BOOLEAN;
      tok:     INTEGER;
      tokInt:  INTEGER;
      tokStr:  ARRAY MaxStr OF CHAR;
      scope:   Scope
    END;

    Parser = PROCEDURE(VAR s: state; VAR v: Value);

  VAR
    (* Oberon-07 has no forward declarations. To resolve the mutual
       recursion between `factor` (for `( expr )` and function args)
       and `orExpr`, a module-level procedure variable holds the
       reference; the module body binds it after both are declared. *)
    orExprFn: Parser;

  PROCEDURE setError(VAR v: Value);
  BEGIN
    v.kind := VError; v.int := 0; v.bool := FALSE; v.str[0] := 0X
  END setError;

  PROCEDURE setInt(VAR v: Value; n: INTEGER);
  BEGIN
    v.kind := VInt; v.int := n
  END setInt;

  PROCEDURE setBool(VAR v: Value; b: BOOLEAN);
  BEGIN
    v.kind := VBool; v.bool := b
  END setBool;

  PROCEDURE setString(VAR v: Value; s: ARRAY OF CHAR);
    VAR i: INTEGER;
  BEGIN
    v.kind := VString;
    i := 0;
    WHILE (i < MaxStr - 1) & (i < LEN(s)) & (s[i] # 0X) DO
      v.str[i] := s[i]; INC(i)
    END;
    v.str[i] := 0X
  END setString;

  PROCEDURE copyStr(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(dst) - 1) & (i < LEN(src)) & (src[i] # 0X) DO
      dst[i] := src[i]; INC(i)
    END;
    dst[i] := 0X
  END copyStr;

  PROCEDURE strLen(s: ARRAY OF CHAR): INTEGER;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
    RETURN i
  END strLen;

  PROCEDURE strEq(a, b: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (a[i] # 0X) & (a[i] = b[i]) DO INC(i) END;
    RETURN a[i] = b[i]
  END strEq;

  PROCEDURE strLess(a, b: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (a[i] # 0X) & (a[i] = b[i]) DO INC(i) END;
    RETURN ORD(a[i]) < ORD(b[i])
  END strLess;

  (* ---------------- lexer ---------------- *)

  PROCEDURE step(VAR s: state);
  BEGIN
    IF ~s.eof THEN
      Buffer.Read(s.r, s.ch);
      IF s.r.eot THEN s.eof := TRUE END;
      INC(s.pos)
    END
  END step;

  PROCEDURE isAlpha(ch: CHAR): BOOLEAN;
  BEGIN
    RETURN ((ch >= "A") & (ch <= "Z"))
        OR ((ch >= "a") & (ch <= "z"))
        OR (ch = "_")
  END isAlpha;

  PROCEDURE isDigit(ch: CHAR): BOOLEAN;
  BEGIN RETURN (ch >= "0") & (ch <= "9")
  END isDigit;

  PROCEDURE skipWS(VAR s: state);
  BEGIN
    WHILE ~s.eof & ((s.ch = " ") OR (s.ch = TAB) OR (s.ch = NL)) DO
      step(s)
    END
  END skipWS;

  PROCEDURE readIdent(VAR s: state);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE ~s.eof & (isAlpha(s.ch) OR isDigit(s.ch)) DO
      IF i < LEN(s.tokStr) - 1 THEN s.tokStr[i] := s.ch; INC(i) END;
      step(s)
    END;
    s.tokStr[i] := 0X
  END readIdent;

  PROCEDURE readInt(VAR s: state);
  BEGIN
    s.tokInt := 0;
    WHILE ~s.eof & isDigit(s.ch) DO
      s.tokInt := s.tokInt * 10 + (ORD(s.ch) - ORD("0"));
      step(s)
    END
  END readInt;

  PROCEDURE readStringLit(VAR s: state);
  (* Caller has seen the opening QUOTE. Reads through the closing
     QUOTE, treating \" and \\ as literal quote / backslash. *)
    VAR i: INTEGER; done: BOOLEAN;
  BEGIN
    step(s);              (* past opening " *)
    i := 0; done := FALSE;
    WHILE ~done DO
      IF s.eof THEN done := TRUE; s.tok := TErr
      ELSIF s.ch = BACKSL THEN
        step(s);
        IF s.eof THEN done := TRUE; s.tok := TErr
        ELSE
          IF i < LEN(s.tokStr) - 1 THEN s.tokStr[i] := s.ch; INC(i) END;
          step(s)
        END
      ELSIF s.ch = QUOTE THEN
        step(s); done := TRUE
      ELSE
        IF i < LEN(s.tokStr) - 1 THEN s.tokStr[i] := s.ch; INC(i) END;
        step(s)
      END
    END;
    s.tokStr[i] := 0X
  END readStringLit;

  PROCEDURE classifyIdent(VAR s: state);
  (* After readIdent populates s.tokStr, decide whether the ident is
     a reserved word and adjust s.tok. *)
  BEGIN
    IF    strEq(s.tokStr, "and")   THEN s.tok := TAnd
    ELSIF strEq(s.tokStr, "or")    THEN s.tok := TOr
    ELSIF strEq(s.tokStr, "not")   THEN s.tok := TNot
    ELSIF strEq(s.tokStr, "true")  THEN s.tok := TTrue
    ELSIF strEq(s.tokStr, "false") THEN s.tok := TFalse
    ELSIF strEq(s.tokStr, "nil")   THEN s.tok := TNil
    ELSE                                s.tok := TIdent
    END
  END classifyIdent;

  PROCEDURE next(VAR s: state);
  (* Advance to the next token. *)
  BEGIN
    skipWS(s);
    IF s.eof THEN s.tok := TEOF
    ELSIF isDigit(s.ch) THEN
      s.tok := TInt;
      readInt(s)
    ELSIF isAlpha(s.ch) THEN
      readIdent(s);
      classifyIdent(s)
    ELSIF s.ch = QUOTE THEN
      s.tok := TString;
      readStringLit(s)
    ELSIF s.ch = "(" THEN s.tok := TLParen;  step(s)
    ELSIF s.ch = ")" THEN s.tok := TRParen;  step(s)
    ELSIF s.ch = "[" THEN s.tok := TLBrack;  step(s)
    ELSIF s.ch = "]" THEN s.tok := TRBrack;  step(s)
    ELSIF s.ch = "," THEN s.tok := TComma;   step(s)
    ELSIF s.ch = "+" THEN s.tok := TPlus;    step(s)
    ELSIF s.ch = "-" THEN s.tok := TMinus;   step(s)
    ELSIF s.ch = "*" THEN s.tok := TStar;    step(s)
    ELSIF s.ch = "/" THEN s.tok := TSlash;   step(s)
    ELSIF s.ch = "=" THEN s.tok := TEq;      step(s)
    ELSIF s.ch = "#" THEN s.tok := THash;    step(s)
    ELSIF s.ch = "$" THEN s.tok := TDollar;  step(s)
    ELSIF s.ch = "<" THEN
      step(s);
      IF ~s.eof & (s.ch = "=") THEN s.tok := TLessEq; step(s)
      ELSE s.tok := TLess
      END
    ELSIF s.ch = ">" THEN
      step(s);
      IF ~s.eof & (s.ch = "=") THEN s.tok := TGreaterEq; step(s)
      ELSE s.tok := TGreater
      END
    ELSE
      s.tok := TErr; step(s)
    END
  END next;

  PROCEDURE openLex(VAR s: state; b: Buffer.Buffer; pos: INTEGER);
  BEGIN
    Buffer.OpenReader(s.r, b, pos);
    s.pos := pos; s.eof := FALSE;
    Buffer.Read(s.r, s.ch);
    IF s.r.eot THEN s.eof := TRUE END;
    next(s)
  END openLex;

  (* ---------------- coercions / type helpers ---------------- *)

  PROCEDURE asBool(VAR v: Value): BOOLEAN;
    VAR r: BOOLEAN;
  BEGIN
    IF v.kind = VBool THEN r := v.bool
    ELSE r := FALSE                  (* non-bool in bool context — treat as false *)
    END;
    RETURN r
  END asBool;

  PROCEDURE eitherError(VAR a, b: Value): BOOLEAN;
  BEGIN
    RETURN (a.kind = VError) OR (b.kind = VError)
  END eitherError;

  (* ---------------- built-ins ---------------- *)

  PROCEDURE builtinIf(VAR args: ARRAY OF Value; n: INTEGER; VAR r: Value);
  BEGIN
    IF n # 3 THEN setError(r)
    ELSIF args[0].kind = VError THEN setError(r)
    ELSIF args[0].kind # VBool THEN setError(r)
    ELSIF args[0].bool THEN r := args[1]
    ELSE r := args[2]
    END
  END builtinIf;

  PROCEDURE builtinNot(VAR args: ARRAY OF Value; n: INTEGER; VAR r: Value);
  BEGIN
    IF (n # 1) OR (args[0].kind # VBool) THEN setError(r)
    ELSE setBool(r, ~args[0].bool)
    END
  END builtinNot;

  PROCEDURE builtinLen(VAR args: ARRAY OF Value; n: INTEGER; VAR r: Value);
  BEGIN
    IF (n # 1) OR (args[0].kind # VString) THEN setError(r)
    ELSE setInt(r, strLen(args[0].str))
    END
  END builtinLen;

  PROCEDURE builtinConcat(VAR args: ARRAY OF Value; n: INTEGER; VAR r: Value);
    VAR i, j, k: INTEGER; bad: BOOLEAN; out: ARRAY MaxStr OF CHAR;
  BEGIN
    i := 0; j := 0; bad := FALSE;
    WHILE ~bad & (i < n) & (j < MaxStr - 1) DO
      IF args[i].kind # VString THEN
        bad := TRUE
      ELSE
        k := 0;
        WHILE (k < LEN(args[i].str)) & (args[i].str[k] # 0X) & (j < MaxStr - 1) DO
          out[j] := args[i].str[k]; INC(j); INC(k)
        END
      END;
      INC(i)
    END;
    IF bad THEN setError(r)
    ELSE out[j] := 0X; setString(r, out)
    END
  END builtinConcat;

  PROCEDURE digitVal(ch: CHAR): INTEGER;
  BEGIN RETURN ORD(ch) - ORD("0")
  END digitVal;

  PROCEDURE builtinInt(VAR args: ARRAY OF Value; n: INTEGER; VAR r: Value);
    VAR i, val: INTEGER; neg, ok: BOOLEAN; s: ARRAY MaxStr OF CHAR;
  BEGIN
    IF n # 1 THEN setError(r)
    ELSIF args[0].kind = VInt THEN setInt(r, args[0].int)
    ELSIF args[0].kind = VString THEN
      s := args[0].str;
      i := 0; neg := FALSE; val := 0;
      IF (s[0] = "-") THEN neg := TRUE; INC(i) END;
      ok := isDigit(s[i]);
      WHILE ok & isDigit(s[i]) DO
        val := val * 10 + digitVal(s[i]); INC(i)
      END;
      IF ~ok OR (s[i] # 0X) THEN setError(r)
      ELSE
        IF neg THEN val := -val END;
        setInt(r, val)
      END
    ELSE setError(r)
    END
  END builtinInt;

  PROCEDURE callBuiltin(name: ARRAY OF CHAR;
                        VAR args: ARRAY OF Value; n: INTEGER;
                        VAR r: Value; VAR found: BOOLEAN);
  BEGIN
    found := TRUE;
    IF    strEq(name, "if")     THEN builtinIf(args, n, r)
    ELSIF strEq(name, "not")    THEN builtinNot(args, n, r)
    ELSIF strEq(name, "len")    THEN builtinLen(args, n, r)
    ELSIF strEq(name, "concat") THEN builtinConcat(args, n, r)
    ELSIF strEq(name, "int")    THEN builtinInt(args, n, r)
    ELSE found := FALSE; setError(r)
    END
  END callBuiltin;

  (* ---------------- parser ---------------- *)

  PROCEDURE parseFunc(VAR s: state; name: ARRAY OF CHAR; VAR v: Value);
  (* Caller has read the ident and seen '(', advanced past it. Parses
     the argument list, then dispatches to a built-in. *)
    VAR args: ARRAY MaxBuiltinArgs OF Value; n: INTEGER; found: BOOLEAN;
  BEGIN
    n := 0;
    IF s.tok # TRParen THEN
      orExprFn(s, args[n]); INC(n);
      WHILE (s.tok = TComma) & (n < MaxBuiltinArgs) DO
        next(s);
        orExprFn(s, args[n]); INC(n)
      END
    END;
    IF s.tok # TRParen THEN setError(v)
    ELSE
      next(s);
      callBuiltin(name, args, n, v, found)
    END
  END parseFunc;

  PROCEDURE parseColRef(VAR s: state; name: ARRAY OF CHAR; VAR v: Value);
  BEGIN
    IF s.scope.col = NIL THEN setError(v)
    ELSE s.scope.col(name, v)
    END
  END parseColRef;

  PROCEDURE factor(VAR s: state; VAR v: Value);
    VAR name: ARRAY MaxIdent OF CHAR;
  BEGIN
    IF s.tok = TInt THEN
      setInt(v, s.tokInt); next(s)
    ELSIF s.tok = TString THEN
      setString(v, s.tokStr); next(s)
    ELSIF s.tok = TTrue THEN
      setBool(v, TRUE); next(s)
    ELSIF s.tok = TFalse THEN
      setBool(v, FALSE); next(s)
    ELSIF s.tok = TNil THEN
      v.kind := VNil; next(s)
    ELSIF s.tok = TLParen THEN
      next(s);
      orExprFn(s, v);
      IF s.tok # TRParen THEN setError(v) ELSE next(s) END
    ELSIF s.tok = TDollar THEN
      next(s);
      IF s.tok # TIdent THEN setError(v)
      ELSE
        copyStr(name, s.tokStr);
        next(s);
        IF s.scope.prompt = NIL THEN setError(v)
        ELSE s.scope.prompt(name, v)
        END
      END
    ELSIF s.tok = TIdent THEN
      copyStr(name, s.tokStr);
      next(s);
      IF s.tok = TLParen THEN
        next(s);
        parseFunc(s, name, v)
      ELSIF (s.tok = TLBrack) & strEq(name, "c") THEN
        (* c[name] escape hatch *)
        next(s);
        IF s.tok # TIdent THEN setError(v)
        ELSE
          copyStr(name, s.tokStr);
          next(s);
          IF s.tok # TRBrack THEN setError(v)
          ELSE
            next(s);
            parseColRef(s, name, v)
          END
        END
      ELSE
        parseColRef(s, name, v)
      END
    ELSE
      setError(v); next(s)
    END
  END factor;

  PROCEDURE unary(VAR s: state; VAR v: Value);
  BEGIN
    IF s.tok = TMinus THEN
      next(s);
      unary(s, v);
      IF v.kind = VInt THEN v.int := -v.int
      ELSE setError(v)
      END
    ELSIF s.tok = TNot THEN
      next(s);
      unary(s, v);
      IF v.kind = VBool THEN v.bool := ~v.bool
      ELSE setError(v)
      END
    ELSE
      factor(s, v)
    END
  END unary;

  PROCEDURE mulExpr(VAR s: state; VAR v: Value);
    VAR rhs: Value; op: INTEGER;
  BEGIN
    unary(s, v);
    WHILE (s.tok = TStar) OR (s.tok = TSlash) DO
      op := s.tok; next(s);
      unary(s, rhs);
      IF eitherError(v, rhs) OR (v.kind # VInt) OR (rhs.kind # VInt) THEN
        setError(v)
      ELSIF op = TStar THEN v.int := v.int * rhs.int
      ELSIF rhs.int = 0 THEN setError(v)
      ELSE v.int := v.int DIV rhs.int
      END
    END
  END mulExpr;

  PROCEDURE addExpr(VAR s: state; VAR v: Value);
    VAR rhs: Value; op: INTEGER;
  BEGIN
    mulExpr(s, v);
    WHILE (s.tok = TPlus) OR (s.tok = TMinus) DO
      op := s.tok; next(s);
      mulExpr(s, rhs);
      IF eitherError(v, rhs) OR (v.kind # VInt) OR (rhs.kind # VInt) THEN
        setError(v)
      ELSIF op = TPlus THEN v.int := v.int + rhs.int
      ELSE v.int := v.int - rhs.int
      END
    END
  END addExpr;

  PROCEDURE compare(op: INTEGER; VAR a, b: Value; VAR r: Value);
  (* Common path for the six relational operators. *)
    VAR less, eq: BOOLEAN; ok: BOOLEAN;
  BEGIN
    ok := FALSE; less := FALSE; eq := FALSE;
    IF (a.kind = VInt) & (b.kind = VInt) THEN
      eq := a.int = b.int;
      less := a.int < b.int;
      ok := TRUE
    ELSIF (a.kind = VString) & (b.kind = VString) THEN
      eq := strEq(a.str, b.str);
      less := strLess(a.str, b.str);
      ok := TRUE
    ELSIF (a.kind = VBool) & (b.kind = VBool) THEN
      IF (op = TEq) OR (op = THash) THEN
        eq := a.bool = b.bool;
        ok := TRUE
      END
    END;
    IF ~ok THEN setError(r)
    ELSIF op = TEq        THEN setBool(r, eq)
    ELSIF op = THash      THEN setBool(r, ~eq)
    ELSIF op = TLess      THEN setBool(r, less)
    ELSIF op = TLessEq    THEN setBool(r, less OR eq)
    ELSIF op = TGreater   THEN setBool(r, ~less & ~eq)
    ELSIF op = TGreaterEq THEN setBool(r, ~less)
    END
  END compare;

  PROCEDURE relExpr(VAR s: state; VAR v: Value);
    VAR rhs, tmp: Value; op: INTEGER;
  BEGIN
    addExpr(s, v);
    IF (s.tok = TEq) OR (s.tok = THash)
        OR (s.tok = TLess) OR (s.tok = TLessEq)
        OR (s.tok = TGreater) OR (s.tok = TGreaterEq) THEN
      op := s.tok; next(s);
      addExpr(s, rhs);
      IF eitherError(v, rhs) THEN
        setError(v)
      ELSE
        compare(op, v, rhs, tmp);
        v := tmp
      END
    END
  END relExpr;

  PROCEDURE andExpr(VAR s: state; VAR v: Value);
    VAR rhs: Value;
  BEGIN
    relExpr(s, v);
    WHILE s.tok = TAnd DO
      next(s);
      relExpr(s, rhs);
      IF eitherError(v, rhs) OR (v.kind # VBool) OR (rhs.kind # VBool) THEN
        setError(v)
      ELSE
        setBool(v, v.bool & rhs.bool)
      END
    END
  END andExpr;

  PROCEDURE orExpr(VAR s: state; VAR v: Value);
    VAR rhs: Value;
  BEGIN
    andExpr(s, v);
    WHILE s.tok = TOr DO
      next(s);
      andExpr(s, rhs);
      IF eitherError(v, rhs) OR (v.kind # VBool) OR (rhs.kind # VBool) THEN
        setError(v)
      ELSE
        setBool(v, v.bool OR rhs.bool)
      END
    END
  END orExpr;

  PROCEDURE Eval*(b: Buffer.Buffer; pos: INTEGER;
                  scope: Scope; VAR result: Value; VAR endPos: INTEGER);
  (* Parse and evaluate one expression starting at pos. Whatever
     comes after the first expression (and surrounding whitespace) is
     left untouched; endPos points to the first non-consumed byte. *)
    VAR s: state;
  BEGIN
    openLex(s, b, pos);
    s.scope := scope;
    orExpr(s, result);
    endPos := s.pos                   (* approximate; caller usually doesn't care *)
  END Eval;

BEGIN
  orExprFn := orExpr
END Expr.
