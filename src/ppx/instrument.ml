(* This Source Code Form is subject to the terms of the Mozilla Public License,
   v. 2.0. If a copy of the MPL was not distributed with this file, You can
   obtain one at http://mozilla.org/MPL/2.0/. *)



(* From ocaml-migrate-parsetree. *)
module Ast = Ast_404

module Location = Ast.Location
module Parsetree = Ast.Parsetree

module Pat = Ast.Ast_helper.Pat
module Exp = Ast.Ast_helper.Exp
module Str = Ast.Ast_helper.Str
module Cf = Ast.Ast_helper.Cf

(* From ppx_tools_versioned. *)
module Ast_convenience = Ast_convenience_404
module Ast_mapper_class = Ast_mapper_class_404



module Generated_code :
sig
  type points

  val init : unit -> points

  val instrument_expr :
    points -> ?loc:Location.t -> Parsetree.expression -> Parsetree.expression

  val instrument_case :
    points -> Parsetree.case -> Parsetree.case

  val instrument_class_field_kind :
    points -> Parsetree.class_field_kind -> Parsetree.class_field_kind

  val runtime_initialization :
    points -> string -> Parsetree.structure_item
end =
struct
  type points = Bisect.Common.point_definition list ref

  let init () = ref []

  (* Given an AST for an expression [e], replaces it by the sequence expression
     [instrumentation; e], where [instrumentation] is some code that tells
     Bisect_ppx, at runtime, that [e] has been visited. *)
  let instrument_expr points ?loc e =
    let rec outline () =
      let point_loc = choose_location_of_point ~maybe_override_loc:loc e in
      if expression_should_not_be_instrumented ~point_loc then
        e
      else
        let point_index = get_index_of_point_at_location ~point_loc in
        [%expr ___bisect_mark___ [%e point_index]; [%e e]]
          [@metaloc point_loc]

    and choose_location_of_point ~maybe_override_loc e =
      match maybe_override_loc with
      | Some override_loc -> override_loc
      | _ -> Parsetree.(e.pexp_loc)

    and expression_should_not_be_instrumented ~point_loc:loc =
      if Location.(loc.loc_ghost) then
        true
      else
        (* Retrieve the expression's file and line number. The file can be
           different from the input file to Bisect_ppx, in case of the [#line]
           directive.

           That is typically emitted by cppo, ocamlyacc, and other
           preprocessors. To be intuitive to the user, we need to make the
           decision on ignoring this expression based on its original source
           location, as seen by the user, not based on where it was spliced in
           by another prerocessor that ran before Bisect_ppx. *)
        let file, line =
          let start = Location.(loc.loc_start) in
          Lexing.(start.pos_fname, start.pos_lnum)
        in
        Comments.get file
        |> Comments.line_is_ignored line

    and get_index_of_point_at_location ~point_loc:loc =
      let point_offset = Location.(Lexing.(loc.loc_start.pos_cnum)) in
      let point =
        try
          List.find
            (fun point -> Bisect.Common.(point.offset) = point_offset)
            !points
        with Not_found ->
          let new_index = List.length !points in
          let new_point =
            Bisect.Common.{offset = point_offset; identifier = new_index} in
          points := new_point::!points;
          new_point
      in
      Ast_convenience.int point.identifier

    in

    outline ()

  (* Instruments a case, as found in [match] and [function] expressions. Cases
     contain patterns.

     Bisect_ppx treats or-patterns specially. For example, suppose you have

       match foo with
       | A -> bar
       | B -> baz

     Both [bar] and [baz] get separate instrumentation points, so that if [A]
     is passed, but [B] is never passed, during testing, you will know that [B]
     was not tested with.

     However, if you refactor to use an or-pattern,

       match foo with
       | A | B -> bar

     and nothing is special is done, the instrumentation point on [bar] covers
     both [A] and [B], so you lose the information that [B] is not tested.

     The fix for this is a bit tricky, because patterns are not expressions. So,
     they can't be instrumented directly. Bisect_ppx instead inserts a special
     secondary [match] expression right in front of [bar]:

       match foo with
       | A | B as ___bisect_matched_value___ ->
         (match ___bisect_matched_value___ with
         | A -> visited "A"
         | B -> visited "B");
         bar

     So, Bisect_ppx takes that or-pattern [A | B], rotates the "or" out to the
     top level (it already is there), splits it into indepedent cases, and
     creates a new [match] expression out of them, that allows it to
     distinguish, after the fact, which branch was actually taken to reach
     [bar].

     There are actually several complications to this. The first is that the
     generated [match] expression is generally not exhaustive: it only includes
     the patterns from the case for which it was generated. This is solved by
     adding a catch-all case, and locally suppressing a bunch of warnings:

       match foo with
       | A | B as ___bisect_matched_value___ ->
         (match ___bisect_matched_value___ with
         | A -> visited "A"
         | B -> visited "B"
         | _ (* for C, D, which can't happen here *) -> ())
           [@ocaml.warning "..."];
         bar
       | C | D as ___bisect_matched_value___ ->
         (match ___bisect_matched_value___ with
         | C -> visited "C"
         | D -> visited "D"
         | _ (* for A, B, which can't happen here *) -> ())
           [@ocaml.warning "..."];;
         baz

      Next, or-patterns might not be at the top level:

        match foo with
        | C (A | B) -> bar

      has to become

        match foo with
        | C (A | B) as ___bisect_matched_value___ ->
          (match ___bisect_matched_value___ with
          | C A -> visited "A"
          | C B -> visited "B"
          | _ -> ());
          bar

      This is done by "rotating" the or-pattern to the top level. In this
      example, [C (A | B)] is equivalent to [C A | C B]. The latter pattern can
      easily be split into cases. This could also be done by aliasing individual
      or-patterns, but we did not investigate it.

      There might be multiple or-patterns:

        match foo with
        | C (A | B), D (A | B) -> bar

      should become

        match foo with
        | C (A | B), D (A | B) as ___bisect_matched_value___ ->
          (match ___bisect_matched_value___ with
          | C A, D A -> visited "A1"; visited "A2"
          | C A, D B -> visited "A1"; visited "B2"
          | C B, D A -> visited "B1"; visited "A2"
          | C B, D B -> visited "B1"; visited "B2"
          | _ -> ());
          bar

      as you can see, or-patterns under and-like patterns (tuples, arrays,
      records) get multiplied combinatorially.

      The above example also shows that Bisect_ppx needs to mark a whole list of
      points in each of the generated cases. For that, the function that rotates
      or-patterns to the top level also keeps track of the original locations of
      each case of each or-pattern. Each of the resulting top-level patterns is
      paired with the list of locations of the or-cases it contains, visualised
      above as ["A1"; "A2"], ["A1"; "B2"], etc. These are termed *location
      traces*.

      Finally, there are some corner cases. First is the exception pattern:

        match foo with
        | exception (Exit | Failure _) -> bar

      should become

        match foo with
        | exception ((Exit | Failure _) as ___bisect_matched_value___) ->
          (match ___bisect_matched_value___ with
          | Exit -> visited "Exit"
          | Failure _ -> visited "Failure"
          | _ -> ());
          bar

      note that the [as] alias is attached to the payload of [exception], not to
      the outer pattern! The latter would be syntactically invalid. Also, we
      don't want to generate [exception] cases in the nested [match]: the
      exception has already been caught, we are not re-raising and re-catching
      it, which just need to know which constructor it was. To deal with this,
      we just need to check for the [exception] pattern, and work on its inside
      if it is present.

      The last corner case is the trivial one. If there no or-patterns, there is
      no point in generating a nested [match]:

        match foo with
        | A as ___bisect_matched_value___ ->
          (match ___bisect_matched_value___ with
          | A -> visited "A"   (* totally redundant *)
          | _ -> ());
          bar

      It's enough to just do

        match foo with
        | A -> visited "A"; bar

      which is pretty much just normal expression instrumentation, though with
      location overridden to the location of the pattern.

      This is detected when there is only one case after rotating all
      or-patterns to the top. If there had been an or-pattern, there would be at
      least two cases after rotation.

      Handling or-patterns is the most challening thing done here. There are a
      few simpler things to consider:

      - Pattern guards ([when] clauses) should be instrumented if present.
      - We don't instrument [assert false] cases.
      - We also don't instrument refutation cases ([| -> .]).

      So, without further ado, here is the function that does all this magic: *)
  let instrument_case points case =
    let module Helper_types =
      struct
        type location_trace = Location.t list
        type rotated_case = location_trace * Parsetree.pattern
          (* The [Parsetree.pattern] above will not contain or-patterns. *)
      end
    in
    let open Helper_types in

    let rec outline () =
      if is_assert_false_or_refutation case then
        case
      else
        let entire_pattern = Parsetree.(case.pc_lhs) in
        let loc = Parsetree.(entire_pattern.ppat_loc) in
        let non_exception_pattern, reassemble_exception_pattern_if_present =
          go_into_exception_pattern_if_present ~entire_pattern in

        let rotated_cases : rotated_case list =   (* No or-patterns. *)
          rotate_or_patterns_to_top loc ~non_exception_pattern in

        match rotated_cases with
        | [] ->
          empty_case_list case    (* Should be unreachable. *)

        | [(location_trace, _)] ->
          no_or_patterns case location_trace

        | _::_::_ ->
          let new_case_pattern_with_alias =
            add_bisect_matched_value_alias loc ~non_exception_pattern
            |> reassemble_exception_pattern_if_present
          in

          let new_case_expr_with_nested_match =
            generate_nested_match loc rotated_cases in

          Exp.case
            new_case_pattern_with_alias
            ?guard:(instrument_when_clause case)
            new_case_expr_with_nested_match

    and is_assert_false_or_refutation case =
      match case.pc_rhs with
      | [%expr assert false] -> true
      | {pexp_desc = Pexp_unreachable; _} -> true
      | _ -> false

    and go_into_exception_pattern_if_present ~entire_pattern
        : Parsetree.pattern * (Parsetree.pattern -> Parsetree.pattern) =
      match entire_pattern with
      | [%pat? exception [%p? nested_pattern]] ->
        (nested_pattern,
         (fun p ->
          Parsetree.{entire_pattern with ppat_desc = Ppat_exception p}))
      | _ ->
        (entire_pattern,
         (fun p -> p))

    and empty_case_list case =
      Parsetree.{case with
        pc_rhs = instrument_expr points case.pc_rhs;
        pc_guard = instrument_when_clause case}

    and no_or_patterns case location_trace =
      Parsetree.{case with
        pc_rhs = instrumentation_for_location_trace case.pc_rhs location_trace;
        pc_guard = instrument_when_clause case}

    and instrument_when_clause case =
      match Parsetree.(case.pc_guard) with
      | None -> None
      | Some guard -> Some (instrument_expr points guard)

    and instrumentation_for_location_trace e location_trace =
      location_trace
      |> List.sort_uniq (fun l l' ->
        l.Location.loc_start.Lexing.pos_cnum -
        l'.Location.loc_start.Lexing.pos_cnum)
      |> List.fold_left (fun e l ->
        instrument_expr points ~loc:l e) e

    and add_bisect_matched_value_alias loc ~non_exception_pattern =
      [%pat? [%p non_exception_pattern] as ___bisect_matched_value___]
        [@metaloc loc]

    and generate_nested_match loc rotated_cases =
      (rotated_cases
      |> List.map (fun (location_trace, rotated_pattern) ->
        Exp.case
          rotated_pattern
          (instrumentation_for_location_trace [%expr ()] location_trace))
      |> fun nested_match_cases ->
        nested_match_cases @ [Exp.case [%pat? _] [%expr ()]]
      |> Exp.match_ ~loc ([%expr ___bisect_matched_value___])
      |> fun nested_match ->
        Exp.attr
          nested_match
          (Location.mkloc "ocaml.warning" loc,
            PStr [[%stri "-4-8-9-11-26-27-28"]])
      |> fun nested_match_with_attribute ->
        [%expr [%e nested_match_with_attribute]; [%e case.pc_rhs]])
          [@metaloc loc]

    (* This function works recursively. It should be called with a pattern [p]
       (second argument) and its location (first argument).

       It evaluates to a list of patterns. Each of these resulting patterns
       contains no nested or-patterns. Joining the resulting patterns in a
       single or-pattern would create a pattern equivalent to [p].

       Each pattern in the list is paired with a list of locations. These are
       the locations of the original cases of or-patterns in [p] that were
       chosen for the corresponding result pattern. For example:

         C (A | B), D (E | F)

       becomes the list of pairs

         (C A, D E), [loc A, loc E]
         (C A, D F), [loc A, loc F]
         (C B, D E), [loc B, loc E]
         (C B, D F), [loc B, loc F]

        During recursion, the invariant on the location is that it is the
        location of the nearest enclosing or-pattern, or the entire pattern, if
        there is no enclosing or-pattern. *)
    and rotate_or_patterns_to_top loc ~non_exception_pattern
        : rotated_case list =

      let rec recurse ~enclosing_loc p : rotated_case list =
        let loc = Parsetree.(p.ppat_loc) in
        let attrs = Parsetree.(p.ppat_attributes) in

        match p.ppat_desc with

        (* If the pattern ends with something trivial, that is not an
           or-pattern, and has no nested patterns (so can't have a nested
           or-pattern), then that pattern is the only top-level case. The
           location trace is just the location of the overall pattern.

           Here are some examples of how this plays out. Let's say the entire
           pattern was "x". Then the case list will be just "x", with its own
           location for the trace.

           If the entire pattern was "x as y", this recursive call will return
           just "x" with the location of "x as y" for the trace. The wrapping
           recursive call will turn the "x" back into "x as y".

           If the entire pattern was "A x | B", this recursive call will return
           just "x" with the location of "A" (not the whole pattern!). The
           wrapping recursive call, for constructor "A", will turn the "x" into
           "A x". A yet-higher wrapping recursive call, for the actual
           or-pattern, will concatenate this with a second top-level case,
           corresponding to "B". *)
        | Ppat_any | Ppat_var _ | Ppat_constant _ | Ppat_interval _
        | Ppat_construct (_, None) | Ppat_variant (_, None) | Ppat_type _
        | Ppat_unpack _ | Ppat_extension _ ->
          [([enclosing_loc], p)]

        (* Recursively rotate or-patterns in [p'] to the top. Then, for each
           one, re-wrap it in an alias pattern. The location traces are not
           affected. *)
        | Ppat_alias (p', x) ->
          recurse ~enclosing_loc p'
          |> List.map (fun (location_trace, p'') ->
            (location_trace, Pat.alias ~loc ~attrs p'' x))

        (* Same logic as [Ppat_alias]. *)
        | Ppat_construct (c, Some p') ->
          recurse ~enclosing_loc p'
          |> List.map (fun (location_trace, p'') ->
            (location_trace, Pat.construct ~loc ~attrs c (Some p'')))

        (* Same logic as [Ppat_alias]. *)
        | Ppat_variant (c, Some p') ->
          recurse ~enclosing_loc p'
          |> List.map (fun (location_trace, p'') ->
            (location_trace, Pat.variant ~loc ~attrs c (Some p'')))

        (* Same logic as [Ppat_alias]. *)
        | Ppat_constraint (p', t) ->
          recurse ~enclosing_loc p'
          |> List.map (fun (location_trace, p'') ->
            (location_trace, Pat.constraint_ ~loc ~attrs p'' t))

        (* Same logic as [Ppat_alias]. *)
        | Ppat_lazy p' ->
          recurse ~enclosing_loc p'
          |> List.map (fun (location_trace, p'') ->
            (location_trace, Pat.lazy_ ~loc ~attrs p''))

        (* Same logic as [Ppat_alias]. *)
        | Ppat_open (c, p') ->
          recurse ~enclosing_loc p'
          |> List.map (fun (location_trace, p'') ->
            (location_trace, Pat.open_ ~loc ~attrs c p''))

        (* Recursively rotate or-patterns in each pattern in [ps] to the top.
           Then, take a Cartesian product of the cases, and re-wrap each row in
           a replacement tuple pattern.

           For example, suppose we have the pair pattern

             (A | B, C | D)

           The recursive calls will produce lists of rotated cases for each
           component pattern:

             A | B   =>   [A, loc A]; [B, loc B]
             C | D   =>   [C, loc C]; [D, loc D]

           We now need every possible combination of one case from the first
           component, one case from the second, and so on, and to concatenate
           all the location traces accordingly:

             [A; C, loc A; loc C]
             [A; D, loc A; loc D]
             [B; C, loc B; loc C]
             [B; D, loc B; loc D]

           This is performed by [all_combinations].

           Finally, we need to take each one of these rows, and re-wrap the
           pattern lists (on the left side) into tuples.

           This is typical of "and-patterns", i.e. those that match various
           product types (though that carry multiple pieces of data
           simultaneously). *)
        | Ppat_tuple ps ->
          ps
          |> List.map (recurse ~enclosing_loc)
          |> all_combinations
          |> List.map (fun (location_trace, ps') ->
            (location_trace, Pat.tuple ~loc ~attrs ps'))

        (* Same logic as for [Ppat_tuple]. *)
        | Ppat_record (entries, closed) ->
          let labels, ps = List.split entries in
          ps
          |> List.map (recurse ~enclosing_loc)
          |> all_combinations
          |> List.map (fun (location_trace, ps') ->
            (location_trace,
             Pat.record ~loc ~attrs (List.combine labels ps') closed))

        (* Same logic as for [Ppat_tuple]. *)
        | Ppat_array ps ->
          ps
          |> List.map (recurse ~enclosing_loc)
          |> all_combinations
          |> List.map (fun (location_trace, ps') ->
            location_trace, Pat.array ~loc ~attrs ps')

        (* For or-patterns, recurse into each branch. Then, concatenate the
           resulting case lists. Don't reassemble an or-pattern. *)
        | Ppat_or (p_1, p_2) ->
          let ps_1 = recurse ~enclosing_loc:p_1.ppat_loc p_1 in
          let ps_2 = recurse ~enclosing_loc:p_2.ppat_loc p_2 in
          ps_1 @ ps_2

        (* This should be unreachable in well-formed ASTs, because the caller
           strips off the [exception] pattern, and [exception] patterns cannot
           ordinarily be nested in other patterns. *)
        | Ppat_exception _ -> []

      (* Performs the Cartesian product operation described at [Ppat_tuple]
         above, concatenating location traces along the way.

         The argument is rows of top-level case lists (so a list of lists), each
         case list resulting from rotating some nested pattern. Since tuples,
         arrays, etc., have lists of nested patterns, we have a list of
         case lists. *)
      and all_combinations
          : rotated_case list list ->
              (location_trace * Parsetree.pattern list) list =
        function
        | [] -> []
        | cases::more ->
          let multiply product cases =
            product |> List.map (fun (location_trace_1, ps) ->
              cases |> List.map (fun (location_trace_2, p) ->
                location_trace_1 @ location_trace_2, ps @ [p]))
            |> List.flatten
          in

          let initial =
            cases
            |> List.map (fun (location_trace, p) -> location_trace, [p])
          in

          List.fold_left multiply initial more
      in

      recurse ~enclosing_loc:loc non_exception_pattern

    in

    outline ()

  let instrument_class_field_kind points = function
    | Parsetree.Cfk_virtual _ as cf ->
      cf
    | Parsetree.Cfk_concrete (o,e) ->
      Cf.concrete o (instrument_expr points e)

  let runtime_initialization points file =
    let point_count = Ast_convenience.int (List.length !points) in
    let points_data =
        Ast_convenience.str (Bisect.Common.write_points !points) in
    let file = Ast_convenience.str file in

    [%stri
      let ___bisect_mark___ =
        let points = [%e points_data] in
        let marks = Array.make [%e point_count] 0 in
        Bisect.Runtime.init_with_array [%e file] marks points;

        function idx ->
          let curr = marks.(idx) in
          marks.(idx) <-
            if curr < Pervasives.max_int then
              Pervasives.succ curr
            else
              curr]
end



(* The actual "instrumenter" object, marking expressions. *)
class instrumenter =
  let points = Generated_code.init () in
  let instrument_expr = Generated_code.instrument_expr points in
  let instrument_case = Generated_code.instrument_case points in
  let instrument_class_field_kind =
    Generated_code.instrument_class_field_kind points in

  object (self)
    inherit Ast_mapper_class.mapper as super

    method! class_expr ce =
      let loc = ce.pcl_loc in
      let ce = super#class_expr ce in
      match ce.pcl_desc with
      | Pcl_apply (ce, l) ->
        let l =
          List.map
            (fun (l, e) ->
              (l, (instrument_expr e)))
            l
        in
        Ast.Ast_helper.Cl.apply ~loc ~attrs:ce.pcl_attributes ce l
      | _ ->
        ce

    method! class_field cf =
      let loc = cf.pcf_loc in
      let attrs = cf.pcf_attributes in
      let cf = super#class_field cf in
      match cf.pcf_desc with
      | Pcf_val (id, mut, cf) ->
        Cf.val_ ~loc ~attrs id mut (instrument_class_field_kind cf)
      | Pcf_method (id, mut, cf) ->
        Cf.method_ ~loc ~attrs id mut (instrument_class_field_kind cf)
      | Pcf_initializer e ->
        Cf.initializer_ ~loc ~attrs (instrument_expr e)
      | _ ->
        cf

    val mutable extension_guard = false
    val mutable attribute_guard = false

    method! expr e =
      let string_of_ident ident =
        String.concat "." Ast.(Longident.flatten ident.Asttypes.txt) in
      if attribute_guard || extension_guard then
        super#expr e
      else
        let loc = e.pexp_loc in
        let attrs = e.pexp_attributes in
        let e' = super#expr e in

        match e'.pexp_desc with
        | Pexp_let (rec_flag, l, e) ->
          let l =
            List.map (fun vb ->
              Parsetree.{vb with pvb_expr = instrument_expr vb.pvb_expr}) l
          in
          Exp.let_ ~loc ~attrs rec_flag l (instrument_expr e)

        | Pexp_poly (e, ct) ->
          Exp.poly ~loc ~attrs (instrument_expr e) ct

        | Pexp_fun (al, eo, p, e) ->
          let eo = Ast.Ast_mapper.map_opt instrument_expr eo in
          Exp.fun_ ~loc ~attrs al eo p (instrument_expr e)

        | Pexp_apply (e1, [l2, e2; l3, e3]) ->
          begin match e1.pexp_desc with
          | Pexp_ident ident
              when List.mem (string_of_ident ident) [ "&&"; "&"; "||"; "or" ] ->
            Exp.apply ~loc ~attrs e1
              [l2, (instrument_expr e2);
              l3, (instrument_expr e3)]

          | Pexp_ident ident
              when string_of_ident ident = "|>" ->
            Exp.apply ~loc ~attrs e1 [l2, e2; l3, (instrument_expr e3)]

          | _ ->
            e'
          end

        | Pexp_match (e, l) ->
          List.map instrument_case l
          |> Exp.match_ ~loc ~attrs e

        | Pexp_function l ->
          List.map instrument_case l
          |> Exp.function_ ~loc ~attrs

        | Pexp_try (e, l) ->
          List.map instrument_case l
          |> Exp.try_ ~loc ~attrs e

        | Pexp_ifthenelse (e1, e2, e3) ->
          Exp.ifthenelse ~loc ~attrs e1 (instrument_expr e2)
            (match e3 with Some x -> Some (instrument_expr x) | None -> None)

        | Pexp_sequence (e1, e2) ->
          Exp.sequence ~loc ~attrs e1 (instrument_expr e2)

        | Pexp_while (e1, e2) ->
          Exp.while_ ~loc ~attrs e1 (instrument_expr e2)
        | Pexp_for (id, e1, e2, dir, e3) ->
          Exp.for_ ~loc ~attrs id e1 e2 dir (instrument_expr e3)

        | _ ->
          e'

    method! structure_item si =
      let loc = si.pstr_loc in
      match si.pstr_desc with
      | Pstr_value (rec_flag, l) ->
        let l =
          List.map begin fun vb ->    (* Only instrument things not excluded. *)
            Parsetree.{ vb with pvb_expr =
              match vb.pvb_pat.ppat_desc with
              (* Match the 'f' in 'let f x = ... ' *)
              | Ppat_var ident
                  when Exclusions.contains_value
                    (ident.loc.Location.loc_start.Lexing.pos_fname)
                    ident.txt ->
                vb.pvb_expr

              (* Match the 'f' in 'let f : type a. a -> string = ...' *)
              | Ppat_constraint (p,_) ->
                begin match p.ppat_desc with
                | Ppat_var ident
                    when Exclusions.contains_value
                      (ident.loc.Location.loc_start.Lexing.pos_fname)
                      ident.txt ->
                  vb.pvb_expr

                | _ ->
                  instrument_expr (self#expr vb.pvb_expr)
                end

              | _ ->
                instrument_expr (self#expr vb.pvb_expr)}
            end l
        in
        Str.value ~loc rec_flag l

      | Pstr_eval (e, a) when not (attribute_guard || extension_guard) ->
        Str.eval ~loc ~attrs:a (instrument_expr (self#expr e))

      | _ ->
        super#structure_item si

    (* Guard these because they can carry payloads that we
       do not want to instrument. *)
    method! extension e =
      extension_guard <- true;
      let r = super#extension e in
      extension_guard <- false;
      r

    method! attribute a =
      attribute_guard <- true;
      let r = super#attribute a in
      attribute_guard <- false;
      r

    (* This is set to [true] once the [structure] method is called for the first
       time. It's used to determine whether Bisect_ppx is looking at the
       top-level structure (module) in the file, or a nested structure
       (module). *)
    val mutable saw_top_level_structure = false

    method! structure ast =
      if saw_top_level_structure then
        super#structure ast
        (* This is *not* the first structure we see, so it is nested within the
           file, either inside [struct]..[end] or in an attribute or extension
           point. Traverse it recursively as normal. *)

      else begin
        (* This is the first structure we see, so Bisect_ppx is beginning to
           (potentially) instrument the current file. We need to check whether
           this file is excluded from instrumentation before proceeding. *)
          saw_top_level_structure <- true;

        (* Bisect_ppx is hardcoded to ignore files with certain names. If we
           have one of these, return the AST uninstrumented. In particular, do
           not recurse into it. *)
        let always_ignore_paths = ["//toplevel//"; "(stdin)"] in
        let always_ignore_basenames = [".ocamlinit"; "topfind"] in
        let always_ignore path =
          List.mem path always_ignore_paths ||
          List.mem (Filename.basename path) always_ignore_basenames
        in

        if always_ignore !Location.input_name then
          ast

        else
          (* The file might also be excluded by the user. *)
          if Exclusions.contains_file !Location.input_name then
            ast

          else begin
            (* This file should be instrumented. Traverse the AST recursively,
               then prepend some generated code for initializing the Bisect_ppx
               runtime and telling it about the instrumentation points in this
               file. *)
            let instrumented_ast = super#structure ast in
            let runtime_initialization =
              Generated_code.runtime_initialization
                points !Location.input_name
            in
            runtime_initialization::instrumented_ast
          end
      end
end