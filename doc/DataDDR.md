# DDR — Structured Data and Views in oed

Detailed design for the data / view system sketched in `doc/Data.md`.
Aims to turn oed from a free-form text editor into a HyperCard-style
environment over plain-text storage: typed records (collections),
multiple presentations of those records (tables, spreadsheets, forms),
and links between them. Everything still lives on disk as text.

The text-editor substrate doesn't change — Buffer, Lines, the piece
chain, Save/Load all work as today. The structured-data layer sits on
top, interpreting the bytes of selected viewers through a parsed
schema and a directive grammar.

This is v2 of the DDR, folding in resolutions from the question walk
in §16.

## 1. Conceptual model

### 1.1 Object

An Object is a single CSV row. The bytes for an Object are one line:

    Alice,30,alice@example.com

Standard CSV conventions: double-quoted strings, doubled quotes
inside, optional embedded newlines inside quotes. A user can open a
collection in any plain-text editor and read it.

### 1.2 Collection

An ordered list of Objects sharing a Schema. On disk:

    @column(name,  "Name",  string(50))
    @column(age,   "Age",   integer)
    @column(email, "Email", string(80))
    Alice,30,alice@example.com
    Bob,25,bob@example.com

The directive header (lines starting with `@`) declares the schema;
the data zone (everything after the first non-`@` line) is CSV
records. Comments (`# …`) and blank lines are allowed in the header.

### 1.3 Schema

The Schema is the ordered list of `@column` directives. Each entry:

  - `name`  — identifier; how the column is referenced in expressions
              (`c[name]` or bare `name`).
  - `label` — display string for headers / form prompts.
  - `type`  — see §4.
  - `width` — optional column width hint for tabular rendering.

### 1.4 Doc

A **Doc** is a loaded file in memory: a `Buffer.Buffer` of bytes plus
a `Lines.Lines` index plus a canonical name. Multiple Viewers can
share one Doc — for example, a `.col` opened both as a Table view
and as raw text via `C-x C-r` references the same underlying Doc.

```oberon
TYPE
  Doc* = POINTER TO DocDesc;
  DocDesc* = RECORD
    name*:  ARRAY NameLen OF CHAR;     (* canonical path *)
    buf*:   Buffer.Buffer;
    lines*: Lines.Lines
  END;
```

When the last Viewer referencing a Doc is killed, ARC reclaims the
Doc.

### 1.5 Viewer

A **Viewer** is a presentation of a Doc — a kind plus per-viewer UI
state (cursor, viewport top, mark). The viewer registry (renamed
from `Buffers.Mod` to `Viewers.Mod`) holds Viewers; that's what
`C-x b` switches between and what `C-x C-b` lists.

```oberon
TYPE
  Viewer* = POINTER TO ViewerDesc;
  ViewerDesc* = RECORD
    label*: ARRAY NameLen OF CHAR;     (* display name in viewer list *)
    doc*:   Doc;                        (* shared with other viewers possibly *)
    kind*:  INTEGER;                    (* kText, kCollection, ... *)
    cur*:   INTEGER;
    top*:   INTEGER;
    mark*:  INTEGER
  END;
```

This Doc / Viewer split is the foundational architecture. Edits
through any Viewer mutate the shared Doc; sibling Viewers see the
changes on their next Refresh. Each Viewer has its own cursor.

### 1.6 View definition

A "View definition" is the on-disk shape of a non-text Viewer kind:
a small file of directives describing how to render an underlying
collection. `.tbl`, `.frm`, `.ssh` files are view definitions. They
are themselves Docs (they have bytes) opened via Viewers.

A view definition typically declares which collection it renders
(via `@ref(/path)`), then specialises with `@filter`, `@column`,
`@prompt`, layout text, etc. depending on the kind.

A Spreadsheet's view definition (`.ssh`) is a special case — see
§7.3.

### 1.7 Synthetic collection

