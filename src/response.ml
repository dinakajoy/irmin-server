open Lwt.Syntax

module Header = struct
  type t = { status : int }

  let v ~status = { status } [@@inline]
end

module Write = struct
  let header t Header.{ status; _ } =
    Logs.debug (fun l -> l "Writing response header: status=%d" status);
    let+ x = Lwt_io.LE.write_int t status in
    x
end

module Read = struct
  let header t =
    let+ status = Lwt_io.LE.read_int t in
    Logs.debug (fun l -> l "Read response header: status=%d" status);
    Header.{ status }
    [@@inline]

  let is_error Header.{ status; _ } = status < 0 [@@inline]

  let get_error t header =
    if is_error header then (
      let* x = Message.read t Irmin.Type.string in
      let x = Result.value ~default:"Unknown error" x in
      Logs.debug (fun l -> l "Error response message: %s" x);
      Lwt.return_some x)
    else Lwt.return_none
end
