// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal interface for a randomness source that powers the candle close.
/// Implementations: ChainlinkVRFProvider (production), BlockhashProvider (fallback and local demo).
interface IRandomnessProvider {
    /// @notice Ask the provider for one random word tied to an opaque key.
    /// @param key Consumer-defined identifier, echoed back on fulfillment.
    /// @return requestId Provider-specific id for the request.
    function requestRandomness(bytes32 key) external returns (uint256 requestId);
}

/// @notice Contract that receives the random word. WickHook implements this.
interface IRandomnessConsumer {
    /// @notice Called by the provider exactly once per request.
    function fulfillRandomness(bytes32 key, uint256 randomWord) external;
}
