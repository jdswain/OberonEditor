MODULE FileOps;
(* Save-side primitives. The prompt-chained save flow (Save /
   PromptSaveAs / DoSave with directory-create confirmation) lives
   in Oed.Mod because every step needs the editor's `buf`, `name`,
   `status` globals plus the `refreshSchema` and `detachCurrent`
   helpers — keeping the chain there avoids passing every piece
   through layers of callbacks. *)

  IMPORT Strings, Buffer, Viewers;

  PROCEDURE WriteFile*(buf: Buffer.Buffer; name: ARRAY OF CHAR;
                       VAR status: ARRAY OF CHAR);
    VAR res: INTEGER;
  BEGIN
    Buffer.Save(buf, name, res);
    IF res = Buffer.Ok THEN Strings.Copy(status, "Saved")
    ELSE Strings.Copy(status, "Save failed")
    END
  END WriteFile;

  (* C-x s: save every dirty buffer that has a real filename. Skips
     internal/*-named buffers and any with no name. Reports the
     count, plus any failures. Caller passes `detach` to flush the
     current viewer's cursor before iterating. *)
  PROCEDURE SaveAll*(VAR status: ARRAY OF CHAR; detach: PROCEDURE);
    VAR i, saved, failed, res: INTEGER;
        v: Viewers.Viewer;
        msg: ARRAY 96 OF CHAR;
        countStr: ARRAY 16 OF CHAR;
  BEGIN
    detach;
    saved := 0; failed := 0;
    i := 0;
    WHILE i < Viewers.Count() DO
      v := Viewers.At(i);
      IF v.doc.buf.changed & (v.doc.name[0] # 0X) & (v.doc.name[0] # "*") THEN
        Buffer.Save(v.doc.buf, v.doc.name, res);
        IF res = Buffer.Ok THEN INC(saved) ELSE INC(failed) END
      END;
      INC(i)
    END;
    Strings.Copy(msg, "Saved ");
    Strings.IntStr(saved, countStr); Strings.Append(msg, countStr);
    IF failed > 0 THEN
      Strings.Append(msg, ", ");
      Strings.IntStr(failed, countStr); Strings.Append(msg, countStr);
      Strings.Append(msg, " failed")
    END;
    Strings.Copy(status, msg)
  END SaveAll;

END FileOps.
