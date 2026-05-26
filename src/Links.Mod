MODULE Links;
(* Follow-side handling for markdown `[text](url)` links.

   The edit-URL flow lives in Oed.Mod because it spans a prompt
   (Mini.PromptEdit) and the result needs to write back to the
   editor's `buf` / `lines` / `cur` globals on commit. The done
   callback is naturally a top-level procedure in Oed.

   Follow rules for the URL at cur:
     file:PATH      → strip prefix, open / switch to viewer for PATH
     /logical/path  → Project.Resolve, open / switch
     bare path      → same, treated as project-logical
     scheme://...   → external; do not navigate *)

  IMPORT Strings, Buffer, Lines, Viewers, Project, Render;

  TYPE
    MakeView* = PROCEDURE(VAR n: ARRAY OF CHAR): Viewers.Viewer;
    Switch*   = PROCEDURE(t: Viewers.Viewer);

  PROCEDURE strLen(s: ARRAY OF CHAR): INTEGER;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
    RETURN i
  END strLen;

  PROCEDURE hasScheme(url: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER; found: BOOLEAN;
  BEGIN
    found := FALSE; i := 0;
    WHILE (i + 2 < LEN(url)) & (url[i] # 0X) & ~found DO
      IF (url[i] = ":") & (url[i+1] = "/") & (url[i+2] = "/") THEN
        found := TRUE
      END;
      INC(i)
    END;
    RETURN found
  END hasScheme;

  PROCEDURE stripFile(url: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
    VAR i, j: INTEGER;
  BEGIN
    IF (strLen(url) >= 5)
        & (url[0] = "f") & (url[1] = "i") & (url[2] = "l") & (url[3] = "e")
        & (url[4] = ":") THEN
      j := 5
    ELSE
      j := 0
    END;
    i := 0;
    WHILE (i < LEN(path) - 1) & (i + j < LEN(url)) & (url[i + j] # 0X) DO
      path[i] := url[i + j]; INC(i)
    END;
    path[i] := 0X
  END stripFile;

  (* Collapse "." and ".." segments in `path` in-place. Leading "/"
     is preserved; the path can be project-logical or absolute. ".."
     at the start of a relative path stays in place since there's no
     parent to climb past. *)
  PROCEDURE normalize(VAR path: ARRAY OF CHAR);
    VAR src, dst, segStart, prevSep, i: INTEGER;
        out: ARRAY 256 OF CHAR;
        seg: ARRAY 256 OF CHAR;
        segLen: INTEGER;
        rooted: BOOLEAN;
  BEGIN
    rooted := path[0] = "/";
    dst := 0;
    IF rooted THEN out[0] := "/"; dst := 1 END;
    src := 0;
    IF rooted THEN src := 1 END;
    WHILE path[src] # 0X DO
      (* Pull next segment into `seg`. *)
      segLen := 0;
      WHILE (path[src] # 0X) & (path[src] # "/") DO
        seg[segLen] := path[src]; INC(segLen); INC(src)
      END;
      seg[segLen] := 0X;
      IF path[src] = "/" THEN INC(src) END;

      IF segLen = 0 THEN
        (* "//" — skip the extra separator. *)
      ELSIF (segLen = 1) & (seg[0] = ".") THEN
        (* "." — skip. *)
      ELSIF (segLen = 2) & (seg[0] = ".") & (seg[1] = ".") THEN
        (* ".." — pop the previous out-segment if there is one and
           it isn't itself ".." (relative paths preserve leading
           ".."). *)
        IF dst > 0 THEN
          (* Find start of previous segment in out. *)
          prevSep := dst - 1;
          IF rooted & (prevSep = 0) THEN
            (* At project root, nothing to pop. *)
          ELSE
            IF (prevSep >= 0) & (out[prevSep] = "/") THEN DEC(prevSep) END;
            segStart := prevSep;
            WHILE (segStart > 0) & (out[segStart - 1] # "/") DO
              DEC(segStart)
            END;
            (* Don't pop a leading ".." in a relative path. *)
            IF (out[segStart] = ".") & (out[segStart + 1] = ".")
                & ((segStart + 2 = dst) OR (out[segStart + 2] = "/")) THEN
              IF dst < LEN(out) - 3 THEN
                out[dst] := "."; out[dst + 1] := "."; out[dst + 2] := "/";
                dst := dst + 3
              END
            ELSE
              dst := segStart
            END
          END
        ELSE
          IF dst < LEN(out) - 3 THEN
            out[dst] := "."; out[dst + 1] := "."; out[dst + 2] := "/";
            dst := dst + 3
          END
        END
      ELSE
        i := 0;
        WHILE (i < segLen) & (dst < LEN(out) - 2) DO
          out[dst] := seg[i]; INC(dst); INC(i)
        END;
        IF path[src - 1] = "/" THEN
          IF dst < LEN(out) - 1 THEN
            out[dst] := "/"; INC(dst)
          END
        END;
        IF (path[src] = 0X) & (dst > 0) & (out[dst - 1] = "/") THEN
          (* Trailing slash from "foo/" — keep, don't strip. *)
        END
      END
    END;
    out[dst] := 0X;
    Strings.Copy(path, out)
  END normalize;

  (* Resolve a (possibly relative) link path against the source
     document's directory. Absolute project paths ("/Foo") and
     bare paths whose first segment looks like an absolute disk
     path are left untouched; otherwise dir-of-srcPath is prefixed.
     The joined path is normalised so "Notes/../Calc/data.txt"
     collapses to "Calc/data.txt" before Project.Resolve runs. *)
  PROCEDURE resolveAgainst(srcPath, path: ARRAY OF CHAR;
                           VAR out: ARRAY OF CHAR);
    VAR joined: ARRAY 256 OF CHAR;
        i, last: INTEGER;
  BEGIN
    IF path[0] = "/" THEN
      (* Project-logical absolute — Project.Resolve prepends the
         project root and we're done. Don't normalize first or
         Resolve sees a normalised form that's already absolute on
         disk and would double-prefix. *)
      Project.Resolve(path, out)
    ELSIF srcPath[0] = 0X THEN
      (* No anchor available — treat as cwd-relative. *)
      Strings.Copy(out, path);
      normalize(out)
    ELSE
      (* Splice dir-of-srcPath in front of path. srcPath is already
         a physical (post-Resolve) path, so the result is physical
         too — skip Project.Resolve, just normalise. *)
      last := -1; i := 0;
      WHILE (i < LEN(srcPath)) & (srcPath[i] # 0X) DO
        IF srcPath[i] = "/" THEN last := i END;
        INC(i)
      END;
      i := 0;
      WHILE (i <= last) & (i < LEN(joined) - 1) DO
        joined[i] := srcPath[i]; INC(i)
      END;
      joined[i] := 0X;
      Strings.Append(joined, path);
      normalize(joined);
      Strings.Copy(out, joined)
    END
  END resolveAgainst;

  PROCEDURE follow(url, srcPath: ARRAY OF CHAR;
                   makeView: MakeView; switch: Switch;
                   VAR status: ARRAY OF CHAR);
    VAR path, phys: ARRAY 256 OF CHAR;
        target: Viewers.Viewer;
        res: INTEGER;
  BEGIN
    IF hasScheme(url) THEN
      Strings.Copy(status, "External URL — not followed")
    ELSE
      stripFile(url, path);
      resolveAgainst(srcPath, path, phys);
      target := Viewers.FindByDocName(phys);
      IF target = NIL THEN
        target := makeView(phys);
        Buffer.Load(target.doc.buf, phys, res);
        Lines.Invalidate(target.doc.lines);
        Viewers.Add(target)
      END;
      switch(target);
      Strings.Copy(status, "Followed link")
    END
  END follow;

  PROCEDURE readUrl(buf: Buffer.Buffer; uS, uE: INTEGER;
                    VAR out: ARRAY OF CHAR);
    VAR i, urlLen: INTEGER;
  BEGIN
    urlLen := uE - uS;
    IF urlLen > LEN(out) - 1 THEN urlLen := LEN(out) - 1 END;
    i := 0;
    WHILE i < urlLen DO
      out[i] := Render.CharAt(buf, uS + i); INC(i)
    END;
    out[urlLen] := 0X
  END readUrl;

  (* Follow the link at cur. Returns TRUE if cur was on a link
     (caller should not treat the keypress as plain text); FALSE
     if cur was elsewhere and the caller should insert newline.
     srcPath is the path of the document containing the link;
     relative URLs resolve against its directory. *)
  PROCEDURE Follow*(buf: Buffer.Buffer; cur: INTEGER;
                    srcPath: ARRAY OF CHAR;
                    VAR status: ARRAY OF CHAR;
                    makeView: MakeView; switch: Switch): BOOLEAN;
    VAR op, tE, uS, uE: INTEGER;
        url: ARRAY 256 OF CHAR;
        handled: BOOLEAN;
  BEGIN
    handled := FALSE;
    IF Render.AtLink(buf, cur, op, tE, uS, uE) THEN
      handled := TRUE;
      readUrl(buf, uS, uE, url);
      follow(url, srcPath, makeView, switch, status)
    END;
    RETURN handled
  END Follow;

END Links.
