open Core.Std
open Async.Std
open OpenFlow0x01
open NetKAT_Types
open Async_NetKAT_Updates
module Controller = Async_OpenFlow0x01_Controller
module Log = Async_OpenFlow_Log

let printf = Log.printf

let bytes_to_headers
  (port_id : SDN_Types.portId)
  (bytes : Cstruct.t)
  : NetKAT_Semantics.HeadersValues.t =
  let open NetKAT_Semantics.HeadersValues in
  let open Frenetic_Packet in
  let pkt = Frenetic_Packet.parse bytes in
  { location = NetKAT_Types.Physical port_id
  ; ethSrc = pkt.dlSrc
  ; ethDst = pkt.dlDst
  ; vlan = (match pkt.dlVlan with Some (v) -> v | None -> 0)
  ; vlanPcp = pkt.dlVlanPcp
  ; ethType = dlTyp pkt
  ; ipProto = (try nwProto pkt with Invalid_argument(_) -> 0)
  ; ipSrc = (try nwSrc pkt with Invalid_argument(_) -> 0l)
  ; ipDst = (try nwDst pkt with Invalid_argument(_) -> 0l)
  ; tcpSrcPort = (try tpSrc pkt with Invalid_argument(_) -> 0)
  ; tcpDstPort = (try tpDst pkt with Invalid_argument(_) -> 0)
  }

