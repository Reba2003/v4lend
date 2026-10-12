# Hook AUTO_LEND redeems all shares at once: a withdrawal-limited lend vault strands the position and bricks `autoLendForceExit` (V4LE-96 not applied to the hook)

**Severity:** Medium
**Files:** `src/hook/RevertHookAutoLendActions.sol` (`autoLendWithdraw`, `autoLendForceExit`), `src/hook/RevertHookExecution.sol` (`_handleAutoLend`)

## Summary

The hook's AUTO_LEND mode parks an out-of-range position's idle token in an ERC4626 vault and records the shares in `_positionStates[tokenId].autoLendShares`. Every exit path redeems that whole balance in one call:

```solidity
// RevertHookAutoLendActions.autoLendWithdraw
try IERC4626(state.autoLendVault).redeem(shares, address(this), address(this)) returns (uint256 amount) { ... }
catch (bytes memory reason) { emit HookAutoLendFailed(...); emit HookActionFailed(tokenId, Mode.AUTO_LEND); }

// RevertHookAutoLendActions.autoLendForceExit
uint256 redeemedAmount = IERC4626(state.autoLendVault).redeem(shares, address(this), address(this));
```

ERC4626 explicitly allows `maxRedeem(owner)` to be below the owner's balance. Withdrawal limits, cooldowns and queues all do this, and so does the protocol's own `V4Vault`, whose `maxRedeem` is capped by idle cash and whose `_withdraw` reverts with `InsufficientLiquidity` when utilization is high. When the vault cannot pay out the full recorded balance:

1. **The automatic withdrawal fails, and its trigger is used up.** When the price returns to the range, `_afterSwap` pops the withdrawal node and calls `autoLendWithdraw`. The full `redeem` reverts inside the `try`, the action emits `HookActionFailed`, and nothing re-arms the trigger (`AUDIT-ACCEPTED-HOOK-TRIGGER-CONSUME`). The position stays lent with zero liquidity, and nothing retries the withdrawal automatically.
2. **The owner's escape hatch reverts outright.** `autoLendForceExit` also redeems every share, so it reverts even when almost all of them are redeemable (the PoC shows a limit of `shares - 1` is enough to block it). It never hands over the part that could be redeemed, and it cannot hand over the vault shares themselves, because the hook holds them and keeps them out of every sweep (`_custodiedShares`).

The owner's principal stays locked inside the hook until the vault can pay out the entire recorded balance in a single call. For a lending vault near full utilization, that is unbounded in time. Re-arming with `setPositionConfig` doesn't help, because every retry hits the same all-or-nothing `redeem`.

## This was already fixed for the standalone automator

The team accepted this exact issue as a **Medium** for the standalone `AutoLend` (Scan #2, **V4LE-96**) and fixed it there:

- `AutoLend.withdraw` redeems `min(recorded shares, vault.maxRedeem)` and keeps the leftover recorded.
- `AutoLend.forceExit` redeems what it can and transfers the leftover vault shares to the NFT owner.

The hook implements the same strategy over the same kind of vault, but neither function got the fix. The ledger entry for V4LE-96 only covers `src/automators/AutoLend.sol`.

## Proof of concept

`test/hook/PocHookAutoLendRedeemLimit.t.sol` uses the repository's own `RevertHookTest` harness (real PoolManager, PositionManager and hook stack) and `LimitedRedeemERC4626Vault` (the mock the team wrote for V4LE-96).

```
forge test --offline --match-path test/hook/PocHookAutoLendRedeemLimit.t.sol --match-test testPoC -vvv
[PASS] testPoC_lockLastsAsLongAsTheLimit()
[PASS] testPoC_triggeredWithdrawFailsAndForceExitIsBricked()
```

`testPoC_triggeredWithdrawFailsAndForceExitIsBricked`:
1. A hooked position is configured for `MODE_AUTO_LEND`. A swap pushes the price below the range, and the hook removes the liquidity and deposits token0 into the lend vault. The shares are recorded and held by the hook.
2. The vault's `maxRedeem` is set to half of the hook's shares.
3. A swap brings the price back into the range. The withdrawal trigger fires and fails: `autoLendShares` is unchanged and the position still has 0 liquidity.
4. `hook.autoLendForceExit(tokenId)` reverts with `ERC4626: redeem more than max`, even though half the shares are redeemable.
5. The owner holds no assets and no shares. All shares remain in the hook.

`testPoC_lockLastsAsLongAsTheLimit` shows that a limit of `shares - 1` already blocks `autoLendForceExit`, and that it only succeeds once the limit is fully removed.

## Impact

Any user of hook AUTO_LEND loses access to their principal for as long as the configured lend vault cannot redeem the full recorded balance at once. Funds aren't permanently lost, but they are locked for an unbounded period with no partial exit. For `V4Vault` used as the lend vault, the lock lasts until borrowers repay or are liquidated. This matches the impact and severity the protocol accepted for V4LE-96.

## Recommended mitigation

Apply the V4LE-96 fix to the hook:

- **`autoLendWithdraw`:** redeem `min(autoLendShares, vault.maxRedeem(address(this)))`. Re-enter with the redeemed amount and keep the leftover in `autoLendShares`, `autoLendAmount` and `_custodiedShares`, scaling the principal pro rata. Re-arm the withdrawal trigger while a leftover remains.
- **`autoLendForceExit`:** redeem what is redeemable now, release the full amount from `_custodiedShares`, and transfer the leftover vault shares to the owner. Take no protocol fee on the shares transferred.
