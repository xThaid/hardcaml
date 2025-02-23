open Base

include struct
  open Interface_intf

  module type Pre_partial = Pre_partial
  module type Pre = Pre
  module type S = S
  module type S_Of_signal = S_Of_signal
  module type Ast = Ast
  module type Empty = Empty
  module type Comb = Comb
end

module Create_fn (I : S) (O : S) = struct
  type 'a t = 'a I.t -> 'a O.t

  let sexp_of_t _ _ =
    [%message "" ~inputs:(I.t : (string * int) I.t) ~outputs:(O.t : (string * int) O.t)]
  ;;
end

module Ast = struct
  module rec Ast : sig
    type t = Field.t list [@@deriving sexp_of]
  end = struct
    type t = Field.t list [@@deriving sexp_of]
  end

  and Field : sig
    type t =
      { name : string
      ; type_ : Type.t
      ; sequence : Sequence.t option
      ; doc : string option
      }
    [@@deriving sexp_of]
  end = struct
    type t =
      { name : string
      ; type_ : Type.t
      ; sequence : Sequence.t option
      ; doc : string option
      }
    [@@deriving sexp_of]
  end

  and Type : sig
    type t =
      | Signal of
          { bits : int
          ; rtlname : string
          }
      | Module of
          { name : string
          ; ast : Ast.t
          }
    [@@deriving sexp_of]
  end = struct
    type t =
      | Signal of
          { bits : int
          ; rtlname : string
          }
      | Module of
          { name : string
          ; ast : Ast.t
          }
    [@@deriving sexp_of]
  end

  and Sequence : sig
    module Kind : sig
      type t =
        | Array
        | List
      [@@deriving sexp_of]
    end

    type t =
      { kind : Kind.t
      ; length : int
      }
    [@@deriving sexp_of]
  end = struct
    module Kind = struct
      type t =
        | Array
        | List
      [@@deriving sexp_of]
    end

    type t =
      { kind : Kind.t
      ; length : int
      }
    [@@deriving sexp_of]
  end

  type t = Ast.t [@@deriving sexp_of]
end

module type S_enum = Interface_intf.S_enum with module Ast := Ast
module type S_enums = Interface_intf.S_enums with module Ast := Ast

