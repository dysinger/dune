Formatting can be checked using the @fmt target:

  $ cp enabled/ocaml_file.ml.orig enabled/ocaml_file.ml
  $ cp enabled/reason_file.re.orig enabled/reason_file.re
  $ dune build --root enabled @fmt
  Entering directory 'enabled'
  File "reason_file.rei", line 1, characters 0-0:
  Files _build/default/reason_file.rei and _build/default/reason_file.rei.formatted differ.
  File "reason_file.re", line 1, characters 0-0:
  Files _build/default/reason_file.re and _build/default/reason_file.re.formatted differ.
  File "ocaml_file.mli", line 1, characters 0-0:
  Files _build/default/ocaml_file.mli and _build/default/ocaml_file.mli.formatted differ.
  File "ocaml_file.ml", line 1, characters 0-0:
  Files _build/default/ocaml_file.ml and _build/default/ocaml_file.ml.formatted differ.
  File "subdir/lib.ml", line 1, characters 0-0:
  Files _build/default/subdir/lib.ml and _build/default/subdir/lib.ml.formatted differ.
  [1]

And fixable files can be promoted:

  $ cd enabled; dune promote ocaml_file.ml reason_file.re
  Promoting _build/default/ocaml_file.ml.formatted to ocaml_file.ml.
  Promoting _build/default/reason_file.re.formatted to reason_file.re.
  $ cat enabled/ocaml_file.ml
  let y = ()
  $ cat enabled/reason_file.re
  let y = ();

For projects without (using fmt), this does nothing:

  $ dune build --root disabled @fmt
  Entering directory 'disabled'
  From the command line:
  Error: Alias "fmt" is empty.
  It is not defined in . or any of its descendants.
  [1]

It is also possible to enable formatting only for some syntaxes.

  $ dune build --root partial @fmt
  Entering directory 'partial'
  File "a.ml", line 1, characters 0-0:
  Files _build/default/a.ml and _build/default/a.ml.formatted differ.
  [1]
