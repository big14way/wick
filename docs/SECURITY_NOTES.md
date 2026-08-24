# Security notes

A self audit. Wick has not had an external audit, so this document does what a hackathon can do instead: name every sharp edge found, say what was done about it, and map each safety claim to a test that proves it. Numbers below were printed by real runs on Aug 24 2026.

## Scope and tools

- src/WickHook.sol, src/randomness/BlockhashProvider.sol, src/randomness/ChainlinkVRFProvider.sol
- forge test: 46 tests passing (unit, sandwich simulation, fuzz, invariant, guard paths, providers)
- forge coverage (ir-minimum): 99.35 percent lines, 98.39 percent statements, 92.65 percent branches, 100 percent functions across src
- forge lint: 15 warnings, all unsafe-typecast, dispositioned below
- Invariant campaign: random interleavings of orders, instants, cancels, draws, settles and redeems, 32 runs of 48 calls, zero tolerated reverts, holding solvency in both currencies, close in window, and refund at most input per side

## Claims mapped to tests

| Claim | Test |
| --- | --- |
| Protected order custody never moves the price | test_protected_takesCustodyAndMintsClaim |
| Claim liabilities always backed by hook balances | invariant_hookSolventCurrency0 and 1 |
| Close block always inside [start + minSpan - 1, start + maxSpan - 1] | testFuzz_close_alwaysInWindow, invariant_closeAlwaysInWindow |
| Redeem splits pro rata, never overpays, dust bounded | testFuzz_redeem_proRata |
| Refund never exceeds input per side | testFuzz_netting_conservation, invariant_epochConservation |
| Settlement price move bounded around the snapshot | testFuzz_netting_conservation |
| Settle griefing delays but cannot steal, recovery works, tip pays | test_settle_bricksOutsideBoundThenRecovers |
| Sandwich attack unprofitable against Wick | test_wick_protectedVictimStarvesTheSandwich |
| Every guard revert fires | WickGuards.t.sol, 13 tests |
| Both randomness providers gate callers and fulfill once | RandomnessProviders.t.sol, 7 tests |

## Findings and dispositions

1. Settle reverts when price already sits beyond the deviation bound. The residual swap cannot start (v4 rejects a price limit already exceeded), so settle reverts until price returns inside the bound. Funds stay custodied and are never lost. This is the documented griefing edge: it delays, it does not steal. Proven both directions in SettleGrief.t.sol. The keeper script detects repeated settle reverts and prints the recovery instruction.

2. Fifteen unsafe-typecast lint warnings, all accepted deliberately. The uint128 casts on order input are guarded by an explicit AmountTooLarge check in beforeSwap. The casts inside settle truncate values already bounded by uint128 bucket sums and by v4 swap deltas, which fit int128 by protocol construction. The uint24 fee cast follows an explicit clamp to MAX_LP_FEE. The source is not being churned to silence a linter this close to submission; the reasoning lives here instead.

3. tx.origin is used for two things: the default claim owner when hookData is empty, and same block round trip detection on the instant lane. The owner default is a convenience with an explicit override (encode the owner in hookData); routers that batch for many users should always pass the override. Round trip detection catches the naive single wallet sandwich shape only; an attacker splitting across two origins pays the volatility premium without the surcharge. The custody lane, not the surcharge, is the defense against sophisticated attackers.

4. Instant fee can pin at the 100 percent cap after a violent price move. The volatility EMA can spike so high that the clamped fee eats any instant input entirely, which effectively pauses the instant lane until the EMA decays (a quarter of the gap per block containing a swap). Protected orders, settlement and redemption are unaffected. The owner can also lower volFeePerTick live within its bound. Observed and recovered on the live Unichain deployment; the recovery needs nothing but time or dust swaps.

5. Blockhash randomness is proposer biasable. The provider exists because no VRF grade service runs on Unichain Sepolia today: verified against the Chainlink VRF 2.5 supported networks page and the Pyth Entropy chain list on Aug 24 2026, neither serves it. It is labeled demo only in code, README and UI. The production path, ChainlinkVRFProvider, runs live on Base Sepolia with a settled epoch to show. The provider interface is one function each way, ready for whichever service reaches Unichain first.

6. Owner powers are bounded. setFees clamps every parameter (base at most 10 percent, batch at most 1 percent, surcharge at most 20 percent, tip at most 0.1 percent), setMaxSettleDeviationTicks stays within [10, 5000], setConsumer on both providers is one time and deployer only. There is no upgradeability, no pause, no way for the owner to touch custodied funds.

7. Reentrancy surface. unlockCallback is poolManager only. Payouts burn the hook's ERC6909 claims and transfer real tokens last. ERC6909 mints and burns have no receiver callbacks. Standard ERC20s only: fee on transfer and rebasing tokens are unsupported and would break custody accounting, the same caveat as most v4 hooks.

8. Rounding. All pro rata math floors, so the hook can only underpay dust, never overpay. Fuzz asserts payouts at or below recorded totals with dust bounded to a couple of wei per epoch, and the invariant campaign holds solvency through random sequences.

## Known limits, stated plainly

- The protected lane costs a few blocks of latency by design.
- Dynamic fee pools are not routed natively by the Uniswap interface; use the bundled dashboard or any custom router.
- Deployed testnet bytecode predates none of the source changes: src has not changed since the first commit, so the published addresses run exactly the code in this repo.
