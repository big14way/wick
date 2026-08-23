// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {WickFixture} from "./utils/WickFixture.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice The settle griefing edge from the threat model, proven both ways: an
/// attacker who shoves the price outside the settlement bound after the reveal
/// makes settle revert (griefing, funds stay custodied), and the moment price
/// returns inside the bound the same settle succeeds, pays the keeper tip, and
/// every claim redeems.
contract SettleGriefTest is WickFixture {
    using StateLibrary for IPoolManager;

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        _setUpWick();
        // Tip the settle caller 0.1 percent of each side's output.
        hook.setFees(3000, 25, 30_000, 500, 1000);
    }

    function test_settle_bricksOutsideBoundThenRecovers() public {
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

        // Settlement cannot start a swap whose price limit is already exceeded.
        vm.prank(keeper);
        vm.expectRevert();
        hook.settle(poolKey);

        // Funds are custodied, nothing was lost, the epoch is simply waiting.
        (,,, uint40 epochCount,,,,,) = hook.pools(poolId);
        assertEq(epochCount, 0, "epoch not settled while bricked");

        // Price returns inside the bound and the very same settle succeeds.
        _swapInstant(false, 30e18);
        (, int24 tickBack,,) = poolManager.getSlot0(poolId);
        assertGt(tickBack, snapshotTick - hook.maxSettleDeviationTicks(), "price back inside the bound");

        uint256 keeperBal1Before = currency1.balanceOf(keeper);
        vm.prank(keeper);
        hook.settle(poolKey);

        // Epoch settled, keeper earned the tip, the claim redeems.
        assertEq(hook.epochOfBlock(poolId, start), 1, "epoch settled after recovery");
        (,, uint128 in0,,,, uint128 refund0,) = hook.epochs(poolId, 1);
        assertEq(in0, 5e18, "full input recorded");
        assertLe(refund0, in0, "refund conservation");
        assertGt(currency1.balanceOf(keeper) - keeperBal1Before, 0, "keeper tip paid");

        uint256 aliceOut = _redeem(alice, start, true);
        assertGt(aliceOut, 0, "claim redeems after recovery");
    }
}
