(*
 * This file is part of Bisect_ppx.
 * Copyright (C) 2016 Anton Bachin.
 *
 * Bisect is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * Bisect is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *)

open OUnit2

let _directory = "_scratch"

let _test_context = ref None

let _read_file name =
  let buffer = Buffer.create 4096 in
  let channel = open_in name in

  try
    let rec read () =
      try input_char channel |> Buffer.add_char buffer; read ()
      with End_of_file -> ()
    in
    read ();
    close_in channel;

    Buffer.contents buffer

  with exn ->
    close_in_noerr channel;
    raise exn

let _command_failed ?status command =
  match status with
  | None -> Printf.sprintf "'%s' did not exit" command |> failwith
  | Some v -> Printf.sprintf "'%s' failed with status %i" command v |> failwith

let _run_int command =
  begin
    match !_test_context with
    | None -> ()
    | Some context -> logf context `Info "Running '%s'" command
  end;

  match Unix.system command with
  | Unix.WEXITED v -> v
  | _ -> _command_failed command

let run command =
  let v = _run_int command in
  if v <> 0 then _command_failed command ~status:v

let _run_bool command = _run_int command = 0

let with_directory context f =
  if Sys.file_exists _directory then run ("rm -r " ^ _directory);
  Unix.mkdir _directory 0o755;

  let old_wd = Sys.getcwd () in
  let new_wd = Filename.concat old_wd _directory in
  Sys.chdir new_wd;

  _test_context := Some context;

  let restore () =
    _test_context := None;
    Sys.chdir old_wd;
    run ("rm -r " ^ _directory)
  in

  logf context `Info "In directory '%s'" new_wd;

  try f (); restore ()
  with exn -> restore (); raise exn

let have_binary binary =
  _run_bool ("which " ^ binary ^ " > /dev/null 2> /dev/null")

let have_package package =
  _run_bool ("ocamlfind query " ^ package ^ "> /dev/null 2> /dev/null")

let if_package package =
  skip_if (not @@ have_package package) (package ^ " not installed")

let compile ?(r = "") arguments source =
  let source_copy = Filename.basename source in

  let intermediate = Filename.dirname source = _directory in
  begin
    if not intermediate then
      let source_actual = Filename.concat Filename.parent_dir_name source in
      run ("cp " ^ source_actual ^ " " ^ source_copy)
  end;

  run ("ocamlfind ocamlc -linkpkg " ^ arguments ^ " " ^ source_copy ^ " " ^ r)

let with_bisect_ppx =
  "-I ../../_build bisect.cma -ppx ../../_build/src/syntax/bisect_ppx.byte"

let with_bisect_ppx_args arguments =
  "-I ../../_build bisect.cma -ppx " ^
  "\"../../_build/src/syntax/bisect_ppx.byte " ^ arguments ^ " \""

let report ?(f = "bisect*.out") ?(r = "") arguments =
  Printf.sprintf "../../_build/src/report/report.byte %s %s %s" arguments f r
  |> run

let diff reference =
  let reference_actual = Filename.concat Filename.parent_dir_name reference in
  let command = "diff " ^ reference_actual ^ " output" in

  let status = _run_int (command ^ " > /dev/null") in
  match status with
  | 0 -> ()
  | v when v <> 1 -> _command_failed command ~status:v
  | _ ->
    _run_int (command ^ " > delta") |> ignore;
    let delta = _read_file "delta" in
    Printf.sprintf "Difference against '%s':\n\n%s" reference delta
    |> assert_failure

let xmllint arguments =
  skip_if (not @@ have_binary "xmllint") "xmllint not installed";
  run ("xmllint " ^ arguments)

let compile_compare arguments directory =
  let tests =
    Sys.readdir directory
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".ml")
    |> List.filter (fun f ->
      let prefix = "test_" in
      let prefix_length = String.length prefix in
      String.length f < prefix_length || String.sub f 0 prefix_length <> prefix)

    |> List.map begin fun f ->
      let source = Filename.concat directory f in
      let title = Filename.chop_suffix f ".ml" in
      let reference = Filename.concat directory (f ^ ".reference") in

      title >:: begin fun context ->
        with_directory context (fun () ->
          compile (arguments ^ " -dsource") source ~r:"2> output";
          diff reference)
      end
    end
  in

  directory >::: tests
