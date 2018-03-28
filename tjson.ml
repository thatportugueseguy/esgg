(** Template JSON *)

open Printf
open ExtLib
open Prelude

type t = [
| `Assoc of (string * t) list
| `Bool of bool
| `Float of float
| `List of t list
| `Null
| `String of string
| `Var of string
]

let pp_string f x =
  let b = Buffer.create 10 in
  let pf = Format.formatter_of_buffer b in
  f pf x;
  Format.pp_flush_formatter pf;
  Buffer.contents b

let show_error = pp_string Jsonm.pp_error
let show_lexeme = pp_string Jsonm.pp_lexeme

let sub_decoded d s =
  let ((l1,c1),(l2,c2)) = Jsonm.decoded_range d in
  let find_line l =
    let rec loop i = function
    | 0 -> assert false
    | 1 -> i
    | l -> loop (String.index_from s i '\n' + 1) (l - 1)
    in
    loop 0 l
  in
  let first = find_line l1 + c1 - 1 in
  let last = find_line l2 + c2 in
  String.slice ~first ~last s

let var_name s =
  match Scanf.sscanf s "$%_[a-zA-Z]%_[0-9_a-zA-Z]%!" () with
  | exception _ -> Exn.fail "bad var name %S" s
  | () -> String.slice ~first:1 s

let show_decoded_range ((l1,c1),(l2,c2)) = sprintf "%d,%d-%d,%d" l1 c1 l2 c2

let parse s : t =
  let exception Escape of ((int * int) * (int * int)) * Jsonm.error in
  let lexeme d =
    match Jsonm.decode d with
    | `Lexeme l -> (l :> [Jsonm.lexeme|`Var of string])
    | `Error (`Expected `Value) -> `Var (var_name @@ String.strip @@ sub_decoded d s)
    | `Error e -> raise (Escape (Jsonm.decoded_range d, e))
    | `End | `Await -> assert false
  in
  let rec value v k d =
    match v with
    | `Os -> obj [] k d
    | `As -> arr [] k d
    | `Null | `Bool _ | `String _ | `Float _ | `Var _ as v -> k v d
    | _ -> assert false
  and arr vs k d =
    match lexeme d with
    | `Ae -> k (`List (List.rev vs)) d
    | v -> value v (fun v -> arr (v :: vs) k) d
  and obj ms k d =
    match lexeme d with
    | `Oe -> k (`Assoc (List.rev ms)) d
    | `Name n -> value (lexeme d) (fun v -> obj ((n, v) :: ms) k) d
    | _ -> assert false
  in
  let d = Jsonm.decoder @@ `String s in
  try
    let v = value (lexeme d) (fun v _ -> v) d in
    match Jsonm.decode d with
    | `End -> v
    | `Lexeme l -> Exn.fail "expected End, got %s" (show_lexeme l)
    | `Error e -> Exn.fail "expected End, got %s" (show_error e)
    | `Await -> assert false
  with
    Escape (range,e) -> Exn.fail "E: %s %s" (show_decoded_range range) (show_error e)

let lift_to_string v =
  let module J = Yojson.Basic in
  let module Bi = Bi_outbuf in
  let out = Buffer.create 10 in
  let cur = Bi.create 10 in
  let comma f = fun i x -> if i <> 0 then Bi.add_char cur ','; f x in
  let rec write = function
  | `Null -> J.write_null cur ()
  | `Bool b -> J.write_bool cur b
  | `String s -> J.write_string cur s
  | `Float f -> J.write_float cur f
  | `Var name -> bprintf out "%S^%s^" (Bi.contents cur) name; Bi.clear cur
  | `List l -> Bi.add_char cur '['; List.iteri (comma write) l; Bi.add_char cur ']'
  | `Assoc a ->
    Bi.add_char cur '{';
    List.iteri (comma @@ (fun (k,v) -> J.write_string cur k; Bi.add_char cur ':'; write v)) a;
    Bi.add_char cur '}'
  in
  write v;
  bprintf out "%S" (Bi.contents cur);
  Buffer.contents out

let rec fold (f:'a->t->'a) acc = function
| `Null | `Bool _ | `String _ | `Float _ | `Var _ as x -> f acc x
| `List l -> List.fold_left (fold f) acc l
| `Assoc a -> List.fold_left (fun acc (_,v) -> fold f acc v) acc a

let vars v =
  List.unique ~cmp:String.equal (fold (fun acc x -> match x with `Var name -> name::acc | _ -> acc) [] v)

let tjson s =
  let v = parse s in
  printf "fun ";
  List.iter (fun var -> printf "~%s " var) (vars v);
  printf "() -> %s" (lift_to_string v);
  print_newline ();
  ()

let parse_json s =
  let rec show d =
    match Jsonm.decode d with
    | `Await -> assert false
    | `End -> printfn "end"
    | `Error e -> printfn "error %s %s" (show_decoded_range @@ Jsonm.decoded_range d) (show_error e); show d
    | `Lexeme x -> printfn "%s" (show_lexeme x); show d
  in
  show @@ Jsonm.decoder @@ `String s
