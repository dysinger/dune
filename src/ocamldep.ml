open! Stdune
open Import
open Build.O

module CC = Compilation_context
module SC = Super_context

module Dep_graph = struct
  type t =
    { dir        : Path.t
    ; per_module : (unit, Module.t list) Build.t Module.Name.Map.t
    }

  let deps_of t (m : Module.t) =
    match Module.Name.Map.find t.per_module m.name with
    | Some x -> x
    | None ->
      Exn.code_error "Ocamldep.Dep_graph.deps_of"
        [ "dir", Path.to_sexp t.dir
        ; "modules", Sexp.To_sexp.(list Module.Name.to_sexp)
                       (Module.Name.Map.keys t.per_module)
        ; "module", Module.Name.to_sexp m.name
        ]

  let top_closed t modules =
    Build.all
      (List.map (Module.Name.Map.to_list t.per_module) ~f:(fun (unit, deps) ->
         deps >>^ fun deps -> (unit, deps)))
    >>^ fun per_module ->
    let per_module = Module.Name.Map.of_list_exn per_module in
    match
      Module.Name.Top_closure.top_closure modules
        ~key:Module.name
        ~deps:(fun m ->
          Option.value_exn (Module.Name.Map.find per_module (Module.name m)))
    with
    | Ok modules -> modules
    | Error cycle ->
      die "dependency cycle between modules in %s:\n   %a"
        (Path.to_string t.dir)
        (Fmt.list ~pp_sep:Fmt.nl (Fmt.prefix (Fmt.string "-> ") Module.Name.pp))
        (List.map cycle ~f:Module.name)

  let top_closed_implementations t modules =
    Build.memoize "top sorted implementations" (
      let filter_out_intf_only = List.filter ~f:Module.has_impl in
      top_closed t (filter_out_intf_only modules)
      >>^ filter_out_intf_only)

  let dummy (m : Module.t) =
    { dir = Path.root
    ; per_module = Module.Name.Map.singleton m.name (Build.return [])
    }

  let wrapped_compat ~modules ~wrapped_compat =
    { dir = Path.root
    ; per_module = Module.Name.Map.merge wrapped_compat modules ~f:(fun _ d m ->
        match d, m with
        | None, None -> assert false
        | Some wrapped_compat, None ->
          Exn.code_error "deprecated module needs counterpart"
            [ "deprecated", Module.to_sexp wrapped_compat
            ]
        | None, Some _ -> None
        | Some _, Some m -> Some (Build.return [m])
      )
    }
end

module Dep_graphs = struct
  type t = Dep_graph.t Ml_kind.Dict.t

  let dummy m =
    Ml_kind.Dict.make_both (Dep_graph.dummy m)

  let wrapped_compat ~modules ~wrapped_compat =
    Ml_kind.Dict.make_both (Dep_graph.wrapped_compat ~modules ~wrapped_compat)

  let merge_for_impl ~(vlib : t) ~(impl : t) =
    { Ml_kind.Dict.
      impl =
        { Dep_graph.
          dir = impl.impl.dir
        ; per_module =
            Module.Name.Map.merge vlib.impl.per_module impl.impl.per_module
              ~f:(fun _ vlib impl ->
                match vlib, impl with
                | None, None -> assert false
                | Some d, None
                | None, Some d -> Some d
                | Some v, Some i ->
                  (* Special case when there's only 1 module named after the
                     alias module *)
                  Some (
                    v &&& i >>^ (fun (v, i) ->
                      assert (v = []);
                      i)
                  )
              )
        }
    (* implementations don't introduce interface deps b/c they don't have
       interfaces *)
    ; intf =
        { vlib.intf with
          per_module =
            Module.Name.Map.map vlib.intf.per_module ~f:(fun v ->
              v >>^ List.map ~f:Module.remove_files
            )
        }
    }
end

let parse_module_names ~(unit : Module.t) ~modules words =
  let open Module.Name.Infix in
  List.filter_map words ~f:(fun m ->
    let m = Module.Name.of_string m in
    if m = unit.name then
      None
    else
      Module.Name.Map.find modules m)

let is_alias_module cctx (m : Module.t) =
  let open Module.Name.Infix in
  match CC.alias_module cctx with
  | None -> false
  | Some alias -> alias.name = m.name

