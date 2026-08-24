# Wick demo video script

Target length: 4 minutes 45 seconds, hard cap 5 minutes. Record your own voice in a quiet room. Unlisted YouTube upload is fine for submission. Screen record at 1080p or better. Practice the whole thing twice before recording, the timings below assume a calm reading pace.

Prep before recording:

- Dashboard running with the hook deployed and at least one settled epoch already on screen.
- A terminal with big font ready to run `forge test --match-path "test/SandwichSim.t.sol" -vv`.
- The keeper running (script/keeper.sh) so close, reveal and settle happen on their own during the demo, and a wallet connected with test tokens for the on camera swap.
- README open in a tab for the architecture diagram.
- Close notifications. Full screen the windows you will show.

---

## 0:00 to 0:40. The problem

On screen: a slide or the README problem section.

Say:

"Sandwich bots take hundreds of millions of dollars a year from ordinary swappers. Every fix so far has a weakness. Private orderflow means trusting a relay. Commit reveal means two transactions. And batch auctions with a fixed closing time just move the fight to the last block, because if the attacker knows exactly when the batch ends, they camp the deadline. That deadline race is the one game MEV bots always win."

## 0:40 to 1:10. The idea

On screen: dashboard with the burning candle.

Say:

"Wick removes the deadline. It borrows the candle auction, a format from seventeenth century England where bidding stayed open while a candle burned, and the winner was whoever led when the flame died. Nobody knew when that would be. Polkadot used the same trick for its parachain auctions. Wick brings it to swap settlement on Uniswap v4. Orders collect during a window, then a random close block inside that window is drawn after the fact. You cannot snipe a deadline that did not exist when your transaction landed."

## 1:10 to 2:00. Architecture

On screen: README diagram, then briefly WickHook.sol scrolled slowly.

Say:

"One hook, two lanes, chosen per swap. The protected lane takes custody of your input in beforeSwap, so the price does not move and there is nothing to sandwich. You get an ERC6909 claim token. When the candle dies, everything up to the close settles at one uniform price per side. Opposing orders net against each other without touching the curve, only the leftover imbalance crosses the pool, and that crossing is bounded to a tick range with anything unfilled refunded. The instant lane is for people who cannot wait. It executes immediately but pays a dynamic premium, a base fee plus a volatility component, plus a heavy surcharge if the same address round trips direction inside one block, which is the sandwich signature. Every pip of that premium is the LP fee, so toxic flow now pays the liquidity providers it used to bleed. The randomness provider is pluggable: this Unichain demo draws from a blockhash provider since Chainlink does not serve Unichain Sepolia yet, and the same hook runs live on Base Sepolia with real Chainlink VRF 2.5, which is the production path."

## 2:00 to 3:00. Live demo

On screen: dashboard plus the command terminal, side by side.

Do while talking: connect the wallet, place a protected swap from the swap card, show the order appear in the feed and the candle burning, let the keeper drive the close, the reveal and the settlement on its own, then redeem from the claims list. The whole cycle takes about thirty seconds on Unichain.

Say:

"Here is the live pool on testnet. I place a protected swap straight from the dashboard. Watch the order feed. The pool price has not moved, my input is in custody and I hold a claim. The candle burns down the window, and the striped band is where it might die. Nobody knows where, including me. The window ends, the keeper requests the close, and the draw comes back. There is the burn mark, the candle died at this block. Settlement runs by itself. Both sides cleared at one price, the residual crossed the pool inside the bound, and I redeem my claim for the output."

## 3:00 to 3:40. The receipts

On screen: terminal, run the sandwich sim live.

Say:

"Do not take my word for it. This test suite builds two pools with identical liquidity, one vanilla, one with Wick, and runs the same sandwich attack against both. Against the vanilla pool the attacker clears seven point eight tokens of pure profit. Against Wick, the protected victim moves no price, so the attacker front runs into nothing, pays the instant lane premium twice, including the round trip surcharge, and finishes down zero point three three tokens. The sandwich is not discouraged. It is starved."

Read the actual numbers from the terminal output as they print, they should match.

## 3:40 to 4:10. Sustainable liquidity

On screen: dashboard instant lane panel with the fee chips.

Say:

"The theme is sustainable liquidity, and here is the sentence. Wick converts MEV pressure into LP yield. Impatient and toxic flow pays a premium that goes entirely to liquidity providers, patient flow gets structural protection for free, and the pool keeps both kinds of volume instead of losing users to private relays."

## 4:10 to 4:45. Novelty and roadmap

On screen: the UHI-Hook-Data search results or the README novelty section.

Say:

"Atrium publishes every prior hookathon submission, seven hundred and fifteen of them. Zero candle auctions. Zero uniform clearing hooks. Zero probabilistic closes. The nearest neighbors batch or delay swaps, but every one of them has a settlement time the attacker can see coming. Next steps: launch protection mode for new token pools where the candle runs continuously from block one, a keeper network for settlement calls, and gas tuning for mainnet. The repo has twenty six passing tests including fuzz and invariant coverage, the threat model written honestly, and everything you need to run it yourself. Thanks for watching."

## 4:45. End card

On screen: repo URL, Wick wordmark, your handles.

---

Recording tips:

- Do the live demo section in one take if possible. If the VRF fulfillment is slow on testnet, pre record that segment earlier and cut it in, the draw taking a minute is normal and boring on camera.
- Keep the cursor still when not pointing at something.
- If you stumble on a line, pause two seconds and reread the whole sentence. Editing a pause is easy, editing a mid sentence stumble is not.
- Export at 1080p, check audio levels before uploading.
