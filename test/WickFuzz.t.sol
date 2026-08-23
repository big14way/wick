// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {WickFixture} from "./utils/WickFixture.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Fuzzed properties of the settlement math. Sizes and the drawn close are
/// random; the pro rata split, per side conservation, and the settlement price
/// bound must hold for all of them.
contract WickFuzzTest is WickFixture {
    using StateLibrary for IPoolManager;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        _setUpWick();
    }

    /// @dev Two owners share one bucket (same block, same side). Redeem must split
    /// the epoch output pro rata to their claim sizes, and the hook must never pay
    /// out more than the epoch recorded.
    function testFuzz_redeem_proRata(uint96 aRaw, uint96 bRaw, uint64 word) public {
        uint256 a = bound(uint256(aRaw), 1e9, 20e18);
        uint256 b = bound(uint256(bRaw), 1e9, 20e18);
        uint64 start = uint64(block.number);

        _placeProtected(true, a, alice);
        _placeProtected(true, b, bob);

        vm.roll(start + MAX_SPAN);
        _drawAndSettle(word);

        (,,,, uint128 out1For0,, uint128 refund0,) = hook.epochs(poolId, 1);

        uint256 aliceOut = _redeem(alice, start, true);
        uint256 bobOut = _redeem(bob, start, true);

        // Pro rata: aliceOut / bobOut == a / b, up to floor rounding.
        assertApproxEqAbs(aliceOut * b, bobOut * a, a + b, "pro rata split");

        // The hook never pays more currency1 than the epoch recorded, and at most
        // one wei of dust per claimant stays behind.
        assertLe(aliceOut + bobOut, out1For0, "no overpayment");
        assertLe(out1For0 - (aliceOut + bobOut), 2, "dust bounded");
        assertLe(refund0, a + b, "refund cannot exceed input");
    }

    /// @dev Random opposing flows. After settlement: refunds never exceed inputs,
    /// the pool tick stays inside the deviation bound around the snapshot, and all
    /// claims remain fully backed by the hook's balances at the pool manager.
    function testFuzz_netting_conservation(uint96 xRaw, uint96 yRaw, uint64 word) public {
        uint256 x = bound(uint256(xRaw), 1e9, 20e18);
        uint256 y = bound(uint256(yRaw), 1e9, 20e18);
        uint64 start = uint64(block.number);

        _placeProtected(true, x, alice);
        _placeProtected(false, y, bob);

        vm.roll(start + MAX_SPAN);
        hook.requestClose(poolKey);
        randomness.fulfill(randomness.lastRequestId(), word);
        (,,,,, int24 snapshotTick,,,) = hook.pools(poolId);
        hook.settle(poolKey);

        (,, uint128 in0, uint128 in1, uint128 out1For0, uint128 out0For1, uint128 refund0, uint128 refund1) =
            hook.epochs(poolId, 1);

        assertEq(in0, x, "epoch recorded side zero");
        assertEq(in1, y, "epoch recorded side one");
        assertLe(refund0, in0, "refund0 conservation");
        assertLe(refund1, in1, "refund1 conservation");

        // Settlement never moved the pool past the bound around the snapshot.
        (, int24 tickAfter,,) = poolManager.getSlot0(poolId);
        int24 dev = tickAfter >= snapshotTick ? tickAfter - snapshotTick : snapshotTick - tickAfter;
        assertLe(int256(dev), int256(hook.maxSettleDeviationTicks()) + 1, "settle price bound");

        // Every claim is redeemable and fully backed.
        uint256 aliceOut = _redeem(alice, start, true);
        uint256 bobOut = _redeem(bob, start, false);
        assertLe(aliceOut, out1For0, "side zero payout backed");
        assertLe(bobOut, out0For1, "side one payout backed");

        // After all redeems the hook holds no more than rounding dust for this epoch.
        uint256 c0Id = uint256(uint160(Currency.unwrap(currency0)));
        uint256 c1Id = uint256(uint160(Currency.unwrap(currency1)));
        assertLe(poolManager.balanceOf(address(hook), c0Id), 2, "currency0 dust only");
        assertLe(poolManager.balanceOf(address(hook), c1Id), 2, "currency1 dust only");
    }

    /// @dev The drawn close always lands inside [start + minSpan - 1, start + maxSpan - 1].
    function testFuzz_close_alwaysInWindow(uint256 word) public {
        uint64 start = uint64(block.number);
        _placeProtected(true, 1e18, alice);

        vm.roll(start + MAX_SPAN);
        hook.requestClose(poolKey);
        randomness.fulfill(randomness.lastRequestId(), word);

        (, uint64 close,,,,,,,) = hook.pools(poolId);
        assertGe(close, start + MIN_SPAN - 1, "close not before earliest");
        assertLe(close, start + MAX_SPAN - 1, "close not after window");
    }

    // ---------------------------------------------------------------
    // Gas: printed numbers for the README, also captured by forge snapshot
    // ---------------------------------------------------------------

    function test_gas_protectedOrderSwap() public {
        bytes memory hookData = abi.encode(uint8(0), alice);
        uint256 g = gasleft();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        console2.log("protected order swap gas:", g - gasleft());
    }

    function test_gas_instantSwap() public {
        bytes memory hookData = abi.encode(uint8(1));
        uint256 g = gasleft();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        console2.log("instant lane swap gas:", g - gasleft());
    }
}
