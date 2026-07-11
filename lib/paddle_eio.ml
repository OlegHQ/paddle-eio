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

type transport =
  sw:Eio.Switch.t -> request -> (response, transport_error) result

type configured_client = {
  environment : environment;
  api_key : string;
  transport : transport;
}

type t = Disabled | Configured of configured_client

type transaction_checkout_json = { url : string option [@default None] }
[@@deriving yojson { strict = false }]

type transaction_json = {
  id : string;
  checkout : transaction_checkout_json option; [@default None]
  customer_id : string option; [@default None]
}
[@@deriving yojson { strict = false }]

type transaction_envelope_json = { data : transaction_json }
[@@deriving yojson { strict = false }]

type portal_general_json = { overview : string }
[@@deriving yojson { strict = false }]

type portal_urls_json = { general : portal_general_json }
[@@deriving yojson { strict = false }]

type portal_session_json = { urls : portal_urls_json }
[@@deriving yojson { strict = false }]

type portal_envelope_json = { data : portal_session_json }
[@@deriving yojson { strict = false }]

type error_payload_json = {
  code : string option; [@default None]
  detail : string option; [@default None]
}
[@@deriving yojson { strict = false }]

type meta_json = { request_id : string option [@default None] }
[@@deriving yojson { strict = false }]

type error_envelope_json = {
  error : error_payload_json;
  meta : meta_json option; [@default None]
}
[@@deriving yojson { strict = false }]

type webhook_event_json = {
  event_id : string;
  event_type : string;
  occurred_at : string;
  notification_id : string;
  data : Yojson.Safe.t;
}
[@@deriving yojson { strict = false }]

let disabled () = Disabled
let configured = function Disabled -> false | Configured _ -> true

let environment = function
  | Disabled -> None
  | Configured client -> Some client.environment

let error_to_string = function
  | Not_configured -> "Paddle is not configured"
  | Invalid_request detail -> "Invalid Paddle request: " ^ detail
  | Configuration detail -> "Paddle client configuration failed: " ^ detail
  | Timeout -> "Paddle request timed out after 10 seconds"
  | Transport detail -> "Paddle transport error: " ^ detail
  | Api { status; code; detail; request_id; retry_after; _ } ->
      let optional label = function
        | None -> ""
        | Some value -> Printf.sprintf " %s=%s" label value
      in
      Printf.sprintf "Paddle API HTTP %d%s%s%s%s" status (optional "code" code)
        (optional "detail" detail)
        (optional "request_id" request_id)
        (optional "retry_after" retry_after)
  | Decode { operation; detail } ->
      Printf.sprintf "Paddle %s response decode failed: %s" operation detail

let api_base = function
  | Sandbox -> "https://sandbox-api.paddle.com"
  | Live -> "https://api.paddle.com"

let read_body body = Eio.Buf_read.(parse_exn take_all) body ~max_size:2_000_000

let tls_config () =
  match Ca_certs.authenticator () with
  | Error (`Msg message) ->
      Error (Configuration ("CA certificates: " ^ message))
  | Ok authenticator -> (
      match Tls.Config.client ~authenticator () with
      | Ok config -> Ok config
      | Error (`Msg message) -> Error (Configuration ("TLS: " ^ message)))

