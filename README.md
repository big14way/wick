# Wick

Candle auction settlement for Uniswap v4. A hook that makes sandwich attacks structurally impossible on one lane and unprofitable on the other.

Built solo by Gwill (GitHub big14way) for Atrium UHI10. Theme: Sustainable Liquidity and MEV Protection.

## The problem

Sandwich bots extract hundreds of millions of dollars a year from AMM swappers. Every mitigation so far leans on one of three crutches: private orderflow (trust a relay), commit reveal (two transactions, bad UX), or batch auctions with a fixed close (the bot just waits for the last block and sandwiches the settlement itself). The fixed close is the weakness. If the attacker knows exactly when the batch ends, the endgame is a queue position race, which is the game MEV bots already win.

## The idea

Wick borrows the candle auction, a 17th century English auction format where bidding stayed open while a candle burned and the winner was whoever led when the flame died. Nobody knew when that would be. Polkadot revived the format for parachain auctions because it provably blunts last moment sniping. Wick brings it to swap settlement.

Orders accumulate during a window of blocks. After the window passes, a random close block inside the window is drawn and revealed retroactively. Every order at or before the close settles together at one uniform price per side. Orders after the close roll into the next epoch. An attacker cannot position around a close block that did not exist yet when their transaction landed.

## Two lanes

```
                            +--------------------+
        swap with           |                    |
        empty or 0x00 data  |   PROTECTED LANE   |
  ----------------------->  |                    |
                            |  custody in        |
                            |  beforeSwap,       |
                            |  ERC6909 claim,    |
                            |  bucket by block   |
                            +---------+----------+
                                      |
                        window ends,  v
                        random close  +----------+     +-----------+
                        drawn         | SETTLE   | --> | REDEEM    |
                        (VRF)         | net both |     | pro rata, |
                                      | sides,   |     | uniform   |
                                      | residual |     | price per |
                                      | to curve |     | side      |
                                      | bounded  |     +-----------+
                                      +----------+
                            +--------------------+
        swap with           |                    |
        0x01 data           |   INSTANT LANE     |
  ----------------------->  |                    |
                            |  executes now,     |
                            |  pays dynamic      |
                            |  anti MEV premium  |
                            |  as LP fee         |
                            +--------------------+
```

Protected lane. The hook takes custody of the swap input in beforeSwap (NoOp via BeforeSwapDelta), mints an ERC6909 claim token, and buckets the order by absolute block. Price does not move. There is nothing to sandwich because nothing touched the curve.

Instant lane. Executes immediately but pays a dynamic premium: a base fee, plus a volatility component from an EMA of tick movement, plus a heavy surcharge if the same origin address round trips direction in the same block (the sandwich signature). The premium is charged as the LP fee override, so every pip goes to liquidity providers. Toxic flow subsidizes the LPs it used to bleed.

## Settlement mechanics

1. First protected order lights the candle. The window is [epochStart, epochStart + maxSpan - 1].
2. After the window, anyone calls requestClose. The hook snapshots the pool price and asks the randomness provider for a word.
3. The provider fulfills. Close block = epochStart + minSpan - 1 + (word mod (maxSpan - minSpan + 1)).
4. Anyone calls settle. Opposing flow inside the epoch nets internally at the snapshot price without touching the curve. Only the residual imbalance crosses the pool, and it is bounded by a price limit of maxSettleDeviationTicks around the snapshot tick. Whatever the bound leaves unfilled is refunded pro rata.
5. Traders redeem claims for a pro rata share of the output plus any refund. Everyone on a side gets the same price. Orders after the close block roll into the next epoch automatically.

## Threat model, honestly

