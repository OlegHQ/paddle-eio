open Paddle_eio

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let standard_headers api_key =
  [
    ("Authorization", "Bearer " ^ api_key);
    ("Paddle-Version", "1");
    ("Content-Type", "application/json");
    ("Accept", "application/json");
  ]

let read_headers api_key =
  [
    ("Authorization", "Bearer " ^ api_key);
    ("Paddle-Version", "1");
    ("Accept", "application/json");
  ]

let with_switch f = Eio.Switch.run f
let method_name = function `GET -> "GET" | `PATCH -> "PATCH" | `POST -> "POST"

let transaction_response =
  {|
    {
      "data": {
        "id": "txn_01test",
        "customer_id": "ctm_01test",
        "checkout": { "url": "https://checkout.paddle.test/pay?_ptxn=txn_01test" },
        "ignored_new_field": true
      },
      "meta": { "request_id": "req-success" }
    }
  |}

let test_create_transaction_exact_request () =
  let seen = ref None in
  let api_key = "pdl_sdbx_apikey_test" in
  let transport ~sw:_ (request : For_testing.request) =
    seen := Some request;
    Ok For_testing.{ status = 201; headers = []; body = transaction_response }
  in
  let client = For_testing.configured ~environment:Sandbox ~api_key transport in
  let result =
    with_switch (fun sw ->
        create_transaction client ~sw
          ~items:
            [
              { price_id = "pri_creator"; quantity = 1 };
              { price_id = "pri_x_addon"; quantity = 2 };
            ]
          ~customer_id:"ctm_01test"
          ~checkout_url:"https://poster.test/billing/complete"
          ~custom_data:(`Assoc [ ("poster_user_id", `String "usr_01test") ])
          ())
  in
  (match result with
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok transaction ->
      Alcotest.(check string) "transaction id" "txn_01test" transaction.id;
      Alcotest.(check (option string))
        "customer id" (Some "ctm_01test") transaction.customer_id;
      Alcotest.(check (option string))
        "checkout URL"
        (Some "https://checkout.paddle.test/pay?_ptxn=txn_01test")
        transaction.checkout_url);
  match !seen with
  | None -> Alcotest.fail "transport was not called"
  | Some request ->
      Alcotest.(check string) "method" "POST" (method_name request.meth);
      Alcotest.(check string)
        "sandbox URI" "https://sandbox-api.paddle.com/transactions"
        (Uri.to_string request.uri);
      Alcotest.(check (list (pair string string)))
        "headers" (standard_headers api_key) request.headers;
      Alcotest.(check string)
        "exact JSON body"
        {|{"items":[{"price_id":"pri_creator","quantity":1},{"price_id":"pri_x_addon","quantity":2}],"collection_mode":"automatic","customer_id":"ctm_01test","checkout":{"url":"https://poster.test/billing/complete"},"custom_data":{"poster_user_id":"usr_01test"}}|}
        request.body

let test_get_price_with_product () =
  let seen = ref None in
  let api_key = "pdl_live_apikey_test" in
  let transport ~sw:_ (request : For_testing.request) =
    seen := Some request;
    Ok
      For_testing.
        {
          status = 200;
          headers = [];
          body =
            {|{
              "data": {
                "id": "pri_creator_monthly",
                "product_id": "pro_creator",
                "type": "standard",
                "billing_cycle": { "interval": "month", "frequency": 1 },
                "trial_period": null,
                "unit_price": { "amount": "2400", "currency_code": "USD" },
                "quantity": { "minimum": 1, "maximum": 100 },
                "status": "active",
                "product": {
                  "id": "pro_creator",
                  "name": "Poster Creator",
                  "type": "standard",
                  "tax_category": "saas",
                  "status": "active"
                },
                "ignored_new_field": true
              },
              "meta": { "request_id": "req-price" }
            }|};
        }
  in
  let client = For_testing.configured ~environment:Live ~api_key transport in
  let result =
    with_switch (fun sw ->
        get_price client ~sw ~price_id:"pri_creator_monthly"
          ~include_product:true ())
  in
  (match result with
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok price -> (
      Alcotest.(check string) "price id" "pri_creator_monthly" price.id;
      Alcotest.(check string) "product id" "pro_creator" price.product_id;
      Alcotest.(check bool) "standard price" true (price.entity_type = Standard);
      Alcotest.(check bool) "active price" true (price.status = Active);
      Alcotest.(check bool)
        "monthly" true
        (price.billing_cycle = Some { interval = Month; frequency = 1 });
      Alcotest.(check (option string))
        "no trial" None
        (Option.map (fun _ -> "trial") price.trial_period);
      Alcotest.(check string) "amount" "2400" price.unit_price.amount;
      Alcotest.(check string) "currency" "USD" price.unit_price.currency_code;
      Alcotest.(check int) "minimum quantity" 1 price.quantity.minimum;
      Alcotest.(check int) "maximum quantity" 100 price.quantity.maximum;
      match price.product with
      | None -> Alcotest.fail "included product was not decoded"
      | Some product ->
          Alcotest.(check string) "product name" "Poster Creator" product.name;
          Alcotest.(check string) "tax category" "saas" product.tax_category;
          Alcotest.(check bool) "active product" true (product.status = Active)));
  match !seen with
  | None -> Alcotest.fail "transport was not called"
  | Some request ->
      Alcotest.(check string) "method" "GET" (method_name request.meth);
      Alcotest.(check string)
        "live URI"
        "https://api.paddle.com/prices/pri_creator_monthly?include=product"
        (Uri.to_string request.uri);
      Alcotest.(check (list (pair string string)))
        "headers" (read_headers api_key) request.headers;
      Alcotest.(check string) "empty GET body" "" request.body

let test_update_transaction_items_exact_request () =
  let seen = ref None in
  let api_key = "pdl_sdbx_apikey_test" in
  let custom_data =
    `Assoc
      [
        ("poster_checkout_intent_id", `String "bci_01test");
        ("poster_checkout_nonce", `String "nonce_01test");
      ]
  in
  let transport ~sw:_ (request : For_testing.request) =
    seen := Some request;
    Ok
      For_testing.
        {
          status = 200;
          headers = [];
          body =
            {|{
              "data": {
                "id": "txn_01update",
                "status": "ready",
                "custom_data": {
                  "poster_checkout_intent_id": "bci_01test",
                  "poster_checkout_nonce": "nonce_01test"
                },
                "ignored_new_field": true
              },
              "meta": { "request_id": "req-update" }
            }|};
        }
  in
  let client = For_testing.configured ~environment:Sandbox ~api_key transport in
  let result =
    with_switch (fun sw ->
        update_transaction_items client ~sw ~transaction_id:"txn_01update"
          ~items:
            [
              { price_id = "pri_creator_annual"; quantity = 1 };
              { price_id = "pri_x_annual"; quantity = 1 };
            ]
          ~custom_data)
  in
  (match result with
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok transaction ->
      Alcotest.(check string) "transaction id" "txn_01update" transaction.id;
      Alcotest.(check bool) "ready status" true (transaction.status = Ready);
      Alcotest.(check (option json))
        "custom data" (Some custom_data) transaction.custom_data);
  match !seen with
  | None -> Alcotest.fail "transport was not called"
  | Some request ->
      Alcotest.(check string) "method" "PATCH" (method_name request.meth);
      Alcotest.(check string)
        "sandbox URI" "https://sandbox-api.paddle.com/transactions/txn_01update"
        (Uri.to_string request.uri);
      Alcotest.(check (list (pair string string)))
        "headers" (standard_headers api_key) request.headers;
      Alcotest.(check string)
        "exact update body"
        {|{"items":[{"price_id":"pri_creator_annual","quantity":1},{"price_id":"pri_x_annual","quantity":1}],"custom_data":{"poster_checkout_intent_id":"bci_01test","poster_checkout_nonce":"nonce_01test"}}|}
        request.body

let test_update_transaction_items_structured_error_no_retry () =
  let calls = ref 0 in
  let raw_body =
    {|{"error":{"type":"request_error","code":"transaction_invalid_status_change","detail":"This transaction can no longer be updated."},"meta":{"request_id":"req-update-conflict"}}|}
  in
  let transport ~sw:_ (_ : For_testing.request) =
    incr calls;
    Ok
      For_testing.
        { status = 409; headers = [ ("Retry-After", "15") ]; body = raw_body }
  in
  let client =
    For_testing.configured ~environment:Sandbox ~api_key:"sandbox-key" transport
  in
  let result =
    with_switch (fun sw ->
        update_transaction_items client ~sw ~transaction_id:"txn_completed"
          ~items:[ { price_id = "pri_creator"; quantity = 1 } ]
          ~custom_data:(`Assoc [ ("checkout_intent", `String "bci_01") ]))
  in
  Alcotest.(check int) "single update attempt" 1 !calls;
  match result with
  | Error
      (Api
         {
           status;
           code;
           detail;
           request_id;
           retry_after;
           raw_body = actual_body;
         }) ->
      Alcotest.(check int) "status" 409 status;
      Alcotest.(check (option string))
        "code" (Some "transaction_invalid_status_change") code;
      Alcotest.(check (option string))
        "detail" (Some "This transaction can no longer be updated.") detail;
      Alcotest.(check (option string))
        "request id" (Some "req-update-conflict") request_id;
      Alcotest.(check (option string)) "retry after" (Some "15") retry_after;
      Alcotest.(check string) "raw error body" raw_body actual_body
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok _ -> Alcotest.fail "immutable transaction unexpectedly updated"