let cohttp_transport ~clock client : transport =
 fun ~sw request ->
  let perform () =
    let headers = Cohttp.Header.of_list request.headers in
    let body = Cohttp_eio.Body.of_string request.body in
    let http_response, response_body =
      Cohttp_eio.Client.post client ~sw ~headers ~body request.uri
    in
    let status =
      Cohttp.Response.status http_response |> Cohttp.Code.code_of_status
    in
    let headers =
      Cohttp.Response.headers http_response |> Cohttp.Header.to_list
    in
    let body = read_body response_body in
    Ok { status; headers; body }
  in
  try
    match
      Eio.Time.Timeout.run (Eio.Time.Timeout.seconds clock 10.0) perform
    with
    | Ok response -> Ok response
    | Error `Timeout -> Error `Timeout
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (`Transport (Printexc.to_string exn))

let create ~net ~clock ~environment ~api_key () =
  if String.trim api_key = "" then
    Error (Configuration "API key must not be empty")
  else
    let ( let* ) = Result.bind in
    let* config = tls_config () in
    let https_connector uri raw =
      let host =
        Uri.host uri
        |> Option.map (fun value ->
            Domain_name.(host_exn (of_string_exn value)))
      in
      Tls_eio.client_of_flow ?host config raw
    in
    let http = Cohttp_eio.Client.make ~https:(Some https_connector) net in
    Ok
      (Configured
         { environment; api_key; transport = cohttp_transport ~clock http })

let headers api_key =
  [
    ("Authorization", "Bearer " ^ api_key);
    ("Paddle-Version", "1");
    ("Content-Type", "application/json");
    ("Accept", "application/json");
  ]

let header_value name headers =
  let wanted = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) wanted then Some value
      else None)
    headers

let decode_json ~operation decoder raw_body =
  match Yojson.Safe.from_string raw_body with
  | exception Yojson.Json_error detail -> Error (Decode { operation; detail })
  | json -> (
      match decoder json with
      | Ok value -> Ok value
      | Error detail -> Error (Decode { operation; detail }))

let api_error_of_response response =
  let parsed =
    match Yojson.Safe.from_string response.body with
    | exception Yojson.Json_error _ -> None
    | json -> (
        match error_envelope_json_of_yojson json with
        | Ok envelope -> Some envelope
        | Error _ -> None)
  in
  let code, detail, request_id =
    match parsed with
    | None -> (None, None, None)
    | Some envelope ->
        let request_id =
          Option.bind envelope.meta (fun meta -> meta.request_id)
        in
        (envelope.error.code, envelope.error.detail, request_id)
  in
  Api
    {
      status = response.status;
      code;
      detail;
      request_id;
      retry_after = header_value "retry-after" response.headers;
      raw_body = response.body;
    }

let post client ~sw ~path ~body ~decode =
  match client with
  | Disabled -> Error Not_configured
  | Configured client -> (
      let request =
        {
          meth = `POST;
          uri = Uri.of_string (api_base client.environment ^ path);
          headers = headers client.api_key;
          body = Yojson.Safe.to_string body;
        }
      in
      match client.transport ~sw request with
      | Error `Timeout -> Error Timeout
      | Error (`Transport detail) -> Error (Transport detail)
      | Ok response when response.status >= 200 && response.status < 300 ->
          decode response.body
      | Ok response -> Error (api_error_of_response response))

let validate_items items =
  match items with
  | [] -> Error (Invalid_request "at least one price item is required")
  | _ when List.length items > 100 ->
      Error (Invalid_request "at most 100 price items are allowed")
  | _ ->
      let validate { price_id; quantity } =
        if String.trim price_id = "" then
          Error (Invalid_request "price_id must not be empty")
        else if quantity < 1 || quantity > 999_999_999 then
          Error
            (Invalid_request "item quantity must be between 1 and 999999999")
        else Ok ()
      in
      List.fold_left
        (fun result item -> Result.bind result (fun () -> validate item))
        (Ok ()) items

let validate_optional label value =
  match value with
  | Some value when String.trim value = "" ->
      Error (Invalid_request (label ^ " must not be empty"))
  | _ -> Ok ()

let validate_custom_data = function
  | None -> Ok ()
  | Some (`Assoc (_ :: _)) -> Ok ()
  | Some (`Assoc []) ->
      Error (Invalid_request "custom_data must contain at least one key")
  | Some _ -> Error (Invalid_request "custom_data must be a JSON object")

let item_json { price_id; quantity } =
  `Assoc [ ("price_id", `String price_id); ("quantity", `Int quantity) ]

let create_transaction client ~sw ~items ?customer_id ?checkout_url ?custom_data
    () =
  let ( let* ) = Result.bind in
  let* () = validate_items items in
  let* () = validate_optional "customer_id" customer_id in
  let* () = validate_optional "checkout URL" checkout_url in
  let* () = validate_custom_data custom_data in
  let fields =
    [
      ("items", `List (List.map item_json items));
      ("collection_mode", `String "automatic");
    ]
  in
  let fields =
    match customer_id with
    | None -> fields
    | Some value -> fields @ [ ("customer_id", `String value) ]
  in
  let fields =
    match checkout_url with
    | None -> fields
    | Some value -> fields @ [ ("checkout", `Assoc [ ("url", `String value) ]) ]
  in
  let fields =
    match custom_data with
    | None -> fields
    | Some value -> fields @ [ ("custom_data", value) ]
  in
  post client ~sw ~path:"/transactions" ~body:(`Assoc fields)
    ~decode:(fun raw_body ->
      let* envelope =
        decode_json ~operation:"create transaction"
          transaction_envelope_json_of_yojson raw_body
      in
      let checkout_url =
        Option.bind envelope.data.checkout (fun checkout -> checkout.url)
      in
      Ok
        {
          id = envelope.data.id;
          checkout_url;
          customer_id = envelope.data.customer_id;
        })

let create_customer_portal_session client ~sw ~customer_id =
  let ( let* ) = Result.bind in
  let* () = validate_optional "customer_id" (Some customer_id) in
  let path = "/customers/" ^ Uri.pct_encode customer_id ^ "/portal-sessions" in
  post client ~sw ~path ~body:(`Assoc []) ~decode:(fun raw_body ->
      let* envelope =
        decode_json ~operation:"create customer portal session"
          portal_envelope_json_of_yojson raw_body
      in
      Ok { overview_url = envelope.data.urls.general.overview })

