MODULE BufList;
(* Synthesis and helpers for the `*viewers*` listing buffer.

   The listing is a Doc whose bytes are regenerated from the Viewers
   registry on every Refresh while *viewers* is current — that way
   the table layout (driven by @column directives at the head of the
   Doc) always reflects the current set of buffers.

   Also exports the buffer-name completer used by Mini prompts and
   a short kind→label mapping. The command-level wrappers around
   these (switch / kill / list) stay in Oed.Mod where the active
   viewer's attach / detach lives. *)

  IMPORT Strings, Buffer, Schema, Lines, Csv, Doc, Viewers;

  PROCEDURE appendBytes(b: Buffer.Buffer; VAR pos: INTEGER; s: ARRAY OF CHAR);
    VAR k: INTEGER;
  BEGIN
    k := 0;
    WHILE (k < LEN(s)) & (s[k] # 0X) DO
      Buffer.Insert(b, pos, s[k]); INC(pos); INC(k)
    END
  END appendBytes;

  PROCEDURE KindName*(k: INTEGER; VAR s: ARRAY OF CHAR);
  BEGIN
    IF    k = Viewers.KText            THEN Strings.Copy(s, "text")
    ELSIF k = Viewers.KCollection      THEN Strings.Copy(s, "coll")
    ELSIF k = Viewers.KTableView       THEN Strings.Copy(s, "table")
    ELSIF k = Viewers.KSpreadsheetView THEN Strings.Copy(s, "sheet")
    ELSIF k = Viewers.KFormView        THEN Strings.Copy(s, "form")
    ELSIF k = Viewers.KViewerList      THEN Strings.Copy(s, "list")
    ELSE                                    Strings.Copy(s, "?")
    END
  END KindName;

  (* (Re)populate d with one CSV row per registered Viewer, behind a
     small @column header that drives the table layout. *)
  PROCEDURE Rebuild*(d: Doc.Doc);
    VAR pos, i: INTEGER;
        v: Viewers.Viewer;
        sizeStr, kStr: ARRAY 16 OF CHAR;
  BEGIN
    (* Synthetic doc — rebuilt wholesale on every Refresh while
       *viewers* is current. Mute undo recording so the ring doesn't
       fill with edits the user never made; reset history after. *)
    Buffer.SuspendRecording(d.buf);
    Buffer.Delete(d.buf, 0, d.buf.len);
    pos := 0;
    appendBytes(d.buf, pos, "@column(label, 32)");
    Buffer.Insert(d.buf, pos, 0AX); INC(pos);
    appendBytes(d.buf, pos, "@column(kind, 6)");
    Buffer.Insert(d.buf, pos, 0AX); INC(pos);
    appendBytes(d.buf, pos, "@column(size, 6)");
    Buffer.Insert(d.buf, pos, 0AX); INC(pos);
    appendBytes(d.buf, pos, "@column(dirty, 2)");
    Buffer.Insert(d.buf, pos, 0AX); INC(pos);

    i := 0;
    WHILE i < Viewers.Count() DO
      v := Viewers.At(i);
      Csv.WriteField(d.buf, pos, v.label); Csv.WriteSep(d.buf, pos);
      KindName(v.kind, kStr);
      Csv.WriteField(d.buf, pos, kStr);    Csv.WriteSep(d.buf, pos);
      Strings.IntStr(v.doc.buf.len, sizeStr);
      Csv.WriteField(d.buf, pos, sizeStr); Csv.WriteSep(d.buf, pos);
      IF v.doc.buf.changed THEN Csv.WriteField(d.buf, pos, "*")
      ELSE Csv.WriteField(d.buf, pos, "")
      END;
      Csv.EndRow(d.buf, pos);
      INC(i)
    END;

    Lines.Invalidate(d.lines);
    d.buf.changed := FALSE;
    Buffer.ResetHistory(d.buf);
    Buffer.ResumeRecording(d.buf);
    IF d.schema = NIL THEN d.schema := Schema.New() END;
    Schema.Parse(d.buf, d.schema)
  END Rebuild;

  (* Tab-completion source for the buffer-switch prompt. Extends
     `text` to the longest prefix shared by all viewer labels that
     start with text[0..len-1]. *)
  PROCEDURE Completer*(VAR text: ARRAY OF CHAR; VAR len: INTEGER);
    VAR i, k, commonLen: INTEGER;
        v: Viewers.Viewer;
        first, matches: BOOLEAN;
        common: ARRAY 64 OF CHAR;
  BEGIN
    first := TRUE; commonLen := 0;
    i := 0;
    WHILE i < Viewers.Count() DO
      v := Viewers.At(i);
      matches := TRUE;
      k := 0;
      WHILE matches & (k < len) DO
        IF v.label[k] # text[k] THEN matches := FALSE END;
        INC(k)
      END;
      IF matches THEN
        IF first THEN
          Strings.Copy(common, v.label);
          commonLen := 0;
          WHILE (commonLen < LEN(common)) & (common[commonLen] # 0X) DO
            INC(commonLen)
          END;
          first := FALSE
        ELSE
          k := 0;
          WHILE (k < commonLen) & (common[k] = v.label[k]) DO INC(k) END;
          commonLen := k
        END
      END;
      INC(i)
    END;
    IF ~first & (commonLen > len) THEN
      k := 0;
      WHILE k < commonLen DO text[k] := common[k]; INC(k) END;
      text[commonLen] := 0X;
      len := commonLen
    END
  END Completer;

END BufList.