let parse_deps cctx ~file ~unit lines =
  let dir                  = CC.dir                  cctx in
  let alias_module         = CC.alias_module         cctx in
  let lib_interface_module = CC.lib_interface_module cctx in
  let modules              = CC.modules              cctx in
  let invalid () =
    die "ocamldep returned unexpected output for %s:\n\
         %s"
      (Path.to_string_maybe_quoted file)
      (String.concat ~sep:"\n"
         (List.map lines ~f:(sprintf "> %s")))
  in
  match lines with
  | [] | _ :: _ :: _ -> invalid ()
  | [line] ->
    match String.lsplit2 line ~on:':' with
    | None -> invalid ()
    | Some (basename, deps) ->
      let basename = Filename.basename basename in
      if basename <> Path.basename file then invalid ();
      let deps =
        String.extract_blank_separated_words deps
        |> parse_module_names ~unit ~modules
      in
      let stdlib = CC.stdlib cctx in
      let deps =
        match stdlib, CC.lib_interface_module cctx with
        | Some { modules_before_stdlib; _ }, Some m when unit.name = m.name ->
          (* See comment in [Dune_file.Stdlib]. *)
          List.filter deps ~f:(fun m ->
            Module.Name.Set.mem modules_before_stdlib m.Module.name)
        | _ -> deps
      in
      if Option.is_none stdlib then
        Option.iter lib_interface_module ~f:(fun (m : Module.t) ->
          let open Module.Name.Infix in
          if unit.name <> m.name && not (is_alias_module cctx unit) &&
             List.exists deps ~f:(fun x -> Module.name x = m.name) then
            die "Module %a in directory %s depends on %a.\n\
                 This doesn't make sense to me.\n\
                 \n\
                 %a is the main module of the library and is \
                 the only module exposed \n\
                 outside of the library. Consequently, it should \
                 be the one depending \n\
                 on all the other modules in the library."
              Module.Name.pp unit.name (Path.to_string dir)
              Module.Name.pp m.name
              Module.Name.pp m.name);
      match stdlib with
      | None -> begin
          match alias_module with
          | None -> deps
          | Some m -> m :: deps
        end
      | Some { modules_before_stdlib; _ } ->
        if Module.Name.Set.mem modules_before_stdlib unit.name then
          deps
        else
          match CC.lib_interface_module cctx with
          | None -> deps
          | Some m ->
            if unit.name = m.name then
              deps
            else
              m :: deps

let deps_of cctx ~ml_kind unit =
  let sctx = CC.super_context cctx in
  if is_alias_module cctx unit then
    Build.return []
  else
    match Module.file unit ml_kind with
    | None -> Build.return []
    | Some file ->
      let file_in_obj_dir ~suffix file =
        let base = Path.basename file in
        Path.relative (Compilation_context.obj_dir cctx) (base ^ suffix)
      in
      let all_deps_path file = file_in_obj_dir file ~suffix:".all-deps" in
      let context = SC.context sctx in
      let all_deps_file = all_deps_path file in
      let ocamldep_output = file_in_obj_dir file ~suffix:".d" in
      SC.add_rule sctx
        (let flags = Option.value unit.pp ~default:(Build.return []) in
         flags >>>
         Build.run ~context (Ok context.ocamldep)
           [ A "-modules"
           ; Dyn (fun flags -> As flags)
           ; Ml_kind.flag ml_kind
           ; Dep file
           ]
           ~stdout_to:ocamldep_output
        );
      let build_paths dependencies =
        let dependency_file_path m =
          let file_path m =
            if is_alias_module cctx m then
              None
            else
              match Module.file m Ml_kind.Intf with
              | Some _ as x -> x
              | None ->
                Module.file m Ml_kind.Impl
          in
          let module_file_ =
            match file_path m with
            | Some v -> Some v
            | None ->
              Module.name m
              |> Module.Name.Map.find (Compilation_context.modules_of_vlib cctx)
              |> Option.bind ~f:file_path
          in
          Option.map ~f:all_deps_path module_file_
        in
        List.filter_map dependencies ~f:dependency_file_path
      in
      SC.add_rule sctx
        ( Build.lines_of ocamldep_output
          >>^ parse_deps cctx ~file ~unit
          >>^ (fun modules ->
            (build_paths modules,
             List.map modules ~f:(fun m ->
               Module.Name.to_string (Module.name m))
            ))
          >>> Build.merge_files_dyn ~target:all_deps_file);
      Build.memoize (Path.to_string all_deps_file)
        ( Build.lines_of all_deps_file
          >>^ parse_module_names ~unit ~modules:(CC.modules cctx))

let rules_generic cctx ~modules =
  Ml_kind.Dict.of_func
    (fun ~ml_kind ->
       let per_module =
         Module.Name.Map.map modules ~f:(deps_of cctx ~ml_kind)
       in
       { Dep_graph.
         dir = CC.dir cctx
       ; per_module
       })

let rules cctx = rules_generic cctx ~modules:(CC.modules cctx)

let rules_for_auxiliary_module cctx (m : Module.t) =
  rules_generic cctx ~modules:(Module.Name.Map.singleton m.name m)

let graph_of_remote_lib ~obj_dir ~modules =
  let deps_of unit ~ml_kind =
    match Module.file unit ml_kind with
    | None -> Build.return []
    | Some file ->
      let file_in_obj_dir ~suffix file =
        let base = Path.basename file in
        Path.relative obj_dir (base ^ suffix)
      in
      let all_deps_path file = file_in_obj_dir file ~suffix:".all-deps" in
      let all_deps_file = all_deps_path file in
      Build.memoize (Path.to_string all_deps_file)
        (Build.lines_of all_deps_file >>^ parse_module_names ~unit ~modules)
  in
  Ml_kind.Dict.of_func (fun ~ml_kind ->
    let per_module =
      Module.Name.Map.map modules ~f:(deps_of ~ml_kind) in
    { Dep_graph.
      dir = obj_dir
    ; per_module
    })
