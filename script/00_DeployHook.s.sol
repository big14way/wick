// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {WickHook} from "../src/WickHook.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomness.sol";
import {BlockhashProvider} from "../src/randomness/BlockhashProvider.sol";
import {ChainlinkVRFProvider} from "../src/randomness/ChainlinkVRFProvider.sol";

/// @notice Deploys a randomness provider, mines a valid hook address, and deploys WickHook.
///
/// Randomness selection is env driven:
///   set VRF_COORDINATOR to a non zero address to use Chainlink VRF 2.5 on a live testnet,
///   otherwise the script deploys BlockhashProvider (fine for local anvil and quick demos,
///   not for value at risk since a proposer can bias blockhash).
///
/// Env vars (all optional, with the defaults shown):
///   MIN_SPAN            uint, default 3      first block a candle can close, from window start
///   MAX_SPAN            uint, default 10     last block of the window
///   VRF_COORDINATOR     address, default 0   Chainlink VRF coordinator for this chain
///   VRF_KEYHASH         bytes32              gas lane key hash
///   VRF_SUBSCRIPTION_ID uint                 funded VRF subscription id
///   VRF_CONFIRMATIONS   uint, default 3      request confirmations
///   VRF_CALLBACK_GAS    uint, default 200000 callback gas limit
///   VRF_NATIVE_PAYMENT  bool, default false  pay VRF in native gas token instead of LINK
///
/// VERIFY the coordinator address and key hash for your target network against the
/// Chainlink docs before broadcasting: https://docs.chain.link/vrf/v2-5/supported-networks
/// VERIFY the PoolManager address (pulled in by BaseScript via hookmate) against the
/// Uniswap deployments page: https://docs.uniswap.org/contracts/v4/deployments
contract DeployHookScript is BaseScript {
    function run() public {
        uint64 minSpan = uint64(vm.envOr("MIN_SPAN", uint256(3)));
        uint64 maxSpan = uint64(vm.envOr("MAX_SPAN", uint256(10)));

        address vrfCoordinator = vm.envOr("VRF_COORDINATOR", address(0));

        vm.startBroadcast();

        // 1. Randomness provider.
        IRandomnessProvider provider;
        if (vrfCoordinator != address(0)) {
            provider = IRandomnessProvider(
                address(
                    new ChainlinkVRFProvider(
                        vrfCoordinator,
                        vm.envBytes32("VRF_KEYHASH"),
                        vm.envUint("VRF_SUBSCRIPTION_ID"),
                        uint16(vm.envOr("VRF_CONFIRMATIONS", uint256(3))),
                        uint32(vm.envOr("VRF_CALLBACK_GAS", uint256(200000))),
                        vm.envOr("VRF_NATIVE_PAYMENT", false)
                    )
                )
            );
        } else {
            provider = IRandomnessProvider(address(new BlockhashProvider()));
        }

        // 2. Mine a salt so the hook address carries the right permission flags.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, provider, minSpan, maxSpan);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(WickHook).creationCode, constructorArgs);

        // 3. Deploy the hook to the mined address.
        WickHook hook = new WickHook{salt: salt}(poolManager, provider, minSpan, maxSpan);
        require(address(hook) == hookAddress, "DeployHookScript: hook address mismatch");

        // 4. Point the provider at the hook. One time, deployer only. Both providers
        //    expose setConsumer(address) but do not share a type, so call by selector.
        (bool ok,) = address(provider).call(abi.encodeWithSignature("setConsumer(address)", address(hook)));
        require(ok, "DeployHookScript: setConsumer failed");

        vm.stopBroadcast();

        console2.log("Randomness provider:", address(provider));
        console2.log("Using Chainlink VRF:", vrfCoordinator != address(0));
        console2.log("WickHook:           ", address(hook));
        console2.log("minSpan:            ", uint256(minSpan));
        console2.log("maxSpan:            ", uint256(maxSpan));
        console2.log("Set hookContract in script/base/BaseScript.sol to the WickHook address above.");
    }
}