module Make (X : Pre) : S with type 'a t := 'a X.t = struct
  include X

  let port_names = map t ~f:fst
  let port_widths = map t ~f:snd
  let to_list_rev x = to_list x |> List.rev
  let to_alist x = to_list (map2 port_names x ~f:(fun name x -> name, x))

  let of_alist x =
    (* Assert there are no ports with duplicate names. *)
    (match List.find_all_dups (fst (List.unzip x)) ~compare:String.compare with
     | [] -> ()
     | dups -> raise_s [%message "Cannot have duplicate port names" (dups : string list)]);
    map port_names ~f:(fun name ->
      match List.Assoc.find x name ~equal:String.equal with
      | Some x -> x
      | None ->
        raise_s
          [%message
            "[Interface_extended.of_alist] Field not found in interface"
              ~missing_field_name:(name : string)
              ~input:(x : (string * _) list)
              ~interface:(port_widths : int X.t)])
  ;;

  let zip a b = map2 a b ~f:(fun a b -> a, b)
  let zip3 a b c = map2 (zip a b) c ~f:(fun (a, b) c -> a, b, c)
  let zip4 a b c d = map2 (zip a b) (zip c d) ~f:(fun (a, b) (c, d) -> a, b, c, d)

  let zip5 a b c d e =
    map2 (zip3 a b c) (zip d e) ~f:(fun (a, b, c) (d, e) -> a, b, c, d, e)
  ;;

  let map3 a b c ~f = map ~f:(fun (a, b, c) -> f a b c) (zip3 a b c)
  let map4 a b c d ~f = map ~f:(fun (a, b, c, d) -> f a b c d) (zip4 a b c d)
  let map5 a b c d e ~f = map ~f:(fun (a, b, c, d, e) -> f a b c d e) (zip5 a b c d e)
  let iter3 a b c ~f = ignore @@ map3 ~f a b c
  let iter4 a b c d ~f = ignore @@ map4 ~f a b c d
  let iter5 a b c d e ~f = ignore @@ map5 ~f a b c d e

  let equal equal_a t1 t2 =
    With_return.with_return (fun r ->
      iter2 t1 t2 ~f:(fun a1 a2 -> if not (equal_a a1 a2) then r.return false);
      true)
  ;;

  let fold a ~init ~f =
    let init = ref init in
    iter a ~f:(fun a -> init := f !init a);
    !init
  ;;

  let fold2 a b ~init ~f = fold (zip a b) ~init ~f:(fun c (a, b) -> f c a b)

  let scan a ~init ~f =
    let acc = ref init in
    map a ~f:(fun a ->
      let acc', field = f !acc a in
      acc := acc';
      field)
  ;;

  let scan2 a b ~init ~f = scan (zip a b) ~init ~f:(fun c (a, b) -> f c a b)

  let offsets ?(rev = false) () =
    let rec loop fields ~offset =
      match fields with
      | [] -> []
      | (name, width) :: fields -> (name, offset) :: loop fields ~offset:(offset + width)
    in
    loop (if rev then to_list_rev t else to_list t) ~offset:0 |> of_alist
  ;;

  let of_interface_list ts =
    List.fold
      (List.rev ts)
      ~init:(map t ~f:(fun _ -> []))
      ~f:(fun ac t -> map2 t ac ~f:(fun h t -> h :: t))
  ;;

  let to_interface_list t =
    let lengths = map t ~f:List.length in
    let distinct_lengths = fold lengths ~init:(Set.empty (module Int)) ~f:Set.add in
    match Set.to_list distinct_lengths with
    | [] -> []
    | [ length ] ->
      let rec loop length t =
        if length = 0
        then []
        else map t ~f:List.hd_exn :: loop (length - 1) (map t ~f:List.tl_exn)
      in
      loop length t
    | _ ->
      raise_s
        [%message
          "[Interface_extended.to_interface_list] field list lengths must be the same"
            (lengths : int t)]
  ;;

  module All (M : Monad.S) = struct
    let all (t : _ M.t t) =
      let%map.M l = M.all (to_list t) in
      of_alist (List.zip_exn (to_list port_names) l)
    ;;
  end

  let or_error_all t =
    let open All (Or_error) in
    all t
  ;;

  module Make_comb (Comb : Comb.S) = struct
    type comb = Comb.t [@@deriving sexp_of]
    type t = Comb.t X.t [@@deriving sexp_of]

    let widths t = map t ~f:Comb.width

    let assert_widths x =
      iter2 (widths x) t ~f:(fun actual_width (port_name, expected_width) ->
        if actual_width <> expected_width
        then
          raise_s
            [%message
              "Port width mismatch in interface"
                (port_name : string)
                (expected_width : int)
                (actual_width : int)])
    ;;

    let of_int i = map port_widths ~f:(fun b -> Comb.of_int ~width:b i)
    let of_ints i = map2 port_widths i ~f:(fun width -> Comb.of_int ~width)
    let const = of_int
    let consts = of_ints

    let pack ?(rev = false) t =
      if rev then to_list t |> Comb.concat_msb else to_list_rev t |> Comb.concat_msb
    ;;

    let unpack ?(rev = false) comb =
      let rec loop fields ~offset =
        match fields with
        | [] -> []
        | (name, width) :: fields ->
          (name, Comb.select comb (offset + width - 1) offset)
          :: loop fields ~offset:(offset + width)
      in
      loop (if rev then to_list_rev t else to_list t) ~offset:0 |> of_alist
    ;;

    let mux s l = map ~f:(Comb.mux s) (of_interface_list l)
    let mux2 s h l = mux s [ l; h ]
    let concat l = map ~f:Comb.concat_msb (of_interface_list l)

    let distribute_valids (ts : (comb, t) With_valid.t2 list) =
      List.map ts ~f:(fun { valid; value } ->
        map value ~f:(fun value -> { With_valid.valid; value }))
    ;;

    let collect_valids (t : comb With_valid.t X.t) =
      { With_valid.valid =
          (match to_list t with
           | { valid; _ } :: _ -> valid
           | [] -> raise_s [%message "[priority_select] interface has no fields"])
      ; value = map t ~f:(fun { valid = _; value } -> value)
      }
    ;;

    let priority_select ?branching_factor (ts : (comb, t) With_valid.t2 list)
      : (comb, t) With_valid.t2
      =
      if List.is_empty ts
      then raise_s [%message "[priority_select] requires at least one input"];
      let ts = distribute_valids ts in
      let t = map (of_interface_list ts) ~f:(Comb.priority_select ?branching_factor) in
      collect_valids t
    ;;

    let priority_select_with_default
          ?branching_factor
          (ts : (comb, t) With_valid.t2 list)
          ~(default : t)
      =
      if List.is_empty ts
      then raise_s [%message "[priority_select_with_default] requires at least one input"];
      let ts = distribute_valids ts in
      map2 (of_interface_list ts) default ~f:(fun t default ->
        Comb.priority_select_with_default ?branching_factor t ~default)
    ;;

    let onehot_select ?branching_factor (ts : (comb, t) With_valid.t2 list) =
      if List.is_empty ts
      then raise_s [%message "[onehot_select] requires at least one input"];
      let ts = distribute_valids ts in
      map (of_interface_list ts) ~f:(fun t -> Comb.onehot_select ?branching_factor t)
    ;;
  end

  module type Comb = Comb with type 'a interface := 'a t

  module Of_bits = Make_comb (Bits)

  module Of_signal = struct
    include Make_comb (Signal)

    let assign t1 t2 = iter2 t1 t2 ~f:Signal.assign
    let ( <== ) = assign

    let wires ?(named = false) ?from () =
      let wires =
        match from with
        | None -> map port_widths ~f:Signal.wire
        | Some x -> map x ~f:Signal.wireof
      in
      if named then map2 wires port_names ~f:Signal.( -- ) else wires
    ;;

    let reg ?enable spec t = map ~f:(Signal.reg ?enable spec) t
    let inputs () = wires () ~named:true
    let outputs t = wires () ~from:t ~named:true

    let apply_names ?(prefix = "") ?(suffix = "") ?(naming_op = Signal.( -- )) t =
      map2 t port_names ~f:(fun s n -> naming_op s (prefix ^ n ^ suffix))
    ;;

    let validate t =
      let (_ : unit X.t) =
        map3 port_names port_widths t ~f:(fun port_name port_width signal ->
          if Signal.width signal <> port_width
          then (
            let signal_width = Signal.width signal in
            Or_error.error_s
              [%message
                "Interface validation failed!"
                  (port_name : string)
                  (port_width : int)
                  (signal_width : int)])
          else Ok ())
        |> or_error_all
        |> Or_error.ok_exn
      in
      ()
    ;;
  end

  module Names_and_widths = struct
    let t = to_list t
    let port_names = to_list port_names
    let port_widths = to_list port_widths
  end

  module Of_always = struct
    let assign dst src = map2 dst src ~f:Always.( <-- ) |> to_list |> Always.proc
    let value t = map t ~f:(fun a -> a.Always.Variable.value)

    let reg ?enable spec =
      map port_widths ~f:(fun width -> Always.Variable.reg spec ?enable ~width)
    ;;

    let wire f = map port_widths ~f:(fun width -> Always.Variable.wire ~default:(f width))
  end
