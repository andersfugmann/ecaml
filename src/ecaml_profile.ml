open! Core_kernel
open! Async_kernel
open! Import

include (val Major_mode.define_derived_mode
               ("ecaml-profile-mode" |> Symbol.intern)
               [%here]
               ~docstring:
                 {|
The major mode for the *profile* buffer, which holds a log of Ecaml profile output.
|}
               ~define_keys:
                 [ "SPC", "scroll-up" |> Symbol.intern
                 ; "DEL", "scroll-down" |> Symbol.intern
                 ; "<", "beginning-of-buffer" |> Symbol.intern
                 ; ">", "end-of-buffer" |> Symbol.intern
                 ; "q", "quit-window" |> Symbol.intern
                 ]
               ~mode_line:"ecaml-profile"
               ~initialize:
                 ( Returns Value.Type.unit
                 , fun () -> Minor_mode.enable Minor_mode.read_only )
               ())

let () = Keymap.suppress_keymap (Major_mode.keymap major_mode) ~suppress_digits:true

module Start_location = struct
  include Profile.Start_location

  let to_string t =
    [%sexp (t : t)]
    |> Sexp.to_string
    |> String.lowercase
    |> String.tr ~target:'_' ~replacement:'-'
  ;;

  let to_symbol t = t |> to_string |> Symbol.intern

  let docstring = function
    | End_of_profile_first_line -> "put the time at the end of the profile's first line"
    | Line_preceding_profile -> "put the time on its own line, before the profile"
  ;;
end

module Profile_buffer : sig
  val profile_buffer : unit -> Buffer.t option
end = struct
  type t =
    | Absent
    | Initializing
    | This of Buffer.t
  [@@deriving sexp_of]

  let profile_buffer : t ref = ref Absent

  let initialize_profile_buffer () =
    profile_buffer := Initializing;
    let buffer = Buffer.create ~name:"*profile*" in
    Background.don't_wait_for [%here] (fun () ->
      let%bind () = Major_mode.change_to major_mode ~in_:buffer in
      Buffer_local.set Current_buffer.truncate_lines true buffer;
      profile_buffer := This buffer;
      return ())
  ;;

  let profile_buffer () =
    match !profile_buffer with
    | Initializing -> None
    | Absent ->
      initialize_profile_buffer ();
      None
    | This buffer ->
      if Buffer.is_live buffer
      then Some buffer
      else (
        initialize_profile_buffer ();
        None)
  ;;
end

let tag_function =
  Defvar.defvar
    ("ecaml-profile-tag-frame-function" |> Symbol.intern)
    [%here]
    ~docstring:
      {|
If non-nil, ecaml-profile calls this function with 0 arguments when creating a profile
frame.  The output is added to the profile frame. |}
    ~type_:(Value.Type.nil_or Function.type_)
    ~initial_value:None
    ()
;;

