(** Side-by-side diffing of files or buffers.

    [(Info-goto-node "(ediff) Introduction")] *)

open! Core
open! Import

(** [(describe-function 'ediff-buffers)] *)
val buffers : a:Buffer.t -> b:Buffer.t -> startup_hooks:(unit -> unit) list -> unit

(** [(describe-variable 'ediff-cleanup-hook)]
    [(Info-goto-node "(ediff) Hooks")] *)
val cleanup_hook : Hook.normal Hook.t