let test_update_transaction_items_rejects_wrong_id () =
  let transport ~sw:_ (_ : For_testing.request) =
    Ok
      For_testing.
        {
          status = 200;
          headers = [];
          body =
            {|{"data":{"id":"txn_other","status":"draft","custom_data":{"checkout_intent":"bci_01"}}}|};
        }
  in
  let client =
    For_testing.configured ~environment:Sandbox ~api_key:"sandbox-key" transport
  in
  match
    with_switch (fun sw ->
        update_transaction_items client ~sw ~transaction_id:"txn_requested"
          ~items:[ { price_id = "pri_creator"; quantity = 1 } ]
          ~custom_data:(`Assoc [ ("checkout_intent", `String "bci_01") ]))
  with
  | Error (Decode { operation = "update transaction items"; detail }) ->
      Alcotest.(check string)
        "id mismatch"
        {|response id "txn_other" does not match request id "txn_requested"|}
        detail
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok _ -> Alcotest.fail "mismatched transaction id was accepted"

let test_update_transaction_items_accepts_draft () =
  let transport ~sw:_ (_ : For_testing.request) =
    Ok
      For_testing.
        {
          status = 200;
          headers = [];
          body =
            {|{"data":{"id":"txn_draft","status":"draft","custom_data":{"checkout_intent":"bci_01"}}}|};
        }
  in
  let client =
    For_testing.configured ~environment:Sandbox ~api_key:"sandbox-key" transport
  in
  match
    with_switch (fun sw ->
        update_transaction_items client ~sw ~transaction_id:"txn_draft"
          ~items:[ { price_id = "pri_creator"; quantity = 1 } ]
          ~custom_data:(`Assoc [ ("checkout_intent", `String "bci_01") ]))
  with
  | Ok transaction ->
      Alcotest.(check bool) "draft status" true (transaction.status = Draft)
  | Error error -> Alcotest.fail (error_to_string error)

