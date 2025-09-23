# WiWi — Subscription Contract (short)

WiWi is a Clarity contract for simple STX-based recurring subscriptions. Each subscriber can have one subscription that immediately pays a rate to a receiver, stores an expiry, and can be renewed or cancelled.

## Quick facts
- Owner (deployer) is set as `CONTRACT_OWNER`.
- Minimum rate: `MIN_RATE = 1 STX` (1_000_000 microSTX).
- Default renewal period: `RENEWAL_PERIOD = 10080` blocks (~7 days).

## Storage
- `subscriptions` map: subscriber principal -> { expiry: uint, rate: uint, receiver: principal }

## Main actions
- **subscribe(receiver, rate, period)**
  - Requires `rate >= MIN_RATE`.
  - Transfers `rate` from caller to `receiver` immediately.
  - Stores expiry = current block + period.
- **renew()**
  - Caller must have a subscription.
  - Allowed only if current block >= stored expiry (subscription expired).
  - Transfers `rate` and sets expiry = current block + RENEWAL_PERIOD.
- **cancel-subscription()**
  - Subscriber deletes their subscription.
- **admin-cancel-subscription(subscriber)**
  - Only `CONTRACT_OWNER` can cancel any subscription.

## Views
- `get-subscription(sub)` — returns subscription data (option)
- `is-subscription-active(sub)` — true if expiry > current block
- `get-contract-owner()`, `get-min-rate()`

## Notes & suggestions
- Renew is only allowed after expiry. Change the assertion if you want early renewals.
- Each principal can only hold one subscription. Use different map keys to support multiples.
- Validate `period` if you want to prevent zero or extreme values.
- Consider explicit owner initialization for clarity.

--
