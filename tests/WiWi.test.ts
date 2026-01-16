
import { describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";

const CONTRACT = "WiWi";
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const alice = accounts.get("wallet_1")!;
const bob = accounts.get("wallet_2")!;
const operator = accounts.get("wallet_3")!;
const mallory = accounts.get("wallet_4")!;

const MIN_RATE = 1_000_000n;
const RENEWAL_PERIOD = 10_080n;
const RATE_CHANGE_COOLDOWN = 1_440n;

const principal = (addr: string) => Cl.principal(addr);
const uint = (value: bigint) => Cl.uint(value);

const subscribe = (sender: string, receiver: string, rate = MIN_RATE, period = 10n) =>
  simnet.callPublicFn(CONTRACT, "subscribe", [principal(receiver), uint(rate), uint(period)], sender);

const getSubscription = (id: bigint) =>
  simnet.callReadOnlyFn(CONTRACT, "get-subscription", [uint(id)], deployer);

describe("subscribe", () => {
  it("creates a subscription, transfers funds, and indexes it", () => {
    const period = 5n;

    const receipt = subscribe(alice, bob, MIN_RATE, period);
    expect(receipt.result).toBeOk(uint(1n));
    const expectedExpiry = BigInt(simnet.blockHeight) + period;

    const subscription = getSubscription(1n);
    expect(subscription.result).toBeSome(
      Cl.tuple({
        subscriber: principal(alice),
        receiver: principal(bob),
        rate: uint(MIN_RATE),
        expiry: uint(expectedExpiry),
      }),
    );

    const index = simnet.callReadOnlyFn(
      CONTRACT,
      "get-subscription-id",
      [principal(alice), principal(bob)],
      deployer,
    );
    expect(index.result).toBeSome(uint(1n));

    const count = simnet.callReadOnlyFn(
      CONTRACT,
      "get-user-subscription-count",
      [principal(alice)],
      deployer,
    );
    expect(count.result).toBeUint(1n);

    const volume = simnet.callReadOnlyFn(CONTRACT, "get-total-volume", [], deployer);
    expect(volume.result).toBeUint(MIN_RATE);

    const transfer = receipt.events.find((event) => event.event === "stx_transfer_event");
    expect(transfer?.data.sender).toBe(alice);
    expect(transfer?.data.recipient).toBe(bob);
    expect(String(transfer?.data.amount)).toBe(MIN_RATE.toString());
  });

  it("rejects duplicate, low-rate, and self-subscription attempts", () => {
    const first = subscribe(alice, bob, MIN_RATE, 10n);
    expect(first.result).toBeOk(uint(1n));

    const duplicate = subscribe(alice, bob, MIN_RATE, 10n);
    expect(duplicate.result).toBeErr(uint(111n));

    const belowMin = subscribe(alice, operator, MIN_RATE - 1n, 5n);
    expect(belowMin.result).toBeErr(uint(101n));

    const selfSub = subscribe(alice, alice, MIN_RATE, 5n);
    expect(selfSub.result).toBeErr(uint(110n));
  });
});

describe("renew", () => {
  it("renews only after expiry and bumps expiry and volume", () => {
    const initial = subscribe(alice, bob, MIN_RATE, 1n);
    expect(initial.result).toBeOk(uint(1n));

    simnet.mineEmptyBlocks(1);

    const renew = simnet.callPublicFn(CONTRACT, "renew", [uint(1n)], alice);
    expect(renew.result).toBeOk(Cl.bool(true));
    const expectedExpiry = BigInt(simnet.blockHeight) + RENEWAL_PERIOD;

    const subscription = getSubscription(1n);
    expect(subscription.result).toBeSome(
      Cl.tuple({
        subscriber: principal(alice),
        receiver: principal(bob),
        rate: uint(MIN_RATE),
        expiry: uint(expectedExpiry),
      }),
    );

    const volume = simnet.callReadOnlyFn(CONTRACT, "get-total-volume", [], deployer);
    expect(volume.result).toBeUint(MIN_RATE * 2n);
  });

  it("fails if the subscription has not expired", () => {
    const sub = subscribe(alice, bob, MIN_RATE, 10n);
    expect(sub.result).toBeOk(uint(1n));

    const renew = simnet.callPublicFn(CONTRACT, "renew", [uint(1n)], alice);
    expect(renew.result).toBeErr(uint(103n));
  });
});

describe("change-subscription-rate", () => {
  it("updates the rate and enforces cooldown", () => {
    const period = 5n;
    const sub = subscribe(alice, bob, MIN_RATE, period);
    expect(sub.result).toBeOk(uint(1n));
    const expectedExpiry = BigInt(simnet.blockHeight) + period;

    const newRate = MIN_RATE + 500n;
    const change = simnet.callPublicFn(
      CONTRACT,
      "change-subscription-rate",
      [uint(1n), uint(newRate)],
      alice,
    );
    expect(change.result).toBeOk(Cl.bool(true));

    const updated = getSubscription(1n);
    expect(updated.result).toBeSome(
      Cl.tuple({
        subscriber: principal(alice),
        receiver: principal(bob),
        rate: uint(newRate),
        expiry: uint(expectedExpiry),
      }),
    );

    const cooldownRemaining = simnet.callReadOnlyFn(
      CONTRACT,
      "get-rate-change-cooldown-remaining",
      [uint(1n)],
      deployer,
    );
    expect(cooldownRemaining.result).toBeUint(RATE_CHANGE_COOLDOWN);

    const secondChange = simnet.callPublicFn(
      CONTRACT,
      "change-subscription-rate",
      [uint(1n), uint(newRate + 100n)],
      alice,
    );
    expect(secondChange.result).toBeErr(uint(106n));
  });
});

describe("cancellation", () => {
  it("allows subscriber to cancel and cleans up indices and counts", () => {
    const sub = subscribe(alice, bob, MIN_RATE, 5n);
    expect(sub.result).toBeOk(uint(1n));

    const cancel = simnet.callPublicFn(CONTRACT, "cancel-subscription", [uint(1n)], alice);
    expect(cancel.result).toBeOk(Cl.bool(true));

    const subscription = getSubscription(1n);
    expect(subscription.result).toBeNone();

    const index = simnet.callReadOnlyFn(
      CONTRACT,
      "get-subscription-id",
      [principal(alice), principal(bob)],
      deployer,
    );
    expect(index.result).toBeNone();

    const count = simnet.callReadOnlyFn(
      CONTRACT,
      "get-user-subscription-count",
      [principal(alice)],
      deployer,
    );
    expect(count.result).toBeUint(0n);
  });

  it("requires admin role for admin cancellation and honours operator list", () => {
    const sub = subscribe(alice, bob, MIN_RATE, 5n);
    expect(sub.result).toBeOk(uint(1n));

    const unauthorized = simnet.callPublicFn(
      CONTRACT,
      "admin-cancel-subscription",
      [uint(1n)],
      mallory,
    );
    expect(unauthorized.result).toBeErr(uint(100n));

    const addOp = simnet.callPublicFn(CONTRACT, "add-operator", [principal(operator)], deployer);
    expect(addOp.result).toBeOk(Cl.bool(true));

    const adminCancel = simnet.callPublicFn(
      CONTRACT,
      "admin-cancel-subscription",
      [uint(1n)],
      operator,
    );
    expect(adminCancel.result).toBeOk(Cl.bool(true));

    const subscription = getSubscription(1n);
    expect(subscription.result).toBeNone();
  });
});

describe("pause controls", () => {
  it("blocks actions while paused and allows unpausing", () => {
    const pause = simnet.callPublicFn(CONTRACT, "emergency-pause", [uint(5n)], deployer);
    expect(pause.result).toBeOk(Cl.bool(true));

    const blocked = subscribe(alice, bob, MIN_RATE, 5n);
    expect(blocked.result).toBeErr(uint(107n));

    const unpause = simnet.callPublicFn(CONTRACT, "unpause-contract", [], deployer);
    expect(unpause.result).toBeOk(Cl.bool(true));

    const allowed = subscribe(alice, bob, MIN_RATE, 5n);
    expect(allowed.result).toBeOk(uint(1n));
  });
});
