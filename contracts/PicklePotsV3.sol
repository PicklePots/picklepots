// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PicklePotsV2} from "./PicklePotsV2.sol";

/**
 * @title PicklePotsV3
 * @notice Same game as V2 with two additions and NO new storage (so it upgrades the live proxy safely):
 *   1. setTierTiming(): the owner can tune a jar's timers later without another upgrade.
 *   2. initializeV3(): runs once inside upgradeToAndCall and gives the existing jars timers long enough
 *      for a player to approve a counter-bid in a wallet pop-up.
 *
 * How the timers work: a bid sets the deadline to (now + extensionTime), never longer than
 * (now + maxTimeCap). roundDuration is the opening timer of a fresh round. So extensionTime is the
 * window every player gets to answer the last bid.
 */
contract PicklePotsV3 is PicklePotsV2 {
    event TierTimingUpdated(uint8 indexed tierId, uint256 roundDuration, uint256 extensionTime, uint256 maxTimeCap);

    uint256 public constant MAX_TIMER = 1 days;

    /// @notice Owner-only. Changes the timers of one jar. A round already running keeps its current deadline;
    ///         the new timers apply from the next bid and the next round.
    function setTierTiming(uint8 tierId, uint256 roundDuration, uint256 extensionTime, uint256 maxTimeCap) external onlyOwner {
        _setTierTiming(tierId, roundDuration, extensionTime, maxTimeCap);
    }

    /// @notice One-time. Call through upgradeToAndCall(newImpl, abi.encodeCall(initializeV3, ())).
    function initializeV3() external reinitializer(2) onlyOwner {
        // opening / reset (extension) / cap, in seconds: Cocktail, Baby Gherkin, Classic Dill, Spicy Brine, PKL Barrel
        uint8 n = numTiers;
        if (n > 0) _setTierTiming(0, 35, 25, 35);
        if (n > 1) _setTierTiming(1, 40, 30, 40);
        if (n > 2) _setTierTiming(2, 50, 35, 50);
        if (n > 3) _setTierTiming(3, 60, 40, 60);
        if (n > 4) _setTierTiming(4, 50, 35, 50);
    }

    function _setTierTiming(uint8 tierId, uint256 roundDuration, uint256 extensionTime, uint256 maxTimeCap) internal {
        require(tierId < numTiers, "PicklePots: Invalid tier");
        require(roundDuration > 0 && extensionTime > 0, "PicklePots: bad timer");
        require(maxTimeCap >= roundDuration && maxTimeCap >= extensionTime, "PicklePots: bad cap");
        require(maxTimeCap <= MAX_TIMER, "PicklePots: timer too long");
        TierConfig storage cfg = tierConfigs[tierId];
        cfg.roundDuration = roundDuration;
        cfg.extensionTime = extensionTime;
        cfg.maxTimeCap = maxTimeCap;
        emit TierTimingUpdated(tierId, roundDuration, extensionTime, maxTimeCap);
    }
}
