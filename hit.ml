open ExtLib

open Common

let get_meta json default k =
  let meta = `Assoc (Option.default [] @@ U.(opt "_meta" to_assoc json)) in
  Option.default default U.(opt k to_bool meta)

module ES_names = Set.Make(ES_name)
let es_names mapping l = l |> List.map (ES_name.make mapping) |> ES_names.of_list

let option_map2 op a b =
  match a, b with
  | x, None | None, x -> x
  | Some a, Some b -> Some (op a b)

let include_parents x = ES_names.fold (ES_name.fold_up ES_names.add) x x
let parent_included path set = ES_name.fold_up (fun x acc -> acc || ES_names.mem x set) path false

let of_mapping ?(filter=empty_filter) x : result_type =
  let smake k = source_fields k x.mapping |> Option.map (es_names x) in
  let excludes = option_map2 ES_names.union (smake "excludes") (Option.map (es_names x) filter.excludes) in
  let includes = option_map2 ES_names.inter (smake "includes") (Option.map (es_names x) filter.includes) in
  let includes = match includes with None -> None | Some set -> Some (set, include_parents set) in
  let rec make ~optional path json =
    let meta = get_meta json in
    let wrap multi t =
      let t = if meta multi "multi" then `List t else t in
      if meta optional "optional" then `Maybe t else t
    in
    let default_optional = meta false "fields_default_optional" in
    match U.assoc "type" json with
    | exception _ -> wrap false @@ make_properties ~default_optional path json
    | `String "nested" -> wrap true @@ make_properties ~default_optional path json
    | `String t -> wrap false @@ `Ref (path, simple_of_es_type path t)
    | _ -> Exn.fail "strange type : %s" (U.to_string json)
  and make_properties ~default_optional path json =
    match U.(get "properties" to_assoc json) with
    | exception _ -> Exn.fail "strange mapping : %s" (U.to_string json)
    | f -> `Dict (f |> List.filter_map begin fun (name,x) ->
      begin match x with `Assoc _ -> () | _ -> Exn.fail "property %S not a dict" name end;
      let path = ES_name.append path name in
      let included = (* TODO wildcards *)
        (match excludes with None -> true | Some set -> not @@ ES_names.mem path set) &&
        (match includes with None -> true | Some (set,parents) -> parent_included path set || ES_names.mem path parents) &&
        not @@ get_meta x false "ignore"
      in
      match included with
      | false -> (* printfn "(* excluded %s *)" (ES_name.show path); *) None
      | true -> Some (name, make ~optional:default_optional path x)
      end)
  in
  make ~optional:false (ES_name.make x "") x.mapping

let get_nested path x =
  let rec loop path x =
    match path, x with
    | p, (`Maybe x | `List x) -> loop p x (* HACK unwrap *)
    | [], _ -> x
    | k::p, `Dict l -> loop p (try List.assoc k l with exn -> Exn.fail ~exn "cannot find nested %S" k)
    | k::_, _ -> Exn.fail "nested %S is not a dict" k
  in
  loop (ES_name.get_path path) x

let doc_ ?(id=true) ?found source =
  let a = [
    "_id", if id then Some `String else None;
  (*
    "_index", `String;
    "_type", `String;
    "_score", `Maybe `Float;
  *)
    "found", found;
    "_source", source;
  ] |> List.filter_map (function (_,None) -> None | (k,Some v) -> Some (k,v))
  in
  `Dict a

let doc_no_source = doc_ ~found:`Bool None
let doc source = doc_ ~found:`Bool (Some source)
let hit ?id source = doc_ ?id (Some source)

let hits mapping ?nested source : result_type =
  let hit x =
    match nested with
    | None -> hit x
    | Some nested -> hit ~id:false @@ get_nested nested x
  in
  `Dict (
    List.concat [
        ["total", `Int];
        (match source with None -> [] | Some filter -> ["hits", `List (hit @@ of_mapping ~filter mapping)]);
      ]
  )
