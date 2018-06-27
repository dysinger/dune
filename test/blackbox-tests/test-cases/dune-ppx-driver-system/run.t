No ppx driver found

  $ dune build foo1.cma
  File "dune", line 6, characters 14-19:
  Error: You must specify at least one ppx rewriter.
  [1]

Too many drivers

  $ dune build foo2.cma
  File "dune", line 13, characters 14-29:
  Error: Too many incompatible ppx drivers were found: foo.driver2 and
  foo.driver1.
  [1]

Not compatible with Dune

  $ dune build foo3.cma
  File "dune", line 20, characters 14-29:
  Error: No ppx driver were found. It seems that ppx_other is not compatible
  with Dune. Examples of ppx rewriters that are compatible with Dune are ones
  using ocaml-migrate-parsetree, ppxlib or ppx_driver.
  [1]

Same, but with error pointing to .ppx

  $ dune build .ppx/foo.ppx1+foo.ppx2/ppx.exe
  File "_build/default/.ppx/foo.ppx1+foo.ppx2/ppx.exe", line 1, characters 0-0:
  Error: Failed to create on-demand ppx rewriter for foo.ppx1 and foo.ppx2; too
  many incompatible ppx drivers were found: foo.driver2 and foo.driver1.
  [1]

  $ dune build .ppx/foo.ppx-other/ppx.exe
  File "_build/default/.ppx/foo.ppx-other/ppx.exe", line 1, characters 0-0:
  Error: Failed to create on-demand ppx rewriter for foo.ppx-other; no ppx
  driver were found. It seems that foo.ppx-other is not compatible with Dune.
  Examples of ppx rewriters that are compatible with Dune are ones using
  ocaml-migrate-parsetree, ppxlib or ppx_driver.
  [1]

Test the argument syntax

  $ dune build test_ppx_args.cma
           ppx test_ppx_args.pp.ml
  .ppx/driver_print_args@foo/ppx.exe
  -arg1
  -arg2
  -foo
  bar
  --cookie
  library-name="test_ppx_args"
  -o
  test_ppx_args.pp.ml
  --impl
  test_ppx_args.ml
  Error: Rule failed to generate the following targets:
  - test_ppx_args.pp.ml
  [1]