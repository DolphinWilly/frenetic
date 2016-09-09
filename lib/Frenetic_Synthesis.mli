open Core.Std
open Frenetic_NetKAT
open Frenetic_OpenFlow
open Frenetic_Fabric

type approach =
  | Graphical
  | Synthesis

type heuristic =
  | Random of int * int
  | MaxSpread
  | MinSpread

type topology = {
  topo : policy
; preds : (place, place) Hashtbl.t
; succs : (place, place) Hashtbl.t }

module type MAPPING = sig
  val decide : topology -> stream -> stream -> bool
  val generate : topology -> (stream * stream list) list -> (policy * policy)
end

module Make(M:MAPPING) : sig
  val synthesize : ?approach:approach -> ?heuristic:heuristic ->
    policy -> policy -> policy -> policy
end

module Optical : MAPPING

