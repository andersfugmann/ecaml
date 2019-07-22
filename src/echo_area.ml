open! Core_kernel
open! Async_kernel
open! Import0
module Current_buffer = Current_buffer0

let inhibit_message = Var.Wrap.("inhibit-message" <: bool)

let inhibit_messages sync_or_async f =
  Current_buffer.set_value_temporarily sync_or_async inhibit_message true ~f
;;

let maybe_echo ~echo f =
  if Option.value echo ~default:true then f () else inhibit_messages Sync f
;;

let message ?echo s = maybe_echo ~echo (fun () -> Value.message s)
let messagef ?echo fmt = ksprintf (message ?echo) fmt
let message_s ?echo s = maybe_echo ~echo (fun () -> Value.message_s s)

let wrap_message ?echo message ~f =
  let message = concat [ message; " ... " ] in
  message_s ?echo [%sexp (message : string)];
  match%map Monitor.try_with f with
  | Ok x ->
    message_s ?echo [%sexp (concat [ message; "done" ] : string)];
    x
  | Error exn ->
    message_s ?echo [%sexp (concat [ message; "raised" ] : string)];
    raise exn
;;
