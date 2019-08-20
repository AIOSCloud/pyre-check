(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
open Expression
open Statement
open Pyre
open CustomAnalysis
module Error = AnalysisError

module ErrorMap = struct
  type key = {
    location: Location.t;
    identifier: string;
  }
  [@@deriving compare, eq, sexp, show, hash]

  include Hashable.Make (struct
    type nonrec t = key

    let compare = compare_key

    let hash = Hashtbl.hash

    let hash_fold_t = hash_fold_key

    let sexp_of_t = sexp_of_key

    let t_of_sexp = key_of_sexp
  end)

  type t = Error.t Table.t
end

module type Context = sig
  val global_resolution : GlobalResolution.t

  val errors : ErrorMap.t
end

module State (Context : Context) = struct
  type t = {
    unused: Location.Reference.Set.t Identifier.Map.t;
    used: Identifier.Set.t;
    bottom: bool;
    define: Define.t Node.t;
    nested_defines: t NestedDefines.t;
  }

  let show { used; _ } = Set.to_list used |> String.concat ~sep:", "

  let pp format state = Format.fprintf format "%s" (show state)

  let update_unused ~state:({ unused; define; _ } as state) ~location identifier =
    let _ =
      match Map.find unused identifier with
      | Some existing ->
          let add_error location =
            let error = Error.create ~location ~kind:(Error.DeadStore identifier) ~define in
            ErrorMap.Table.set Context.errors ~key:{ ErrorMap.location; identifier } ~data:error
          in
          Set.to_list existing |> List.iter ~f:add_error
      | None -> ()
    in
    let unused =
      Map.set unused ~key:identifier ~data:(Location.Reference.Set.of_list [location])
    in
    { state with unused }


  let initial
      ~state:_
      ~define:({ Node.value = { Define.signature = { Define.parameters; _ }; _ }; _ } as define)
    =
    let empty_state =
      {
        unused = Identifier.Map.empty;
        used = Identifier.Set.empty;
        bottom = false;
        define;
        nested_defines = NestedDefines.initial;
      }
    in
    let add_parameter state { Node.value = { Parameter.name; _ }; location } =
      update_unused ~state ~location name
    in
    List.fold ~init:empty_state ~f:add_parameter parameters


  let less_or_equal
      ~left:{ unused = left; used = used_left; _ }
      ~right:{ unused = right; used = used_right; _ }
    =
    let less_or_equal (reference, location) =
      match location, Map.find right reference with
      | left, Some right -> Set.is_subset left ~of_:right
      | _ -> false
    in
    Map.to_alist left |> List.for_all ~f:less_or_equal && Set.is_subset used_left ~of_:used_right


  let join left right =
    let merge ~key:_ = function
      | `Both (left, right) -> Some (Set.union left right)
      | `Left left -> Some left
      | `Right right -> Some right
    in
    {
      left with
      used = Set.union left.used right.used;
      unused = Map.merge left.unused right.unused ~f:merge;
      bottom = left.bottom && right.bottom;
    }


  let widen ~previous ~next ~iteration:_ = join previous next

  let nested_defines { nested_defines; _ } = nested_defines

  let errors { unused; define; _ } =
    let add_errors ~key ~data =
      let add_error location =
        let error = Error.create ~location ~kind:(Error.DeadStore key) ~define in
        ErrorMap.Table.set Context.errors ~key:{ ErrorMap.location; identifier = key } ~data:error
      in
      Set.to_list data |> List.iter ~f:add_error
    in
    Map.iteri unused ~f:add_errors;
    ErrorMap.Table.data Context.errors |> List.sort ~compare:Error.compare


  let forward
      ?key
      ({ unused; bottom; nested_defines; define; _ } as state)
      ~statement:({ Node.location; value } as statement)
    =
    let resolution =
      let { Node.value = { Define.signature = { name; parent; _ }; _ }; _ } = define in
      TypeCheck.resolution_with_key ~global_resolution:Context.global_resolution ~parent ~name ~key
    in
    (* Remove used names. *)
    let state =
      let unused =
        if bottom then
          unused
        else
          let used_names =
            match value with
            | Assign { annotation; value; _ } ->
                (* Don't count LHS of assignments as used. *)
                annotation
                >>| (fun annotation ->
                      Visit.collect_base_identifiers
                        (Node.create ~location (Statement.Expression annotation)))
                |> Option.value ~default:[]
                |> List.append
                     (Visit.collect_base_identifiers
                        (Node.create ~location (Statement.Expression value)))
                |> List.map ~f:Node.value
            | _ -> Visit.collect_base_identifiers statement |> List.map ~f:Node.value
          in
          List.fold used_names ~f:Map.remove ~init:unused
      in
      { state with unused }
    in
    (* Add assignments to unused. *)
    let state =
      match value with
      | Assign { target; _ } ->
          let rec update_target state = function
            | { Node.value = Name (Name.Identifier identifier); _ } ->
                update_unused ~state ~location identifier
            | { Node.value = List elements; _ } -> List.fold ~init:state ~f:update_target elements
            | { Node.value = Starred (Starred.Once target); _ } -> update_target state target
            | { Node.value = Tuple elements; _ } -> List.fold ~init:state ~f:update_target elements
            | _ -> state
          in
          update_target state target
      | _ -> state
    in
    (* Check for bottomed out state. *)
    let bottom =
      match value with
      | Assert { Assert.test; _ } -> (
        match Node.value test with
        | False -> true
        | _ -> bottom )
      | Expression expression ->
          if Type.is_noreturn (Resolution.resolve resolution expression) then
            true
          else
            bottom
      | Return _ -> true
      | _ -> bottom
    in
    let nested_defines = NestedDefines.update_nested_defines nested_defines ~statement ~state in
    { state with bottom; nested_defines }


  let backward
      ?key:_
      ({ used; define; _ } as state)
      ~statement:({ Node.location; value } as statement)
    =
    (* Remove assignments from used. *)
    let used =
      let remove_from_used ~used ~location identifier =
        match Set.find used ~f:(Identifier.equal identifier) with
        | Some _ -> Set.remove used identifier
        | None ->
            let error = Error.create ~location ~kind:(Error.DeadStore identifier) ~define in
            ErrorMap.Table.set Context.errors ~key:{ ErrorMap.location; identifier } ~data:error;
            used
      in
      match value with
      | Assign { target; _ } ->
          let rec update_target used = function
            | { Node.value = Name (Name.Identifier identifier); _ } ->
                remove_from_used ~used ~location identifier
            | { Node.value = List elements; _ } -> List.fold ~init:used ~f:update_target elements
            | { Node.value = Starred (Starred.Once target); _ } -> update_target used target
            | { Node.value = Tuple elements; _ } -> List.fold ~init:used ~f:update_target elements
            | _ -> used
          in
          update_target used target
      | _ -> used
    in
    (* Add used identifiers. *)
    let used =
      let used_names =
        match value with
        | Assign { annotation; value; _ } ->
            (* Don't count LHS of assignments as used. *)
            annotation
            >>| (fun annotation ->
                  Visit.collect_base_identifiers
                    (Node.create ~location (Statement.Expression annotation)))
            |> Option.value ~default:[]
            |> List.append
                 (Visit.collect_base_identifiers
                    (Node.create ~location (Statement.Expression value)))
            |> List.map ~f:Node.value
        | _ -> Visit.collect_base_identifiers statement |> List.map ~f:Node.value
      in
      List.fold used_names ~f:Set.add ~init:used
    in
    { state with used }
end

let name = "Liveness"

let run ~configuration:_ ~global_resolution ~source =
  let module Context = struct
    let global_resolution = global_resolution

    let errors = ErrorMap.Table.create ()
  end
  in
  let module State = State (Context) in
  let module Fixpoint = Fixpoint.Make (State) in
  let rec check ~state define =
    let run_nested ~key ~data:{ NestedDefines.nested_define; state } =
      check ~state:(Some state) { Node.location = key; value = nested_define } |> ignore
    in
    let cfg = Cfg.create (Node.value define) in
    Fixpoint.forward ~cfg ~initial:(State.initial ~state ~define)
    |> Fixpoint.exit
    >>| (fun state -> Fixpoint.backward ~cfg ~initial:state)
    >>= Fixpoint.exit
    >>| (fun state ->
          State.nested_defines state |> Map.iteri ~f:run_nested;
          State.errors state)
    |> Option.value ~default:[]
  in
  check ~state:None (Source.top_level_define_node source)
