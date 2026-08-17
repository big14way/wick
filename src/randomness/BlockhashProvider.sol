// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRandomnessProvider, IRandomnessConsumer} from "../interfaces/IRandomness.sol";

/// @title BlockhashProvider
/// @notice Fallback randomness source: commits to a future blockhash at request time,
/// then anyone can reveal once that block has passed. Good enough for testnets and
/// local demos. On mainnet a proposer can bias a blockhash, so production deployments
/// should point WickHook at ChainlinkVRFProvider instead. The provider is pluggable
/// for exactly this reason.
contract BlockhashProvider is IRandomnessProvider {
    struct Request {
        bytes32 key;
        uint64 targetBlock;
        bool fulfilled;
    }

    /// @notice The single consumer allowed to open requests (the WickHook).
    address public consumer;
    address public immutable deployer;

    /// @notice How many blocks ahead the committed blockhash sits.
    uint64 public constant COMMIT_DELAY = 2;

    uint256 public nextRequestId = 1;
    mapping(uint256 => Request) public requests;

    event RandomnessRequested(uint256 indexed requestId, bytes32 indexed key, uint64 targetBlock);
    event RandomnessRevealed(uint256 indexed requestId, bytes32 indexed key, uint256 word);
    event RequestRearmed(uint256 indexed requestId, uint64 newTargetBlock);

    error OnlyConsumer();
    error OnlyDeployer();
    error ConsumerAlreadySet();
    error TargetNotReached();
    error AlreadyFulfilled();
    error HashUnavailable();

    constructor() {
        deployer = msg.sender;
    }

    /// @notice One-time wiring of the consumer, done right after WickHook is deployed.
    function setConsumer(address _consumer) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (consumer != address(0)) revert ConsumerAlreadySet();
        consumer = _consumer;
    }

    /// @inheritdoc IRandomnessProvider
    function requestRandomness(bytes32 key) external returns (uint256 requestId) {
        if (msg.sender != consumer) revert OnlyConsumer();
        requestId = nextRequestId++;
        requests[requestId] = Request({key: key, targetBlock: uint64(block.number) + COMMIT_DELAY, fulfilled: false});
        emit RandomnessRequested(requestId, key, uint64(block.number) + COMMIT_DELAY);
    }

    /// @notice Permissionless reveal once the committed block has passed.
    /// If more than 256 blocks have gone by (blockhash no longer available),
    /// the request re-arms to a new future block instead of getting stuck.
    function reveal(uint256 requestId) external {
        Request storage r = requests[requestId];
        if (r.fulfilled) revert AlreadyFulfilled();
        if (block.number <= r.targetBlock) revert TargetNotReached();

        bytes32 bh = blockhash(r.targetBlock);
        if (bh == bytes32(0)) {
            r.targetBlock = uint64(block.number) + COMMIT_DELAY;
            emit RequestRearmed(requestId, r.targetBlock);
            return;
        }

        r.fulfilled = true;
        uint256 word = uint256(keccak256(abi.encodePacked(bh, requestId, r.key)));
        emit RandomnessRevealed(requestId, r.key, word);
        IRandomnessConsumer(consumer).fulfillRandomness(r.key, word);
    }
}