let test_update_transaction_items_rejects_terminal_status () =
  let transport ~sw:_ (_ : For_testing.request) =
    Ok
      For_testing.
        {
          status = 200;
          headers = [];
          body =
            {|{"data":{"id":"txn_completed","status":"completed","custom_data":{"checkout_intent":"bci_01"}}}|};
        }
  in
  let client =
    For_testing.configured ~environment:Sandbox ~api_key:"sandbox-key" transport
  in
  match
    with_switch (fun sw ->
        update_transaction_items client ~sw ~transaction_id:"txn_completed"
          ~items:[ { price_id = "pri_creator"; quantity = 1 } ]
          ~custom_data:(`Assoc [ ("checkout_intent", `String "bci_01") ]))
  with
  | Error (Decode { operation = "update transaction items"; detail }) ->
      Alcotest.(check string)
        "status mismatch"
        {|response status is "completed", expected draft or ready|} detail
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok _ -> Alcotest.fail "terminal transaction status was accepted"

let test_update_transaction_items_requires_custom_data () =
  let calls = ref 0 in
  let transport ~sw:_ (_ : For_testing.request) =
    incr calls;
    Alcotest.fail "invalid update reached transport"
  in
  let client =
    For_testing.configured ~environment:Sandbox ~api_key:"sandbox-key" transport
  in
  let result =
    with_switch (fun sw ->
        update_transaction_items client ~sw ~transaction_id:"txn_draft"
          ~items:[ { price_id = "pri_creator"; quantity = 1 } ]
          ~custom_data:(`Assoc []))
  in
  Alcotest.(check int) "no HTTP request" 0 !calls;
  match result with
  | Error (Invalid_request "custom_data must contain at least one key") -> ()
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok _ -> Alcotest.fail "empty custom data was accepted"

let test_cancel_transaction_exact_request () =
  let seen = ref None in
  let api_key = "pdl_sdbx_apikey_test" in
  let custom_data =
    `Assoc
      [
        ("poster_checkout_intent_id", `String "bci_01test");
        ("poster_checkout_nonce", `String "nonce_01test");
      ]
  in
  let transport ~sw:_ (request : For_testing.request) =
    seen := Some request;
    Ok
      For_testing.
        {
          status = 200;
          headers = [];
          body =
            {|{
              "data": {
                "id": "txn_01cancel",
                "status": "canceled",
                "custom_data": {
                  "poster_checkout_intent_id": "bci_01test",
                  "poster_checkout_nonce": "nonce_01test"
                },
                "ignored_new_field": true
              },
              "meta": { "request_id": "req-cancel" }
            }|};
        }
  in
  let client = For_testing.configured ~environment:Sandbox ~api_key transport in
  let result =
    with_switch (fun sw ->
        cancel_transaction client ~sw ~transaction_id:"txn_01cancel")
  in
  (match result with
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok transaction ->
      Alcotest.(check string) "transaction id" "txn_01cancel" transaction.id;
      Alcotest.(check bool)
        "canceled status" true
        (transaction.status = Canceled);
      Alcotest.(check (option json))
        "custom data" (Some custom_data) transaction.custom_data);
  match !seen with
  | None -> Alcotest.fail "transport was not called"
  | Some request ->
      Alcotest.(check string) "method" "PATCH" (method_name request.meth);
      Alcotest.(check string)
        "sandbox URI" "https://sandbox-api.paddle.com/transactions/txn_01cancel"
        (Uri.to_string request.uri);
      Alcotest.(check (list (pair string string)))
        "headers" (standard_headers api_key) request.headers;
      Alcotest.(check string)
        "exact cancel body" {|{"status":"canceled"}|} request.body

let test_cancel_transaction_structured_error_no_retry () =
  let calls = ref 0 in
  let raw_body =
    {|{"error":{"type":"request_error","code":"transaction_invalid_status_change","detail":"This completed transaction cannot be canceled."},"meta":{"request_id":"req-cancel-conflict"}}|}
  in
  let transport ~sw:_ (_ : For_testing.request) =
    incr calls;
    Ok For_testing.{ status = 409; headers = []; body = raw_body }
  in
  let client =
    For_testing.configured ~environment:Sandbox ~api_key:"sandbox-key" transport
  in
  let result =
    with_switch (fun sw ->
        cancel_transaction client ~sw ~transaction_id:"txn_completed")
  in
  Alcotest.(check int) "single cancel attempt" 1 !calls;
  match result with
  | Error
      (Api
         {
           status;
           code;
           detail;
           request_id;
           retry_after;
           raw_body = actual_body;
         }) ->
      Alcotest.(check int) "status" 409 status;
      Alcotest.(check (option string))
        "code" (Some "transaction_invalid_status_change") code;
      Alcotest.(check (option string))
        "detail" (Some "This completed transaction cannot be canceled.") detail;
      Alcotest.(check (option string))
        "request id" (Some "req-cancel-conflict") request_id;
      Alcotest.(check (option string)) "retry after" None retry_after;
      Alcotest.(check string) "raw error body" raw_body actual_body
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok _ -> Alcotest.fail "completed transaction unexpectedly canceled"

let test_cancel_transaction_requires_canceled_response () =
  let transport ~sw:_ (_ : For_testing.request) =
    Ok
      For_testing.
        {
          status = 200;
          headers = [];
          body =
            {|{"data":{"id":"txn_01stillready","status":"ready","custom_data":null}}|};
        }
  in
  let client =
    For_testing.configured ~environment:Sandbox ~api_key:"sandbox-key" transport
  in
  match
    with_switch (fun sw ->
        cancel_transaction client ~sw ~transaction_id:"txn_01stillready")
  with
  | Error (Decode { operation = "cancel transaction"; detail }) ->
      Alcotest.(check string)
        "status mismatch" {|response status is "ready", expected canceled|}
        detail
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok _ -> Alcotest.fail "non-canceled response was accepted"

let test_create_transaction_without_customer () =
  let seen = ref None in
  let transport ~sw:_ (request : For_testing.request) =
    seen := Some request;
    Ok
      For_testing.
        {
          status = 201;
          headers = [];
          body =
            {|{"data":{"id":"txn_draft","customer_id":null,"checkout":{"url":"https://checkout.paddle.test/draft"}}}|};
        }
  in
  let client =
    For_testing.configured ~environment:Live ~api_key:"live-key" transport
  in
  let result =
    with_switch (fun sw ->
        create_transaction client ~sw
          ~items:[ { price_id = "pri_creator"; quantity = 1 } ]
          ())
  in
  (match result with
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok transaction ->
      Alcotest.(check (option string))
        "customer absent" None transaction.customer_id);
  match !seen with
  | None -> Alcotest.fail "transport was not called"
  | Some request ->
      Alcotest.(check string)
        "live URI" "https://api.paddle.com/transactions"
        (Uri.to_string request.uri);
      Alcotest.(check string)
        "draft request body"
        {|{"items":[{"price_id":"pri_creator","quantity":1}],"collection_mode":"automatic"}|}
        request.body

let test_portal_session_exact_request () =
  let seen = ref None in
  let transport ~sw:_ (request : For_testing.request) =
    seen := Some request;
    Ok
      For_testing.
        {
          status = 201;
          headers = [];
          body =
            {|{"data":{"id":"cpls_ignored","urls":{"general":{"overview":"https://customer-portal.paddle.test/overview?token=short-lived"},"subscriptions":[]}}}|};
        }
  in
  let client =
    For_testing.configured ~environment:Sandbox ~api_key:"sandbox-key" transport
  in
  let result =
    with_switch (fun sw ->
        create_customer_portal_session client ~sw ~customer_id:"ctm_01portal")
  in
  (match result with
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok session ->
      Alcotest.(check string)
        "overview URL"
        "https://customer-portal.paddle.test/overview?token=short-lived"
        session.overview_url);
  match !seen with
  | None -> Alcotest.fail "transport was not called"
  | Some request ->
      Alcotest.(check string)
        "portal path"
        "https://sandbox-api.paddle.com/customers/ctm_01portal/portal-sessions"
        (Uri.to_string request.uri);
      Alcotest.(check string) "empty portal body" "{}" request.body

let test_disabled () =
  let client = disabled () in
  Alcotest.(check bool) "disabled" false (configured client);
  let result =
    with_switch (fun sw ->
        create_transaction client ~sw
          ~items:[ { price_id = "pri_creator"; quantity = 1 } ]
          ())
  in
  match result with
  | Error Not_configured -> ()
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok _ -> Alcotest.fail "disabled client unexpectedly created a transaction"

let test_api_error_preserves_context_and_no_retry () =
  let calls = ref 0 in
  let raw_body =
    {|{"error":{"type":"api_error","code":"too_many_requests","detail":"Wait before trying again.","documentation_url":"https://developer.paddle.com/errors/too_many_requests"},"meta":{"request_id":"req-rate-limit"}}|}
  in
  let transport ~sw:_ (_ : For_testing.request) =
    incr calls;
    Ok
      For_testing.
        { status = 429; headers = [ ("rEtRy-AfTeR", "60") ]; body = raw_body }
  in
  let client =
    For_testing.configured ~environment:Sandbox ~api_key:"sandbox-key" transport
  in
  let result =
    with_switch (fun sw ->
        create_transaction client ~sw
          ~items:[ { price_id = "pri_creator"; quantity = 1 } ]
          ())
  in
  Alcotest.(check int) "single mutation attempt" 1 !calls;
  match result with
  | Error
      (Api
         {
           status;
           code;
           detail;
           request_id;
           retry_after;
           raw_body = actual_body;
         }) ->
      Alcotest.(check int) "status" 429 status;
      Alcotest.(check (option string)) "code" (Some "too_many_requests") code;
      Alcotest.(check (option string))
        "detail" (Some "Wait before trying again.") detail;
      Alcotest.(check (option string))
        "request id" (Some "req-rate-limit") request_id;
      Alcotest.(check (option string)) "retry after" (Some "60") retry_after;
      Alcotest.(check string) "raw error body" raw_body actual_body
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok _ -> Alcotest.fail "rate-limited request unexpectedly succeeded"

let test_transport_timeout () =
  let transport ~sw:_ (_ : For_testing.request) = Error `Timeout in
  let client =
    For_testing.configured ~environment:Sandbox ~api_key:"sandbox-key" transport
  in
  let result =
    with_switch (fun sw ->
        create_customer_portal_session client ~sw ~customer_id:"ctm_timeout")
  in
  match result with
  | Error Timeout -> ()
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok _ -> Alcotest.fail "timed-out request unexpectedly succeeded"

let fixture_secret = "pdl_ntfset_test_secret"
let fixture_timestamp = 1_700_000_000L

let fixture_body =
  {|{"event_id":"evt_123","event_type":"transaction.completed"}|}

let fixture_signature =
  "335d1cef3e097f186c3c20f669f9fd11a80ba909cfc18d9c269b2e1359e39f36"

let verify ?tolerance_seconds ?(now = fixture_timestamp) ?(body = fixture_body)
    signature_header =
  Webhook.verify ?tolerance_seconds ~now ~secret:fixture_secret
    ~signature_header ~raw_body:body ()

let test_signature_fixture () =
  match verify ("ts=1700000000;h1=" ^ fixture_signature) with
  | Ok () -> ()
  | Error error -> Alcotest.fail (Webhook.verification_error_to_string error)

let test_multiple_signatures () =
  let invalid = String.make 64 '0' in
  match verify ("ts=1700000000;h1=" ^ invalid ^ ";h1=" ^ fixture_signature) with
  | Ok () -> ()
  | Error error -> Alcotest.fail (Webhook.verification_error_to_string error)

let test_tampered_body () =
  match
    verify ~body:(fixture_body ^ " ") ("ts=1700000000;h1=" ^ fixture_signature)
  with
  | Error Webhook.Signature_mismatch -> ()
  | Error error -> Alcotest.fail (Webhook.verification_error_to_string error)
  | Ok () -> Alcotest.fail "tampered body passed signature verification"

let test_rejects_unbounded_h1 () =
  let oversized = String.make 65 '0' in
  match verify ("ts=1700000000;h1=" ^ oversized) with
  | Error (Webhook.Malformed_signature _) -> ()
  | Error error -> Alcotest.fail (Webhook.verification_error_to_string error)
  | Ok () -> Alcotest.fail "oversized h1 passed signature verification"

let test_timestamp_tolerance () =
  let header = "ts=1700000000;h1=" ^ fixture_signature in
  (match verify ~now:1_700_000_005L header with
  | Ok () -> ()
  | Error error ->
      Alcotest.fail
        ("five-second boundary rejected: "
        ^ Webhook.verification_error_to_string error));
  match verify ~now:1_700_000_006L header with
  | Error (Webhook.Timestamp_outside_tolerance _) -> ()
  | Error error -> Alcotest.fail (Webhook.verification_error_to_string error)
  | Ok () -> Alcotest.fail "stale timestamp passed verification"

let test_future_timestamp () =
  let header = "ts=1700000000;h1=" ^ fixture_signature in
  match verify ~now:1_699_999_994L header with
  | Error (Webhook.Timestamp_outside_tolerance _) -> ()
  | Error error -> Alcotest.fail (Webhook.verification_error_to_string error)
  | Ok () -> Alcotest.fail "future timestamp passed verification"

let test_webhook_envelope () =
  let raw_body =
    {|{"event_id":"evt_01","event_type":"subscription.updated","occurred_at":"2026-07-12T12:00:00Z","notification_id":"ntf_01","data":{"id":"sub_01","status":"active"},"new_field":"ignored"}|}
  in
  match Webhook.decode ~raw_body with
  | Error error -> Alcotest.fail (error_to_string error)
  | Ok event ->
      Alcotest.(check string) "event id" "evt_01" event.event_id;
      Alcotest.(check string)
        "event type" "subscription.updated" event.event_type;
      Alcotest.(check string)
        "occurred at" "2026-07-12T12:00:00Z" event.occurred_at;
      Alcotest.(check string) "notification id" "ntf_01" event.notification_id;
      Alcotest.check json "opaque data"
        (`Assoc [ ("id", `String "sub_01"); ("status", `String "active") ])
        event.data

let () =
  Eio_main.run @@ fun _env ->
  Alcotest.run "paddle-eio"
    [
      ( "REST",
        [
          Alcotest.test_case "transaction request" `Quick
            test_create_transaction_exact_request;
          Alcotest.test_case "get price with product" `Quick
            test_get_price_with_product;
          Alcotest.test_case "update transaction items request" `Quick
            test_update_transaction_items_exact_request;
          Alcotest.test_case "update structured error and no retry" `Quick
            test_update_transaction_items_structured_error_no_retry;
          Alcotest.test_case "update rejects wrong id" `Quick
            test_update_transaction_items_rejects_wrong_id;
          Alcotest.test_case "update accepts draft" `Quick
            test_update_transaction_items_accepts_draft;
          Alcotest.test_case "update rejects terminal status" `Quick
            test_update_transaction_items_rejects_terminal_status;
          Alcotest.test_case "update requires custom data" `Quick
            test_update_transaction_items_requires_custom_data;
          Alcotest.test_case "cancel transaction request" `Quick
            test_cancel_transaction_exact_request;
          Alcotest.test_case "cancel structured error and no retry" `Quick
            test_cancel_transaction_structured_error_no_retry;
          Alcotest.test_case "cancel requires canceled response" `Quick
            test_cancel_transaction_requires_canceled_response;
          Alcotest.test_case "transaction without customer" `Quick
            test_create_transaction_without_customer;
          Alcotest.test_case "portal request" `Quick
            test_portal_session_exact_request;
          Alcotest.test_case "disabled" `Quick test_disabled;
          Alcotest.test_case "rich API error and no retry" `Quick
            test_api_error_preserves_context_and_no_retry;
          Alcotest.test_case "transport timeout" `Quick test_transport_timeout;
        ] );
      ( "webhook signature",
        [
          Alcotest.test_case "fixed fixture" `Quick test_signature_fixture;
          Alcotest.test_case "multiple h1" `Quick test_multiple_signatures;
          Alcotest.test_case "tampered raw body" `Quick test_tampered_body;
          Alcotest.test_case "bounded h1" `Quick test_rejects_unbounded_h1;
          Alcotest.test_case "timestamp tolerance" `Quick
            test_timestamp_tolerance;
          Alcotest.test_case "future timestamp" `Quick test_future_timestamp;
        ] );
      ( "webhook envelope",
        [ Alcotest.test_case "generic decode" `Quick test_webhook_envelope ] );
    ]
