# Tutorial — A Contacts database

This walkthrough builds a small contacts database in oed using the
three data-oriented file kinds the editor knows about today:

  | extension | kind           | what it stores                          |
  |-----------|----------------|-----------------------------------------|
  | `.col`    | kCollection    | the raw CSV data with an `@column` header |
  | `.tbl`    | kTableView     | a table layout that projects columns of a `.col` |
  | `.frm`    | kFormView      | a single-record card layout              |

Open / save round-trip through the same Doc/Buffer pipeline as plain
text; the only difference is that the editor reads the `@column`
header to drive table column widths, form field substitution, and
cell editing.

## 1. Project root

oed treats the closest ancestor directory containing a `.oed/`
marker as the project root. Logical paths beginning with `/` are
resolved against that root; everything else is interpreted relative
to the working directory.

    mkdir -p ~/work/contacts/.oed
    cd ~/work/contacts

From here on, `/Contacts.col` resolves to `~/work/contacts/Contacts.col`.

## 2. Create the data file

Launch oed on a new `.col` file:

    oed Contacts.col

The buffer is empty. Type the schema header (a sequence of
`@column` directives, one per line) followed by a blank line, then
the CSV rows:

    @column(name, "Name", 16)
    @column(age, integer, 4)
    @column(email, "Email", 28)

    Alice,30,alice@example.com
    Bob,42,bob@example.com
    Carol,27,carol@example.com

The header takes three positional arguments per column —
`(identifier, optional label, optional integer, optional width)`.
Any subset is fine; column identifiers must be unique. Save with
**C-x C-s**.

oed recognises the `.col` extension as `kCollection`. The editor
parses the `@column` header (so other viewers can project against
the schema) but the kCollection viewer itself still renders the
file as plain text — the CSV stays editable byte-for-byte. Press
**C-x C-b** to switch to the `*viewers*` listing and `Contacts.col`
appears as kind `coll`.

The grid view + per-cell editing comes from a `.tbl` projection,
which we build next.

## 3. Add a table view

A `.tbl` projects a subset (or re-ordering) of the data columns
under a custom label / width.

    oed Contacts.tbl

In the new buffer:

    @ref(/Contacts)
    @column(name, "Name", 14)
    @column(email, "Email", 30)

`@ref` points at the backing `.col` using a project-logical path
(no extension). On save, oed loads the referenced file as a
`kCollection` Doc and the table renders the projected columns
against the shared data. Edits made in the table propagate to the
underlying `.col` (because the same Buffer is shared between
viewers), and **C-x s** saves every dirty buffer.

In the table viewer:

  | key       | action                                       |
  |-----------|----------------------------------------------|
  | arrows    | move cursor by row / column                  |
  | **Enter** | jump to the matching form's record           |
  | **C-x e** | edit the cell at point (Mini.PromptEdit)     |
  | **C-x ,** | back — return to the previous viewer         |
  | **C-x .** | forward — undo a `C-x ,`                     |

The buffer list now shows three entries: `Contacts.tbl` as kind
`table`, `Contacts.col` as kind `coll` (auto-loaded as the data
backing), and `*scratch*`.

## 4. Add a form view

A `.frm` is a single-record card. Its header is `@ref(...)` like a
table; the rest of the file is free text with `@field(<column>)`
placeholders that get substituted with the current record's value.

    oed ContactCard.frm

Content:

    @ref(/Contacts)

    ╭──────────────────────────────╮
    │  Contact: @field(name)
    │
    │  Age:     @field(age)
    │  Email:   @field(email)
    ╰──────────────────────────────╯

Save it. The viewer now shows the first record. **M-n** / **M-p**
step records; **Tab** cycles fields within the current record;
**Enter** edits the field at point. The status bar shows
`Rec:1 Fld:1` so you can tell which record + field you're on.

## 5. Round trip