A Doc whose bytes are *generated programmatically* rather than
loaded from disk. Same shape as any Doc, but never persisted. The
viewer list is implemented this way: a `*viewers*` Doc holding one
row per Viewer in the registry, regenerated on each Refresh. Other
synthetic collections will follow (`*search-results*`, `*help*`,
…).

### 1.8 Project root and logical paths

oed gains a project root: a directory under which collections and
views live. Logical paths begin with `/` and map onto the filesystem
under the root.

    Project root: ~/Documents/Notes/
      Objects/
        Contact.col              ← logical /Objects/Contact
        Order.col                ← logical /Objects/Order
      Views/
        Tables/
          Contacts.tbl           ← logical /Views/Tables/Contacts
        Forms/
          ContactCard.frm        ← logical /Views/Forms/ContactCard

The root is determined by walking up from `dirname(argv[1])` looking
for a `.oed/` marker directory (git-style). First hit = root. If no
marker found, fall back to the file's own directory. With no argv,
use `pwd`. The marker can later carry config; for v1 it's just the
directory's existence.

Logical paths in directives (`@ref(/Objects/Contact)`) resolve
through `Project.Mod`, decoupling content from the user's filesystem
layout.

## 2. Viewer kinds

`Viewer.kind` is an integer with these defined values:

    kText              free-form text (today's behavior)
    kCollection        typed-row data
    kTableView         tabular projection
    kSpreadsheetView   A1-grid editing
    kFormView          single-record card with text layout
    kBufferList        the *viewers* listing (a Table over a synthetic
                       collection)
    (room for more — kHelp, kSearch, kProjectTree, …)

### 2.1 Kind detection

Kind is determined at Load time **by file extension**, not by any
in-file directive:

    .col   → kCollection
    .tbl   → kTableView
    .ssh   → kSpreadsheetView
    .frm   → kFormView
    other  → kText

There is no `@kind(...)` directive. The extension is the single
source of truth.

`C-x C-r` (find-file-as-raw-text) bypasses extension detection and
loads the file as `kText`, useful for inspecting/repairing
malformed structured files. The text Viewer's label gets a `<text>`
suffix when there's already a structured Viewer on the same Doc.

When a Viewer's Doc is saved with `C-x C-w` to a path with a
different extension, the Viewer's kind updates on next Refresh —
re-parsing schema and re-validating. Slightly magical, matches user
intuition.

Synthetic Docs (`*scratch*`, `*viewers*`, etc.) have no extension;
they keep whatever kind their creator assigned (e.g. `*viewers*`
is `kTableView`).

### 2.2 Per-kind dispatch

Each kind plugs into a dispatch table:

    kind → { Refresh, EntryKey, Save, OnLoaded }

The current `Oed.Refresh` and `Oed.EntryKey` become the entries for
`kText`. The other kinds register their own. Kind-agnostic
behaviour (movement, search, files, multi-buffer commands) stays in
`Oed.Mod`; kind-specific behaviour lives in the corresponding view
module.

## 3. Type system

Per-column types declared in `@column`:

    boolean              true | false
    integer              decimal int
    real                 IEEE-754 single
    string(maxlen)       up to maxlen UTF-8 bytes
    text                 unbounded; multi-line wrapped/escaped in CSV
    date                 YYYY-MM-DD
    time                 HH:MM[:SS]
    enum(v1, v2, ...)    one of the listed string literals
    @ref(path, c[col])   foreign key — value is the c[col] value of
                         a row in /path

For `@ref`, the on-disk cell stores the referenced row's *opaque
identifier*: the value of whichever column was nominated by the
`@ref(...)` declaration (typically a code or natural key). Plain
CSV — the cell looks like any string. The "ref-ness" is purely a
schema concern.

Implicit conversion is integer → real only. Other casts are
explicit (`int(x)` / `real(x)` etc., to be added when first
needed).

Type literals in expressions:

    boolean   true | false (bare; reserved words)
    nil       nil
    string    "hello"
    integer   42
    real      3.14
    date      "2026-05-08"
    time      "14:30"
    datetime  "2026-05-08T14:30"
    enum val  "active"  (just a string; enum type does the validation)

All literal strings (incl. dates, times, enum values) are
double-quoted. Type coercion applies when a string literal meets a
typed column in a binary operation (e.g. `c[birthday] <
"2026-01-01"` parses the string as a date).

## 4. Directive syntax

A directive is a line whose first non-whitespace character is `@`.
Grammar:

    directive  = '@' name '(' [ arg { ',' arg } ] ')'
    arg        = literal | identifier | expr | directive
               | nameBinding | '"' string '"'
    nameBinding= name '=' expr

Lexically: identifiers and integers per Oberon-07; strings are
double-quoted with `\"` for embedded quotes; expressions in
parentheses are parsed as full expressions (§5).

The header zone of a structured-data file ends at the first line
that is not blank, not a comment (`# …`), and not a directive.
Below that, content depends on the kind: data rows for collections,
layout text for forms, etc.

### 4.1 Common directives

  - `@column(name, "Label", type, [width])`
                     schema entry (collection) or projection
                     (table/form/spreadsheet column).

  - `@filter(expr)`  restrict rows to those satisfying expr.

  - `@prompt(name, "Label", type [, default])`
                     declare a runtime parameter; gathered before
                     the view first renders. 4th arg is the default
                     value (literal). The user can accept by Enter
                     or override by typing. Bound as `$name` in
                     expressions. Tab completion uses the type
                     (enum values, ref column).

  - `@ref(path [, filter [, column]])`
                     reference another collection (full or sliced).

  - `@field(expr)`   embedded field placeholder in a Form layout.

  - `@link(label, view-path [, name=expr]*)`
                     navigable link from a row to a view; bindings
                     pre-fill the target's prompts. See §8.

  - `@cell(coord [, key=value]*)`
                     spreadsheet cell override (formula, format,
                     etc.). Coord is A1-style. See §7.3.

## 5. Expression language

Used by `@filter`, `@field`, spreadsheet formulas, and any directive
arg that's a parenthesised expression. Recursive-descent grammar:

    expr        = orExpr
    orExpr      = andExpr  { 'or' andExpr }
    andExpr     = relExpr  { 'and' relExpr }
    relExpr     = addExpr  [ relop addExpr ]
    addExpr     = mulExpr  { ('+' | '-') mulExpr }
    mulExpr     = unary    { ('*' | '/') unary }
    unary       = ['-' | 'not'] factor
    factor      = literal | colExpr | promptref | cellref | rangeref
                | funcCall | '(' expr ')'
    relop       = '=' | '#' | '<' | '<=' | '>' | '>='
    colExpr     = ( name | 'c' '[' name ']' ) { '.' name }
    promptref   = '$' name
    cellref     = letter [ letter ] digit { digit }   (* spreadsheet only *)
    rangeref    = cellref ':' cellref                  (* spreadsheet only *)
    funcCall    = name '(' [ expr { ',' expr } ] ')'

Disambiguation rules:

  1. **Function vs identifier**: trailing `(` makes it a function
     call. `sum > 10` is "compare column `sum` to 10";
     `sum(c[age])` is a function call.
  2. **Cell vs column in spreadsheet scope**: identifier matching
     `[A-Z]+[0-9]+` is a cell ref; otherwise column ref. `c[A1]` is
     the escape hatch for a column literally named "A1".
  3. **Cell refs outside spreadsheet scope** don't exist —
     identifiers are column refs.
  4. **Prompts** require `$` prefix.
  5. **`c[name]` always works** — escape hatch for column names that
     would otherwise parse as keywords or function names.

Selector chains (`.field`) follow `@ref`-typed columns into the
target row. `c[country].name` looks up the row in
`/Lookups/Country` whose lookup column equals the cell's value, and
projects `c[name]`. Chains compose:
`c[order].customer.address.city`. Missing target →
`<?ID>` placeholder; type mismatch → `<error>` sentinel; cycles
truncated at depth 8 with `<cycle>`.

Built-in functions for v1:

    sum(range)    avg(range)    count(range)    min(range)    max(range)
    if(c, a, b)   len(s)        concat(...)     not(b)
    int(x)        real(x)       date(s)         time(s)

The evaluator takes a `Scope` callback bundle: column lookup,
prompt lookup, cell lookup, function lookup, ref dereference. The
same evaluator runs over named-column and A1-grid scopes.

Reserved-word list: `and`, `or`, `not`, `true`, `false`, `nil`. A
column with one of these names is accessible only as `c[name]`.

## 6. Views — common architecture

All view kinds are projections over data Docs. Three rules apply
across kinds:

  - **One backing collection per view.** Each view definition has at
    most one `@ref(...)` directive. (Joins / multi-collection
    queries are deferred — see §15.)
  - **Pull-on-focus rendering.** Each Viewer reads bytes from its
    Doc(s) on every Refresh; no per-Viewer caches that can drift
    from the bytes. Edits propagate through the shared Doc to
    sibling Viewers automatically.
  - **Eager commit.** Field/cell/row edits write back to the
    underlying Doc on commit (no staging). Closing without saving
    the Doc still loses the changes since the Doc is dirty in
    memory; `b.changed` is the gate.

### 6.1 Cross-Viewer state and two-Doc views

Most view kinds depend on exactly one Doc — the view file itself.
A `kTableView` Viewer's `doc` field points at the `.tbl` file's
Doc; the underlying `.col` is fetched per Refresh through
`@ref(...)`.

Spreadsheets are special: a `kSpreadsheetView` Viewer needs both
the `.ssh` (its own Doc) and the `.col` (a separate Doc fetched on
demand). Edits route to whichever file owns the affected state
(see §7.3).

This pattern — a Viewer depending on multiple Docs — is general.
Future view kinds (e.g., reports combining multiple data sources)
follow the same pattern.

## 7. Views — kinds in detail

### 7.1 Table

A Table view definition (`.tbl`):

    @ref(/Objects/Contact)
    @prompt(minAge, "Minimum age", integer, 0)
    @filter(c[age] >= $minAge)
    @column(c[name],  "Name",  20)
    @column(c[age],   "Age",   4)
    @column(c[email], "Email", 30)

Render: a header row from `@column` labels; one data row per
matching record. Cells are produced by evaluating the expression in
each `@column`'s first arg against the row's scope. Computed
columns:
`@column(c[age]*12, "Age (months)", 6)`.

Editing: Enter on a cell opens a minibuffer-style edit. On commit,
the corresponding column of the underlying row is rewritten in the
backing collection. The collection Doc's `b.changed` flips; `C-x s`
saves it. (See §6 — eager commit.)

Cell navigation: arrows, `C-f`/`C-b`/`C-n`/`C-p`, `Home`/`End` for
row, `M-<`/`M->` for first/last row.

Synthetic Tables (e.g., `*viewers*`, `*search-results*`) may
declare row actions:

  - `Enter` on a row: switch to that Viewer (for `*viewers*`).
  - `k` on a row: kill that Viewer.

For v1, row actions are hardcoded for the synthetic Docs we
implement; later, `@onEnter(...)` etc. directives generalise this.

### 7.2 Form

Mixed directive header + layout text (`.frm`):

    @ref(/Objects/Contact)
    @prompt(qname, "Name to find", string)
    @filter(c[name] = $qname)

    Name:    @field(c[name])
    Age:     @field(c[age])
    Email:   @field(c[email])

Header zone ends at the first blank line; below that, the form's
*layout text* renders as-is, with `@field(...)` placeholders
substituted by the matching column from the *current* record.

If `@filter` matches multiple rows, the form is paginated:

  - `M-p` / `M-n`     previous / next record (buffer-local).
  - `Tab` / `S-Tab`   next / previous editable @field.
  - `Enter` on a field: edit (substitutes a minibuffer in place).

Field edits write back to the collection on commit (eager).

If editing a field changes a value the filter depends on, the row
stays visible until the next page-step (M-n / M-p), then
re-evaluates. Surprising-but-tolerable; refining means re-running
the filter on every commit.

### 7.3 Spreadsheet

The architecture differs from Table/Form. A spreadsheet pairs:

  - A `.col` data file (pure CSV; positional grid).
  - A `.ssh` view file (formulas, formatting, labels declared as
    overrides).

Editing routing rule: **any cell content beginning with `=` goes to
the `.ssh` as an `@cell` directive; all other content goes to the
`.col` at the corresponding (col, row).**

Format / alignment / comment commands also write to the `.ssh` as
`@cell(coord, key=value)` entries.

Example `.ssh` for a mortgage planner:

    @ref(/Calc/Mortgage)
    @cell(B2, formula="=B1*0.05")
    @cell(B3, formula="=PMT(B2, 360, B1)")
    @cell(A1, format="bold")
    @cell(A2, format="bold")
    @cell(A3, format="bold")

The matching `.col`:

    Loan Amount,
    Interest Rate,
    Monthly Payment,
    100000,
    ,
    ,

On render, the spreadsheet view composes each cell:

  1. If `@cell(coord, formula=...)` exists, evaluate the formula
     (using `.col` values, `@cell` overrides for other cells, and
     prompt parameters).
  2. Else, read `.col` at (col, row).
  3. Apply formatting from `@cell(coord, format=...)` if present.

Spreadsheet UX:

  - **Always in edit mode.** Cell navigation is the outer state;
    pressing any printable char or `=` enters cell-edit; Enter
    commits and moves down. No view/edit toggle.
  - **A1 references** are positional. Schema column names (if any)
    are display-only; they show as the column label, but formulas
    use `A`, `B`, `C`, …
  - **Cache invalidation**: v1 wholesale invalidate on any edit;
    re-evaluate all formula cells on next Refresh. Refinement via
    dependency tracking is deferred.
  - **No persistent cache**: v1 re-evaluates every formula on each
    Refresh. Add a `value=` slot in `@cell` later if profiling
    shows it's needed.
  - **Forwards-compat**: unknown `@cell` keys are preserved through
    the round-trip but ignored. So a v3 build adding `comment=` /
    `validation=` doesn't break v1 readers, and v1 saves don't
    strip newer metadata if a sibling tool wrote it.

The data/view split enables workflow patterns spreadsheets are
historically weak at — e.g., a single mortgage `.ssh` shared
between many `.col` scenario files. The user copies a `.col`,
edits values, watches formulas re-compute. Reset = revert one file.

**Future direction (not v1)**: Lotus Improv-style named-axis
references. Each row/column carries an optional name; formulas can
reference axes by name (`=loan * rate`) instead of position
(`=B1 * B2`). The directive grammar (`@col(letter=B, name="rate")`)
leaves room for this without disturbing v1 cell semantics.

## 8. References and links

`@ref(path, filter, column)` resolves to:

  - `path`   — collection logical path.
  - `filter` — optional row predicate.
  - `column` — optional projection of a single column.

A column declared `@ref(/Lookups/Country, c[code])` stores
`c[code]` of a row in the target. Forms can dereference and chase:

    @field(c[country])           → "AU" (raw stored ID)
    @field(c[country].name)      → "Australia" (dereferenced)

Dereference is render-time only — single-direction navigation,
not a relational join.

`@link(label, view-path, name=expr*)` is an inline element used in
Form layout text or Table column expressions. Renders as `label`;
pressing Enter navigates to the named view, evaluating each
`name=expr` binding in the *source row's scope* and pre-filling
the target's matching `@prompt(name, ...)` slots. Bindings without
a matching prompt are silently ignored (forward-compat). Prompts
without a binding fall through to the prompt's normal flow.

Link in plain (non-row-scoped) layout: `c[col]` bindings produce a
"no row context" parse error. Use prompt refs (`$x`) and literals
in such contexts.

Navigation through a link pushes onto the back-stack (see §11);
`C-x [` returns to the source view.

## 9. Synthetic collections

Some collections are produced by the editor at runtime rather than
loaded from disk:

  - `*viewers*` — the Viewer registry, one row per open Viewer.
  - `*search-results*` — output of search-and-replace (future).
  - `*help*` — help text browser (future).

Schema for `*viewers*`:

    @column(label, "Label", string(64))
    @column(kind,  "Kind",  enum(text, collection, table, spreadsheet, form))
    @column(path,  "Path",  string(128))
    @column(size,  "Size",  integer)
    @column(dirty, "Dirty", boolean)

Regeneration: when a Table Viewer over a synthetic Doc is
Refreshed, the Doc's bytes are wiped and rewritten from the
in-memory source (the Viewer registry, in this case). No
invalidation hooks; the Refresh path always regenerates.

Saving a synthetic Doc is a no-op (or could be made an error). The
Doc is never persisted to disk; it lives only as long as a Viewer
references it.

Synthetic collections are valuable validation: if `*viewers*`
works as a Table, real `.tbl` files work the same way. The
mechanism extends naturally to other generated content.

## 10. Persistence

Default file extensions:

    .col   collection
    .tbl   table view
    .ssh   spreadsheet view
    .frm   form view

Other extensions default to `kText`.

Save uses the existing `Buffer.Save` — walks the piece chain and
writes bytes verbatim. Edits made through view kinds are reflected
in the underlying Doc's bytes *as the edit happens*, so the Doc is
always saveable. There is no "compile to binary" step.

Synthetic Docs are not persisted.

## 11. Navigation history

Per-window back/forward stack. v1 has one window (single viewport);
later split-windows give each pane its own history.

```oberon
TYPE
  Window* = POINTER TO WindowDesc;
  WindowDesc* = RECORD
    current*:  Viewers.Viewer;
    backStack: ARRAY HistMax OF Viewers.Viewer;
    backTop:   INTEGER;
    fwdStack:  ARRAY HistMax OF Viewers.Viewer;
    fwdTop:    INTEGER
  END;
```

Behaviour:

  - **Navigate** (link, C-x b, C-x C-f): push current onto `back`,
    clear `fwd`, set current to target. Skip the push if
    `target = current`.
  - **`C-x [`** back: if back non-empty, push current onto `fwd`,
    pop into current.
  - **`C-x ]`** forward: if fwd non-empty, push current onto
    `back`, pop into current.
  - **Killed Viewers** in either stack: filter dead refs lazily on
    next navigation.

Bounded stack (HistMax = 64). Older entries fall off.

Form-level record paging (M-p / M-n) is buffer-local to a Form
Viewer and doesn't affect the global view history.

## 12. Doc / Viewer kinds in code

`Doc.Mod` exposes the Doc type and helpers (load, save, decoding
the schema header).

`Viewers.Mod` (renamed from `Buffers.Mod`) holds the registry,
provides `Add`, `Find`, `Current`, `SetCurrent`, `Kill`,
`RegenerateSyntheticListing`.

`Oed.Mod` is the kind-agnostic dispatcher. It owns the Window, the
kill ring, and per-kind dispatch:

```oberon
VAR dispatch: ARRAY KindCount OF KindOps;

TYPE KindOps = RECORD
  refresh:    PROCEDURE(v: Viewer);
  entryKey:   PROCEDURE(v: Viewer; k: INTEGER);
  save:       PROCEDURE(v: Viewer; VAR res: INTEGER);
  onLoaded:   PROCEDURE(v: Viewer)
END;
```

Per-kind modules register themselves at startup.

## 13. Module decomposition

New modules to add, in implementation order:

  - **`Doc.Mod`** — Doc type; load/save/refresh; schema-header
    detection; canonical names. Wraps the existing Buffer + Lines.
  - **`Csv.Mod`** — CSV row reader/writer over `Buffer.Reader`.
    Handles quoting, embedded newlines, embedded commas.
  - **`Directive.Mod`** — directive lexer + parser. Each header
    line returns a `(name, [arg])` AST. Pure syntax.
  - **`Expr.Mod`** — expression parser + evaluator. Takes a
    `Scope` callback bundle.
  - **`Schema.Mod`** — schema built from `@column` directives.
    Provides column→index, name→type, etc.
  - **`Collection.Mod`** — typed wrapper over a `Doc` + `Schema`.
    Row iteration, lookup-by-(row, col), and edits that rewrite the
    underlying CSV row in place.
  - **`Project.Mod`** — root path + logical-to-disk mapping.
  - **`Window.Mod`** — current Viewer, back/forward stacks,
    navigation. v1 is a single Window instance.
  - **`View.Mod`** — common view dispatch (filter, prompts, ref
    resolution, history). Each view kind:
    - **`TableView.Mod`**       table render and cell edit.
    - **`SpreadsheetView.Mod`** A1 render, formula evaluation,
                                `=`-routing on edit.
    - **`FormView.Mod`**        layout-text render with `@field`
                                substitution and pagination.

`Viewers.Mod` (renamed from `Buffers.Mod`) gains a Doc registry
implicit via Viewer references; new helpers for synthetic Docs.

## 14. Migration plan

Each step is a self-contained increment producing a working build.

  1. **Doc / Viewer split.** Refactor `Buffers.Mod` →
     `Viewers.Mod`. Introduce `Doc.Mod`. Move Buffer / Lines /
     name from Viewer fields into Doc. All existing tests pass.
  2. **Kind by extension.** Viewer has `kind: INTEGER`; load-time
     extension dispatch sets it. `kText` for everything for now —
     no behavior change. `C-x C-r` (find-file-as-raw-text) added.
  3. **Project.Mod.** `.oed/` marker walk-up; logical path
     resolution. Used implicitly by file commands.
  4. **`Csv.Mod` and `Directive.Mod`** with unit tests over
     `Buffer.Buffer`.
  5. **`@column` recognition at Load.** `kCollection` viewers
     parse the schema header; status displays the schema. Editing
     still uses `kText` keymap.
  6. **`Schema.Mod` and `Collection.Mod`.** `CollectionTest`
     covers row iteration and edits.
  7. **`Expr.Mod`** with flat scope. Tests for arithmetic,
     comparison, built-ins.
  8. **`TableView.Mod`** read-only. Loading a `.tbl` shows a
     working tabular view.
  9. **Cell edit in Tables** — write back to underlying
     collection.
 10. **`Project.Mod` `@ref` resolution.** Cross-file references
     work.
 11. **Synthetic `*viewers*`.** `C-x C-b` is now a Table view
     over a synthetic collection.
 12. **`FormView.Mod`** layout rendering + record pagination.
 13. **`SpreadsheetView.Mod`**:
     a. `.ssh` parser/writer (`@cell` directives).
     b. Cell composition from `.ssh` + `.col`.
     c. Formula evaluation with cache invalidation.
     d. `=`-prefix routing on edit.
     e. Format directives.
 14. **`@link` and view history.** Navigation between views,
     `C-x [` / `C-x ]`.
 15. **`Window.Mod`**, with navigation history. (Could be
     consolidated into Step 14.)

Tree (the brief flagged it as deferred) is one Table convention
away from working: column 0 is indent depth; renderer indents
accordingly. We adopt that convention without a new view kind for
v1.

## 15. Future directions

Items deliberately deferred from v1.

  - **True multi-collection joins.** A view declaring multiple
    `@ref(...)` directives, with cross-collection filters and
    cartesian products. Needs a query language step beyond what we
    have.
  - **Lotus Improv-style named axes.** Spreadsheet rows/columns
    carrying names; formulas reference `=loan * rate` instead of
    `=B1 * B2`. Directive: `@col(letter=B, name="rate")`. Forward-
    compatible with v1 cell semantics.
  - **Persistent formula caches.** Add `value=` to `@cell` if
    profile says re-evaluation is too slow.
  - **Form transactions.** A "save" or "cancel" mode for Forms
    where edits stage until commit, instead of eager. Would need a
    Form-local edit buffer.
  - **Read-only views** as a flag in the view definition.
  - **Mark coherence under edits** (already on the editor's ToDo).
    Critical for cell selection / clipboard once those exist.
  - **Async formula evaluation** for big sheets that block the
    editor today.
  - **Range / column / sheet-level formatting** (not just per-cell
    `@cell`).
  - **`@onEnter`, `@onKill`, `@onLoad`** directives generalising
    synthetic-collection row actions.
  - **Search across collections** (`*search-results*` as a
    synthetic collection).

## 16. Resolved questions

Pointer back to the design conversations that locked each decision.
Section references are to v2 (this document).

| Q | Topic | Resolution | See |
|---|---|---|---|
| 1 | Project root | `.oed/` marker walk-up from argv; fallback to dirname; pwd if no argv | §1.8 |
| 2 | Buffer kind detection | File extension; no `@kind` directive; `C-x C-r` for raw-text override | §2.1 |
| 3 | `@prompt` 4th arg | Default value; type carries the picker / completion source | §4.1 |
| 4 | `@ref` cell on-disk format | Opaque ID = the referenced column's value; plain CSV | §3 |
| 5 | Spreadsheet vs collection isomorphism | Relaxed; A1 references positional; schema names display only | §7.3 |
| 6 | Table view of formula-bearing collection | N/A — formulas live in `.ssh`, not `.col`, so tables never see them | §7.3 |
| 7 | Form edit ↔ collection commit | Eager (HyperCard-style); edits write through on Enter | §6 / §7.2 |
| 8 | Multi-collection joins in a view | Single backing collection per view; ref-dereferencing covers most cases | §6 |
| 9 | History scope | Per-window from day one; v1 has one Window | §11 |
| 10 | Cross-Viewer change notification | Pull-on-focus; Doc bytes are single source of truth | §6 / §6.1 |
| 11 | Bare identifier in expressions | Column shorthand; `(` makes it a function call | §5 |
| 12 | Date/time literal syntax | Quoted ISO strings; type coercion at operand level | §3 |
| 13 | Reference dereferencing syntax | `c[col].field` selector chain | §5 / §8 |
| 14 | `@link` parameter passing | Explicit `name=expr` bindings; no implicit by-name | §8 |

Architectural decisions reached during the walk:

  - **Doc / Viewer split** (§1.4 / §1.5). Replaces the previous
    BufRec which fused data and presentation. Multiple Viewers can
    share a Doc; killing a Viewer drops one reference.
  - **Synthetic collections** (§1.7). `*viewers*` is a Table over
    a synthetic Doc, regenerated per Refresh. The mechanism
    generalises to `*search-results*`, `*help*`, etc.
  - **`.col` / `.ssh` data-view split for spreadsheets** (§7.3).
    Replaces the cell-envelope idea (TAB-separated formula + value
    in a single CSV cell). The `=`-prefix routing rule directs
    typed content to the right file at edit time. Enables shared-
    formula / multi-scenario workflows that single-file
    spreadsheets handle poorly.
