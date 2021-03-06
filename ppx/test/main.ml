(* let declaration *)
let%nk p = {| drop |}
let%nk q = {| filter true; $p; (port:=2 + port:=pipe("test") ) |}
let%nk_pred egress = {| switch=1 and port=1 |}
let%nk egress' = {| filter $egress |}
let%nk loop = {| let `inport := port in while not $egress do $q + drop |}

(* let expressions *)
let letin =
  let%nk s = {| $p; ($q + $loop) |} in
  let open Frenetic_NetKAT_Optimize in
  mk_seq s s

(* can have open terms *)
let%nk opent = {| `inport := 1 |}

(* can use IP and MAC accresses with meta fields *)
let%nk addresses = {| `aux := 192.168.2.1; filter `aux = 00:0a:95:9d:68:16 |}
(* maximum addresses *)
let%nk ip_and_mac = {| `ip := 255.255.255.0; `mac := ff:ff:ff:ff:ff:ff |}
(* above maximum, but still accepted by parser currently *)
let%nk illegal = {| `ip := 255.255.255.255 |}

(* The declarations below should cause compile-time errors with approproate
   source locations. *)
(* let%nk s = {| filter typo = 1 |} *)
(* let%nk r = {| while not $egress' do $q |} *)
(* let%nk r = {| `inport := port |} *)

let () =
  let open Frenetic_NetKAT_Pretty in
  let open Printf in
  printf "p = %s\n" (string_of_policy p);
  printf "q = %s\n" (string_of_policy q);
  printf "egress = %s\n" (string_of_pred egress);
  printf "egress' = %s\n" (string_of_policy egress');
  printf "loop = %s\n" (string_of_policy loop);
  printf "letin = %s\n" (string_of_policy letin);
  printf "opent = %s\n" (string_of_policy opent);
  printf "addresses = %s\n" (string_of_policy addresses);
  printf "ip_and_mac = %s\n" (string_of_policy ip_and_mac);
  printf "illegal = %s\n" (string_of_policy illegal);
  ()