let initialize () =
  let (_ : _ Customization.t) =
    Customization.defcustom_enum
      ("ecaml-profile-start-location" |> Symbol.intern)
      [%here]
      (module Start_location)
      ~docstring:{| Where to render a profile's start time: |}
      ~group:Customization.Group.ecaml
      ~standard_value:End_of_profile_first_line
      ~on_set:(fun start_location -> Profile.start_location := start_location)
      ()
  in
  let should_profile =
    Customization.defcustom
      ("ecaml-profile-should-profile" |> Symbol.intern)
      [%here]
      ~docstring:{| Whether profiling is enabled. |}
      ~group:Customization.Group.ecaml
      ~type_:Value.Type.bool
      ~customization_type:Boolean
      ~standard_value:false
      ~on_set:(fun bool -> Profile.should_profile := bool)
      ()
  in
  let _hide_if_less_than =
    Customization.defcustom
      ("ecaml-profile-hide-frame-if-less-than" |> Symbol.intern)
      [%here]
      ~docstring:{| Hide profile frames shorter than this duration. |}
      ~group:Customization.Group.ecaml
      ~type_:Value.Type.string
      ~customization_type:String
      ~standard_value:"1ms"
      ~on_set:(fun string ->
        Profile.hide_if_less_than := string |> Time_ns.Span.of_string)
      ()
  in
  let _hide_top_level_if_less_than =
    Customization.defcustom
      ("ecaml-profile-hide-top-level-if-less-than" |> Symbol.intern)
      [%here]
      ~docstring:{| Hide profiles shorter than this duration. |}
      ~group:Customization.Group.ecaml
      ~type_:Value.Type.string
      ~customization_type:String
      ~standard_value:"100ms"
      ~on_set:(fun string ->
        Profile.hide_top_level_if_less_than := string |> Time_ns.Span.of_string)
      ()
  in
  if System.is_interactive ()
  then
    (* We start initializing the profile buffer, so that it exists when we need it. *)
    ignore (Profile_buffer.profile_buffer () : Buffer.t option);
  (Profile.sexp_of_time_ns
   := fun time_ns ->
     match [%sexp (time_ns : Core.Time_ns.t)] with
     | List [ date; ofday ] -> List [ ofday; date ]
     | sexp -> sexp);
  (Profile.output_profile
   := fun string ->
     (* If [output_profile] raises, then Nested_profile use [eprint_s] to print the
        exception, which doesn't work well in Emacs.  So we do our own exception
        handling. *)
     try
       match Profile_buffer.profile_buffer () with
       | None -> ()
       | Some buffer ->
         Current_buffer.set_temporarily Sync buffer ~f:(fun () ->
           Current_buffer.inhibit_read_only Sync (fun () ->
             Current_buffer.append_to string))
     with
     | exn -> message_s [%message "unable to output profile" ~_:(exn : exn)]);
  Profile.tag_frames_with
  := Some
       (fun () ->
          match Current_buffer.value_exn tag_function with
          | None -> None
          | Some f ->
            Some (f |> Function.to_value |> Value.funcall0 |> [%sexp_of: Value.t]));
  Hook.add
    Elisp_gc.post_gc_hook
    (Hook.Function.create
       ("ecaml-profile-record-gc" |> Symbol.intern)
       [%here]
       (* We don't profile this hook so that the gc frame is attributed to the enclosing
          frame that actually experienced the gc. *)
       ~should_profile:false
       ~hook_type:Normal
       (Returns Value.Type.unit)
       (let last_gc_elapsed = ref (Elisp_gc.gc_elapsed ()) in
        fun () ->
          if !Profile.should_profile
          then (
            let module Clock = Profile.Private.Clock in
            let clock = !Profile.Private.clock in
            let gc_elapsed = Elisp_gc.gc_elapsed () in
            let gc_took =
              if not am_running_test
              then Time_ns.Span.( - ) gc_elapsed !last_gc_elapsed
              else (
                (* A fixed time, to make test output deterministic. *)
                let took = 10 |> Time_ns.Span.of_int_ms in
                Clock.advance clock ~by:took;
                took)
            in
            last_gc_elapsed := gc_elapsed;
            let stop = Clock.now clock in
            let gcs_done =
              Ref.set_temporarily Profile.should_profile false ~f:Elisp_gc.gcs_done
            in
            Profile.Private.record_frame
              ~start:(Time_ns.sub stop gc_took)
              ~stop
              ~message:(lazy [%message "gc" (gcs_done : int opaque_in_test)]))));
  let set_should_profile bool =
    Customization.set_value should_profile bool;
    let verb = if !Profile.should_profile then "enabled" else "disabled" in
    message (String.concat [ "You just "; verb; " ecaml profiling" ])
  in
  Defun.defun_nullary_nil
    ("ecaml-toggle-profiling" |> Symbol.intern)
    [%here]
    ~docstring:
      "Enable or disable logging of elisp->ecaml calls and durations in the `*profile*' \
       buffer."
    ~interactive:No_arg
    (fun () -> set_should_profile (not !Profile.should_profile));
  Defun.defun_nullary_nil
    ("ecaml-enable-profiling" |> Symbol.intern)
    [%here]
    ~docstring:
      "Enable logging of elisp->ecaml calls and durations in the `*profile*' buffer."
    ~interactive:No_arg
    (fun () -> set_should_profile true);
  Defun.defun_nullary_nil
    ("ecaml-disable-profiling" |> Symbol.intern)
    [%here]
    ~docstring:
      "Disable logging of elisp->ecaml calls and durations in the `*profile*' buffer."
    ~interactive:No_arg
    (fun () -> set_should_profile false);
  Defun.defun
    ("ecaml-profile-inner" |> Symbol.intern)
    [%here]
    ~docstring:"profile an elisp function using Nested_profile"
    ~should_profile:false
    (Returns Value.Type.value)
    (let%map_open.Defun () = return ()
     and description = required "description" string
     and f = required "function" value in
     profile Sync (lazy [%message description]) (fun () -> Value.funcall0 f));
  Defun.defun
    ("ecaml-profile-elisp-function" |> Symbol.intern)
    [%here]
    ~docstring:"Wrap the given function in a call to [Nested_profile.profile]."
    ~interactive:
      (let history =
         Minibuffer.History.find_or_create
           ("ecaml-profile-elisp-function-history" |> Symbol.intern)
           [%here]
       in
       Args
         (fun () ->
            let%bind function_name =
              Completing.read_function_name ~prompt:"Profile function: " ~history
            in
            return [ function_name |> Value.intern ]))
    (Returns Value.Type.unit)
    (let%map_open.Defun () = return ()
     and fn = required "function" Symbol.t in
     Advice.around_values
       ("ecaml-profile-wrapper-for-" ^ Symbol.name fn |> Symbol.intern)
       [%here]
       ~for_function:fn
       ~should_profile:false
       (fun f args ->
          profile
            Sync
            (lazy [%sexp ((fn |> Symbol.to_value) :: args : Value.t list)])
            (fun () -> f args));
     message (concat [ "You just added Ecaml profiling of ["; fn |> Symbol.name; "]" ]))
;;

module Private = struct
  let tag_function = tag_function
end
