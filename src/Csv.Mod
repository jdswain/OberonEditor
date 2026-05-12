MODULE Csv;
(* CSV row reader/writer over Buffer.Buffer. RFC-4180 quoting:
   double-quoted fields, embedded double-quotes are doubled, embedded
   commas and newlines are allowed inside quotes.

   Reader hands fields out one at a time. Outer loop drives by EOF;
   inner state EOR marks the field that just closed a row, so the
   caller can split rows without scanning newlines itself.

       Csv.OpenReader(cr, b, 0);
       WHILE ~cr.eof DO
         Csv.ReadField(cr, f);
         (* ...process f... *)
         IF cr.eor THEN (* row complete *) END
       END

   Writer is stream-style: WriteField, WriteSep, EndRow each insert
   into the underlying Buffer at pos and advance pos. Caller controls
   when separators and row terminators go in. *)

  IMPORT Buffer;

  CONST
    NL    = 0AX;
    QUOTE = 22X;
    COMMA = ",";

  TYPE
    Reader* = RECORD
      r:         Buffer.Reader;
      ch:        CHAR;
      eof*:      BOOLEAN;        (* underlying reader has hit eot *)
      eor*:      BOOLEAN;        (* the field just read closed a row *)
      pos*:      INTEGER;        (* position of byte in ch, or buf.len if eof *)
      fieldEnd*: INTEGER         (* byte position right after the most recently read
                                    field's content, BEFORE the terminator was consumed.
                                    Useful for in-place rewrites: the field's bytes are
                                    [fieldStart .. fieldEnd). *)
    END;

  PROCEDURE step(VAR cr: Reader);
  (* Advance one byte. cr.pos tracks the position of the byte
     currently in cr.ch; once eof, cr.pos = buf.len. *)
  BEGIN
    IF ~cr.eof THEN
      Buffer.Read(cr.r, cr.ch);
      IF cr.r.eot THEN cr.eof := TRUE END;
      INC(cr.pos)
    END
  END step;

  PROCEDURE OpenReader*(VAR cr: Reader; b: Buffer.Buffer; pos: INTEGER);
  BEGIN
    Buffer.OpenReader(cr.r, b, pos);
    cr.eof := FALSE; cr.eor := FALSE;
    cr.pos := pos;
    cr.fieldEnd := pos;
    Buffer.Read(cr.r, cr.ch);
    IF cr.r.eot THEN cr.eof := TRUE; cr.pos := b.len END
  END OpenReader;

  PROCEDURE ReadField*(VAR cr: Reader; VAR field: ARRAY OF CHAR);
    VAR i: INTEGER; done: BOOLEAN;
  BEGIN
    i := 0; cr.eor := FALSE;
    IF cr.eof THEN
      field[0] := 0X; cr.eor := TRUE;
      cr.fieldEnd := cr.pos
    ELSIF cr.ch = QUOTE THEN
      step(cr);
      done := FALSE;
      WHILE ~done DO
        IF cr.eof THEN
          done := TRUE                 (* unterminated — accept as-is *)
        ELSIF cr.ch = QUOTE THEN
          step(cr);
          IF ~cr.eof & (cr.ch = QUOTE) THEN
            IF i < LEN(field) - 1 THEN field[i] := QUOTE; INC(i) END;
            step(cr)
          ELSE
            done := TRUE                (* closing quote *)
          END
        ELSE
          IF i < LEN(field) - 1 THEN field[i] := cr.ch; INC(i) END;
          step(cr)
        END
      END;
      field[i] := 0X;
      cr.fieldEnd := cr.pos;            (* position of the terminator or eof *)
      IF cr.eof THEN cr.eor := TRUE
      ELSIF cr.ch = NL THEN cr.eor := TRUE; step(cr)
      ELSIF cr.ch = COMMA THEN step(cr)
      ELSE cr.eor := TRUE                (* stray bytes after closing quote *)
      END
    ELSE
      WHILE ~cr.eof & (cr.ch # COMMA) & (cr.ch # NL) DO
        IF i < LEN(field) - 1 THEN field[i] := cr.ch; INC(i) END;
        step(cr)
      END;
      field[i] := 0X;
      cr.fieldEnd := cr.pos;            (* position of the terminator or eof *)
      IF cr.eof THEN cr.eor := TRUE
      ELSIF cr.ch = NL THEN cr.eor := TRUE; step(cr)
      ELSE step(cr)                      (* COMMA: eor stays FALSE *)
      END
    END
  END ReadField;

  PROCEDURE NeedsQuote(field: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER; q: BOOLEAN;
  BEGIN
    i := 0; q := FALSE;
    WHILE (i < LEN(field)) & (field[i] # 0X) & ~q DO
      IF (field[i] = COMMA) OR (field[i] = NL) OR (field[i] = QUOTE) THEN
        q := TRUE
      END;
      INC(i)
    END;
    RETURN q
  END NeedsQuote;

  PROCEDURE WriteField*(b: Buffer.Buffer; VAR pos: INTEGER; field: ARRAY OF CHAR);
    VAR i: INTEGER; q: BOOLEAN;
  BEGIN
    q := NeedsQuote(field);
    IF q THEN Buffer.Insert(b, pos, QUOTE); INC(pos) END;
    i := 0;
    WHILE (i < LEN(field)) & (field[i] # 0X) DO
      IF q & (field[i] = QUOTE) THEN
        Buffer.Insert(b, pos, QUOTE); INC(pos)
      END;
      Buffer.Insert(b, pos, field[i]); INC(pos);
      INC(i)
    END;
    IF q THEN Buffer.Insert(b, pos, QUOTE); INC(pos) END
  END WriteField;

  PROCEDURE WriteSep*(b: Buffer.Buffer; VAR pos: INTEGER);
  BEGIN Buffer.Insert(b, pos, COMMA); INC(pos)
  END WriteSep;

  PROCEDURE EndRow*(b: Buffer.Buffer; VAR pos: INTEGER);
  BEGIN Buffer.Insert(b, pos, NL); INC(pos)
  END EndRow;

END Csv.
