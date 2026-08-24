// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {BlockhashProvider} from "../src/randomness/BlockhashProvider.sol";
import {ChainlinkVRFProvider, IVRFCoordinatorV2Plus} from "../src/randomness/ChainlinkVRFProvider.sol";
import {IRandomnessConsumer} from "../src/interfaces/IRandomness.sol";

/// @notice Records what the provider delivers, standing in for the hook.
contract RecordingConsumer is IRandomnessConsumer {
    bytes32 public lastKey;
    uint256 public lastWord;
    uint256 public calls;

    function fulfillRandomness(bytes32 key, uint256 randomWord) external {
        lastKey = key;
        lastWord = randomWord;
        calls++;
    }
}

/// @notice Minimal coordinator double: hands out sequential ids and lets the test
/// deliver words back through the provider's raw fulfillment path.
contract MockCoordinator {
    uint256 public nextId = 100;
    IVRFCoordinatorV2Plus.RandomWordsRequest public lastReq;

    function requestRandomWords(IVRFCoordinatorV2Plus.RandomWordsRequest calldata req)
        external
        returns (uint256 requestId)
    {
        lastReq = req;
        requestId = nextId++;
    }

    function deliver(ChainlinkVRFProvider provider, uint256 requestId, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        provider.rawFulfillRandomWords(requestId, words);
    }
}

contract BlockhashProviderTest is Test {
    BlockhashProvider internal provider;
    RecordingConsumer internal consumer;

    function setUp() public {
        provider = new BlockhashProvider();
        consumer = new RecordingConsumer();
        provider.setConsumer(address(consumer));
        vm.roll(100);
    }

    function test_setConsumer_onlyDeployerAndOnce() public {
        BlockhashProvider fresh = new BlockhashProvider();
        vm.prank(address(0xBEEF));
        vm.expectRevert(BlockhashProvider.OnlyDeployer.selector);
        fresh.setConsumer(address(this));

        fresh.setConsumer(address(consumer));
        vm.expectRevert(BlockhashProvider.ConsumerAlreadySet.selector);
        fresh.setConsumer(address(this));
    }

    function test_request_onlyConsumer() public {
        vm.expectRevert(BlockhashProvider.OnlyConsumer.selector);
        provider.requestRandomness(bytes32("nope"));
    }

    function test_reveal_fullLifecycle() public {
        vm.prank(address(consumer));
        uint256 id = provider.requestRandomness(bytes32("k1"));

        // Not past the committed block yet.
        vm.expectRevert(BlockhashProvider.TargetNotReached.selector);
        provider.reveal(id);

        vm.roll(block.number + provider.COMMIT_DELAY() + 1);
        provider.reveal(id);

        assertEq(consumer.calls(), 1, "consumer called once");
        assertEq(consumer.lastKey(), bytes32("k1"), "key echoed");
        assertGt(consumer.lastWord(), 0, "word delivered");

        vm.expectRevert(BlockhashProvider.AlreadyFulfilled.selector);
        provider.reveal(id);
    }

    function test_reveal_rearmsWhenHashExpired() public {
        vm.prank(address(consumer));
        uint256 id = provider.requestRandomness(bytes32("k2"));
        (, uint64 firstTarget,) = provider.requests(id);

        // Let more than 256 blocks pass so the committed blockhash is gone.
        vm.roll(block.number + 300);
        provider.reveal(id);

        (, uint64 newTarget, bool fulfilled) = provider.requests(id);
        assertFalse(fulfilled, "not fulfilled, re-armed");
        assertGt(newTarget, firstTarget, "target moved forward");
        assertEq(consumer.calls(), 0, "consumer untouched by re-arm");

        // The re-armed request fulfills normally.
        vm.roll(uint256(newTarget) + 1);
        provider.reveal(id);
        assertEq(consumer.calls(), 1, "fulfilled after re-arm");
        assertEq(consumer.lastKey(), bytes32("k2"), "key echoed after re-arm");
    }
}

contract ChainlinkVRFProviderTest is Test {
    MockCoordinator internal coordinator;
    ChainlinkVRFProvider internal provider;
    RecordingConsumer internal consumer;

    bytes32 internal constant KEYHASH = bytes32(uint256(0xABCD));

    function setUp() public {
        coordinator = new MockCoordinator();
        provider = new ChainlinkVRFProvider(address(coordinator), KEYHASH, 42, 3, 200_000, false);
        consumer = new RecordingConsumer();
        provider.setConsumer(address(consumer));
    }

    function test_setConsumer_onlyDeployerAndOnce() public {
        ChainlinkVRFProvider fresh = new ChainlinkVRFProvider(address(coordinator), KEYHASH, 42, 3, 200_000, false);
        vm.prank(address(0xBEEF));
        vm.expectRevert(ChainlinkVRFProvider.OnlyDeployer.selector);
        fresh.setConsumer(address(this));

        fresh.setConsumer(address(consumer));
        vm.expectRevert(ChainlinkVRFProvider.ConsumerAlreadySet.selector);
        fresh.setConsumer(address(this));
    }

    function test_request_onlyConsumerAndForwardsConfig() public {
        vm.expectRevert(ChainlinkVRFProvider.OnlyConsumer.selector);
        provider.requestRandomness(bytes32("nope"));

        vm.prank(address(consumer));
        uint256 id = provider.requestRandomness(bytes32("k1"));
        assertEq(provider.keyOf(id), bytes32("k1"), "key stored");

        (bytes32 kh, uint256 sub, uint16 conf, uint32 gas, uint32 numWords,) = coordinator.lastReq();
        assertEq(kh, KEYHASH, "key hash forwarded");
        assertEq(sub, 42, "subscription forwarded");
        assertEq(conf, 3, "confirmations forwarded");
        assertEq(gas, 200_000, "callback gas forwarded");
        assertEq(numWords, 1, "exactly one word");
    }

    function test_fulfill_onlyCoordinatorAndForwardsWord() public {
        vm.prank(address(consumer));
        uint256 id = provider.requestRandomness(bytes32("k2"));

        uint256[] memory words = new uint256[](1);
        words[0] = 777;
        vm.expectRevert(ChainlinkVRFProvider.OnlyCoordinator.selector);
        provider.rawFulfillRandomWords(id, words);

        coordinator.deliver(provider, id, 777);
        assertEq(consumer.lastKey(), bytes32("k2"), "key echoed");
        assertEq(consumer.lastWord(), 777, "word forwarded");
        assertEq(provider.keyOf(id), bytes32(0), "request cleared");

        // Same id again is unknown now.
        vm.expectRevert(ChainlinkVRFProvider.UnknownRequest.selector);
        coordinator.deliver(provider, id, 778);
    }
}
