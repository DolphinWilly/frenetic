open Core.Std
open Async.Std

open NetKAT_Types

(** [node] is an entity in the network, currently either a switch with a
    datapath id, or a host with a MAC and IPv4 address. *)
type node =
  | Switch of SDN_Types.switchId
  | Host of Frenetic_Packet.dlAddr * Frenetic_Packet.nwAddr

module Node : Network.VERTEX
  with type t = node
module Link : Network.EDGE
  with type t = unit

(** A representation of the network, with [node] as a label for vertices, and
    [unit] as labels for edges. *)
module Net : Network.NETWORK
  with module Topology.Vertex = Node
   and module Topology.Edge = Link

(** The set of pipe names that an application is listening on. *)
module PipeSet : Set.S
  with type Elt.t = string

type ('phantom, 'a) pipes = {
  pkt_out : (switchId * SDN_Types.pktOut, 'phantom) Pipe.t;
  update  : ('a, 'phantom) Pipe.t
}

type 'a send = (Pipe.Writer.phantom, 'a) pipes
type 'a recv = (Pipe.Reader.phantom, 'a) pipes

type 'a callback = event -> 'a option Deferred.t

(** A [handler] is a function that's used to both create basic reactive [app]s as
    well as run them. The [unit] argument indicates a partial application point. *)
type ('r, 'a) handler
  =  'r -> (switchId * SDN_Types.pktOut) Pipe.Writer.t -> unit -> 'a callback

(** [asycn_handler] is a function that's used to build reactive [app]s that
    are also capable of pushing asynchronous value updates. The [unit] argument
    indicates a partial application point. *)
type ('r, 'a) async_handler
  =  'r -> 'a send -> unit -> 'a callback

module Raw : sig

  (** [t] is an opaque application type.  The user can use constructors and
      combinators defined below to build up complex applications from simple
      parts. *)
  type ('r, 'a) t

  (** [create ?pipes valu handler] returns a [t] that listens to the pipes
      included in [pipes], uses [val] as the initial default value and [handler]
      as the function to handle network events. *)
  val create : ?pipes:PipeSet.t -> 'a -> ('r, 'a) handler -> ('r, 'a) t

  (** [create_async ?pipes val async_handler] returns a [t] that listens to
      the pipes included in [pipes], uses [val] as the initial value and
      [async_handler] as the function used to handle network events.

      In addition to a [pktOut] pipe, the [async_handler] is also given an ['a]
      pipe that it can use to push asychronous value updates. *)
  val create_async : ?pipes:PipeSet.t -> 'a -> ('r, 'a) async_handler -> ('r, 'a) t

  (** [create_static val] returns a static [t] that will only ever take on the
       value [val]. *)
  val create_static : 'a -> ('r, 'a) t
end

module Pred : sig
  type t = (Net.Topology.t ref, pred) Raw.t

  type handler = Net.Topology.t -> event -> pred option Deferred.t
  type async_handler = pred Pipe.Writer.t -> unit -> handler

  (** [create pred handler] returns a [Pred.t] that uses [pred] as a default
      predicate and [handler] as the network event handler. *)
  val create : pred -> handler -> t

  (** [create pred async_handler] returns a [Pred.t] that uses pred as the
      default predicate and [async_handler] as the network event handler. The
      unit argument of the handler indicates a partial application ponit that
      will only be evaluated once by this constructor. *)
  val create_async : pred -> async_handler -> t

  (** [create_static pred] returns a static [Pred.t] for the NetKAT predicate
      [pred]. *)
  val create_static : pred -> t

  (** [crate_from_string str] returns a static [Pred.t] for the NetKAT policy
      [str]. *)
  val create_from_string : string -> t

  (** [create_from_file f] returns a static [Pred.t] from the NetKAT policy
      contained in the file [f]. *)
  val create_from_file : string -> t
end

module Policy : sig
  type t = (Net.Topology.t ref, policy) Raw.t

  (** [create ?pipes pol handler] returns an [Policy.t] that listens to the
      pipes included in [pipes], uses [pol] as the initial default policy to
      install, and [handler] as the network event handler. The unit argument of
      the handler indicates a partial application point that will only be
      evaluated once by this constructor. *)
  val create : ?pipes:PipeSet.t -> policy -> (Net.Topology.t ref, policy) handler -> t

  (** [create_async ?pipes pol async_handler] returns an [app] that listens to
      the pipes included in [pipes], uses [pol] as the initial default policy to
      install, and [async_handler] as the network event handler. The unit
      argument of the handler indicates a partial application point that will
      only be evaluated once by this constructor.

      This constructor also passes the handler function a [Pipe.t] that can be
      used to push asynchronous policy updates, i.e., a policy update that's not
      in response to a network event.
      *)
  val create_async : ?pipes:PipeSet.t -> policy -> (Net.Topology.t ref, policy) async_handler -> t

  (** [create_static pol] returns a static [Policy.t] for the NetKAT syntax tree [pol] *)
  val create_static : policy -> t

  (** [create_from_string str] returns a static [Policy.t] for the NetKAT policy [str] *)
  val create_from_string : string -> t

  (** [create_from_file f] returns a static [Policy.t] from the NetKAT policy contained
      in the file [f]. *)
  val create_from_file : string -> t
end


(** [default t] returns the current value of the app

    Note that this may not be the same default value used to construct the
    application. It is the last value that the application generated in
    response to an event. *)
val default : ('r, 'a) Raw.t -> 'a

(** [run t] returns a [handler] that implements [t]. The [unit] argument
 * indicates a partial application point. *)
val run : ('r, 'a) Raw.t -> 'r -> unit -> ('a recv * (event -> unit Deferred.t))