You now have three viewers backed by one source of truth. Try:

  1. Land on Bob in `Contacts.tbl`, press **Enter** → the form jumps
     to his record. **C-x ,** brings you back to the table at the
     same row; **C-x .** jumps forward again. (The Enter-on-link
     pattern reused: Enter navigates, **C-x e** edits.)
  2. While on Bob in the form, **C-x e** opens an "Edit email:"
     prompt pre-filled with the current value. Commit with Enter
     → switch to `Contacts.col` (**C-x b** then `/Contacts.col`)
     and see the change reflected in the CSV.
  3. **C-x s** to save every dirty buffer.

## 6. Missing features

These showed up as obvious gaps while exercising the workflow. Each
is a candidate for a follow-up — listed in roughly the order I'd
implement them.

### Cross-view navigation
- ~~**Jump from a table row to its form.**~~ ✓ Done. Enter on a
  table row scans the viewer registry for a `kFormView` whose
  `dataDoc` matches the row's backing `.col`, sets its record
  index to `cur`, and `navTo`s. `C-x ,` returns. (Edit moved
  to **C-x e**.) Open the form once via `C-x C-f` to have it in
  the registry; if no form is open the status hints at this.
- **Auto-open the matching form.** Today the form has to be
  opened manually (e.g. `C-x C-f /ContactCard.frm`) so the
  Enter-jump can find it. A nicer behaviour: if no `kFormView`
  for the collection is open, prompt for one — or use a `@form`
  hint in the `.tbl` header to point at a default.
- **Jump back from form to table.** Symmetric: in a `.frm` viewer,
  some binding (most naturally Enter, but it currently edits)
  would jump to the `.tbl` row matching the form's current
  record. Could also rebind Form Enter to navigate and put edit
  on `C-x e` there too — that would generalise the pattern.

### Search and filter
- **Cell-aware Ctrl-S.** Today **Ctrl-S** runs `Search.Interactive`
  which works on raw bytes. Inside a `kTableView` / `kCollection`
  the cursor lives in row/column space, not byte space, so
  Ctrl-S currently does nothing useful there. A
  "Search-in-column" prompt that narrows to a given column and
  jumps to the next matching row would slot in nicely.
- **Filter directive.** `Directive.Parse` already recognises
  `@filter` as a directive (it's reserved). What's missing is the
  table renderer honouring it — skip rows whose specified column
  doesn't match. Interactive variant: **Ctrl-X /** to set / clear
  a filter on the current column.
- **Sort directive.** Similar story: a `@sort(column, asc|desc)`
  header would let `.tbl` views present rows in a consistent
  order; interactive **Ctrl-X o** would set sort on the current
  column. Underlying data stays unsorted; only the projection
  reorders.

### Record lifecycle
- **Append a new record.** Currently the only way to add a row is
  to switch to `Contacts.col` as raw text (**C-x C-r**) and type
  a new CSV line. A **Ctrl-X n** ("new record") in a table or
  form view that opens prompts for each schema column would be a
  big quality-of-life win.
- **Delete the current record.** No binding exists. **Ctrl-X d**
  with a confirm prompt could remove the row at cur.

### Display
- **Resize / reorder columns interactively.** Today you edit the
  `.tbl` file directly to change widths and order.
- ~~**No undo.**~~ ✓ Done. Buffer.Mod owns a per-buffer ring of
  reversible edits — Insert and Delete record their inverse before
  mutating the piece chain. **C-x u** undoes, **C-x U** redoes;
  adjacent inserts coalesce (typing "hello" makes one undo entry,
  not five). Single-char Deletes (backspace / Ctrl-D) stay
  separate so each backspace is its own undo step.

### Schema integrity
- **Validate cell input against `@column` type.** The header can
  specify `integer`, but the editor doesn't reject non-numeric
  input on commit. Form-validation hooks at `editCellDone` /
  `editFieldDone` would let us reject or coerce.

### Misc
- **Status doesn't show record count.** The table status bar
  shows `R:n C:m` but not the total row count.
- **No "go to record N".** **M-g** with a number prompt would
  jump straight to a record.

Once the list stabilises, each item slots into the
`recogniser` / `Mini.PromptEdit` / chained-continuation patterns
the editor already has — most are 50–100 lines of code plus a
binding.
