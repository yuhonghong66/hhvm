(**
 * Copyright (c) 2017, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
*)
open Core
open Hhbc_ast
open Instruction_sequence
open Emit_type_hint
module SU = Hhbc_string_utils

let has_type_constraint ti =
  match ti with
  | Some ti when (Hhas_type_info.has_type_constraint ti) -> true
  | _ -> false

let emit_method_prolog ~params ~needs_local_this =
  gather (
    (if needs_local_this
    then instr (IMisc (InitThisLoc (Local.Named "$this")))
    else empty)
    ::
    List.filter_map params (fun p ->
    if Hhas_param.is_variadic p
    then None else
    let param_type_info = Hhas_param.type_info p in
    let param_name = Hhas_param.name p in
    if has_type_constraint param_type_info
    then Some (instr (IMisc (VerifyParamType (Param_named param_name))))
    else None))

let tparams_to_strings tparams =
  List.map tparams (fun (_, (_, s), _) -> s)

let rec emit_def env def =
  match def with
  | Ast.Stmt s -> Emit_statement.emit_stmt env s
  | Ast.Constant c ->
    let cns_name = snd c.Ast.cst_name in
    let cns_id =
      if c.Ast.cst_kind = Ast.Cst_define
      then
        (* names of constants declared using 'define function' are always
          prefixed with '\\', see 'def' function in 'namespaces.ml' *)
        Hhbc_id.Const.from_raw_string (SU.strip_global_ns cns_name)
      else Hhbc_id.Const.from_ast_name cns_name in
    gather [
      Emit_expression.emit_expr ~need_ref:false env c.Ast.cst_value;
      instr (IIncludeEvalDefine (DefCns cns_id));
      instr_popc;
    ]
    (* We assume that SetNamespaceEnv does namespace setting *)
  | Ast.Namespace(_, defs) ->
    emit_defs env defs
  | _ ->
    empty

and emit_defs env defs =
  match defs with
  | Ast.SetNamespaceEnv ns :: defs ->
    let env = Emit_env.with_namespace ns env in
    emit_defs env defs
  | [] -> Emit_statement.emit_dropthrough_return ()
  | [Ast.Stmt s] -> Emit_statement.emit_final_statement env s
  | [d] ->
    gather [emit_def env d; Emit_statement.emit_dropthrough_return ()]
  | d::defs ->
    let i1 = emit_def env d in
    let i2 = emit_defs env defs in
    gather [i1; i2]

let make_body body_instrs decl_vars is_memoize_wrapper params return_type_info =
  let body_instrs = rewrite_user_labels body_instrs in
  let body_instrs = rewrite_class_refs body_instrs in
  let params, body_instrs =
    Label_rewriter.relabel_function params body_instrs in
  let num_iters = !Iterator.num_iterators in
  let num_cls_ref_slots = get_num_cls_ref_slots body_instrs in
  Hhas_body.make
    body_instrs
    decl_vars
    num_iters
    num_cls_ref_slots
    is_memoize_wrapper
    params
    return_type_info

let emit_return_type_info ~scope ~skipawaitable ~namespace ret =
  let tparams =
    List.map (Ast_scope.Scope.get_tparams scope) (fun (_, (_, s), _) -> s) in
  match ret with
  | None ->
    Some (Hhas_type_info.make (Some "") (Hhas_type_constraint.make None []))
  | Some h ->
    Some (hint_to_type_info
      ~return:true ~nullable:false
      ~skipawaitable ~always_extended:true ~tparams ~namespace h)

let emit_body
  ~scope
  ~is_closure_body
  ~is_memoize
  ~skipawaitable
  ~is_return_by_ref
  ~default_dropthrough
  ~return_value
  ~namespace params ret body =
  let tparams =
    List.map (Ast_scope.Scope.get_tparams scope) (fun (_, (_, s), _) -> s) in
  Label.reset_label ();
  Iterator.reset_iterator ();
  let return_type_info =
    emit_return_type_info ~scope ~skipawaitable ~namespace ret in
  let verify_return =
    match return_type_info with
    | None -> false
    | Some x when x. Hhas_type_info.type_info_user_type = Some "" -> false
    | Some x -> Hhas_type_info.has_type_constraint x in
  Emit_statement.set_verify_return verify_return;
  Emit_statement.set_default_dropthrough default_dropthrough;
  Emit_statement.set_default_return_value return_value;
  Emit_statement.set_return_by_ref is_return_by_ref;
  let params =
    Emit_param.from_asts
      ~namespace ~tparams ~generate_defaults:(not is_memoize) params
  in
  let has_this = Ast_scope.Scope.has_this scope in
  let needs_local_this, decl_vars =
    Decl_vars.from_ast ~is_closure_body ~has_this ~params:params body in
  Local.reset_local (List.length params + List.length decl_vars);
  let env = Emit_env.(
    empty |>
    with_namespace namespace |>
    with_needs_local_this needs_local_this |>
    with_scope scope) in
  let stmt_instrs = emit_defs env body in
  let begin_label, default_value_setters =
    Emit_param.emit_param_default_value_setter env params in
  let is_generator, is_pair_generator = Generator.is_function_generator body in
  let generator_instr =
    if is_generator then gather [instr_createcont; instr_popc] else empty
  in
  let stmt_instrs =
    rewrite_static_instrseq (Static_var.make_static_map body)
                    (Emit_expression.emit_expr ~need_ref:false) env stmt_instrs
  in
  let body_instrs = gather [
    begin_label;
    emit_method_prolog ~params ~needs_local_this;
    generator_instr;
    stmt_instrs;
    default_value_setters;
  ] in
  let fault_instrs = extract_fault_instructions body_instrs in
  let body_instrs = gather [body_instrs; fault_instrs] in
  make_body
    body_instrs
    decl_vars
    false (*is_memoize_wrapper*)
    params
    return_type_info,
    is_generator,
    is_pair_generator
