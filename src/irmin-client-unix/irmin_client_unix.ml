open Lwt.Syntax
open Irmin_server_internal
module Error = Error
module IO = IO

module Info (I : Irmin.Info.S) = struct
  include I

  let init = v

  let v ?author fmt =
    Fmt.kstr
      (fun message () ->
        let date = Int64.of_float (Unix.gettimeofday ()) in
        init ?author ~message date)
      fmt
end

module type S = sig
  include Irmin_client.S

  val connect :
    ?ctx:IO.ctx -> ?batch_size:int -> ?tls:bool -> uri:Uri.t -> unit -> t Lwt.t
end

let normalize_uri ?hostname uri =
  let scheme = Uri.scheme uri |> Option.value ~default:"tcp" in
  let addr = Uri.host_with_default ~default:"127.0.0.1" uri in
  let scheme_lower = String.lowercase_ascii scheme in
  let uri =
    if scheme_lower = "tcp" || scheme_lower = "ws" || scheme_lower = "wss" then
      let ip = Unix.gethostbyname addr in
      let port = Uri.port uri |> Option.value ~default:9181 in
      let ip = ip.h_addr_list.(0) |> Unix.string_of_inet_addr in
      Uri.make ~scheme:scheme_lower ~port ~host:ip ()
    else uri
  in
  (uri, Option.value ~default:addr hostname)

module Make_ext
    (Codec : Irmin_server_internal.Conn.Codec.S)
    (Store : Irmin.Generic_key.S) =
struct
  include Irmin_client.Make_ext (IO) (Codec) (Store)

  let conf ?(ctx = Lazy.force IO.default_ctx) ?(batch_size = 32) ?(tls = false)
      ~uri () =
    let uri, hostname = normalize_uri uri in
    { ctx; tls; hostname; batch_size; uri }

  let connect ?ctx ?batch_size ?tls ~uri () =
    let client = conf ?ctx ?batch_size ?tls ~uri () in
    let+ t = connect client in
    let () = Lwt_gc.finalise_or_exit (fun t -> close t) t in
    t
end

module Make (Store : Irmin.Generic_key.S) = Make_ext (Conn.Codec.Bin) (Store)

module Make_json (Store : Irmin.Generic_key.S) =
  Make_ext (Conn.Codec.Json) (Store)

module Store = struct
  let config ?batch_size ?tls ?hostname uri =
    let uri, addr = normalize_uri ?hostname uri in
    Irmin_client.Store.config ?batch_size ?tls
      ~hostname:(Option.value ~default:addr hostname)
      uri

  module Make (Store : Irmin.Generic_key.S) =
    Irmin_client.Store.Make (IO) (Conn.Codec.Bin) (Store)

  module Make_json (Store : Irmin.Generic_key.S) =
    Irmin_client.Store.Make (IO) (Conn.Codec.Json) (Store)
end
