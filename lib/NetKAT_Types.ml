open Sexplib.Conv

(** NetKAT Syntax *)
open Core.Std

(** {2 Basics} *)
open Packet

type switchId = SDN_Types.switchId
type portId = SDN_Types.portId
type payload = SDN_Types.payload

(** {2 Policies} *)

type location =
  | Physical of int32
  | Pipe of string
  with sexp

type header_val =
  | Switch of switchId
  | Location of location
  | EthSrc of dlAddr
  | EthDst of dlAddr
  | Vlan of int16
  | VlanPcp of dlVlanPcp
  | EthType of dlTyp
  | IPProto of nwProto
  | IP4Src of nwAddr * int32
  | IP4Dst of nwAddr * int32
  | TCPSrcPort of tpPort
  | TCPDstPort of tpPort

type pred =
  | True
  | False
  | Test of header_val
  | And of pred * pred
  | Or of pred * pred
  | Neg of pred

type policy =
  | Filter of pred
  | Mod of header_val
  | Union of policy * policy
  | Seq of policy * policy
  | Star of policy
  | Link of switchId * portId * switchId * portId

let id = Filter True

let drop = Filter False

(** {2 Packets}

  If we only defined the semantics and were not building a system, a
  packet would only be a record of headers. However, the runtime needs to
  apply [eval] to packets contained in [PACKET_IN] mesages. For the runtime,
  packets also carry a payload that is unmodified by [eval]. *)

(** A map keyed by header names. *)
module Headers = struct
  open Core.Std
  (*
   * Note that this module uses the fieldslib library from Jane Street, a syntax
   * extension that generates several convenience functions, .e.g, fold, map,
   * iter, getters, setters, etc., specialized for the record type.  More
   * documentation can be found here:
   *
   *   https://github.com/janestreet/fieldslib
   * *)

  module type HEADER = sig
    type t with sexp
    val compare : t -> t -> int
    val to_string : t -> string
    val equal : t -> t -> bool
    val is_any : t -> bool
  end

  module Make =
    functor(Location:HEADER) ->
    functor(EthSrc:HEADER) ->
    functor(EthDst:HEADER) ->
    functor(Vlan:HEADER) ->
    functor(VlanPcp:HEADER) ->
    functor(EthType:HEADER) ->
    functor(IpProto:HEADER) ->
    functor(IpSrc:HEADER) ->
    functor(IpDst:HEADER) ->
    functor(TcpSrcPort:HEADER) ->
    functor(TcpDstPort:HEADER) ->
  struct
    type t =
        { location : Location.t sexp_opaque;
          ethSrc : EthSrc.t sexp_opaque;
          ethDst : EthDst.t sexp_opaque;
          vlan : Vlan.t sexp_opaque;
          vlanPcp : VlanPcp.t sexp_opaque;
          ethType : EthType.t sexp_opaque;
          ipProto : IpProto.t sexp_opaque;
          ipSrc : IpSrc.t sexp_opaque;
          ipDst : IpDst.t sexp_opaque;
          tcpSrcPort : TcpSrcPort.t sexp_opaque;
          tcpDstPort : TcpDstPort.t sexp_opaque
        } with sexp, fields

    let compare x y =
      let g c a f =
        if a <> 0 then a
        else c (Field.get f x) (Field.get f y) in
      Fields.fold
        ~init:0
        ~location:(g Location.compare)
        ~ethSrc:(g EthSrc.compare)
        ~ethDst:(g EthDst.compare)
        ~vlan:(g Vlan.compare)
        ~vlanPcp:(g VlanPcp.compare)
        ~ethType:(g EthType.compare)
        ~ipProto:(g IpProto.compare)
        ~ipSrc:(g IpSrc.compare)
        ~ipDst:(g IpDst.compare)
        ~tcpSrcPort:(g TcpSrcPort.compare)
        ~tcpDstPort:(g TcpDstPort.compare)

    let to_string ?init:(init="") ?sep:(sep="=") (x:t) : string =
      let g is_any to_string acc f =
        let v = Field.get f x in
        if is_any v then acc
        else
          Printf.sprintf "%s%s%s%s"
            (if acc = init then "" else acc ^ "; ")
            (Field.name f) sep (to_string (Field.get f x)) in
      Fields.fold
        ~init:init
        ~location:Location.(g is_any to_string)
        ~ethSrc:EthSrc.(g is_any to_string)
        ~ethDst:EthDst.(g is_any to_string)
        ~vlan:Vlan.(g is_any to_string)
        ~vlanPcp:VlanPcp.(g is_any to_string)
        ~ethType:EthType.(g is_any to_string)
        ~ipProto:IpProto.(g is_any to_string)
        ~ipSrc:IpSrc.(g is_any to_string)
        ~ipDst:IpDst.(g is_any to_string)
        ~tcpSrcPort:TcpSrcPort.(g is_any to_string)
        ~tcpDstPort:TcpDstPort.(g is_any to_string)

    let is_any (x:t) : bool = 
      let g is_any f = is_any (Field.get f x) in 
      Fields.for_all
        ~location:Location.(g is_any)
        ~ethSrc:EthSrc.(g is_any)
        ~ethDst:EthDst.(g is_any)
        ~vlan:Vlan.(g is_any)
        ~vlanPcp:VlanPcp.(g is_any)
        ~ethType:EthType.(g is_any)
        ~ipProto:IpProto.(g is_any)
        ~ipSrc:IpSrc.(g is_any)
        ~ipDst:IpDst.(g is_any)
        ~tcpSrcPort:TcpSrcPort.(g is_any)
        ~tcpDstPort:TcpDstPort.(g is_any)

  end