- Sandwiching a protected order: impossible. Custody means no price impact at order time, and the uniform clearing price means order position inside the epoch is irrelevant.
- Sniping the close: the close is drawn after the window ends and applied retroactively. When your transaction landed, the close did not exist.
- Attacking the settlement swap: the residual is public before settle executes. But netting means the residual is small, everyone shares one price so there is no victim slice to carve out, and the tick bound caps how far the settlement can move. Our test suite shows a textbook sandwich that nets +7.87 tokens against a vanilla pool loses 0.33 tokens against Wick on identical liquidity.
- Griefing the settle call: an attacker who pushes price past the bound after the snapshot cannot block settlement. The candle settles anyway; the residual simply fills nothing and comes back as a pro rata refund. The attack buys nothing but the cost of the shove. Proven in SettleGrief.t.sol.
- Randomness: the provider is pluggable. Production config uses Chainlink VRF 2.5. The blockhash provider included for local demos is proposer biasable and says so in its own comments.
- Volatility fee after chaos: a violent price move spikes the tick EMA and with it the instant fee, but the fee is hard capped at 10 percent (maxInstantFee) so the lane never consumes an entire input, and the EMA loses a quarter of its value for every quiet block, so the spike heals with time alone. Protected orders, settlement and redemption are unaffected throughout.
- Round trip detection keys on tx.origin, which catches the naive single wallet sandwich shape. A determined attacker splits across two origins and pays only the volatility premium twice. The surcharge raises the cost of the lazy attack, the custody lane removes the target of the sophisticated one.
- Cost of protection: the protected lane waits a few blocks. That is the product tradeoff, stated plainly: instant execution with a premium, or patient execution with structural immunity.

## Why this is new

Atrium publishes a dataset of every prior hookathon submission (715 rows, github.com/AtriumAcademy/UHI-Hook-Data). Searching it:

- "candle": 0 matches
- "uniform clearing" or "uniform price": 0 matches
- "probabilistic" (close or settlement): 0 matches

Nearest neighbors and how Wick differs:

- Async Swap (UHI4) and AsyncSwapHook (UHI7): async custody, but settlement timing is known and there is no batch clearing price.
- ZeanHook (UHI5): batching with commit reveal UX, fixed timing.
- VeiledBatch (UHI7): hides order contents, not settlement timing. Wick hides timing, which removes the deadline race entirely, and needs no second user transaction.

## Repository map

```
src/WickHook.sol                  the hook, both lanes, candle lifecycle, settlement
src/interfaces/IRandomness.sol    provider and consumer interfaces
src/randomness/ChainlinkVRFProvider.sol   production randomness, VRF 2.5
src/randomness/BlockhashProvider.sol      local demo randomness, biasable, labeled
script/00_DeployHook.s.sol        env driven deploy, mines hook flags, wires provider
test/WickHook.t.sol               7 tests: custody, uniform price, netting, fees, cancel, rollover
test/SandwichSim.t.sol            3 tests: vanilla pool vs Wick under the same sandwich
test/WickFuzz.t.sol               fuzz: pro rata, conservation, price bound, close range, gas
test/WickInvariant.t.sol          invariants over random lifecycle interleavings
test/SettleGrief.t.sol            settle griefing is temporary, keeper tip pays
script/keeper.sh                  polls the hook, drives close, reveal and settle
frontend/                         Vite + React + viem dashboard, the burning candle UI
```

## Run it

```
bash setup.sh        # clones forge-std, uniswap-hooks, hookmate and their submodules
forge test           # 49 tests: unit, sandwich sim, fuzz, invariant, guards, providers
```

Requires Foundry with solc 0.8.30 and via_ir (already pinned in foundry.toml).

Coverage beyond the unit tests: WickFuzz.t.sol fuzzes the pro rata redeem split, per side conservation, the settlement price bound, and the close range over 256 random sizings each. WickInvariant.t.sol drives random interleavings of orders, instants, cancels, draws, settlements and redeems (32 runs of 48 calls, zero tolerated reverts) and holds four invariants: claim liabilities never exceed hook held balances in either currency, every drawn close lands inside the window, and every settled epoch keeps refund at or below input per side. WickGuards.t.sol fires every guard revert and owner knob bound, and RandomnessProviders.t.sol covers both providers to 100 percent. forge coverage prints 98.77 percent lines, 91.89 percent branches and 100 percent functions across src. Findings from a self audit pass, each mapped to the test that proves it, live in docs/SECURITY_NOTES.md.

