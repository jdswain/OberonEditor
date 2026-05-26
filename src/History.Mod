MODULE History;
(* Two-stack browser-style navigation history.

   Each navigation event pushes the SOURCE location (where the user
   came from) onto the back stack and clears the forward stack. Back
   pops the back stack and pushes the user's then-current location
   onto the forward stack. Forward is symmetric.

   "Navigation events" are operations where the user deliberately
   moves to another viewer: link follow, C-x b switch, C-x C-f open.
   Plumbing-level switches — kill-buffer fall-through, attach after
   Run sets up the scratch buffer — use plain switchTo and do NOT
   push, so Back never lands on a buffer that no longer exists. *)

  IMPORT Viewers;

  CONST
    MaxDepth = 64;

  TYPE
    Entry = RECORD
      v:   Viewers.Viewer;
      cur: INTEGER;
      top: INTEGER
    END;

  VAR
    backStack:  ARRAY MaxDepth OF Entry;
    fwdStack:   ARRAY MaxDepth OF Entry;
    backDepth:  INTEGER;
    fwdDepth:   INTEGER;

  PROCEDURE pushTo(VAR s: ARRAY OF Entry; VAR d: INTEGER;
                   v: Viewers.Viewer; cur, top: INTEGER);
  BEGIN
    IF (v # NIL) & (d < MaxDepth) THEN
      s[d].v := v; s[d].cur := cur; s[d].top := top;
      INC(d)
    END
  END pushTo;

  PROCEDURE popFrom(VAR s: ARRAY OF Entry; VAR d: INTEGER;
                    VAR v: Viewers.Viewer;
                    VAR cur, top: INTEGER): BOOLEAN;
    VAR ok: BOOLEAN;
  BEGIN
    ok := d > 0;
    IF ok THEN
      DEC(d);
      v := s[d].v; cur := s[d].cur; top := s[d].top
    END;
    RETURN ok
  END popFrom;

  (* User navigated from (v, cur, top) somewhere new. Push (v, cur,
     top) onto the back stack and clear the forward stack — going
     somewhere new invalidates any pending forward path. *)
  PROCEDURE PushNav*(v: Viewers.Viewer; cur, top: INTEGER);
  BEGIN
    pushTo(backStack, backDepth, v, cur, top);
    fwdDepth := 0
  END PushNav;

  (* If the back stack is non-empty: push the user's current state
     onto the forward stack and pop the most recent back entry into
     the out params. Returns TRUE on success. *)
  PROCEDURE Back*(currV: Viewers.Viewer; currCur, currTop: INTEGER;
                  VAR v: Viewers.Viewer;
                  VAR cur, top: INTEGER): BOOLEAN;
    VAR ok: BOOLEAN;
  BEGIN
    ok := backDepth > 0;
    IF ok THEN
      pushTo(fwdStack, fwdDepth, currV, currCur, currTop);
      ok := popFrom(backStack, backDepth, v, cur, top)
    END;
    RETURN ok
  END Back;

  (* Symmetric to Back: pops the forward stack and pushes the
     current state onto the back stack. *)
  PROCEDURE Forward*(currV: Viewers.Viewer; currCur, currTop: INTEGER;
                     VAR v: Viewers.Viewer;
                     VAR cur, top: INTEGER): BOOLEAN;
    VAR ok: BOOLEAN;
  BEGIN
    ok := fwdDepth > 0;
    IF ok THEN
      pushTo(backStack, backDepth, currV, currCur, currTop);
      ok := popFrom(fwdStack, fwdDepth, v, cur, top)
    END;
    RETURN ok
  END Forward;

  PROCEDURE Reset*;
  BEGIN backDepth := 0; fwdDepth := 0
  END Reset;

BEGIN
  backDepth := 0; fwdDepth := 0
END History.
