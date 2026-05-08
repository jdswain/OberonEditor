MODULE Project;
(* Project root and logical-path mapping. The root is a directory
   under which collections and views live; logical paths begin with
   `/` and resolve to physical paths under the root.

   Root is determined at startup by walking up from the start path
   (typically dirname(argv[1]), or cwd if no argv) looking for a
   `.oed/` marker directory. First hit = root. If no marker found,
   root falls back to that start dir, so logical paths still work
   (just over a flat layout).

   This module is the foundation for @ref resolution (later step in
   the data-layer plan) and for displaying short logical paths in
   the UI today. *)

  IMPORT Env, Files;

  CONST
    PathLen* = 256;
    MaxWalk  = 64;             (* hard cap on walk-up iterations *)

  VAR
    root: ARRAY PathLen OF CHAR;        (* absolute path, no trailing slash *)
    rootLen: INTEGER;

  PROCEDURE strLen(s: ARRAY OF CHAR): INTEGER;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
    RETURN i
  END strLen;

  PROCEDURE copyN(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR; n: INTEGER);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < n) & (i < LEN(dst) - 1) & (i < LEN(src)) & (src[i] # 0X) DO
      dst[i] := src[i]; INC(i)
    END;
    dst[i] := 0X
  END copyN;

  PROCEDURE appendCh(VAR dst: ARRAY OF CHAR; ch: CHAR);
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(dst) - 1) & (dst[i] # 0X) DO INC(i) END;
    IF i < LEN(dst) - 1 THEN dst[i] := ch; dst[i+1] := 0X END
  END appendCh;

  PROCEDURE appendStr(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
    VAR i, j: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(dst) - 1) & (dst[i] # 0X) DO INC(i) END;
    j := 0;
    WHILE (i < LEN(dst) - 1) & (j < LEN(src)) & (src[j] # 0X) DO
      dst[i] := src[j]; INC(i); INC(j)
    END;
    dst[i] := 0X
  END appendStr;

  (* Trim a trailing slash unless the string is exactly "/". *)
  PROCEDURE stripTrailingSlash(VAR s: ARRAY OF CHAR);
    VAR n: INTEGER;
  BEGIN
    n := strLen(s);
    IF (n > 1) & (s[n-1] = "/") THEN s[n-1] := 0X END
  END stripTrailingSlash;

  (* Strip the last path component including the slash before it.
     "/a/b" → "/a", "/a" → "/", "abc" → "" (no slash, treat as cwd). *)
  PROCEDURE parentDir(VAR s: ARRAY OF CHAR);
    VAR n: INTEGER;
  BEGIN
    n := strLen(s);
    WHILE (n > 0) & (s[n-1] # "/") DO DEC(n); s[n] := 0X END;
    IF (n > 1) THEN DEC(n); s[n] := 0X END
    (* "/" is left as "/" *)
  END parentDir;

  (* Drop the basename, keep the slash. "/a/b" → "/a/", "a" → "". *)
  PROCEDURE dirOf(path: ARRAY OF CHAR; VAR dir: ARRAY OF CHAR);
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
  END dirOf;

  (* If start is relative (no leading slash), prepend cwd + "/" so we
     have an absolute path to walk up from. Empty start becomes cwd. *)
  PROCEDURE absolutize(start: ARRAY OF CHAR; VAR abs: ARRAY OF CHAR);
    VAR cwd: ARRAY PathLen OF CHAR;
  BEGIN
    IF (start[0] = 0X) THEN
      Env.Cwd(abs)
    ELSIF start[0] = "/" THEN
      copyN(abs, start, LEN(abs) - 1)
    ELSE
      Env.Cwd(cwd);
      copyN(abs, cwd, LEN(abs) - 1);
      appendCh(abs, "/");
      appendStr(abs, start)
    END
  END absolutize;

  PROCEDURE Init*(start: ARRAY OF CHAR);
  (* start is typically argv[1]; pass "" when no argv was given. *)
    VAR abs, dir, marker: ARRAY PathLen OF CHAR;
        i: INTEGER;
        found: BOOLEAN;
  BEGIN
    absolutize(start, abs);
    dirOf(abs, dir);
    stripTrailingSlash(dir);
    IF dir[0] = 0X THEN
      Env.Cwd(dir);
      stripTrailingSlash(dir)
    END;
    found := FALSE;
    i := 0;
    WHILE ~found & (i < MaxWalk) DO
      copyN(marker, dir, LEN(marker) - 8);
      appendStr(marker, "/.oed");
      IF Files.Exists(marker) = 1 THEN
        found := TRUE
      ELSIF (dir[0] = "/") & (dir[1] = 0X) THEN
        i := MaxWalk           (* hit fs root with no marker *)
      ELSE
        parentDir(dir)
      END;
      INC(i)
    END;
    IF found THEN
      copyN(root, dir, LEN(root) - 1)
    ELSE
      (* No marker — fall back to the start dir itself. *)
      dirOf(abs, root);
      stripTrailingSlash(root);
      IF root[0] = 0X THEN Env.Cwd(root); stripTrailingSlash(root) END
    END;
    rootLen := strLen(root)
  END Init;

  PROCEDURE GetRoot*(VAR r: ARRAY OF CHAR);
  BEGIN copyN(r, root, LEN(r) - 1)
  END GetRoot;

  PROCEDURE HasRoot*(): BOOLEAN;
  BEGIN RETURN root[0] # 0X
  END HasRoot;

  (* If `physical` is under root, write the corresponding logical
     path (leading "/", relative to root) into `logical`. Otherwise
     copy `physical` unchanged. Synthetic names (starting with "*")
     are always copied unchanged. *)
  PROCEDURE Logical*(physical: ARRAY OF CHAR; VAR logical: ARRAY OF CHAR);
    VAR i: INTEGER; under: BOOLEAN;
  BEGIN
    IF (rootLen = 0) OR (physical[0] = "*") THEN
      copyN(logical, physical, LEN(logical) - 1)
    ELSE
      (* Match physical[0..rootLen-1] against root, then expect a
         "/" or end-of-string at physical[rootLen]. *)
      under := TRUE;
      i := 0;
      WHILE under & (i < rootLen) DO
        IF physical[i] # root[i] THEN under := FALSE END;
        INC(i)
      END;
      IF under & (physical[rootLen] # 0X) & (physical[rootLen] # "/") THEN
        under := FALSE
      END;
      IF under THEN
        IF physical[rootLen] = 0X THEN
          logical[0] := "/"; logical[1] := 0X
        ELSE
          (* copy from rootLen onward, which already starts with "/" *)
          i := 0;
          WHILE (i < LEN(logical) - 1) & (physical[rootLen + i] # 0X) DO
            logical[i] := physical[rootLen + i]; INC(i)
          END;
          logical[i] := 0X
        END
      ELSE
        copyN(logical, physical, LEN(logical) - 1)
      END
    END
  END Logical;

  (* Inverse of Logical. If `logical` starts with "/", produce
     root + logical. Else copy unchanged (already physical). *)
  PROCEDURE Resolve*(logical: ARRAY OF CHAR; VAR physical: ARRAY OF CHAR);
  BEGIN
    IF (logical[0] = "/") & (rootLen > 0) THEN
      copyN(physical, root, LEN(physical) - 1);
      appendStr(physical, logical)
    ELSE
      copyN(physical, logical, LEN(physical) - 1)
    END
  END Resolve;

BEGIN
  root[0] := 0X;
  rootLen := 0
END Project.
