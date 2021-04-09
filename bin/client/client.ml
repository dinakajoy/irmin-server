open Cmdliner
open Lwt.Syntax
open Lwt.Infix
open Irmin_server

let with_timer f =
  let t0 = Sys.time () in
  let+ a = f () in
  let t1 = Sys.time () -. t0 in
  (t1, a)

type client = S : ((module Client.S with type t = 'a) * 'a Lwt.t) -> client

let init ~uri ~tls ~level (module Rpc : S) : client =
  let () = Logs.set_level (Some level) in
  let () = Logs.set_reporter (Logs_fmt.reporter ()) in
  let (x : Rpc.Client.t Lwt.t) = Rpc.Client.connect ~tls ~uri () in
  S ((module Rpc.Client : Client.S with type t = Rpc.Client.t), x)

let run x time =
  let x =
    if time then (
      let+ n, x = with_timer (fun () -> x) in
      Logs.app (fun l -> l "Time: %fs" n);
      x)
    else x
  in
  Lwt_main.run x

let ping (S ((module Client), client)) =
  run
    ( client >>= fun client ->
      let+ result = Client.ping client in
      let () = Error.unwrap "ping" result in
      Logs.app (fun l -> l "OK") )

let find (S ((module Client), client)) key =
  run
    ( client >>= fun client ->
      let key = Irmin.Type.of_string Client.Key.t key |> Error.unwrap "key" in
      let* result = Client.Store.find client key >|= Error.unwrap "find" in
      match result with
      | Some data ->
          let* () =
            Lwt_io.printl (Irmin.Type.to_string Client.Contents.t data)
          in
          Lwt_io.flush Lwt_io.stdout
      | None ->
          Logs.err (fun l -> l "Not found: %a" (Irmin.Type.pp Client.Key.t) key);
          Lwt.return_unit )

let mem (S ((module Client), client)) key =
  run
    ( client >>= fun client ->
      let key = Irmin.Type.of_string Client.Key.t key |> Error.unwrap "key" in
      let* result = Client.Store.mem client key >|= Error.unwrap "mem" in
      Lwt_io.printl (if result then "true" else "false") )

let mem_tree (S ((module Client), client)) key =
  run
    ( client >>= fun client ->
      let key = Irmin.Type.of_string Client.Key.t key |> Error.unwrap "key" in
      let* result =
        Client.Store.mem_tree client key >|= Error.unwrap "mem_tree"
      in
      Lwt_io.printl (if result then "true" else "false") )

let set (S ((module Client), client)) key author message contents =
  run
    ( client >>= fun client ->
      let key = Irmin.Type.of_string Client.Key.t key |> Error.unwrap "key" in
      let contents =
        Irmin.Type.of_string Client.Contents.t contents
        |> Error.unwrap "contents"
      in
      let info = Irmin_unix.info ~author "%s" message in
      let+ () =
        Client.Store.set client key ~info contents >|= Error.unwrap "set"
      in
      Logs.app (fun l -> l "OK") )

let remove (S ((module Client), client)) key author message =
  run
    ( client >>= fun client ->
      let key = Irmin.Type.of_string Client.Key.t key |> Error.unwrap "key" in
      let info = Irmin_unix.info ~author "%s" message in
      let+ () =
        Client.Store.remove client key ~info >|= Error.unwrap "remove"
      in
      Logs.app (fun l -> l "OK") )

let export (S ((module Client), client)) filename =
  run
    ( client >>= fun client ->
      let* slice = Client.export client >|= Error.unwrap "export" in
      let s = Irmin.Type.(unstage (to_bin_string Client.slice_t) slice) in
      Lwt_io.chars_to_file filename (Lwt_stream.of_string s) )

let import (S ((module Client), client)) filename =
  run
    ( client >>= fun client ->
      let* slice = Lwt_io.chars_of_file filename |> Lwt_stream.to_string in
      let slice =
        Irmin.Type.(unstage (of_bin_string Client.slice_t) slice)
        |> Error.unwrap "slice"
      in
      let+ () = Client.import client slice >|= Error.unwrap "import" in
      Logs.app (fun l -> l "OK") )

let level =
  let doc = Arg.info ~doc:"Log level" [ "log-level" ] in
  Arg.(value @@ opt string "error" doc)

let pr_str = Format.pp_print_string

let key index =
  let doc = Arg.info ~docv:"PATH" ~doc:"Key to lookup or modify" [] in
  Arg.(required & pos index (some string) None & doc)

let filename index =
  let doc = Arg.info ~docv:"PATH" ~doc:"Filename" [] in
  Arg.(required & pos index (some string) None & doc)

let author =
  let doc = Arg.info ~docv:"NAME" ~doc:"Commit author name" [ "author" ] in
  Arg.(value & opt string "irmin-client" & doc)

let message =
  let doc = Arg.info ~docv:"MESSAGE" ~doc:"Commit message" [ "message" ] in
  Arg.(value & opt string "" & doc)

let value index =
  let doc = Arg.info ~docv:"DATA" ~doc:"Value" [] in
  Arg.(required & pos index (some string) None & doc)

let tls =
  let doc = Arg.info ~doc:"Enable TLS" [ "tls" ] in
  Arg.(value @@ flag doc)

let time =
  let doc = Arg.info ~doc:"Enable timing" [ "time" ] in
  Arg.(value @@ flag doc)

let config =
  let create uri tls level contents hash =
    let (module Hash : Irmin.Hash.S) =
      Option.value ~default:Cli.default_hash hash
    in
    let contents =
      Irmin_unix.Resolver.Contents.find
        (Option.value ~default:Cli.default_contents contents)
    in
    let (module Contents : Irmin.Contents.S) = contents in
    let module Rpc =
      Irmin_server.Make (Irmin_server.Conf.Default) (Irmin.Metadata.None)
        (Contents)
        (Irmin.Branch.String)
        (Hash)
    in
    init ~uri ~tls ~level (module Rpc)
  in
  Term.(const create $ Cli.uri $ tls $ Cli.log_level $ Cli.contents $ Cli.hash)

let help =
  let help () =
    Printf.printf "See output of `%s --help` for usage\n" Sys.argv.(0)
  in
  (Term.(const help $ Term.pure ()), Term.info "irmin-client")

let () =
  Term.exit
  @@ Term.eval_choice help
       [
         ( Term.(const ping $ config $ time),
           Term.info ~doc:"Ping the server" "ping" );
         ( Term.(const find $ config $ key 0 $ time),
           Term.info ~doc:"Get the key associated with a value" "get" );
         ( Term.(const find $ config $ key 0 $ time),
           Term.info ~doc:"Alias for 'get' command" "find" );
         Term.
           ( const set $ config $ key 0 $ author $ message $ value 1 $ time,
             Term.info ~doc:"Set key/value" "set" );
         Term.
           ( const remove $ config $ key 0 $ author $ message $ time,
             Term.info ~doc:"Remove value associated with the given key"
               "remove" );
         ( Term.(const import $ config $ filename 0 $ time),
           Term.info ~doc:"Import from dump file" "import" );
         ( Term.(const export $ config $ filename 0 $ time),
           Term.info ~doc:"Export to dump file" "export" );
         ( Term.(const mem $ config $ key 0 $ time),
           Term.info ~doc:"Check if key is set" "mem" );
         ( Term.(const mem_tree $ config $ key 0 $ time),
           Term.info ~doc:"Check if key is set to a tree value" "mem_tree" );
       ]
