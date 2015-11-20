(*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(** In this module an ObjC interface declaration or implementation is processed. The class  *)
(** is saved in the tenv as a struct with the corresponding fields, potential superclass and *)
(** list of defined methods *)

(* ObjectiveC doesn't have a notion of static or class fields. *)
(* So, in this module we translate a class into a sil srtuct with an empty list of static fields.*)

open Utils
open CFrontend_utils

module L = Logging

let objc_class_str = "ObjC-Class"

let objc_class_annotation =
  [({ Sil.class_name = objc_class_str; Sil.parameters =[]}, true)]

let is_objc_class_annotation a =
  match a with
  | [({ Sil.class_name = n; Sil.parameters =[]}, true)] when n = objc_class_str -> true
  | _ -> false

let is_pointer_to_objc_class tenv typ =
  match typ with
  | Sil.Tptr (Sil.Tvar (Sil.TN_csu (Sil.Class, cname)), _) ->
      (match Sil.tenv_lookup tenv (Sil.TN_csu (Sil.Class, cname)) with
       | Some Sil.Tstruct(_, _, Sil.Class, _, _, _, a) when is_objc_class_annotation a -> true
       | _ -> false)
  | Sil.Tptr (Sil.Tstruct(_, _, Sil.Class, _, _, _, a), _) when
      is_objc_class_annotation a -> true
  | _ -> false

let get_super_interface_decl otdi_super =
  match otdi_super with
  | Some dr -> Ast_utils.name_opt_of_name_info_opt dr.Clang_ast_t.dr_name
  | _ -> None

let get_protocols protocols =
  let protocol_names = IList.map (
      fun decl -> match decl.Clang_ast_t.dr_name with
        | Some name_info -> Ast_utils.get_qualified_name name_info
        | None -> assert false
    ) protocols in
  protocol_names

let get_curr_class class_name ocdi =
  let super = get_super_interface_decl ocdi.Clang_ast_t.otdi_super  in
  let protocols = get_protocols ocdi.Clang_ast_t.otdi_protocols in
  CContext.ContextCls (class_name, super, protocols)

let get_curr_class_impl oi =
  let open Clang_ast_t in
  match oi.Clang_ast_t.oidi_class_interface with
  | Some decl_ref ->
      (match Ast_utils.get_decl decl_ref.Clang_ast_t.dr_decl_pointer with
       | Some ObjCInterfaceDecl (_, name_info, _, _, obj_c_interface_decl_info) ->
           let class_name = Ast_utils.get_qualified_name name_info in
           get_curr_class class_name obj_c_interface_decl_info
       | _ -> assert false)
  | _ -> assert false

let add_class_decl type_ptr_to_sil_type tenv idi =
  let decl_ref_opt = idi.Clang_ast_t.oidi_class_interface in
  Ast_utils.add_type_from_decl_ref type_ptr_to_sil_type tenv decl_ref_opt true

let add_super_class_decl type_ptr_to_sil_type tenv ocdi =
  let decl_ref_opt = ocdi.Clang_ast_t.otdi_super in
  Ast_utils.add_type_from_decl_ref type_ptr_to_sil_type tenv decl_ref_opt false

let add_protocols_decl type_ptr_to_sil_type tenv protocols =
  Ast_utils.add_type_from_decl_ref_list type_ptr_to_sil_type tenv protocols

let add_categories_decl type_ptr_to_sil_type tenv categories =
  Ast_utils.add_type_from_decl_ref_list type_ptr_to_sil_type tenv categories

let add_class_implementation type_ptr_to_sil_type tenv idi =
  let decl_ref_opt = idi.Clang_ast_t.otdi_implementation  in
  Ast_utils.add_type_from_decl_ref type_ptr_to_sil_type tenv decl_ref_opt false

(*The superclass is the first element in the list of super classes of structs in the tenv, *)
(* then come the protocols and categories. *)
let get_interface_superclasses super_opt protocols =
  let super_class =
    match super_opt with
    | None -> []
    | Some super -> [(Sil.Class, Mangled.from_string super)] in
  let protocol_names = IList.map (
      fun name -> (Sil.Protocol, Mangled.from_string name)
    ) protocols in
  let super_classes = super_class@protocol_names in
  super_classes

let create_superclasses_fields type_ptr_to_sil_type tenv curr_class decl_list class_name
    otdi_super otdi_protocols =
  let super = get_super_interface_decl otdi_super in
  let protocols = get_protocols otdi_protocols in
  let superclasses = get_interface_superclasses super protocols in
  let fields = CField_decl.get_fields type_ptr_to_sil_type tenv curr_class decl_list in
  superclasses, fields

(* Adds pairs (interface name, interface_type_info) to the global environment. *)
let add_class_to_tenv type_ptr_to_sil_type tenv curr_class decl_info class_name decl_list ocidi =
  Printing.log_out "ADDING: ObjCInterfaceDecl for '%s'\n" class_name;
  let interface_name = CTypes.mk_classname class_name in
  let decl_key = `DeclPtr decl_info.Clang_ast_t.di_pointer in
  Ast_utils.update_sil_types_map decl_key (Sil.Tvar interface_name);
  let superclasses, fields =
    create_superclasses_fields type_ptr_to_sil_type tenv curr_class decl_list class_name
      ocidi.Clang_ast_t.otdi_super
      ocidi.Clang_ast_t.otdi_protocols in
  let methods = ObjcProperty_decl.get_methods curr_class decl_list in
  let fields_sc = CField_decl.fields_superclass tenv ocidi in
  IList.iter (fun (fn, ft, _) ->
      Printing.log_out "----->SuperClass field: '%s' " (Ident.fieldname_to_string fn);
      Printing.log_out "type: '%s'\n" (Sil.typ_to_string ft)) fields_sc;
  (*In case we found categories, or partial definition of this class earlier and they are already in the tenv *)
  let fields, superclasses, methods =
    match Sil.tenv_lookup tenv interface_name with
    | Some Sil.Tstruct(saved_fields, _, _, _, saved_superclasses, saved_methods, _) ->
        General_utils.append_no_duplicates_fields fields saved_fields,
        General_utils.append_no_duplicates_csu superclasses saved_superclasses,
        General_utils.append_no_duplicates_methods methods saved_methods
    | _ -> fields, superclasses, methods in
  let fields = General_utils.append_no_duplicates_fields fields fields_sc in
  (* We add the special hidden counter_field for implementing reference counting *)
  let fields = General_utils.append_no_duplicates_fields [Sil.objc_ref_counter_field] fields in
  let fields = General_utils.sort_fields fields in
  Printing.log_out "Class %s field:\n" class_name;
  IList.iter (fun (fn, ft, _) ->
      Printing.log_out "-----> field: '%s'\n" (Ident.fieldname_to_string fn)) fields;
  let interface_type_info =
    Sil.Tstruct(fields, [], Sil.Class, Some (Mangled.from_string class_name),
                superclasses, methods, objc_class_annotation) in
  Sil.tenv_add tenv interface_name interface_type_info;
  Printing.log_out
    "  >>>Verifying that Typename '%s' is in tenv\n" (Sil.typename_to_string interface_name);
  (match Sil.tenv_lookup tenv interface_name with
   | Some t -> Printing.log_out "  >>>OK. Found typ='%s'\n" (Sil.typ_to_string t)
   | None -> Printing.log_out "  >>>NOT Found!!\n");
  Sil.Tvar interface_name

let add_missing_methods tenv class_name decl_info decl_list curr_class =
  let methods = ObjcProperty_decl.get_methods curr_class decl_list in
  let class_tn_name = Sil.TN_csu (Sil.Class, (Mangled.from_string class_name)) in
  let decl_key = `DeclPtr decl_info.Clang_ast_t.di_pointer in
  Ast_utils.update_sil_types_map decl_key (Sil.Tvar class_tn_name);
  (match Sil.tenv_lookup tenv class_tn_name with
   | Some Sil.Tstruct(fields, [], Sil.Class, Some name, superclass, existing_methods, annotation) ->
       let methods = General_utils.append_no_duplicates_methods existing_methods methods in
       let typ = Sil.Tstruct(fields, [], Sil.Class, Some name, superclass, methods, annotation) in
       Sil.tenv_add tenv class_tn_name typ
   | _ -> ());
  Sil.Tvar class_tn_name

(* Interface_type_info has the name of instance variables and the name of methods. *)
let interface_declaration type_ptr_to_sil_type tenv decl =
  let open Clang_ast_t in
  match decl with
  | ObjCInterfaceDecl (decl_info, name_info, decl_list, _, ocidi) ->
      let name = Ast_utils.get_qualified_name name_info in
      let curr_class = get_curr_class name ocidi in
      let typ =
        add_class_to_tenv type_ptr_to_sil_type tenv curr_class decl_info name decl_list ocidi in
      let _ = add_class_implementation type_ptr_to_sil_type tenv ocidi in
      let _ = add_super_class_decl type_ptr_to_sil_type tenv ocidi in
      let _ = add_protocols_decl type_ptr_to_sil_type tenv ocidi.Clang_ast_t.otdi_protocols in
      let known_categories = ocidi.Clang_ast_t.otdi_known_categories in
      let _ = add_categories_decl type_ptr_to_sil_type tenv known_categories in
      typ
  | _ -> assert false

(* Translate the methods defined in the implementation.*)
let interface_impl_declaration type_ptr_to_sil_type tenv decl =
  let open Clang_ast_t in
  match decl with
  | ObjCImplementationDecl (decl_info, name_info, decl_list, decl_context_info, idi) ->
      let class_name = Ast_utils.get_qualified_name name_info in
      Printing.log_out "ADDING: ObjCImplementationDecl for class '%s'\n" class_name;
      let _ = add_class_decl type_ptr_to_sil_type tenv idi in
      let curr_class = get_curr_class_impl idi in
      let fields = CField_decl.get_fields type_ptr_to_sil_type tenv curr_class decl_list in
      CField_decl.add_missing_fields tenv class_name fields;
      let typ = add_missing_methods tenv class_name decl_info decl_list curr_class in
      typ
  | _ -> assert false