A gas snapshot lives in .gas-snapshot; the swap path costs, measured through the hookmate router in test_gas_protectedOrderSwap and test_gas_instantSwap, are 198096 gas for a protected order (custody plus claim mint, no curve crossing) and 176761 gas for an instant swap (dynamic fee plus volatility oracle update).

The sandwich receipts:

```
forge test --match-path "test/SandwichSim.t.sol" -vv
  vanilla sandwich attacker profit:  +7.8757 tokens
  same attack against Wick:          -0.3301 tokens
```

## Deploy

```
export PRIVATE_KEY=...
export RPC_URL=https://sepolia.base.org
# optional VRF (recommended for the real demo):
export VRF_COORDINATOR=...   # verify at docs.chain.link/vrf/v2-5/supported-networks
export VRF_KEYHASH=...
export VRF_SUBSCRIPTION_ID=...
forge script script/00_DeployHook.s.sol --rpc-url $RPC_URL --broadcast
```

Then set the printed hook address into script/base/BaseScript.sol (hookContract) and frontend/src/config.ts, create the pool with script/01_CreatePoolAndAddLiquidity.s.sol, and run the dashboard with `cd frontend && npm install && npm run dev`.

## Live deployments

Unichain Sepolia (chain 1301), primary demo. Randomness is the BlockhashProvider because no VRF grade service runs on Unichain Sepolia today (checked against both the Chainlink VRF 2.5 supported networks and the Pyth Entropy chain list). Fine for a demo, biasable by a proposer, not for value at risk; the provider interface is ready for whichever service arrives first.

| Contract | Address |
| --- | --- |
| WickHook | 0x22916F75eDB48a3d66fEB680bB428a901e1D30c8 |
| BlockhashProvider | 0x801A6D9eF9E96Fb2958B9F49E03cb73fA2CC5e11 |
| WICKA | 0x0FC24a0C237C5970e210b1338Ca2dA20d7Fd7831 |
| WICKB | 0xa97c20Fd92efeb66DD7458c9C5dfd3F2b7B2BA7e |

Pool id 0xe83effd1920066d6708f46a248bc87f5681c1fc2557b0b2c8ddaf9b551e16ffa, deployed at block 60721426.

Base Sepolia (chain 84532), production randomness path with Chainlink VRF 2.5 (coordinator 0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE, 30 gwei lane).

| Contract | Address |
| --- | --- |
| WickHook | 0x7cD1F7eC40dA2aF2E2502b19ed5C65ACC26Eb0C8 |
| ChainlinkVRFProvider | 0x1d48ad4b395Cd6810542d520027010738E73799B |
| WICKA | 0x581B822B34bEf5138f2CE6EaCE81384D553F70a8 |
| WICKB | 0x55D4e4714fbcE432A1B15f23FBD28E299AE5037d |

Pool id 0x5107a6be3ace50e5c996af151b592777d34a58e06cec809fc5f1f1bf3461897d, deployed at block 45902893. The ChainlinkVRFProvider is the subscription consumer (it is the contract that calls the coordinator).

## Judging criteria mapping

- Originality (30): first candle auction settlement hook, first uniform clearing price hook, receipts from the official dataset above.
- Execution (25): full lifecycle implemented and tested, custody matches the audited BaseAsyncSwap pattern, settlement is bounded and refund safe, pluggable VRF.
- Impact (20): protected lane removes the largest per user MEV tax; instant lane converts toxic flow into LP yield, which is sustainable liquidity in one sentence.
- Functionality (15): 26 passing tests including fuzz, invariant, and an adversarial sandwich simulation against a control pool.
- Presentation (10): live dashboard with the burning candle, demo video, this document.

## License

MIT
