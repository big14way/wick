// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {IRandomnessProvider, IRandomnessConsumer} from "./interfaces/IRandomness.sol";

/// @title WickHook
/// @notice Candle auction settlement for Uniswap v4.
///
/// Two lanes on every pool:
///
/// Protected lane (default). The hook takes custody of the swap input in beforeSwap
/// (a NoOp via BeforeSwapDelta), mints the swapper an ERC6909 claim, and holds the
/// order in the current epoch. Epochs have no known end: after the window elapses,
/// a random close block is drawn through a pluggable randomness provider and revealed
/// retroactively, the candle auction mechanism. At settlement, opposing flow nets
/// internally at the snapshot price, only the residual crosses the curve under a
/// price bound, and every order in the epoch clears at one uniform price per side.
/// No before and after inside a batch means a protected swap cannot be sandwiched.
///
/// Instant lane. Anyone who cannot wait executes immediately and pays a dynamic
/// anti-MEV premium priced from live toxicity signals (volatility, same-block round
/// trips). The premium is charged as the LP fee, so it flows straight to in-range LPs.
///
/// Reference points: the async custody pattern follows the official v4 async swap
/// design (see also OpenZeppelin uniswap-hooks BaseAsyncSwap). The candle close is
/// the mechanism Polkadot used for parachain auctions, applied to an AMM.
contract WickHook is BaseHook, ERC6909, Owned, IRandomnessConsumer {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ---------------------------------------------------------------
    // Types and storage
    // ---------------------------------------------------------------

    enum Phase {
        Open, // window running or idle, orders accumulate
        Drawing, // window elapsed, randomness requested, close unknown
        Revealed // close block known, settlement pending
    }

    struct PoolState {
        uint64 epochStart; // first block of the current window (0 until first order)
        uint64 revealedClose; // candle close block, set on reveal
        Phase phase;
        uint40 epochCount; // last settled epoch id, ids start at 1
        uint160 snapshotSqrtPriceX96; // pool price captured at requestClose
        int24 snapshotTick;
        int24 lastTick; // toxicity oracle
        uint64 lastTickBlock;
        uint24 volEma; // EMA of absolute tick move per block with a swap
    }

    struct Bucket {
        uint128 in0; // currency0 committed by zeroForOne orders in this block
        uint128 in1; // currency1 committed by oneForZero orders in this block
    }

    struct EpochResult {
        uint64 startBlock;
        uint64 closeBlock;
        uint128 in0; // settled totals per side
        uint128 in1;
        uint128 out1For0; // currency1 owed to the zeroForOne side
        uint128 out0For1; // currency0 owed to the oneForZero side
        uint128 refund0; // unfilled currency0 returned to the zeroForOne side
        uint128 refund1; // unfilled currency1 returned to the oneForZero side
    }

    mapping(PoolId => PoolState) public pools;
    mapping(PoolId => mapping(uint256 => Bucket)) public buckets; // keyed by absolute block
    mapping(PoolId => mapping(uint256 => uint40)) public epochOfBlock; // 0 until that block settles
    mapping(PoolId => mapping(uint40 => EpochResult)) public epochs;
    mapping(bytes32 => PoolId) internal _pendingKeyPool; // randomness key to pool

    IRandomnessProvider public randomnessProvider;

    // Candle geometry, in blocks. Window is [epochStart, epochStart + maxSpan - 1].
    // The close lands in [epochStart + minSpan - 1, epochStart + maxSpan - 1].
    uint64 public immutable minSpan;
    uint64 public immutable maxSpan;

    // Settlement price bound around the snapshot tick. The residual swap cannot move
    // the pool beyond this, so attacking the settlement transaction is capped.
    int24 public maxSettleDeviationTicks = 200;

    // Fee parameters, all in Uniswap fee units (hundredths of a bip, 1e6 = 100 percent).
    uint24 public instantBaseFee = 3000; // 0.30 percent floor for the instant lane
    uint24 public volFeePerTick = 25; // added per EMA tick of realized volatility
    uint24 public roundTripSurcharge = 30_000; // 3 percent extra on same-block round trips
    uint24 public batchFee = 500; // 0.05 percent on the settlement residual, clean flow
    uint16 public keeperTipPips = 0; // share of epoch output paid to the settle caller

    // Same-block round-trip detector: (pool, block, origin) to direction bitmask.
    mapping(bytes32 => uint8) internal _dirSeen;

    uint8 internal constant ACTION_SETTLE = 1;
    uint8 internal constant ACTION_PAY = 2;

    // ---------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------

    event OrderPlaced(
        PoolId indexed poolId,
        address indexed owner,
        uint64 blockNumber,
        bool zeroForOne,
        uint128 amountIn,
        uint256 claimId
    );
    event OrderCancelled(PoolId indexed poolId, address indexed owner, uint64 blockNumber, bool zeroForOne);
    event CandleLit(PoolId indexed poolId, uint64 epochStart, uint64 windowLastBlock);
    event CandleDrawing(PoolId indexed poolId, uint64 epochStart, uint256 requestId, int24 snapshotTick);
    event CandleRevealed(PoolId indexed poolId, uint64 epochStart, uint64 closeBlock);
    event EpochSettled(
        PoolId indexed poolId,
        uint40 indexed epochId,
        uint64 startBlock,
        uint64 closeBlock,
        uint128 in0,
        uint128 in1,
        uint128 out1For0,
        uint128 out0For1,
        uint128 refund0,
        uint128 refund1,
        address keeper
    );
    event InstantFeeCharged(PoolId indexed poolId, address indexed origin, uint24 fee, bool roundTrip);
    event Redeemed(
        PoolId indexed poolId, address indexed owner, uint64 blockNumber, bool zeroForOne, uint256 out, uint256 refund
    );

    error NotDynamicFeePool();
    error ExactOutputNotProtected();
    error AmountTooLarge();
    error WindowStillRunning();
    error NothingToDraw();
    error OnlyProvider();
    error StaleFulfillment();
    error NotRevealed();
    error NothingToRedeem();
    error EpochNotSettled();
    error CannotCancelNow();

    // ---------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------

    constructor(IPoolManager _poolManager, IRandomnessProvider _provider, uint64 _minSpan, uint64 _maxSpan)
        BaseHook(_poolManager)
        Owned(msg.sender)
    {
        require(_minSpan >= 1 && _maxSpan >= _minSpan, "bad spans");
        randomnessProvider = _provider;
        minSpan = _minSpan;
        maxSpan = _maxSpan;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------
    // Owner knobs (demo tunability, all bounded)
    // ---------------------------------------------------------------

    function setFees(
        uint24 _instantBaseFee,
        uint24 _volFeePerTick,
        uint24 _roundTripSurcharge,
        uint24 _batchFee,
        uint16 _keeperTipPips
    ) external onlyOwner {
        require(_instantBaseFee <= 100_000 && _batchFee <= 10_000, "fee too high");
        require(_roundTripSurcharge <= 200_000 && _keeperTipPips <= 1_000, "param too high");
        instantBaseFee = _instantBaseFee;
        volFeePerTick = _volFeePerTick;
        roundTripSurcharge = _roundTripSurcharge;
        batchFee = _batchFee;
        keeperTipPips = _keeperTipPips;
    }

    function setMaxSettleDeviationTicks(int24 t) external onlyOwner {
        require(t >= 10 && t <= 5000, "bad bound");
        maxSettleDeviationTicks = t;
    }

    // ---------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFeePool();
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        // Stored dynamic fee as a safety default; both lanes override it anyway.
        poolManager.updateDynamicLPFee(key, instantBaseFee);
        PoolState storage ps = pools[key.toId()];
        ps.lastTick = tick;
        ps.lastTickBlock = uint64(block.number);
        return BaseHook.afterInitialize.selector;
    }

    /// @dev hookData formats:
    ///   empty                       -> protected lane, owner = tx.origin
    ///   abi.encode(uint8 1)         -> instant lane
    ///   abi.encode(uint8 0, owner)  -> protected lane with explicit claim owner
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId pid = key.toId();

        // Internal settlement swap: pass through at the clean-flow batch fee.
        if (sender == address(this)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, batchFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        (uint8 lane, address owner) = _decodeHookData(hookData);

        if (lane == 1) {
            (uint24 fee, bool roundTrip) = _instantFee(pid, params.zeroForOne);
            emit InstantFeeCharged(pid, tx.origin, fee, roundTrip);
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        // Protected lane: custody NoOp. Exact input only in v1.
        if (params.amountSpecified >= 0) revert ExactOutputNotProtected();
        uint256 amountIn = uint256(-params.amountSpecified);
        if (amountIn > type(uint128).max) revert AmountTooLarge();

        _rollWindow(pid);

        Currency input = params.zeroForOne ? key.currency0 : key.currency1;

        // The hook takes the specified (input) currency as ERC6909 claims: the
        // positive specified delta charges the swapper, and taking claims balances
        // the hook's own delta. Same pairing as the audited BaseAsyncSwap.
        input.take(poolManager, address(this), amountIn, true);

        Bucket storage b = buckets[pid][block.number];
        if (params.zeroForOne) b.in0 += uint128(amountIn);
        else b.in1 += uint128(amountIn);

        uint256 claimId = orderId(pid, uint64(block.number), params.zeroForOne);
        _mint(owner, claimId, amountIn);

        emit OrderPlaced(pid, owner, uint64(block.number), params.zeroForOne, uint128(amountIn), claimId);

        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(int256(amountIn).toInt128(), 0),
            0
        );
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (sender != address(this)) {
            PoolId pid = key.toId();
            PoolState storage ps = pools[pid];
            (, int24 tick,,) = poolManager.getSlot0(pid);
            if (uint64(block.number) > ps.lastTickBlock) {
                int24 d = tick - ps.lastTick;
                uint24 absd = uint24(uint256(int256(d >= 0 ? d : -d)));
                ps.volEma = (ps.volEma * 3 + absd) / 4;
                ps.lastTickBlock = uint64(block.number);
            }
            ps.lastTick = tick;
            _dirSeen[keccak256(abi.encode(pid, block.number, tx.origin))] |= params.zeroForOne ? 1 : 2;
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------
    // Candle lifecycle
    // ---------------------------------------------------------------

    /// @notice After the window has fully elapsed, snapshot the price and ask the
    /// randomness provider for the close block. If the window held no orders, the
    /// epoch fast-forwards to the current block instead of spending randomness.
    function requestClose(PoolKey calldata key) external {
        PoolId pid = key.toId();
        PoolState storage ps = pools[pid];
        if (ps.phase != Phase.Open) revert WindowStillRunning();
        if (ps.epochStart == 0) revert NothingToDraw();
        uint64 windowLast = ps.epochStart + maxSpan - 1;
        if (block.number <= windowLast) revert WindowStillRunning();

        bool hasOrders;
        for (uint256 b = ps.epochStart; b <= windowLast; b++) {
            Bucket storage bk = buckets[pid][b];
            if (bk.in0 != 0 || bk.in1 != 0) {
                hasOrders = true;
                break;
            }
        }
        if (!hasOrders) {
            ps.epochStart = uint64(block.number);
            emit CandleLit(pid, ps.epochStart, ps.epochStart + maxSpan - 1);
            return;
        }

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(pid);
        ps.snapshotSqrtPriceX96 = sqrtPriceX96;
        ps.snapshotTick = tick;
        ps.phase = Phase.Drawing;

        bytes32 rkey = keccak256(abi.encode(pid, ps.epochStart));
        _pendingKeyPool[rkey] = pid;
        uint256 requestId = randomnessProvider.requestRandomness(rkey);
        emit CandleDrawing(pid, ps.epochStart, requestId, tick);
    }

    /// @inheritdoc IRandomnessConsumer
    function fulfillRandomness(bytes32 key, uint256 randomWord) external {
        if (msg.sender != address(randomnessProvider)) revert OnlyProvider();
        PoolId pid = _pendingKeyPool[key];
        PoolState storage ps = pools[pid];
        if (ps.phase != Phase.Drawing || keccak256(abi.encode(pid, ps.epochStart)) != key) revert StaleFulfillment();
        _pendingKeyPool[key] = PoolId.wrap(bytes32(0));

        uint64 span = maxSpan - minSpan + 1;
        uint64 close = ps.epochStart + minSpan - 1 + uint64(randomWord % span);
        ps.revealedClose = close;
        ps.phase = Phase.Revealed;
        emit CandleRevealed(pid, ps.epochStart, close);
    }

    /// @notice Settle the revealed epoch: net opposing flow at the snapshot price,
    /// push only the residual through the pool under a price bound, and record one
    /// uniform clearing outcome per side. Permissionless; the caller earns the tip.
    function settle(PoolKey calldata key) external {
        PoolId pid = key.toId();
        if (pools[pid].phase != Phase.Revealed) revert NotRevealed();
        poolManager.unlock(abi.encode(ACTION_SETTLE, abi.encode(key, msg.sender)));
    }

    // ---------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------

    function orderId(PoolId pid, uint64 blockNumber, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(pid, blockNumber, zeroForOne)));
    }

    /// @notice Redeem a settled order for its uniform-price output plus any pro rata
    /// refund of unfilled input.
    function redeem(PoolKey calldata key, uint64 blockNumber, bool zeroForOne, address to) external {
        PoolId pid = key.toId();
        uint40 epochId = epochOfBlock[pid][blockNumber];
        if (epochId == 0) revert EpochNotSettled();

        uint256 id = orderId(pid, blockNumber, zeroForOne);
        uint256 bal = balanceOf[msg.sender][id];
        if (bal == 0) revert NothingToRedeem();
        _burn(msg.sender, id, bal);

        EpochResult storage r = epochs[pid][epochId];
        uint256 out;
        uint256 refund;
        Currency outCurrency;
        Currency refundCurrency;
        if (zeroForOne) {
            out = FullMath.mulDiv(bal, r.out1For0, r.in0);
            refund = FullMath.mulDiv(bal, r.refund0, r.in0);
            outCurrency = key.currency1;
            refundCurrency = key.currency0;
        } else {
            out = FullMath.mulDiv(bal, r.out0For1, r.in1);
            refund = FullMath.mulDiv(bal, r.refund1, r.in1);
            outCurrency = key.currency0;
            refundCurrency = key.currency1;
        }

        poolManager.unlock(abi.encode(ACTION_PAY, abi.encode(outCurrency, out, refundCurrency, refund, to)));
        emit Redeemed(pid, msg.sender, blockNumber, zeroForOne, out, refund);
    }

    /// @notice Cancel an order whose block has not settled. Not allowed once the
    /// candle is revealed for a block inside the settling range, so nobody can dodge
    /// a clearing price they already know.
    function cancel(PoolKey calldata key, uint64 blockNumber, bool zeroForOne) external {
        PoolId pid = key.toId();
        if (epochOfBlock[pid][blockNumber] != 0) revert CannotCancelNow();
        PoolState storage ps = pools[pid];
        if (ps.phase != Phase.Open && blockNumber <= ps.epochStart + maxSpan - 1) revert CannotCancelNow();

        uint256 id = orderId(pid, blockNumber, zeroForOne);
        uint256 bal = balanceOf[msg.sender][id];
        if (bal == 0) revert NothingToRedeem();
        _burn(msg.sender, id, bal);

        Bucket storage b = buckets[pid][blockNumber];
        Currency refundCurrency;
        if (zeroForOne) {
            b.in0 -= uint128(bal);
            refundCurrency = key.currency0;
        } else {
            b.in1 -= uint128(bal);
            refundCurrency = key.currency1;
        }

        poolManager.unlock(abi.encode(ACTION_PAY, abi.encode(refundCurrency, bal, refundCurrency, uint256(0), msg.sender)));
        emit OrderCancelled(pid, msg.sender, blockNumber, zeroForOne);
    }

    // ---------------------------------------------------------------
    // Unlock callback
    // ---------------------------------------------------------------

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == ACTION_SETTLE) {
            (PoolKey memory key, address keeper) = abi.decode(payload, (PoolKey, address));
            _settle(key, keeper);
        } else if (action == ACTION_PAY) {
            (Currency cA, uint256 aA, Currency cB, uint256 aB, address to) =
                abi.decode(payload, (Currency, uint256, Currency, uint256, address));
            _payOut(cA, aA, to);
            _payOut(cB, aB, to);
        }
        return "";
    }

    function _payOut(Currency c, uint256 amount, address to) internal {
        if (amount == 0) return;
        // Burn the hook's claim tokens to fund the payment, then send real tokens.
        c.settle(poolManager, address(this), amount, true);
        c.take(poolManager, to, amount, false);
    }

    function _settle(PoolKey memory key, address keeper) internal {
        PoolId pid = key.toId();
        PoolState storage ps = pools[pid];

        uint40 epochId = ++ps.epochCount;
        uint64 start = ps.epochStart;
        uint64 close = ps.revealedClose;

        uint128 in0;
        uint128 in1;
        for (uint256 b = start; b <= close; b++) {
            Bucket storage bk = buckets[pid][b];
            in0 += bk.in0;
            in1 += bk.in1;
            epochOfBlock[pid][b] = epochId;
            delete buckets[pid][b];
        }

        EpochResult memory r;
        r.startBlock = start;
        r.closeBlock = close;
        r.in0 = in0;
        r.in1 = in1;

        // Price per currency0 in currency1 terms, Q96.
        uint256 priceX96 = FullMath.mulDiv(ps.snapshotSqrtPriceX96, ps.snapshotSqrtPriceX96, FixedPoint96.Q96);

        // Internal netting at the snapshot price. Matched volume never touches the curve.
        uint256 in1As0 = priceX96 == 0 ? 0 : FullMath.mulDiv(in1, FixedPoint96.Q96, priceX96);
        bool residualZeroForOne;
        uint256 residualIn;
        if (in0 >= in1As0) {
            // All of side one is matched by part of side zero.
            r.out0For1 = uint128(in1As0);
            r.out1For0 = in1;
            residualZeroForOne = true;
            residualIn = in0 - in1As0;
        } else {
            uint256 in0As1 = FullMath.mulDiv(in0, priceX96, FixedPoint96.Q96);
            r.out1For0 = uint128(in0As1);
            r.out0For1 = in0;
            residualZeroForOne = false;
            residualIn = in1 - in0As1;
        }

        // Residual crosses the curve, bounded to the snapshot tick plus or minus the
        // deviation cap. If someone shoved the price outside the bound, the swap
        // partially fills or fills nothing, and the untraded input is refunded pro
        // rata. Attacking the settlement is capped by construction.
        if (residualIn > 0) {
            int24 boundTick = residualZeroForOne
                ? ps.snapshotTick - maxSettleDeviationTicks
                : ps.snapshotTick + maxSettleDeviationTicks;
            if (boundTick < TickMath.MIN_TICK + 1) boundTick = TickMath.MIN_TICK + 1;
            if (boundTick > TickMath.MAX_TICK - 1) boundTick = TickMath.MAX_TICK - 1;

            BalanceDelta d = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: residualZeroForOne,
                    amountSpecified: -int256(residualIn),
                    sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(boundTick)
                }),
                ""
            );

            uint256 actualIn;
            uint256 actualOut;
            if (residualZeroForOne) {
                actualIn = uint256(uint128(-d.amount0()));
                actualOut = uint256(uint128(d.amount1()));
                r.out1For0 += uint128(actualOut);
                r.refund0 = uint128(residualIn - actualIn);
            } else {
                actualIn = uint256(uint128(-d.amount1()));
                actualOut = uint256(uint128(d.amount0()));
                r.out0For1 += uint128(actualOut);
                r.refund1 = uint128(residualIn - actualIn);
            }

            if (actualIn > 0) {
                Currency inC = residualZeroForOne ? key.currency0 : key.currency1;
                Currency outC = residualZeroForOne ? key.currency1 : key.currency0;
                inC.settle(poolManager, address(this), actualIn, true);
                outC.take(poolManager, address(this), actualOut, true);
            }
        }

        // Keeper tip, taken from each side's output.
        if (keeperTipPips > 0) {
            uint128 tip1 = uint128(FullMath.mulDiv(r.out1For0, keeperTipPips, 1e6));
            uint128 tip0 = uint128(FullMath.mulDiv(r.out0For1, keeperTipPips, 1e6));
            r.out1For0 -= tip1;
            r.out0For1 -= tip0;
            _payOut(key.currency1, tip1, keeper);
            _payOut(key.currency0, tip0, keeper);
        }

        epochs[pid][epochId] = r;

        // Open the next window right after the candle died. Blocks between the close
        // and now already hold their buckets and roll straight into the new epoch.
        ps.epochStart = close + 1;
        ps.revealedClose = 0;
        ps.snapshotSqrtPriceX96 = 0;
        ps.snapshotTick = 0;
        ps.phase = Phase.Open;

        emit EpochSettled(
            pid, epochId, start, close, in0, in1, r.out1For0, r.out0For1, r.refund0, r.refund1, keeper
        );
        emit CandleLit(pid, ps.epochStart, ps.epochStart + maxSpan - 1);
    }

    // ---------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------

    function _decodeHookData(bytes calldata hookData) internal view returns (uint8 lane, address owner) {
        if (hookData.length == 0) return (0, tx.origin);
        lane = abi.decode(hookData, (uint8));
        if (lane == 0) {
            if (hookData.length >= 64) (, owner) = abi.decode(hookData, (uint8, address));
            else owner = tx.origin;
        }
    }

    function _instantFee(PoolId pid, bool zeroForOne) internal view returns (uint24 fee, bool roundTrip) {
        PoolState storage ps = pools[pid];
        uint256 f = uint256(instantBaseFee) + uint256(ps.volEma) * volFeePerTick;
        uint8 mask = _dirSeen[keccak256(abi.encode(pid, block.number, tx.origin))];
        uint8 oppositeBit = zeroForOne ? 2 : 1;
        if (mask & oppositeBit != 0) {
            roundTrip = true;
            f += roundTripSurcharge;
        }
        if (f > LPFeeLibrary.MAX_LP_FEE) f = LPFeeLibrary.MAX_LP_FEE;
        fee = uint24(f);
    }

    /// @dev Lazy epoch bookkeeping on order placement: light the first candle, and if
    /// an empty window fully elapsed with nothing pending, restart it at the current
    /// block so stale windows never require randomness.
    function _rollWindow(PoolId pid) internal {
        PoolState storage ps = pools[pid];
        if (ps.epochStart == 0) {
            ps.epochStart = uint64(block.number);
            emit CandleLit(pid, ps.epochStart, ps.epochStart + maxSpan - 1);
            return;
        }
        if (ps.phase == Phase.Open && uint64(block.number) > ps.epochStart + maxSpan - 1) {
            uint64 windowLast = ps.epochStart + maxSpan - 1;
            bool hasOrders;
            for (uint256 b = ps.epochStart; b <= windowLast; b++) {
                Bucket storage bk = buckets[pid][b];
                if (bk.in0 != 0 || bk.in1 != 0) {
                    hasOrders = true;
                    break;
                }
            }
            if (!hasOrders) {
                ps.epochStart = uint64(block.number);
                emit CandleLit(pid, ps.epochStart, ps.epochStart + maxSpan - 1);
            }
        }
    }
}
