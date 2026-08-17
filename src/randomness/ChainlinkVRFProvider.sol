// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRandomnessProvider, IRandomnessConsumer} from "../interfaces/IRandomness.sol";

/// @notice Minimal VRF 2.5 coordinator surface. Mirrors the VRFV2PlusClient types
/// from the Chainlink contracts package so we avoid pulling the whole dependency.
/// Before a mainnet deployment, diff this against the official VRFV2PlusClient library.
interface IVRFCoordinatorV2Plus {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId);
}

/// @title ChainlinkVRFProvider
/// @notice Production randomness for the candle close. Subscription-funded VRF 2.5.
/// Live on Ethereum Sepolia, Base Sepolia and Arbitrum Sepolia among others, which is
/// where the testnet demo runs.
contract ChainlinkVRFProvider is IRandomnessProvider {
    // Tag from Chainlink's VRFV2PlusClient: bytes4(keccak256("VRF ExtraArgsV1"))
    bytes4 private constant EXTRA_ARGS_V1_TAG = 0x92fd1338;

    struct ExtraArgsV1 {
        bool nativePayment;
    }

    address public immutable coordinator;
    bytes32 public immutable keyHash;
    uint256 public immutable subId;
    uint16 public immutable requestConfirmations;
    uint32 public immutable callbackGasLimit;
    bool public immutable nativePayment;

    address public consumer;
    address public immutable deployer;

    mapping(uint256 => bytes32) public keyOf;

    event RandomnessRequested(uint256 indexed requestId, bytes32 indexed key);
    event RandomnessFulfilled(uint256 indexed requestId, bytes32 indexed key, uint256 word);

    error OnlyConsumer();
    error OnlyCoordinator();
    error OnlyDeployer();
    error ConsumerAlreadySet();
    error UnknownRequest();

    constructor(
        address _coordinator,
        bytes32 _keyHash,
        uint256 _subId,
        uint16 _requestConfirmations,
        uint32 _callbackGasLimit,
        bool _nativePayment
    ) {
        coordinator = _coordinator;
        keyHash = _keyHash;
        subId = _subId;
        requestConfirmations = _requestConfirmations;
        callbackGasLimit = _callbackGasLimit;
        nativePayment = _nativePayment;
        deployer = msg.sender;
    }

    function setConsumer(address _consumer) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (consumer != address(0)) revert ConsumerAlreadySet();
        consumer = _consumer;
    }

    /// @inheritdoc IRandomnessProvider
    function requestRandomness(bytes32 key) external returns (uint256 requestId) {
        if (msg.sender != consumer) revert OnlyConsumer();
        requestId = IVRFCoordinatorV2Plus(coordinator).requestRandomWords(
            IVRFCoordinatorV2Plus.RandomWordsRequest({
                keyHash: keyHash,
                subId: subId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                extraArgs: abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, ExtraArgsV1({nativePayment: nativePayment}))
            })
        );
        keyOf[requestId] = key;
        emit RandomnessRequested(requestId, key);
    }

    /// @notice VRF 2.5 coordinators call this exact selector on their consumers.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != coordinator) revert OnlyCoordinator();
        bytes32 key = keyOf[requestId];
        if (key == bytes32(0)) revert UnknownRequest();
        delete keyOf[requestId];
        emit RandomnessFulfilled(requestId, key, randomWords[0]);
        IRandomnessConsumer(consumer).fulfillRandomness(key, randomWords[0]);
    }
}
