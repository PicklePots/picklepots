// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPickleFeeRouter} from "./PicklePots.sol";

/**
 * @title PicklePotsV2
 * @notice "King of the Jar" time-decay pot game for Pickle Chain. Upgradeable (UUPS) so the
 *         contract address stays the same across updates.
 *
 * Tiers 0-3 are paid in the native coin (ETH on Pickle Chain), tier 4 is paid in PKL.
 * More jars can be added by the owner with addTier().
 *
 * Round outcome:
 *   - 2+ different bidders: 90% to the last bidder (the King), 5% seeds the next round, 5% protocol fee.
 *   - Only 1 bidder: nobody to beat, so that bidder is refunded in full. No fee is taken and any
 *     seed already in the pot rolls over to the next round (a lone bidder can't farm the seed).
 *
 * Payouts are pushed with a capped gas stipend. If the receiver rejects the payment it is credited
 * to pending[token][account] and can be pulled with claim(), so a hostile winner can never freeze a jar.
 *
 * Players can bid for another address with dropBidFor / dropBidToken, so a fast session wallet can
 * play while winnings and refunds go to the player's main wallet.
 */
contract PicklePotsV2 is Initializable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant VERSION = 2;
    uint256 public constant WINNER_BPS = 9000;
    uint256 public constant SEED_BPS = 500;
    uint256 public constant PROTOCOL_FEE_BPS = 500;
    uint256 private constant PUSH_GAS = 100_000;

    struct TierConfig {
        string name;
        uint256 minBid;
        uint256 roundDuration;
        uint256 extensionTime;
        uint256 maxTimeCap;
        address token; // address(0) = native coin
    }

    struct Round {
        uint256 roundId;
        uint256 potAmount;
        address leader;
        uint256 deadline;
        uint256 totalBids;
        uint256 uniqueBidders;
        uint256 seed;
        bool finalized;
        bool refunded;
        address winner;
        uint256 payout;
    }

    address payable public feeRecipient;
    IPickleFeeRouter public feeRouter;
    bool public upgradesFrozen;
    uint8 public numTiers;

    TierConfig[] public tierConfigs;
    mapping(uint8 => uint256) public currentRoundIds;
    mapping(uint8 => mapping(uint256 => Round)) public tierRounds;
    mapping(uint8 => mapping(uint256 => mapping(address => uint256))) public roundBids;
    // token (address(0) = native) => account => amount waiting to be claimed
    mapping(address => mapping(address => uint256)) public pending;

    uint256[40] private __gap;

    event RoundStarted(uint8 indexed tierId, uint256 indexed roundId, uint256 initialPot, uint256 deadline);
    event BidPlaced(uint8 indexed tierId, uint256 indexed roundId, address indexed bidder, uint256 amount, uint256 newPot, uint256 newDeadline);
    event RoundFinalized(uint8 indexed tierId, uint256 indexed roundId, address indexed winner, uint256 winAmount, uint256 seedNextPot, uint256 protocolFee);
    event RoundRefunded(uint8 indexed tierId, uint256 indexed roundId, address indexed bidder, uint256 refund, uint256 seedNextPot);
    event ProtocolFeeRouted(uint8 indexed tierId, uint256 grossFee, uint256 builderRetained, uint256 pklBurnRouted);
    event PaymentCredited(address indexed token, address indexed account, uint256 amount);
    event Claimed(address indexed token, address indexed account, uint256 amount);
    event TierAdded(uint8 indexed tierId, string name, address token, uint256 minBid);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeRouterUpdated(address indexed newRouter);
    event UpgradesFrozen();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _owner        Owner (can upgrade, set fee recipient, add jars). Two-step transfer afterwards.
     * @param _feeRecipient Receives the 5% protocol fee.
     * @param _feeRouter    Optional native fee router (address(0) = send fee straight to feeRecipient).
     * @param _pkl          PKL token. If non-zero a PKL jar is created as tier 4.
     */
    function initialize(address _owner, address payable _feeRecipient, address _feeRouter, address _pkl) external initializer {
        require(_owner != address(0) && _feeRecipient != address(0), "PicklePots: zero address");
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        feeRecipient = _feeRecipient;
        if (_feeRouter != address(0)) feeRouter = IPickleFeeRouter(_feeRouter);

        _addTier(TierConfig("Cocktail Jar", 0.0001 ether, 25 seconds, 10 seconds, 45 seconds, address(0)));
        _addTier(TierConfig("Baby Gherkin", 0.0005 ether, 30 seconds, 15 seconds, 60 seconds, address(0)));
        _addTier(TierConfig("Classic Dill", 0.002 ether, 45 seconds, 15 seconds, 90 seconds, address(0)));
        _addTier(TierConfig("Spicy Brine", 0.02 ether, 60 seconds, 20 seconds, 120 seconds, address(0)));
        if (_pkl != address(0)) {
            _addTier(TierConfig("PKL Barrel", 10 ether, 45 seconds, 15 seconds, 90 seconds, _pkl));
        }
    }

    // ---------------------------------------------------------------- admin

    function addTier(TierConfig calldata cfg) external onlyOwner {
        _addTier(cfg);
    }

    function setFeeRecipient(address payable _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "PicklePots: zero address");
        emit FeeRecipientUpdated(feeRecipient, _newRecipient);
        feeRecipient = _newRecipient;
    }

    function setFeeRouter(address _newRouter) external onlyOwner {
        feeRouter = IPickleFeeRouter(_newRouter);
        emit FeeRouterUpdated(_newRouter);
    }

    /// @notice Permanently disables upgrades. Cannot be undone.
    function freezeUpgrades() external onlyOwner {
        upgradesFrozen = true;
        emit UpgradesFrozen();
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {
        require(!upgradesFrozen, "PicklePots: upgrades frozen");
    }

    function _addTier(TierConfig memory cfg) internal {
        require(numTiers < 255, "PicklePots: too many tiers");
        require(cfg.minBid > 0 && cfg.roundDuration > 0, "PicklePots: bad tier");
        require(cfg.maxTimeCap >= cfg.roundDuration, "PicklePots: bad cap");
        uint8 id = numTiers;
        numTiers = id + 1;
        tierConfigs.push(cfg);
        emit TierAdded(id, cfg.name, cfg.token, cfg.minBid);
        _startNewRound(id, 0);
    }

    // ---------------------------------------------------------------- bidding

    /// @notice Bid in a native-coin jar. The King is msg.sender.
    function dropBid(uint8 tierId) external payable nonReentrant {
        require(tierId < numTiers, "PicklePots: Invalid tier");
        require(tierConfigs[tierId].token == address(0), "PicklePots: Use dropBidToken");
        _bid(tierId, msg.sender, msg.value);
    }

    /// @notice Bid in a native-coin jar on behalf of `beneficiary` (wins, refunds go to them).
    function dropBidFor(uint8 tierId, address beneficiary) external payable nonReentrant {
        require(tierId < numTiers, "PicklePots: Invalid tier");
        require(tierConfigs[tierId].token == address(0), "PicklePots: Use dropBidToken");
        _bid(tierId, beneficiary == address(0) ? msg.sender : beneficiary, msg.value);
    }

    /// @notice Bid in a token jar (e.g. PKL). Caller must approve this contract first.
    function dropBidToken(uint8 tierId, address beneficiary, uint256 amount) external nonReentrant {
        require(tierId < numTiers, "PicklePots: Invalid tier");
        address token = tierConfigs[tierId].token;
        require(token != address(0), "PicklePots: Not a token jar");

        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(token).balanceOf(address(this)) - before == amount, "PicklePots: Unsupported token");

        _bid(tierId, beneficiary == address(0) ? msg.sender : beneficiary, amount);
    }

    function _bid(uint8 tierId, address bidder, uint256 amount) internal {
        TierConfig memory cfg = tierConfigs[tierId];
        uint256 rId = currentRoundIds[tierId];
        Round storage r = tierRounds[tierId][rId];

        // An expired round that has a King is settled by the next bid, which then opens the new round.
        if (block.timestamp >= r.deadline && r.leader != address(0)) {
            _finalizeRound(tierId);
            rId = currentRoundIds[tierId];
            r = tierRounds[tierId][rId];
        }

        require(amount >= cfg.minBid, "PicklePots: Bid below tier minimum");

        if (roundBids[tierId][rId][bidder] == 0) r.uniqueBidders += 1;
        roundBids[tierId][rId][bidder] += amount;
        r.potAmount += amount;
        r.leader = bidder;
        r.totalBids += 1;

        uint256 extended = block.timestamp + cfg.extensionTime;
        uint256 maxDeadline = block.timestamp + cfg.maxTimeCap;
        r.deadline = extended > maxDeadline ? maxDeadline : extended;

        emit BidPlaced(tierId, rId, bidder, amount, r.potAmount, r.deadline);
    }

    // ---------------------------------------------------------------- settlement

    function finalizeRound(uint8 tierId) external nonReentrant {
        require(tierId < numTiers, "PicklePots: Invalid tier");
        Round storage r = tierRounds[tierId][currentRoundIds[tierId]];
        require(!r.finalized, "PicklePots: Round already finalized");
        require(block.timestamp >= r.deadline, "PicklePots: Deadline not elapsed");
        require(r.leader != address(0), "PicklePots: No bids placed in this round");
        _finalizeRound(tierId);
    }

    function _finalizeRound(uint8 tierId) internal {
        uint256 rId = currentRoundIds[tierId];
        Round storage r = tierRounds[tierId][rId];
        address token = tierConfigs[tierId].token;
        r.finalized = true;

        uint256 pot = r.potAmount;

        if (r.uniqueBidders < 2) {
            // Nobody to beat: refund the lone bidder, roll the seed forward, no fee.
            uint256 refund = roundBids[tierId][rId][r.leader];
            uint256 seedForNext = pot - refund;
            r.refunded = true;
            r.payout = refund;
            _pay(token, r.leader, refund);
            emit RoundRefunded(tierId, rId, r.leader, refund, seedForNext);
            _startNewRound(tierId, seedForNext);
            return;
        }

        uint256 winnerPayout = (pot * WINNER_BPS) / 10000;
        uint256 seedNext = (pot * SEED_BPS) / 10000;
        uint256 protocolTake = pot - winnerPayout - seedNext;

        r.winner = r.leader;
        r.payout = winnerPayout;

        _payFee(tierId, token, protocolTake);
        _pay(token, r.winner, winnerPayout);

        emit RoundFinalized(tierId, rId, r.winner, winnerPayout, seedNext, protocolTake);
        _startNewRound(tierId, seedNext);
    }

    function _payFee(uint8 tierId, address token, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0) && address(feeRouter) != address(0)) {
            try feeRouter.routeProtocolFee{value: amount}(address(this), amount) returns (uint256 builderShare, uint256 ecosystemShare) {
                emit ProtocolFeeRouted(tierId, amount, builderShare, ecosystemShare);
                return;
            } catch {}
        }
        _pay(token, feeRecipient, amount);
        emit ProtocolFeeRouted(tierId, amount, amount, 0);
    }

    function _startNewRound(uint8 tierId, uint256 seed) internal {
        uint256 rId = ++currentRoundIds[tierId];
        uint256 deadline = block.timestamp + tierConfigs[tierId].roundDuration;
        tierRounds[tierId][rId] = Round({
            roundId: rId,
            potAmount: seed,
            leader: address(0),
            deadline: deadline,
            totalBids: 0,
            uniqueBidders: 0,
            seed: seed,
            finalized: false,
            refunded: false,
            winner: address(0),
            payout: 0
        });
        emit RoundStarted(tierId, rId, seed, deadline);
    }

    // ---------------------------------------------------------------- payments

    function _pay(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        bool ok;
        if (token == address(0)) {
            (ok, ) = payable(to).call{value: amount, gas: PUSH_GAS}("");
        } else {
            try IERC20(token).transfer(to, amount) returns (bool res) {
                ok = res;
            } catch {
                ok = false;
            }
        }
        if (!ok) {
            pending[token][to] += amount;
            emit PaymentCredited(token, to, amount);
        }
    }

    /// @notice Withdraw anything that could not be pushed to you (token = address(0) for the native coin).
    function claim(address token) external nonReentrant {
        uint256 amount = pending[token][msg.sender];
        require(amount > 0, "PicklePots: Nothing to claim");
        pending[token][msg.sender] = 0;
        if (token == address(0)) {
            (bool ok, ) = payable(msg.sender).call{value: amount}("");
            require(ok, "PicklePots: Claim failed");
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
        emit Claimed(token, msg.sender, amount);
    }

    // ---------------------------------------------------------------- views

    function getRound(uint8 tierId) external view returns (
        uint256 roundId,
        uint256 potAmount,
        address leader,
        uint256 deadline,
        uint256 totalBids,
        uint256 timeLeft,
        bool isExpired,
        string memory tierName,
        uint256 minBid
    ) {
        require(tierId < numTiers, "PicklePots: Invalid tier");
        Round storage r = tierRounds[tierId][currentRoundIds[tierId]];
        TierConfig storage cfg = tierConfigs[tierId];

        roundId = r.roundId;
        potAmount = r.potAmount;
        leader = r.leader;
        deadline = r.deadline;
        totalBids = r.totalBids;
        tierName = cfg.name;
        minBid = cfg.minBid;

        if (block.timestamp >= r.deadline) {
            isExpired = true;
        } else {
            timeLeft = r.deadline - block.timestamp;
        }
    }

    /// @notice Extra data for the current round: distinct bidders, seed carried in, jar token.
    function getRoundExtra(uint8 tierId) external view returns (uint256 uniqueBidders, uint256 seed, address token) {
        require(tierId < numTiers, "PicklePots: Invalid tier");
        Round storage r = tierRounds[tierId][currentRoundIds[tierId]];
        return (r.uniqueBidders, r.seed, tierConfigs[tierId].token);
    }

    /// @notice Result of the previous (settled) round of a jar. roundId == 0 means none yet.
    function getLastResult(uint8 tierId) external view returns (uint256 roundId, address winner, uint256 payout, bool refunded) {
        require(tierId < numTiers, "PicklePots: Invalid tier");
        uint256 cur = currentRoundIds[tierId];
        if (cur <= 1) return (0, address(0), 0, false);
        Round storage p = tierRounds[tierId][cur - 1];
        return (p.roundId, p.winner, p.payout, p.refunded);
    }

    receive() external payable {
        revert("PicklePots: Use dropBid(tierId) to enter");
    }
}
