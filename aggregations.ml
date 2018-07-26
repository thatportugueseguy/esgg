open ExtLib

open Common

type agg_type =
| Simple_metric of string
| Cardinality of string
| Terms of { field : string; size : Tjson.t }
| Histogram of string
| Date_histogram of string
| Filter of Query.query
| Filters of (string * Query.query) list
| Top_hits of source_filter option
| Range of string
| Nested of string
| Reverse_nested

type single = { name : string; agg : agg_type; }
type t = { this : single; sub : t list; }

let analyze_single name agg_type json =
  let field () = U.(get "field" to_string json) in
  let agg =
    match agg_type with
    | "max" | "min" | "avg" | "sum" -> Simple_metric (field ())
    | "cardinality" -> Cardinality (field ())
    | "terms" | "significant_terms" -> Terms { field = field (); size = U.member "size" json }
    | "histogram" -> Histogram (field ())
    | "date_histogram" -> Date_histogram (field ())
    | "filter" -> Filter (Query.extract_query json)
    | "filters" -> Filters (json |> U.member "filters" |> U.to_assoc |> List.map (fun (k,v) -> k, Query.extract_query v))
    | "top_hits" -> Top_hits (Query.extract_source json)
    | "range" -> Range (field ()) (* TODO keyed *)
    | "nested" -> Nested U.(get "path" to_string json)
    | "reverse_nested" -> Reverse_nested
    | _ -> Exn.fail "unknown aggregation type %S" agg_type
  in
  { name; agg; }

let extract x =
  let open U in
  let (aggs,rest) = List.partition (function (("aggregations"|"aggs"),_) -> true | _ -> false) (to_assoc x) in
  let aggs =
    match aggs with
    | [] -> []
    | (_,a) :: [] -> to_assoc a
    | _::_::_ -> Exn.fail "only one aggregation expected"
  in
  aggs,rest

let rec make (name,x) =
  try
    let (sub,rest) = extract x in
    match rest with
    | [agg_type,x] ->
      let this = analyze_single name agg_type x in
      let sub = List.map make sub in
      { this; sub }
    | _ -> Exn.fail "no aggregation?"
  with
    exn -> Exn.fail ~exn "aggregation %S" name

let get x =
  extract x |> fst |> List.map make

let infer_single mapping { name; agg; } sub =
  let buckets ?(extra=[]) t = `Dict [ "buckets", `List (sub @@ ("key", t) :: ("doc_count", `Int) :: extra) ] in
  let doc_count () = sub ["doc_count", `Int] in
  let (cstr,shape) =
    match agg with
    | Simple_metric field -> [Field_num field], sub [ "value", `Maybe `Double ]
    | Cardinality _field -> [], sub ["value", `Int ]
    | Terms { field; size } -> (match size with `Var var -> [On_var (var, Eq_type `Int)] | _ -> []), buckets (`Typeof field)
    | Histogram field -> [Field_num field], buckets `Double
    | Date_histogram field -> [Field_date field], buckets `Int ~extra:["key_as_string", `String]
    | Nested _ | Reverse_nested -> [], doc_count ()
    | Filter q -> Query.infer q, doc_count ()
    | Filters l ->  (* TODO other_bucket *)
      let cstrs = l |> List.map snd |> List.map Query.infer |> List.flatten in
      let d = doc_count () in
      cstrs, `Dict [ "buckets", `Dict (l |> List.map (fun (k,_) -> k, d))]
    | Top_hits source -> [], `Dict [ "hits", (Hit.hits mapping source :> resolve_type) ]
    | Range field -> [Field_num field], `Dict [ "buckets", `List (doc_count ()) ]
  in
  cstr, (name, shape)

let rec infer mapping { this; sub } =
  let (constraints, subs) = List.split @@ List.map (infer mapping) sub in
  let sub l = `Dict (l @ subs) in
  let (cstr,desc) = infer_single mapping this sub in
  List.flatten (cstr::constraints), desc

let analyze mapping query = List.map (infer mapping) (get query)
