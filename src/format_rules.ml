open Import

let flag_of_kind : Ml_kind.t -> _ =
  function
  | Impl -> "--impl"
  | Intf -> "--intf"

let dep loc x = String_with_vars.make_macro loc "dep" x

type outcome =
  | Format_using of Action.Unexpanded.t
  | Not_formatted
  | Missing_tool of string

let ocamlformat_bin = lazy (Bin.which "ocamlformat")

let ocamlformat_action ofmt kind loc path =
  let flag = flag_of_kind kind in
  let exe = dep loc @@ Path.to_string ofmt in
  let args =
    [ String_with_vars.make_text loc flag
    ; dep loc path
    ; String_with_vars.make_text loc "-o"
    ; String_with_vars.make_var loc "targets"
    ]
  in
  Action.Unexpanded.Run (exe, args)

let config_includes config s =
  match (config : Dune_file.Auto_format.enabled_for) with
  | Default -> true
  | Only set -> List.mem s ~set

let ocamlformat kind loc path =
  match Lazy.force ocamlformat_bin with
  | Some ofmt -> Format_using (ocamlformat_action ofmt kind loc path)
  | None -> Missing_tool "ocamlformat"

let refmt_action rfmt loc path =
  let exe = dep loc @@ Path.to_string rfmt in
  let args = [dep loc path] in
  Action.Unexpanded.Redirect
    ( Stdout
    , String_with_vars.make_var loc "targets"
    , Run (exe, args)
    )

let refmt_bin = lazy (Bin.which "refmt")

let refmt loc path =
  match Lazy.force refmt_bin with
  | Some rfmt -> Format_using (refmt_action rfmt loc path)
  | None -> Missing_tool "refmt"

let detect : _ -> (Dune_file.Auto_format.language * Ml_kind.t) option =
  function
  | ".ml" -> Some (Ocaml, Impl)
  | ".mli" -> Some (Ocaml, Intf)
  | ".re" -> Some (Reason, Impl)
  | ".rei" -> Some (Reason, Intf)
  | _ -> None

let formatter_for_path config loc path =
  match detect (Filename.extension path) with
  | Some (language, kind) when config_includes config language ->
    begin
      match language with
      | Reason -> refmt loc path
      | Ocaml -> ocamlformat kind loc path
    end
  | _ -> Not_formatted

let add_alias_format sctx loc ~dir ~scope action =
  let alias_conf =
    { Dune_file.Alias_conf.name = "fmt"
    ; deps = []
    ; action = Some (loc, action)
    ; locks = []
    ; package = None
    ; enabled_if = None
    ; loc
    }
  in
  Simple_rules.alias sctx ~dir ~scope alias_conf

let run_rule ~target ~action ~loc =
  { Dune_file.Rule.targets = Static [target]
  ; action = (loc, action)
  ; mode = Standard
  ; deps = []
  ; locks = []
  ; loc
  }

let diff file1 file2 =
  Action.Unexpanded.Diff
    { optional = false
    ; mode = Text
    ; file1
    ; file2
    }

let rules_for_file action loc path =
  let target = String_with_vars.make_text loc (path ^ ".formatted") in
  let format_rule = run_rule ~loc ~target ~action in
  let diff_action = diff (dep loc path) target in
  (format_rule, diff_action)

let setup_formatters files config loc ~setup_rules =
  Path.Set.fold files ~init:String.Set.empty ~f:(fun file acc ->
    let path = Path.basename file in
    match formatter_for_path config loc path with
    | Format_using action ->
      setup_rules (rules_for_file action loc path);
      acc
    | Not_formatted -> acc
    | Missing_tool tool -> String.Set.add acc tool)

let gen_rules sctx (config : Dune_file.Auto_format.t) ~dir ~scope =
  let loc = config.loc in
  let add_alias action = add_alias_format sctx loc ~dir ~scope action in
  let setup_rules (format_rule, diff_action) =
    let _ : Path.t list =
      Simple_rules.user_rule sctx ~dir ~scope format_rule
    in
    add_alias diff_action
  in
  let files =
    File_tree.files_of
      (Super_context.file_tree sctx)
      (Path.drop_build_context_exn dir)
  in
  let unknown_tools = setup_formatters files config.enabled_for loc ~setup_rules in
  if not (String.Set.is_empty unknown_tools) then
    let msg =
      Printf.sprintf
        "Cannot find the following tools, skipping associated files: %s\n"
        (String.concat ~sep:", " (String.Set.to_list unknown_tools))
    in
    add_alias (Echo [String_with_vars.make_text loc msg])