end

module LocationHeader = struct
  type t = location with sexp
  let compare = Pervasives.compare
  let equal = (=)
  let to_string l =
    match l with
      | Pipe x -> Printf.sprintf "%s" x
      | Physical n -> Printf.sprintf "%lu" n
  let is_any l = false
end
module IntHeader = struct
  include Int
  let is_any _ = false
end
module Int32Header = struct
  include Int32
  let is_any _ = false
end
module Int32TupleHeader = struct
  (* Represents an (ip_address, mask) tuple. *)
  type t = Int32Header.t * Int32Header.t with sexp
  let shift (p,m) =
    let s = match Int32.to_int (Int32.(-) 32l m) with Some i -> i | None -> 0 in
    Int32.shift_right p s
  let equal (p,m) (p',m') =
    Int32Header.equal (shift (p,m)) (shift (p',m'))
  let compare ((p,m):t) ((p',m'):t) : int =
    if Pervasives.compare p p' = 0 then Pervasives.compare m m'
    else Pervasives.compare p p'
    (*Int32Header.compare (shift (p,m)) (shift (p',m'))*)
  let to_string (p,m) =
    let s = if m = 32l then "" else "/" ^ (Int32Header.to_string m) in
    Int32Header.to_string p ^ s
  let is_any _ = false

  let min_int32 x y = if Int32.(<) x y then x else y

  let are_compatible ((n,m): t) ((r,s): t) : bool =
    (* Two masked fields are compatible if their prefixes agree. *)
    let common_mask = match Int32.to_int (min_int32 m s) with
    | Some i -> i
    | None   -> 0 in (* overflow case, never happens because m,s < 32 *)
    let mask =
       Int32.shift_left
         (Int32.(-) (Int32.shift_left 1l common_mask) 1l)
         (32 - common_mask) in
    (Int32.bit_and mask n) = (Int32.bit_and mask m)

  let inter ((n,m) as p1: t) ((r,s) as p2: t) : t option =
    if are_compatible p1 p2 then
      (if Int32.(<) m s then Some p1 else Some p2)
    else None

  let subseteq ((n,m) as p1: t) ((r,s) as p2: t) : bool =
    if are_compatible p1 p2 then Int32.(>) m s
    else false

end
module Int64Header = struct
  include Int64
  let is_any _ = false
end

module HeadersValues =
  Headers.Make
    (LocationHeader)
    (Int64Header)
    (Int64Header)
    (IntHeader)
    (IntHeader)
    (IntHeader)
    (IntHeader)
    (Int32Header)
    (Int32Header)
    (IntHeader)
    (IntHeader)

type packet = {
  switch : switchId;
  headers : HeadersValues.t;
  payload : payload
}

module PacketSet = Set.Make (struct
  type t = packet sexp_opaque with sexp

  (* First compare by headers, then payload. The payload comparison is a
     little questionable. However, this is safe to use in eval, since
     all output packets have the same payload as the input packet. *)
  let compare x y =
    let cmp = HeadersValues.compare x.headers y.headers in
    if cmp <> 0 then
      cmp
    else
      Pervasives.compare x.payload y.payload
end)

(** {3 Applications} *)

type action = SDN_Types.action


type switch_port = switchId * portId
type host = Packet.dlAddr * Packet.nwAddr

type bufferId = Int32.t (* XXX(seliopou): different than SDN_Types *)
type bytes = Packet.bytes

type event =
  | PacketIn of string * switchId * portId * payload * int
  | Query of string * int64 * int64
  | SwitchUp of switchId
  | SwitchDown of switchId
  | PortUp of switch_port
  | PortDown of switch_port
  | LinkUp of switch_port * switch_port
  | LinkDown of switch_port * switch_port
  | HostUp of switch_port * host
  | HostDown of switch_port * host