end

module Make_enums (Enum : Interface_intf.Enum) = struct

  module Enum = struct
    include Enum
    include Comparable.Make (Enum)
  end

  let to_rank =
    let mapping =
      List.mapi Enum.all ~f:(fun i x -> x, i) |> Map.of_alist_exn (module Enum)
    in
    fun x -> Map.find_exn mapping x
  ;;

  module Make_pre (M : sig
      val how : [ `Binary | `One_hot ]
    end) =
  struct
    let port_name, width =
      match M.how with
      | `Binary -> "binary_variant", Int.ceil_log2 (List.length Enum.all)
      | `One_hot -> "ont_hot_variant", List.length Enum.all
    ;;

    type 'a t = 'a [@@deriving sexp_of]

    let to_list t = [ t ]
    let map t ~f = f t
    let map2 a b ~f = f a b
    let iter a ~f = f a
    let iter2 a b ~f = f a b
    let t = port_name, width

    let ast : Ast.t =
      [ { Ast.Field.name = port_name
        ; type_ = Signal { bits = width; rtlname = port_name }
        ; sequence = None
        ; doc = None
        }
      ]
    ;;

    let[@inline always] to_raw t = t

    let of_raw (type a) (module Comb : Comb.S with type t = a) (t : a) =
      if Comb.width t <> width
      then
        failwith
          [%string
            "Width mismatch. Enum expects %{width#Int}, but obtained %{Comb.width t#Int}"];
      t
    ;;
  end

  module Make_interface (M : sig
      val how : [ `Binary | `One_hot ]

      val match_
        :  (module Comb.S with type t = 'a)
        -> ?default:'a
        -> 'a
        -> (Enum.t * 'a) list
        -> 'a
    end) =
  struct
    module Pre = Make_pre (M)
    include Pre
    include Make (Pre)

    let to_int_repr enum =
      match M.how with
      | `Binary -> to_rank enum
      | `One_hot -> 1 lsl to_rank enum
    ;;

    let of_enum (type a) (module Comb : Comb.S with type t = a) enum =
      Comb.of_int ~width (to_int_repr enum)
    ;;

    let to_enum =
      List.map Enum.all ~f:(fun variant -> to_int_repr variant, variant)
      |> Map.of_alist_exn (module Int)
    ;;

    let to_enum t =
      let x = Bits.to_int t in
      match Map.find to_enum x with
      | Some x -> Ok x
      | None ->
        Or_error.error_string
          (Printf.sprintf
             "Failed to convert bits %d back to an enum. Is it an undefined value?"
             x)
    ;;

    let to_enum_exn t = Or_error.ok_exn (to_enum t)
    let match_ = M.match_
    let ( ==: ) (type a) (module Comb : Comb.S with type t = a) = Comb.( ==: )

    module Of_signal = struct
      include Of_signal

      let ( ==: ) = ( ==: ) (module Signal)
      let of_enum = of_enum (module Signal)
      let of_raw = of_raw (module Signal)
      let match_ = match_ (module Signal)
      let is lhs rhs = lhs ==: of_enum rhs
    end

    module Of_bits = struct
      include Of_bits

      let ( ==: ) = ( ==: ) (module Bits)
      let of_enum = of_enum (module Bits)
      let of_raw = of_raw (module Bits)
      let match_ = match_ (module Bits)
      let is lhs rhs = lhs ==: of_enum rhs
    end

    module Of_always = struct
      include Of_always

      let all_cases = Set.of_list (module Enum) Enum.all

      let check_for_unhandled_cases cases =
        let handled_cases =
          List.fold
            cases
            ~init:(Set.empty (module Enum))
            ~f:(fun handled (case, _) ->
              if Set.mem handled case
              then raise_s [%message "Case specified multiple times!" (case : Enum.t)];
              Set.add handled case)
        in
        Set.diff all_cases handled_cases
      ;;

      let match_ ?default sel cases =
        let unhandled_cases = check_for_unhandled_cases cases in
        let default_cases =
          if Set.is_empty unhandled_cases
          then []
          else (
            match default with
            | None -> raise_s [%message "[default] not specified on non exhaustive cases"]
            | Some default ->
              List.map (Set.to_list unhandled_cases) ~f:(fun case -> case, default))
        in
        let cases =
          List.map (cases @ default_cases) ~f:(fun (case, x) -> Of_signal.of_enum case, x)
        in
        Always.switch (to_raw sel) cases
      ;;
    end

    (* Testbench functions. *)
    let sim_set t enum = t := of_enum (module Bits) enum
    let sim_set_raw t raw = t := raw
    let sim_get t = to_enum !t
    let sim_get_exn t = Or_error.ok_exn (sim_get t)
    let sim_get_raw t = !t
  end

  let num_enums = List.length Enum.all

  let raise_non_exhaustive_mux () =
    failwith "[mux] on enum cases not exhaustive, and [default] not provided"
  ;;

  module Binary = Make_interface (struct
      let how = `Binary

      let match_
            (type a)
            (module Comb : Comb.S with type t = a)
            ?(default : a option)
            selector
            cases
        =
        let out_cases = Array.create ~len:num_enums default in
        List.iter cases ~f:(fun (enum, value) -> out_cases.(to_rank enum) <- Some value);
        let cases =
          List.map (Array.to_list out_cases) ~f:(function
            | None -> raise_non_exhaustive_mux ()
            | Some case -> case)
        in
        Comb.mux selector cases
      ;;
    end)

  module One_hot = Make_interface (struct
      let how = `One_hot

      let match_
            (type a)
            (module Comb : Comb.S with type t = a)
            ?(default : a option)
            selector
            cases
        =
        let out_cases = Array.create ~len:num_enums default in
        List.iter cases ~f:(fun (enum, value) -> out_cases.(to_rank enum) <- Some value);
        let cases =
          List.map (Array.to_list out_cases) ~f:(function
            | None -> raise_non_exhaustive_mux ()
            | Some case -> case)
        in
        List.map2_exn (Comb.bits_lsb selector) cases ~f:(fun valid value ->
          { With_valid.valid; value })
        |> Comb.onehot_select
      ;;
    end)
end

module Update
    (Pre : Interface_intf.Pre) (M : sig
                                  val t : (string * int) Pre.t
                                end) =
struct
  module T = struct
    include Pre

    let t = M.t
  end

  include (T : Interface_intf.Pre with type 'a t = 'a T.t)
  include Make (T)
end

module Empty = struct
  type 'a t = None [@@deriving sexp_of]

  include Make (struct
      type nonrec 'a t = 'a t [@@deriving sexp_of]

      let t = None
      let iter _ ~f:_ = ()
      let iter2 _ _ ~f:_ = ()
      let map _ ~f:_ = None
      let map2 _ _ ~f:_ = None
      let to_list _ = []
    end)
end

module Make_with_valid (M : Pre) = struct
  module Pre = struct
    type 'a t = 'a With_valid.t M.t [@@deriving sexp_of]

    let map t ~f = M.map ~f:(With_valid.map ~f) t
    let iter (t : 'a t) ~(f : 'a -> unit) = M.iter ~f:(With_valid.iter ~f) t
    let map2 a b ~f = M.map2 a b ~f:(With_valid.map2 ~f)
    let iter2 a b ~f = M.iter2 a b ~f:(With_valid.iter2 ~f)

    let t =
      M.map M.t ~f:(fun (n, w) ->
        { With_valid.value = n ^ "$value", w; valid = n ^ "$valid", 1 })
    ;;

    let to_list t = M.map t ~f:With_valid.to_list |> M.to_list |> List.concat
  end

  include Pre
  include Make (Pre)
end

module type S_with_ast = sig
  include S

  val ast : Ast.t
end
