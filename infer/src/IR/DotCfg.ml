(*
 * Copyright (c) 2009-2013, Monoidics ltd.
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format

let pp_cfgnodename pname fmt (n : Procdesc.Node.t) =
  F.fprintf fmt "\"%s_%d\""
    (Escape.escape_dotty (Procname.to_filename pname))
    (Procdesc.Node.get_id n :> int)


let pp_etlist fmt etl =
  List.iter etl ~f:(fun (id, typ) ->
      Format.fprintf fmt " %a:%a" Mangled.pp id (Typ.pp_full Pp.text) typ )


let pp_var_list fmt etl =
  List.iter etl ~f:(fun (id, ty, mode) ->
      Format.fprintf fmt " [%s]%a:%a"
        (Pvar.string_of_capture_mode mode)
        Mangled.pp id (Typ.pp_full Pp.text) ty )


let pp_local_list fmt etl = List.iter ~f:(Procdesc.pp_local fmt) etl

let pp_cfgnodelabel pdesc fmt (n : Procdesc.Node.t) =
  let pp_label fmt n =
    match Procdesc.Node.get_kind n with
    | Start_node ->
        let pname = Procdesc.Node.get_proc_name n in
        let pname_string = Escape.escape_dotty (Procname.to_string pname) in
        let attributes = Procdesc.get_attributes pdesc in
        Format.fprintf fmt "Start %s\\nFormals: %a\\nLocals: %a" pname_string pp_etlist
          (Procdesc.get_formals pdesc) pp_local_list (Procdesc.get_locals pdesc) ;
        if not (List.is_empty (Procdesc.get_captured pdesc)) then
          Format.fprintf fmt "\\nCaptured: %a" pp_var_list (Procdesc.get_captured pdesc) ;
        let method_annotation = attributes.ProcAttributes.method_annotation in
        if not (Annot.Method.is_empty method_annotation) then
          Format.fprintf fmt "\\nAnnotation: %a" (Annot.Method.pp pname_string) method_annotation
    | Exit_node ->
        let pname = Procdesc.Node.get_proc_name n in
        Format.fprintf fmt "Exit %s" (Escape.escape_dotty (Procname.to_string pname))
    | Join_node ->
        Format.pp_print_char fmt '+'
    | Prune_node (is_true_branch, if_kind, _) ->
        Format.fprintf fmt "Prune (%b branch, %s)" is_true_branch (Sil.if_kind_to_string if_kind)
    | Stmt_node s ->
        Format.fprintf fmt " %a" Procdesc.Node.pp_stmt s
    | Skip_node s ->
        Format.fprintf fmt "Skip %s" s
  in
  let instr_string i =
    let pp f = Sil.pp_instr ~print_types:false Pp.text f i in
    let str = F.asprintf "%t" pp in
    Escape.escape_dotty str
  in
  let pp_instrs fmt instrs =
    Instrs.iter ~f:(fun i -> F.fprintf fmt " %s\\n " (instr_string i)) instrs
  in
  let instrs = Procdesc.Node.get_instrs n in
  F.fprintf fmt "%d: %a \\n  %a" (Procdesc.Node.get_id n :> int) pp_label n pp_instrs instrs


let pp_cfgnodeshape fmt (n : Procdesc.Node.t) =
  match Procdesc.Node.get_kind n with
  | Start_node | Exit_node ->
      F.pp_print_string fmt "color=yellow style=filled"
  | Prune_node _ ->
      F.fprintf fmt "shape=\"invhouse\""
  | Skip_node _ ->
      F.fprintf fmt "color=\"gray\""
  | Stmt_node _ ->
      F.fprintf fmt "shape=\"box\""
  | _ ->
      ()


let pp_cfgnode pdesc fmt (n : Procdesc.Node.t) =
  let pname = Procdesc.get_proc_name pdesc in
  F.fprintf fmt "%a [label=\"%a\" %a]@\n\t@\n" (pp_cfgnodename pname) n (pp_cfgnodelabel pdesc) n
    pp_cfgnodeshape n ;
  let print_edge n1 n2 is_exn =
    let color = if is_exn then "[color=\"red\" ]" else "" in
    match Procdesc.Node.get_kind n2 with
    | Exit_node when is_exn ->
        (* don't print exception edges to the exit node *)
        ()
    | _ ->
        F.fprintf fmt "@\n\t %a -> %a %s;" (pp_cfgnodename pname) n1 (pp_cfgnodename pname) n2 color
  in
  List.iter ~f:(fun n' -> print_edge n n' false) (Procdesc.Node.get_succs n) ;
  List.iter ~f:(fun n' -> print_edge n n' true) (Procdesc.Node.get_exn n)


let print_pdesc source fmt pdesc =
  let print_node pdesc node =
    let loc = Procdesc.Node.get_loc node in
    if Config.dotty_cfg_libs || SourceFile.equal loc.Location.file source then
      F.fprintf fmt "%a@\n" (pp_cfgnode pdesc) node
  in
  Procdesc.get_nodes pdesc
  |> List.sort ~compare:Procdesc.Node.compare
  |> List.iter ~f:(fun node -> print_node pdesc node)


let with_dot_file fname ~pp =
  let chan = Utils.out_channel_create_with_dir fname in
  let fmt = Format.formatter_of_out_channel chan in
  (* avoid phabricator thinking this file was generated by substituting substring with %s *)
  F.fprintf fmt "@[/* %@%s */@\ndigraph cfg {@\n%t}@]@." "generated" pp ;
  Out_channel.close chan


let emit_frontend_cfg source cfg =
  let fname =
    match Config.icfg_dotty_outfile with
    | Some file ->
        file
    | None when Config.frontend_tests ->
        SourceFile.to_abs_path source ^ ".test.dot"
    | None ->
        DB.filename_to_string
          (DB.Results_dir.path_to_filename (DB.Results_dir.Abs_source_dir source)
             [Config.dotty_frontend_output])
  in
  with_dot_file fname ~pp:(fun fmt ->
      Cfg.iter_sorted cfg ~f:(fun pdesc -> print_pdesc source fmt pdesc) )


let emit_proc_desc source proc_desc =
  let filename =
    let db_name =
      DB.Results_dir.path_to_filename (DB.Results_dir.Abs_source_dir source)
        [Procname.to_filename (Procdesc.get_proc_name proc_desc)]
    in
    DB.filename_to_string db_name ^ ".dot"
  in
  with_dot_file filename ~pp:(fun fmt -> print_pdesc source fmt proc_desc)
