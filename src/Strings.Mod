MODULE Strings;
(* Common CHAR-array helpers used across oed: NUL-terminated copy,
   append, decimal-int conversion, and DirOf for splitting a path
   into its directory portion.

   Every operation is bounds-aware against LEN(dst). Source strings
   are read until 0X or LEN(src), whichever comes first. *)

  PROCEDURE Copy*(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(dst) - 1) & (i < LEN(src)) & (src[i] # 0X) DO
      dst[i] := src[i]; INC(i)
    END;
    dst[i] := 0X
  END Copy;

  PROCEDURE Append*(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
    VAR i, j: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(dst) - 1) & (dst[i] # 0X) DO INC(i) END;
    j := 0;
    WHILE (i < LEN(dst) - 1) & (j < LEN(src)) & (src[j] # 0X) DO
      dst[i] := src[j]; INC(i); INC(j)
    END;
    dst[i] := 0X
  END Append;

  (* Decimal int → NUL-terminated string. Negative inputs are written
     without sign (callers do not currently need it). *)
  PROCEDURE IntStr*(n: INTEGER; VAR s: ARRAY OF CHAR);
    VAR digits: ARRAY 16 OF CHAR; i, j: INTEGER; ch: CHAR;
  BEGIN
    IF n < 0 THEN n := -n END;
    IF n = 0 THEN
      s[0] := "0"; s[1] := 0X
    ELSE
      i := 0;
      WHILE n > 0 DO
        ch := CHR(ORD("0") + n MOD 10);
        digits[i] := ch;
        n := n DIV 10;
        INC(i)
      END;
      j := 0;
      WHILE i > 0 DO
        DEC(i);
        s[j] := digits[i];
        INC(j)
      END;
      s[j] := 0X
    END
  END IntStr;

  (* Copy the directory portion of path into dir, including the
     trailing slash. dir = "" when path has no slash (caller treats
     this as cwd). *)
  PROCEDURE DirOf*(path: ARRAY OF CHAR; VAR dir: ARRAY OF CHAR);
    VAR i, last: INTEGER;
  BEGIN
    last := -1; i := 0;
    WHILE (i < LEN(path)) & (path[i] # 0X) DO
      IF path[i] = "/" THEN last := i END;
      INC(i)
    END;
    IF last < 0 THEN
      dir[0] := 0X
    ELSE
      i := 0;
      WHILE (i <= last) & (i < LEN(dir) - 1) DO
        dir[i] := path[i]; INC(i)
      END;
      dir[i] := 0X
    END
  END DirOf;

END Strings.
