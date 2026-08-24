// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {WickFixture} from "./utils/WickFixture.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice The settle griefing edge from the threat model. An attacker who shoves
/// the price outside the settlement bound after the reveal cannot block settlement:
/// the candle settles anyway, the residual fills nothing and comes back as refund.
/// Also proves the keeper tip pays on the normal path and that the instant fee is
/// hard capped and heals with quiet time.
contract SettleGriefTest is WickFixture {
    using StateLibrary for IPoolManager;

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        _setUpWick();
        // Tip the settle caller 0.1 percent of each side's output.
        hook.setFees(3000, 25, 30_000, 500, 1000);
    }

    function test_settle_neverBricks_refundsBeyondBound() public {
        uint64 start = uint64(block.number);
        _placeProtected(true, 5e18, alice);

        // Window over, price snapshotted, close revealed.
        vm.roll(start + MAX_SPAN);
        hook.requestClose(poolKey);
        randomness.fulfill(randomness.lastRequestId(), 3);
        (,,,,, int24 snapshotTick,,,) = hook.pools(poolId);

        // Grief: shove the price far below snapshot minus the deviation bound.
        _swapInstant(true, 30e18);
        (, int24 tickShoved,,) = poolManager.getSlot0(poolId);
        assertLt(tickShoved, snapshotTick - hook.maxSettleDeviationTicks(), "price shoved past the bound");

        // Settlement still goes through. The residual fills nothing and refunds.
        vm.prank(keeper);
        hook.settle(poolKey);

        assertEq(hook.epochOfBlock(poolId, start), 1, "epoch settled despite the shove");
        (,, uint128 in0,, uint128 out1For0,, uint128 refund0,) = hook.epochs(poolId, 1);
        assertEq(in0, 5e18, "full input recorded");
        assertEq(out1For0, 0, "nothing filled beyond the bound");
        assertEq(refund0, 5e18, "everything refunded");

        // The shove did not touch the settlement price either: the pool price is
        // exactly where the attacker's own swap left it, no settlement swap ran.
        (, int24 tickAfter,,) = poolManager.getSlot0(poolId);
        assertEq(tickAfter, tickShoved, "no settlement swap executed");

        // Alice redeems her full input back.
        uint256 before = currency0.balanceOf(alice);
        vm.prank(alice);
        hook.redeem(poolKey, start, true, alice);
        assertEq(currency0.balanceOf(alice) - before, 5e18, "full refund redeemed");
    }

    function test_settle_paysKeeperTipOnNormalPath() public {
        uint64 start = uint64(block.number);
        _placeProtected(true, 5e18, alice);

        vm.roll(start + MAX_SPAN);
        hook.requestClose(poolKey);
        randomness.fulfill(randomness.lastRequestId(), 3);

        uint256 keeperBal1Before = currency1.balanceOf(keeper);
        vm.prank(keeper);
        hook.settle(poolKey);

        assertEq(hook.epochOfBlock(poolId, start), 1, "epoch settled");
        assertGt(currency1.balanceOf(keeper) - keeperBal1Before, 0, "keeper tip paid");

        uint256 aliceOut = _redeem(alice, start, true);
        assertGt(aliceOut, 0, "claim redeems");
    }

    function test_instantFee_hardCappedAtCeiling() public {
        // A violent round trip spikes the EMA far past what the cap allows while
        // leaving the price near par, so the output check below stays meaningful.
        vm.roll(block.number + 1);
        _swapInstant(true, 250e18);
        vm.roll(block.number + 1);
        _swapInstant(false, 80e18);
        vm.roll(block.number + 1);

        (,,,,,,,, uint24 volEma) = hook.pools(poolId);
        assertGt(uint256(volEma) * 25, uint256(hook.maxInstantFee()), "EMA alone would exceed the cap");

        vm.recordLogs();
        _swapInstant(true, 1e17);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("InstantFeeCharged(bytes32,address,uint24,bool)");
        uint24 charged;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                (charged,) = abi.decode(logs[i].data, (uint24, bool));
            }
        }
        assertEq(charged, hook.maxInstantFee(), "fee clamped to the ceiling");

        // Even at the ceiling the swap still delivers output: 10 percent fee,
        // not a lane that consumes the whole input.
        uint256 before = currency1.balanceOf(address(this));
        _swapInstant(true, 1e18);
        assertGt(currency1.balanceOf(address(this)) - before, 8e17, "output survives the capped fee");
    }

    function test_volEma_decaysWithQuietTime() public {
        _swapInstant(true, 30e18);
        vm.roll(block.number + 1);
        _swapInstant(false, 30e18);
        vm.roll(block.number + 1);
        _swapInstant(true, 1e15);
        (,,,,,,,, uint24 emaHot) = hook.pools(poolId);
        assertGt(emaHot, 0, "EMA hot after the move");

        // Forty quiet blocks round the decayed EMA to zero, so the next swap's
        // blended EMA collapses to just that swap's own move.
        vm.roll(block.number + 45);
        _swapInstant(true, 1e15);
        (,,,,,,,, uint24 emaCold) = hook.pools(poolId);
        assertLt(emaCold, emaHot / 10, "quiet time healed the EMA");
    }
}