let packet_sync_headers (pkt:NetKAT_Semantics.packet) : NetKAT_Semantics.packet * bool =
  let open NetKAT_Semantics in
  let open NetKAT_Types in
  let change = ref false in
  let g p q acc f =
    let v = Field.get f pkt.NetKAT_Semantics.headers in
    if p v acc then
      acc
    else begin
      change := true;
      q acc v
    end in
  let fail field = (fun _ -> failwith "unsupported modification") in
  let packet = Frenetic_Packet.parse (SDN_Types.payload_bytes pkt.payload) in
  let packet' = HeadersValues.Fields.fold
    ~init:packet
    ~location:(fun acc _ -> acc)
    ~ethSrc:(g (fun v p -> v = p.Frenetic_Packet.dlSrc) Frenetic_Packet.setDlSrc)
    ~ethDst:(g (fun v p -> v = p.Frenetic_Packet.dlDst) Frenetic_Packet.setDlDst)
    (* XXX(seliopou): Fix impls of: vlan, vlanPcp *)
    ~vlan:(g (fun _ _ -> true) (fail "vlan"))
    ~vlanPcp:(g (fun _ _ -> true) (fail "vlanPcp"))
    ~ipSrc:(g
      (fun v p -> try v = Frenetic_Packet.nwSrc p with Invalid_argument(_) -> true)
      (fun acc nw -> Frenetic_Packet.setNwSrc acc nw))
    ~ipDst:(g
      (fun v p -> try v = Frenetic_Packet.nwDst p with Invalid_argument(_) -> true)
      (fun acc nw -> Frenetic_Packet.setNwDst acc nw))
    ~tcpSrcPort:(g
      (fun v p -> try v= Frenetic_Packet.tpSrc p with Invalid_argument(_) -> true)
      Frenetic_Packet.setTpSrc)
    ~tcpDstPort:(g
      (fun v p -> try v = Frenetic_Packet.tpDst p with Invalid_argument(_) -> true)
      Frenetic_Packet.setTpDst)
    (* XXX(seliopou): currently does not support: *)
    ~ethType:(g (fun _ _ -> true) (fail "ethType"))
    ~ipProto:(g (fun _ _ -> true) (fail "ipProto")) in
  ({ pkt with payload = match pkt.payload with
    | SDN_Types.NotBuffered(_) -> SDN_Types.NotBuffered(Frenetic_Packet.marshal packet')
    | SDN_Types.Buffered(n, _) -> SDN_Types.Buffered(n, Frenetic_Packet.marshal packet')
  }, !change)

let of_to_netkat_event fdd (evt : Controller.event) : NetKAT_Types.event list =
  match evt with
  (* TODO(arjun): include switch features in SwitchUp *)
  | `Connect (sw_id, feats) ->
     (* TODO(joe): Did we just want the port number? Or do we want the entire description? *)
     let ps =
       List.filter
	 (List.map feats.ports ~f:(fun desc -> Int32.of_int_exn desc.port_no))
	 ~f:(fun p -> not (p = 0xFFFEl))
     in [SwitchUp(sw_id, ps)]
  | `Disconnect (sw_id) -> [SwitchDown sw_id]
  | `Message (sw_id, hdr, PortStatusMsg ps) ->
    begin match ps.reason, ps.desc.config.down with
      | Add, _
      | Modify, true ->
        let pt_id = Int32.of_int_exn (ps.desc.port_no) in
        [PortUp (sw_id, pt_id)]
      | Delete, _
      | Modify, false ->
        let pt_id = Int32.of_int_exn (ps.desc.port_no) in
        [PortDown (sw_id, pt_id)]
    end
  | `Message (sw_id,hdr,PacketInMsg pi) when pi.port <= 0xff00 ->
      let open OpenFlow0x01 in
      let port_id = Int32.of_int_exn pi.port in
      let payload : SDN_Types.payload = 
        match pi.input_payload with 
        | Buffered (id,bs) -> Buffered (id,bs) 
        | NotBuffered bs -> NotBuffered bs in 
      (* Eval the packet to get the list of packets that should go to
       * pipes, and the list of packets that can be forwarded to physical
       * locations.
       * *)
      let open NetKAT_Semantics in
      let pkt0 = {
        switch = sw_id;
        headers = bytes_to_headers port_id (SDN_Types.payload_bytes payload);
        payload = payload;
      } in
      let pis, qus, phys = NetKAT_LocalCompiler.eval_pipes pkt0 fdd in
      List.map pis ~f:(fun (pipe, pkt2) ->
        let pkt3, changed = packet_sync_headers pkt2 in
        let payload = match payload, changed with
            | SDN_Types.NotBuffered(_), _
            | _                       , true ->
              SDN_Types.NotBuffered(SDN_Types.payload_bytes pkt3.payload)
            | SDN_Types.Buffered(buf_id, bytes), false ->
              SDN_Types.Buffered(buf_id, bytes)
        in
        PacketIn(pipe, sw_id, port_id, payload, pi.total_len))
  | _ -> []

module type CONTROLLER = sig
  val update_policy : policy -> unit Deferred.t
  val send_packet_out : switchId -> SDN_Types.pktOut -> unit Deferred.t
  val event : unit -> event Deferred.t
  val query : string -> (Int64.t * Int64.t) Deferred.t
  val port_stats : switchId -> portId -> OpenFlow0x01.portStats Deferred.t
  val is_query : string -> bool
  val start : unit -> unit
  val current_switches : unit -> (switchId * portId list) list
end

module Make : CONTROLLER = struct
  let fdd = ref (NetKAT_LocalCompiler.compile drop)
  let stats : (string, Int64.t * Int64.t) Hashtbl.Poly.t = Hashtbl.Poly.create ()
  let (pol_reader, pol_writer) = Pipe.create ()
  let (pktout_reader, pktout_writer) = Pipe.create ()
  let (event_reader, event_writer) =  Pipe.create ()

  (* TODO(arjun,jnfoster): Result should be determined with network is
     updated. *)
  let update_policy (pol : policy) : unit Deferred.t =
    Pipe.write pol_writer pol

  let send_packet_out (sw_id : switchId)
    (pkt_out : SDN_Types.pktOut) : unit Deferred.t =
    Log.printf ~level:`Debug "SENDING PKT_OUT";
    Pipe.write pktout_writer (sw_id, pkt_out)

  let event () : event Deferred.t =
    Pipe.read event_reader
    >>= function
    | `Eof -> assert false
    | `Ok evt -> Deferred.return evt

  let current_switches () =
    let features = 
      List.filter_map ~f:Controller.get_switch_features
        (Controller.get_switches ()) in
    let get_switch_and_ports (feats : OpenFlow0x01.SwitchFeatures.t) =
      (feats.switch_id,
       List.filter_map ~f:(fun port_desc ->
         if port_desc.port_no = 0xFFFE then
           None
         else
           Some (Int32.of_int_exn port_desc.port_no))
         feats.ports) in
    List.map ~f:get_switch_and_ports features

  let get_table (sw_id : switchId) : (SDN_Types.flow * string list) list =
    NetKAT_LocalCompiler.to_table' sw_id !fdd

  let raw_query (name : string) : (Int64.t * Int64.t) Deferred.t =
    Deferred.List.map ~how:`Parallel
      (Controller.get_switches ()) ~f:(fun sw_id ->
        let pats = List.filter_map (get_table sw_id) ~f:(fun (flow, names) ->
          if List.mem names name then
            Some flow.pattern
          else
            None) in
        Deferred.List.map ~how:`Parallel pats
          ~f:(fun pat ->
            let pat0x01 = SDN_Types.To0x01.from_pattern pat in
            let req = 
              IndividualRequest
                { sr_of_match = pat0x01; sr_table_id = 0xff; sr_out_port = None } in 
            match Controller.send_txn sw_id (M.StatsRequestMsg req) with 
              | `Eof -> return (0L,0L)
              | `Ok l -> begin
                l >>| function
                  | [M.StatsReplyMsg (IndividualFlowRep stats)] -> 
                    (List.sum (module Int64) stats ~f:(fun stat -> stat.packet_count),
                     List.sum (module Int64) stats ~f:(fun stat -> stat.byte_count))
                  | _ -> (0L, 0L)
              end))
    >>| fun stats ->
      List.fold (List.concat stats) ~init:(0L, 0L)
        ~f:(fun (pkts, bytes) (pkts', bytes') ->
            Int64.(pkts + pkts', bytes + bytes'))

  let query (name : string) : (Int64.t * Int64.t) Deferred.t =
    raw_query name
    >>= fun (pkts, bytes) ->
    let (pkts', bytes') = Hashtbl.Poly.find_exn stats name in
    Deferred.return (Int64.(pkts + pkts', bytes + bytes'))

  let port_stats (sw_id : switchId) (pid : portId) : OpenFlow0x01.portStats Deferred.t =
    let pt = Int32.(to_int_exn pid) in 
    let req = PortRequest (Some (PhysicalPort pt)) in 
    match Controller.send_txn sw_id (M.StatsRequestMsg req) with 
      | `Eof -> assert false
      | `Ok l -> begin
        l >>| function
          | [M.StatsReplyMsg (PortRep ps)] -> ps
          | _ -> assert false
      end

  let is_query (name : string) : bool = Hashtbl.Poly.mem stats name

  let update_all_switches (pol : policy) : unit Deferred.t =
    Log.printf ~level:`Debug "Installing policy\n%s" (NetKAT_Pretty.string_of_policy pol);
    let new_queries = NetKAT_Misc.queries_of_policy pol in
    (* Discard old queries *)
    Hashtbl.Poly.filteri_inplace stats
      ~f:(fun key _ -> List.mem new_queries key);
    (* Queries that have to be saved. *)
    let preserved_queries = Hashtbl.Poly.keys stats in
    (* Initialize new queries to 0 *)
    List.iter new_queries ~f:(fun query ->
      if not (Hashtbl.Poly.mem stats query) then
        Hashtbl.Poly.set stats ~key:query ~data:(0L, 0L));
    (* Update queries that have been preserved. The query function itself
       adds the current value of the counters to the cumulative sum. We
       simply store this in stats. *)
    Deferred.List.iter preserved_queries ~f:(fun qname ->
      query qname
      >>| fun stat ->
      Hashtbl.Poly.set stats qname stat)
    >>= fun () ->
    (* Actually update things *)
    fdd := NetKAT_LocalCompiler.compile pol;
    BestEffortUpdate.implement_policy !fdd

  let handle_event (evt : Controller.event) : unit Deferred.t =
    List.iter (of_to_netkat_event !fdd evt) ~f:(fun netkat_evt ->
      Pipe.write_without_pushback event_writer netkat_evt);
    match evt with
     | `Connect (sw_id, feats) ->
       printf ~level:`Info "switch %Ld connected" sw_id;
       BestEffortUpdate.bring_up_switch sw_id !fdd
     | _ -> Deferred.return ()

  let send_pktout ((sw_id, pktout) : switchId * SDN_Types.pktOut) : unit Deferred.t =
    let pktout0x01 = SDN_Types.To0x01.from_packetOut pktout in
    match Controller.send sw_id 0l (M.PacketOutMsg pktout0x01) with  
      | `Eof -> return ()
      | `Ok -> return ()

  let start () : unit =
    Controller.init 6633;
    don't_wait_for (Pipe.iter pol_reader ~f:update_all_switches);
    don't_wait_for (Pipe.iter (Controller.events) ~f:handle_event);
    don't_wait_for (Pipe.iter pktout_reader ~f:send_pktout)
end

