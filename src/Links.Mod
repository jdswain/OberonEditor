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

  PROCEDURE follow(url: ARRAY OF CHAR;
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
      Project.Resolve(path, phys);
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
     if cur was elsewhere and the caller should insert newline. *)
  PROCEDURE Follow*(buf: Buffer.Buffer; cur: INTEGER;
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
      follow(url, makeView, switch, status)
    END;
    RETURN handled
  END Follow;

END Links.
