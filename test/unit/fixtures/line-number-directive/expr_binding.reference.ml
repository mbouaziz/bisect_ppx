module Bisect_visit___expr_binding___ml =
  struct
    let ___bisect_visit___ =
      let point_definitions =
        "\132\149\166\190\000\000\000!\000\000\000\b\000\000\000\029\000\000\000\029\240\160}@\160\000vB\160\001\000\142A\160\001\000\183D\160\001\000\186C\160\001\000\211F\160\001\000\223E" in
      let `Staged cb =
        Bisect.Runtime.register_file "expr_binding.ml" ~point_count:7
          ~point_definitions in
      cb
  end
open Bisect_visit___expr_binding___ml
let x = 3
let y = [1; 2; 3]
let z = [|1;2;3|]
let f x = ___bisect_visit___ 0; print_endline x
let f' x =
  ___bisect_visit___ 2;
  (let x' =
     let ___bisect_result___ = String.uppercase x in
     ___bisect_visit___ 1; ___bisect_result___ in
   print_endline x')
let g x y z =
  ___bisect_visit___ 4;
  (let ___bisect_result___ = x + y in
   ___bisect_visit___ 3; ___bisect_result___) * z
let g' x y =
  ___bisect_visit___ 6;
  (let ___bisect_result___ = print_endline x in
   ___bisect_visit___ 5; ___bisect_result___);
  print_endline y
