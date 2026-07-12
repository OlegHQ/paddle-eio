# paddle-eio

`paddle-eio` is a focused OCaml 5/Eio boundary for the Paddle Billing calls
Poster needs. It deliberately is not a generated, account-wide SDK.

The library provides:

- sandbox and live API environments;
- a reusable `Cohttp_eio` HTTPS client with system-CA verification, hostname
  verification, API version pinning, and a ten-second monotonic timeout;
- read-only catalog price lookup with an optional related-product projection;
- one-call automatic transaction creation from catalog price IDs;
- complete item-list replacement for mutable transactions;
- explicit transaction cancellation without automatic retries;
- temporary customer portal overview sessions;
- raw-body Paddle webhook verification and generic event-envelope decoding;
- structured HTTP errors with Paddle's code, detail, request ID, raw body, and
  `Retry-After` header.

The implementation follows Paddle API version 1. See Paddle's current
[API quickstart](https://developer.paddle.com/api-reference/about/),
[get-price API](https://developer.paddle.com/api-reference/prices/get-price/),
[transaction API](https://developer.paddle.com/api-reference/transactions/create-transaction/),
[transaction-update API](https://developer.paddle.com/api-reference/transactions/update-transaction/),
[portal-session API](https://developer.paddle.com/api-reference/customer-portals/create-customer-portal-session/),
and [webhook verification guide](https://developer.paddle.com/webhooks/about/signature-verification/).

## Installation

Pin a checkout while developing it as a Poster submodule:

```sh
opam pin add -n paddle-eio ./vendor/paddle-eio
opam install paddle-eio
```

The embedding executable must initialize a Mirage Crypto RNG before making TLS
connections, as required by `tls-eio`. Keep that runtime concern at the
executable boundary.

## Client lifecycle

Create one client at the application composition root and reuse it for the
server lifetime:

```ocaml
let create_paddle env api_key =
  Paddle_eio.create
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.mono_clock env)
    ~environment:Paddle_eio.Sandbox ~api_key ()
```

Use `Paddle_eio.disabled ()` when billing is intentionally unavailable.
Operations on a disabled client return `Not_configured`; handlers do not need a
second placeholder transport.

`Sandbox` uses `https://sandbox-api.paddle.com`; `Live` uses
`https://api.paddle.com`. API keys are server-side secrets and must come from
environment or secret storage. Do not expose them to browser code.

## Catalog reads

```ocaml
let result =
  Paddle_eio.get_price paddle ~sw ~price_id ~include_product:true ()
```

The decoded projection includes the fields needed for a startup catalog check:
price/product identity and status, standard/custom type, billing and trial
cycles, base amount/currency, quantity bounds, and product tax category. It is
not an entitlement source and callers should not perform provider reads on
normal application requests.

`get_price` requires `price.read`. Passing `include_product:true` also requires
`product.read`, as described by Paddle's current
[permissions documentation](https://developer.paddle.com/api-reference/about/permissions/).

## Transactions

```ocaml
let result =
  Paddle_eio.create_transaction paddle ~sw
    ~items:[ { price_id = creator_price_id; quantity = 1 } ]
    ~customer_id
    ~checkout_url:"https://poster.example/billing/complete"
    ~custom_data:(`Assoc [ ("poster_user_id", `String user_id) ])
    ()
```

`customer_id` is optional. Omit it for a draft checkout that collects customer
details. `custom_data`, when supplied, must be a non-empty JSON object.

### Replace transaction items

```ocaml
let result =
  Paddle_eio.update_transaction_items paddle ~sw ~transaction_id
    ~items:
      [
        { price_id = creator_annual_price_id; quantity = 1 };
        { price_id = x_annual_price_id; quantity = 1 };
      ]
    ~custom_data:
      (`Assoc
        [
          ("checkout_intent_id", `String checkout_intent_id);
          ("checkout_nonce", `String checkout_nonce);
        ])
```

Paddle's
[update-transaction API](https://developer.paddle.com/api-reference/transactions/update-transaction/)
treats `items` as a complete replacement list: omitted existing items are
removed. Only `draft` and `ready` transactions are mutable, and the call
requires `transaction.write`. `custom_data` is mandatory in this focused API
and must be a non-empty object supplied by the server-side caller; do not copy
ownership data from browser input.

The call sends exactly one `PATCH /transactions/{transaction_id}` request and
does not retry. It returns the transaction id, typed status, and custom data,
and rejects a nominally successful response when the id differs, the status is
not `draft` or `ready`, or custom data is neither an object nor `null`.

### Cancel a transaction

```ocaml
let result =
  Paddle_eio.cancel_transaction paddle ~sw ~transaction_id
```

Cancellation sends exactly `{"status":"canceled"}` to
`PATCH /transactions/{transaction_id}` and requires `transaction.write`.
Paddle permits cancellation only for a transaction state it considers
cancelable (currently `ready` or `billed`); in particular, use
`update_transaction_items` rather than trying to cancel a draft to change its
selection.
The returned projection contains only the transaction id, its typed status, and
its custom data. The client rejects a successful response with a different id,
a status other than `canceled`, or custom data that is neither an object nor
`null`.

### Mutation and idempotency caveat

The library sends exactly one request and never automatically retries a Paddle
mutation. It does not invent or attach an idempotency header. If the connection
fails after Paddle may have accepted a transaction, the outcome is unknown;
blindly calling `create_transaction` again can create a duplicate transaction.
Similarly, a timeout, transport failure, or undecodable success while canceling
does not prove that cancellation failed. The same ambiguity applies to an item
update. `update_transaction_items` and `cancel_transaction` are not retried;
the caller must preserve the unknown outcome and reconcile it from trusted
provider state or a verified webhook before deciding on another mutation.

An application should persist a durable intent before transaction creation,
record the canonical Paddle transaction ID after a definite success, and treat
an ambiguous result as indeterminate rather than repeating the effect. A caller
may include its own stable reference in `custom_data`, but custom data alone is
not an API idempotency guarantee.

## Customer portal

```ocaml
let result =
  Paddle_eio.create_customer_portal_session paddle ~sw ~customer_id
```

Only the temporary overview URL is decoded. Do not persist or cache it, and do
not embed the Paddle portal in an iframe.

## Webhooks

Read the body once without parsing or reformatting it, then verify the exact raw
bytes before decoding:

```ocaml
let verified =
  Paddle_eio.Webhook.verify ~now:(Int64.of_float (Unix.time ()))
    ~secret:webhook_secret ~signature_header ~raw_body ()
```

The default tolerance is five seconds. Verification accepts every `h1` value
present in `Paddle-Signature`, compares HMAC-SHA256 values in constant time,
and rejects old or future timestamps outside the tolerance. After verification,
call `Paddle_eio.Webhook.decode ~raw_body`; its `data` field intentionally stays
as `Yojson.Safe.t` so the application can route by `event_type` and decode only
the event types it owns.

## Permissions and production

Use a least-privilege API key with `price.read`, `product.read`,
`transaction.write`, and `customer_portal_session.write`. Develop and test
against sandbox. Moving to live requires a live Paddle account, separate live
catalog IDs and credentials, an approved checkout domain/default payment link,
and a live notification destination with its own endpoint secret.

## Verification

```sh
./scripts/secret-safe-exec.sh opam exec -- dune build --root . @all
./scripts/secret-safe-exec.sh opam exec -- dune runtest --root .
```

Tests use an injected fake transport to assert complete request shapes without
network access. Production construction does not expose transport replacement.

## Secret safety

Never commit API keys, webhook secrets, Vault tokens, environment files, Dune
build output, or trace files. Install the repository's Gitleaks pre-commit hook
or run both history and working-tree scans documented in
[`SECURITY.md`](SECURITY.md). GitHub secret scanning and push protection remain
enabled on the public repository; the CI scan adds a focused short-form Vault
token rule that is not covered by every generic scanner configuration.
