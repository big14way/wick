// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRandomnessProvider, IRandomnessConsumer} from "../../src/interfaces/IRandomness.sol";

/// @notice Test-only provider: the test decides the random word and when it lands.
contract MockRandomnessProvider is IRandomnessProvider {
    address public consumer;
    uint256 public nextRequestId = 1;
    mapping(uint256 => bytes32) public keyOf;
    uint256 public lastRequestId;

    function setConsumer(address _consumer) external {
        consumer = _consumer;
    }

    function requestRandomness(bytes32 key) external returns (uint256 requestId) {
        require(msg.sender == consumer, "only consumer");
        requestId = nextRequestId++;
        keyOf[requestId] = key;
        lastRequestId = requestId;
    }

    function fulfill(uint256 requestId, uint256 word) external {
        bytes32 key = keyOf[requestId];
        require(key != bytes32(0), "unknown request");
        delete keyOf[requestId];
        IRandomnessConsumer(consumer).fulfillRandomness(key, word);
    }
}