(** [lift f t] returns a [Raw.t] that will updates its value to [b = f a]
    whenever [t] updates its value to be [a]. *)
val lift : ('a -> 'b) -> ('r, 'a) Raw.t -> ('r, 'b) Raw.t

(** [ap t1 t2] returns a [Raw.t] that will update its value whenever [t1] or
    [t2] update their value. If [t1] has the value [f] and [t2] has the value
    [a], then the value of the returned [Raw.t] will be [f a]. In other words
    this is application of function-valued [Raw.t]s.

    The [?how] optional parameter detemrines how the callbacks for each [Raw.t]
    should be executed. *)
val ap
  :  ?how:[`Sequential | `Parallel]
  -> ('r, 'a -> 'b) Raw.t
  -> ('r, 'a) Raw.t
  -> ('r, 'b) Raw.t


(** [neg p] returns a [Pred.t] that negates all the [pred]s that [p] produces. *)
val neg  : Pred.t -> Pred.t

(** [conj p1 p2] returns a [Pred.t] that conjoins together all the [pred]s that
    [p1] and [p2] produce. *)
val conj : Pred.t -> Pred.t -> Pred.t

(** [conj p1 p2] returns a [Pred.t] that disjoins together all the [pred]s that
    [p1] and [p2] produce. *)
val disj : Pred.t -> Pred.t -> Pred.t


(** [union ?how app1 app2] returns the union of [app1] and [app2].

    The returned app listens on the union of [app1] and [app2]'s [PipeSet.t]s,
    distributes events across the two apps, unions reactive updates to policies,
    and concatenates the list of [(switchId * pktOut)]s that they produce.

    If the app produce side effects, you may want to control the order of their
    execution using the optional [how] argument to sequence them from left to
    right, or to have them run concurrently.
    *)
val union : ?how:[ `Parallel | `Sequential ] -> Policy.t -> Policy.t -> Policy.t

exception Sequence_error of PipeSet.t * PipeSet.t

(** [seq app1 app2] returns the sequence of [app1] and [app2].

    The returned app listens on the disjoint union of [app1] and [app2]'s
    [PipeSet.t]s. If the two [PipeSet.t]s are not disjoint, then this function
    will raise a [Sequence_error]. If they are disjoint, then the returned app
    will distribute events across the two apps, sequence reactive updates to
    policies, and concatenates the list of [packet_outs] that they produce.  *)
val seq : Policy.t -> Policy.t -> Policy.t

(** [guard pred app] returns an app that is equivalent to [app] except it will
    drop packets that do not satisfy [pred]. *)
val guard  : pred   -> Policy.t -> Policy.t
val guard' : Pred.t -> Policy.t -> Policy.t

(** Lift a predicate to the [app] type. [filter p] returns an app that filters
    packets according to the predicate app. *)
val filter  : pred   -> Policy.t
val filter' : Pred.t -> Policy.t

(** [slice pred app1 app2] returns an application where packets that
    satisfy [pred] will be handled by [app1] and packets that do not satisfy
    [pred] will be handled by [app2].

    The returned application will enforce the pipes that [app1] and [app2]
    listen to, so if a packet matches [pred] but is at a pipe that [app1] is not
    listening on, the packet will be dropped. *)
val slice  : pred   -> Policy.t -> Policy.t -> Policy.t
val slice' : Pred.t -> Policy.t -> Policy.t -> Policy.t