module Webhook = struct
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

  let verification_error_to_string = function
    | Invalid_secret -> "Paddle webhook secret must not be empty"
    | Invalid_tolerance value ->
        Printf.sprintf "Paddle webhook tolerance must be non-negative (got %d)"
          value
    | Malformed_signature detail ->
        "Malformed Paddle-Signature header: " ^ detail
    | Timestamp_outside_tolerance { timestamp; now; tolerance_seconds } ->
        Printf.sprintf
          "Paddle webhook timestamp %Ld is outside %d seconds of current time \
           %Ld"
          timestamp tolerance_seconds now
    | Signature_mismatch -> "Paddle webhook signature does not match"

  let split_field field =
    match String.index_opt field '=' with
    | None -> None
    | Some index ->
        let key = String.sub field 0 index |> String.trim in
        let value =
          String.sub field (index + 1) (String.length field - index - 1)
          |> String.trim
        in
        Some (key, value)

  let parse_header header =
    let fields =
      String.split_on_char ';' header
      |> List.filter_map (fun field ->
          if String.trim field = "" then None else split_field field)
    in
    let timestamps =
      List.filter_map (function "ts", value -> Some value | _ -> None) fields
    in
    let signatures =
      List.filter_map (function "h1", value -> Some value | _ -> None) fields
    in
    let is_lower_or_upper_hex value =
      String.length value = 64
      && String.for_all
           (function
             | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false)
           value
    in
    match timestamps with
    | [] -> Error (Malformed_signature "missing ts")
    | _ :: _ :: _ -> Error (Malformed_signature "more than one ts")
    | [ raw_timestamp ] -> (
        if signatures = [] then Error (Malformed_signature "missing h1")
        else if not (List.for_all is_lower_or_upper_hex signatures) then
          Error
            (Malformed_signature
               "each h1 must be exactly 64 hexadecimal characters")
        else
          match Int64.of_string_opt raw_timestamp with
          | None -> Error (Malformed_signature "ts is not a Unix timestamp")
          | Some timestamp -> Ok (timestamp, raw_timestamp, signatures))

  let constant_time_match expected candidate =
    let candidate = String.lowercase_ascii candidate in
    let expected_length = String.length expected in
    let candidate_length = String.length candidate in
    let length = max expected_length candidate_length in
    let difference = ref (expected_length lxor candidate_length) in
    for index = 0 to length - 1 do
      let expected_char =
        if index < expected_length then Char.code expected.[index] else 0
      in
      let candidate_char =
        if index < candidate_length then Char.code candidate.[index] else 0
      in
      difference := !difference lor (expected_char lxor candidate_char)
    done;
    if !difference = 0 then 1 else 0

  let verify ?(tolerance_seconds = 5) ~now ~secret ~signature_header ~raw_body
      () =
    if String.trim secret = "" then Error Invalid_secret
    else if tolerance_seconds < 0 then
      Error (Invalid_tolerance tolerance_seconds)
    else
      let ( let* ) = Result.bind in
      let* timestamp, raw_timestamp, signatures =
        parse_header signature_header
      in
      let tolerance = Int64.of_int tolerance_seconds in
      let earliest = Int64.sub now tolerance in
      let latest = Int64.add now tolerance in
      if
        Int64.compare timestamp earliest < 0
        || Int64.compare timestamp latest > 0
      then
        Error
          (Timestamp_outside_tolerance { timestamp; now; tolerance_seconds })
      else
        let signed_payload = raw_timestamp ^ ":" ^ raw_body in
        let expected =
          Digestif.SHA256.hmac_string ~key:secret signed_payload
          |> Digestif.SHA256.to_hex
        in
        let matched =
          List.fold_left
            (fun accumulator signature ->
              accumulator lor constant_time_match expected signature)
            0 signatures
        in
        if matched = 1 then Ok () else Error Signature_mismatch

  let decode ~raw_body =
    let ( let* ) = Result.bind in
    let* decoded =
      decode_json ~operation:"webhook envelope" webhook_event_json_of_yojson
        raw_body
    in
    Ok
      {
        event_id = decoded.event_id;
        event_type = decoded.event_type;
        occurred_at = decoded.occurred_at;
        notification_id = decoded.notification_id;
        data = decoded.data;
      }
end

module For_testing = struct
  type nonrec request = request = {
    meth : [ `POST ];
    uri : Uri.t;
    headers : (string * string) list;
    body : string;
  }

  type nonrec response = response = {
    status : int;
    headers : (string * string) list;
    body : string;
  }

  type nonrec transport_error = transport_error

  let configured ~environment ~api_key transport =
    Configured { environment; api_key; transport }
end
