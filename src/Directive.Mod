MODULE Directive;
(* Directive lexer + parser. A directive is a header-zone line whose
   first non-whitespace character is '@':

       directive  = '@' name '(' [ arg { ',' arg } ] ')'
       arg        = literal | identifier | path | name '=' arg-value
       arg-value  = literal | identifier | path
       literal    = string-literal | int-literal
       path       = '/' { pathchar }

   Paths start with `/` and stop at whitespace, comma, or closing
   paren; they capture logical references like `@ref(/Notes/Contact)`
   that Project.Mod resolves to physical files.

   Full expression args (parenthesised expressions, nested directives)
   are reserved for later steps once Expr.Mod arrives. v1 captures
   enough to recognise @column / @filter / @prompt / @cell / @ref /
   @field / @link headers — every value is one of: string, identifier,
   integer, or path; every arg is either bare or the right-hand side
   of a `name=value` binding.

   Strings are double-quoted; embedded `"` is escaped as `\"`,
   embedded `\` as `\\`. *)

  IMPORT Buffer;

  CONST
    AString*  = 0;
    AIdent*   = 1;
    AInt*     = 2;
    APath*    = 3;          (* /-rooted or relative path token, see readPath *)

    MaxArgs* = 16;
    MaxName* = 32;
    MaxText* = 128;

    QUOTE  = 22X;
    BACKSL = 5CX;
    NL     = 0AX;
    CR     = 0DX;
    TAB    = 9X;

  TYPE
    Arg* = RECORD
      kind*:      INTEGER;                  (* AString | AIdent | AInt *)
      isBinding*: BOOLEAN;                  (* TRUE iff key was supplied *)
      key*:       ARRAY MaxName OF CHAR;
      str*:       ARRAY MaxText OF CHAR;    (* AString or AIdent *)
      int*:       INTEGER                   (* AInt *)
    END;

    Directive* = RECORD
      name*: ARRAY MaxName OF CHAR;
      narg*: INTEGER;
      args*: ARRAY MaxArgs OF Arg
    END;

    state = RECORD
      r:   Buffer.Reader;
      ch:  CHAR;
      pos: INTEGER;
      ok:  BOOLEAN
    END;

  PROCEDURE step(VAR s: state);
  (* Advance one byte. Buffer.Read sets eot only when called at the
     trailer, so we INC after the Read but only if it actually
     consumed a real byte (eot still FALSE). Idempotent past end. *)
  BEGIN
    IF ~s.r.eot THEN
      Buffer.Read(s.r, s.ch);
      IF ~s.r.eot THEN INC(s.pos) END
    END
  END step;

  PROCEDURE atEnd(VAR s: state): BOOLEAN;
  BEGIN RETURN s.r.eot
  END atEnd;

  PROCEDURE isAlpha(ch: CHAR): BOOLEAN;
  BEGIN
    RETURN ((ch >= "A") & (ch <= "Z"))
        OR ((ch >= "a") & (ch <= "z"))
        OR (ch = "_")
  END isAlpha;

  PROCEDURE isDigit(ch: CHAR): BOOLEAN;
  BEGIN RETURN (ch >= "0") & (ch <= "9")
  END isDigit;

  PROCEDURE copyStr(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(dst) - 1) & (i < LEN(src)) & (src[i] # 0X) DO
      dst[i] := src[i]; INC(i)
    END;
    dst[i] := 0X
  END copyStr;

  PROCEDURE skipWS(VAR s: state);
  BEGIN
    WHILE ~atEnd(s) & ((s.ch = " ") OR (s.ch = TAB)) DO step(s) END
  END skipWS;

  PROCEDURE readIdent(VAR s: state; VAR id: ARRAY OF CHAR);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE ~atEnd(s) & (isAlpha(s.ch) OR isDigit(s.ch)) DO
      IF i < LEN(id) - 1 THEN id[i] := s.ch; INC(i) END;
      step(s)
    END;
    id[i] := 0X
  END readIdent;

  PROCEDURE isPathCh(ch: CHAR): BOOLEAN;
  (* Chars allowed inside an unquoted directive path: identifier
     chars plus `/`, `.`, `-`. Stops at whitespace, `,`, `)`. *)
  BEGIN
    RETURN isAlpha(ch) OR isDigit(ch)
        OR (ch = "/") OR (ch = ".") OR (ch = "-")
  END isPathCh;

  PROCEDURE readPath(VAR s: state; VAR p: ARRAY OF CHAR);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE ~atEnd(s) & isPathCh(s.ch) DO
      IF i < LEN(p) - 1 THEN p[i] := s.ch; INC(i) END;
      step(s)
    END;
    p[i] := 0X
  END readPath;

  PROCEDURE readInt(VAR s: state; VAR n: INTEGER);
  BEGIN
    n := 0;
    WHILE ~atEnd(s) & isDigit(s.ch) DO
      n := n * 10 + (ORD(s.ch) - ORD("0"));
      step(s)
    END
  END readInt;

  (* Caller has consumed the opening '"'. Reads through the closing
     '"', interpreting \" and \\ as literal quote / backslash. *)
  PROCEDURE readString(VAR s: state; VAR str: ARRAY OF CHAR);
    VAR i: INTEGER; done: BOOLEAN;
  BEGIN
    i := 0; done := FALSE;
    WHILE ~done DO
      IF atEnd(s) THEN
        done := TRUE; s.ok := FALSE        (* unterminated literal *)
      ELSIF s.ch = BACKSL THEN
        step(s);
        IF atEnd(s) THEN
          done := TRUE; s.ok := FALSE
        ELSE
          IF i < LEN(str) - 1 THEN str[i] := s.ch; INC(i) END;
          step(s)
        END
      ELSIF s.ch = QUOTE THEN
        step(s); done := TRUE
      ELSE
        IF i < LEN(str) - 1 THEN str[i] := s.ch; INC(i) END;
        step(s)
      END
    END;
    str[i] := 0X
  END readString;

  (* Read one terminal value (string / ident / signed int) into the
     value-holding slots of `a`. Caller fills key/isBinding around it. *)
  PROCEDURE readValue(VAR s: state; VAR a: Arg);
    VAR neg: BOOLEAN;
  BEGIN
    skipWS(s);
    IF atEnd(s) THEN
      s.ok := FALSE
    ELSIF s.ch = QUOTE THEN
      a.kind := AString;
      step(s);
      readString(s, a.str)
    ELSIF s.ch = "/" THEN
      a.kind := APath;
      readPath(s, a.str)
    ELSIF (s.ch = "-") OR isDigit(s.ch) THEN
      a.kind := AInt;
      neg := s.ch = "-";
      IF neg THEN step(s) END;
      IF atEnd(s) OR ~isDigit(s.ch) THEN
        s.ok := FALSE
      ELSE
        readInt(s, a.int);
        IF neg THEN a.int := -a.int END
      END
    ELSIF isAlpha(s.ch) THEN
      a.kind := AIdent;
      readIdent(s, a.str)
    ELSE
      s.ok := FALSE
    END
  END readValue;

  (* Read one arg, handling the optional `key =` prefix. After
     reading what looks like an ident, peek for `=`: present → it's
     the key of a binding; absent → the ident is the value. *)
  PROCEDURE readArg(VAR s: state; VAR a: Arg);
    VAR savedIdent: ARRAY MaxName OF CHAR;
  BEGIN
    a.key[0] := 0X; a.isBinding := FALSE;
    skipWS(s);
    IF ~atEnd(s) & isAlpha(s.ch) THEN
      readIdent(s, savedIdent);
      skipWS(s);
      IF ~atEnd(s) & (s.ch = "=") THEN
        step(s);
        a.isBinding := TRUE;
        copyStr(a.key, savedIdent);
        readValue(s, a)
      ELSE
        a.kind := AIdent;
        copyStr(a.str, savedIdent)
      END
    ELSE
      readValue(s, a)
    END
  END readArg;

  PROCEDURE Parse*(b: Buffer.Buffer; pos: INTEGER;
                   VAR d: Directive; VAR ok: BOOLEAN; VAR endPos: INTEGER);
    VAR s: state; done: BOOLEAN;
  BEGIN
    Buffer.OpenReader(s.r, b, pos);
    s.pos := pos; s.ok := TRUE;
    Buffer.Read(s.r, s.ch);
    IF s.r.eot THEN s.ok := FALSE
    ELSE
      INC(s.pos);
      skipWS(s);
      IF atEnd(s) OR (s.ch # "@") THEN
        s.ok := FALSE
      ELSE
        step(s);
        readIdent(s, d.name);
        IF d.name[0] = 0X THEN s.ok := FALSE END;
        skipWS(s);
        IF s.ok THEN
          IF atEnd(s) OR (s.ch # "(") THEN
            s.ok := FALSE
          ELSE
            step(s); skipWS(s);
            d.narg := 0;
            IF ~atEnd(s) & (s.ch # ")") THEN
              done := FALSE;
              WHILE s.ok & ~done DO
                IF d.narg >= MaxArgs THEN
                  s.ok := FALSE
                ELSE
                  readArg(s, d.args[d.narg]);
                  IF s.ok THEN
                    INC(d.narg);
                    skipWS(s);
                    IF atEnd(s) THEN
                      s.ok := FALSE
                    ELSIF s.ch = "," THEN
                      step(s); skipWS(s)
                    ELSE
                      done := TRUE
                    END
                  END
                END
              END
            END;
            IF s.ok THEN
              IF atEnd(s) OR (s.ch # ")") THEN
                s.ok := FALSE
              END
              (* No step after ')': s.pos already points one past it. *)
            END
          END
        END
      END
    END;
    ok := s.ok;
    endPos := s.pos
  END Parse;

END Directive.
