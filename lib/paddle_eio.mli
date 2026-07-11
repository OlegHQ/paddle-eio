(** Focused Paddle Billing REST and webhook client for OCaml 5/Eio. *)

type environment = Sandbox | Live
type price_item = { price_id : string; quantity : int }

type transaction = {
  id : string;
  checkout_url : string option;
  customer_id : string option;
}

type portal_session = { overview_url : string }

type api_error = {
  status : int;
  code : string option;
  detail : string option;
  request_id : string option;
  retry_after : string option;
  raw_body : string;
}

type decode_error = { operation : string; detail : string }

type error =
  | Not_configured
  | Invalid_request of string
  | Configuration of string
  | Timeout
  | Transport of string
  | Api of api_error
  | Decode of decode_error

type t

val disabled : unit -> t

val create :
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.Mono.t ->
  environment:environment ->
  api_key:string ->
  unit ->
  (t, error) result
(** [create] builds one reusable HTTPS client with system-CA verification. Every
    operation has a ten-second monotonic timeout. *)

val configured : t -> bool
val environment : t -> environment option
val error_to_string : error -> string

val create_transaction :
  t ->
  sw:Eio.Switch.t ->
  items:price_item list ->
  ?customer_id:string ->
  ?checkout_url:string ->
  ?custom_data:Yojson.Safe.t ->
  unit ->
  (transaction, error) result
(** Creates one automatically-collected transaction. This function makes one
    HTTP request and never retries the mutation. *)

val create_customer_portal_session :
  t -> sw:Eio.Switch.t -> customer_id:string -> (portal_session, error) result
(** Creates a temporary portal session and returns only its overview URL. *)

module Webhook : sig
  type verification_error =
    | Invalid_secret
    | Invalid_tolerance of int
    | Malformed_signature of string
    | Timestamp_outside_tolerance of {
        timestamp : int64;
        now : int64;
        tolerance_seconds : int;
      }
    | Signature_mismatch

  type event = {
    event_id : string;
    event_type : string;
    occurred_at : string;
    notification_id : string;
    data : Yojson.Safe.t;
  }

  val verify :
    ?tolerance_seconds:int ->
    now:int64 ->
    secret:string ->
    signature_header:string ->
    raw_body:string ->
    unit ->
    (unit, verification_error) result
  (** Verifies [Paddle-Signature] over the byte-for-byte raw request body. The
      default timestamp tolerance is five seconds. All [h1] signatures in the
      header are considered, which supports secret rotation. *)

  val decode : raw_body:string -> (event, error) result
  val verification_error_to_string : verification_error -> string
end

module For_testing : sig
  type request = {
    meth : [ `POST ];
    uri : Uri.t;
    headers : (string * string) list;
    body : string;
  }

  type response = {
    status : int;
    headers : (string * string) list;
    body : string;
  }

  type transport_error = [ `Timeout | `Transport of string ]

  val configured :
    environment:environment ->
    api_key:string ->
    (sw:Eio.Switch.t -> request -> (response, transport_error) result) ->
    t
end
