module Json = Yojson.Safe

let () =
  let load fname = Json.from_file ~fname fname in
  match Action.args with
  | ["derive";mapping;query] -> Derive.derive (load mapping) (load query)
  | ["derive";name;mapping;query] -> Derive.derive ~name (load mapping) (load query)
  | ["reflect";name;mapping] -> Derive.reflect name (load mapping)
  | ["tjson";file] -> Tjson.tjson (Std.input_file file)
  | ["parse_json";file] -> Tjson.parse_json (Std.input_file file)
  | _ -> assert false
