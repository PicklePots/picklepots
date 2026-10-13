// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPickleFeeRouter
 * @notice Native fee router interface for Pickle Chain Layer 2
 * @dev Routes progressive marginal shares of protocol take to PKL ecosystem buyback/burn
 *      while ensuring verified builders retain 82-100% of their earnings.
 */
interface IPickleFeeRouter {
    function routeProtocolFee(address dApp, uint256 grossAmount) external payable returns (uint256 builderShare, uint256 ecosystemShare);
    function getMarginalFeeRate(address dApp) external view returns (uint256 basisPoints);
}

/**
 * @title PicklePots
 * @notice 4-Tier High-Speed "King of the Jar" time-decay pot game for Pickle Chain L2
 * @dev Tiers:
 *      - Tier 0: "Cocktail Jar" (0.0001 ETH / ~$0.25)
 *      - Tier 1: "Baby Gherkin" (0.0005 ETH / ~$1.25)
 *      - Tier 2: "Classic Dill" (0.002 ETH  / ~$5.00)
 *      - Tier 3: "Spicy Brine"  (0.02 ETH   / ~$50.00)
 *
 *      Each tier runs independent rounds, timers, and pots.
 *      Payout: 90% to winning King of the Jar, 5% seeds next pot, 5% protocol fee to feeRecipient.
 */
contract PicklePots {
    address public immutable owner;
    address payable public feeRecipient;
    IPickleFeeRouter public feeRouter;

    // Configured protocol fee recipient wallet
    address payable public constant DEFAULT_FEE_RECIPIENT = payable(0x903d2AD79bBa6BB121FdF2102cA80469C6b735eb);

    uint8 public constant NUM_TIERS = 4;
    uint256 public constant WINNER_BPS = 9000;      // 90%
    uint256 public constant SEED_BPS = 500;         // 5%
    uint256 public constant PROTOCOL_FEE_BPS = 500;   // 5%

    struct TierConfig {
        string name;
        uint256 minBid;
        uint256 roundDuration;
        uint256 extensionTime;
        uint256 maxTimeCap;
    }

    TierConfig[NUM_TIERS] public tierConfigs;

    struct Round {
        uint256 roundId;
        uint256 potAmount;
        address leader;
        uint256 deadline;
        uint256 totalBids;
        bool finalized;
        address winner;
        uint256 payout;
    }

    mapping(uint8 => uint256) public currentRoundIds;
    mapping(uint8 => mapping(uint256 => Round)) public tierRounds;
    mapping(uint8 => mapping(uint256 => mapping(address => uint256))) public roundBids;

    bool private locked;

    // --- Events ---
    event RoundStarted(uint8 indexed tierId, uint256 indexed roundId, uint256 initialPot, uint256 deadline);
    event BidPlaced(uint8 indexed tierId, uint256 indexed roundId, address indexed bidder, uint256 amount, uint256 newPot, uint256 newDeadline);
    event RoundFinalized(uint8 indexed tierId, uint256 indexed roundId, address indexed winner, uint256 winAmount, uint256 seedNextPot, uint256 protocolFee);
    event ProtocolFeeRouted(uint8 indexed tierId, uint256 grossFee, uint256 builderRetained, uint256 pklBurnRouted);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeRouterUpdated(address indexed newRouter);

    modifier onlyOwner() {
        require(msg.sender == owner, "PicklePots: caller is not owner");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "PicklePots: reentrant call");
        locked = true;
        _;
        locked = false;
    }

    constructor(address payable _feeRecipient, address _feeRouter) {
        owner = msg.sender;
        feeRecipient = _feeRecipient != address(0) ? _feeRecipient : DEFAULT_FEE_RECIPIENT;
        if (_feeRouter != address(0)) {
            feeRouter = IPickleFeeRouter(_feeRouter);
        }

        // Initialize 4 Tiers (clean ASCII strings for Solidity compiler compliance)
        tierConfigs[0] = TierConfig({
            name: "Cocktail Jar",
            minBid: 0.0001 ether,    // ~$0.25
            roundDuration: 25 seconds,
            extensionTime: 10 seconds,
            maxTimeCap: 45 seconds
        });

        tierConfigs[1] = TierConfig({
            name: "Baby Gherkin",
            minBid: 0.0005 ether,    // ~$1.25
            roundDuration: 30 seconds,
            extensionTime: 15 seconds,
            maxTimeCap: 60 seconds
        });

        tierConfigs[2] = TierConfig({
            name: "Classic Dill",
            minBid: 0.002 ether,     // ~$5.00
            roundDuration: 45 seconds,
            extensionTime: 15 seconds,
            maxTimeCap: 90 seconds
        });

        tierConfigs[3] = TierConfig({
            name: "Spicy Brine",
            minBid: 0.02 ether,      // ~$50.00
            roundDuration: 60 seconds,
            extensionTime: 20 seconds,
            maxTimeCap: 120 seconds
        });

        // Launch Genesis Rounds across all 4 tiers
        for (uint8 i = 0; i < NUM_TIERS; i++) {
            _startNewRound(i, 0);
        }
    }

    function setFeeRecipient(address payable _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "PicklePots: zero address");
        address oldRecipient = feeRecipient;
        feeRecipient = _newRecipient;
        emit FeeRecipientUpdated(oldRecipient, _newRecipient);
    }

    function setFeeRouter(address _newRouter) external onlyOwner {
        feeRouter = IPickleFeeRouter(_newRouter);
        emit FeeRouterUpdated(_newRouter);
    }

    function _startNewRound(uint8 tierId, uint256 seed) internal {
        currentRoundIds[tierId]++;
        uint256 rId = currentRoundIds[tierId];
        uint256 deadline = block.timestamp + tierConfigs[tierId].roundDuration;

        tierRounds[tierId][rId] = Round({
            roundId: rId,
            potAmount: seed,
            leader: address(0),
            deadline: deadline,
            totalBids: 0,
            finalized: false,
            winner: address(0),
            payout: 0
        });

        emit RoundStarted(tierId, rId, seed, deadline);
    }

    function dropBid(uint8 tierId) external payable nonReentrant {
        require(tierId < NUM_TIERS, "PicklePots: Invalid tier");
        TierConfig memory config = tierConfigs[tierId];
        uint256 rId = currentRoundIds[tierId];
        Round storage r = tierRounds[tierId][rId];

        if (block.timestamp >= r.deadline && r.leader != address(0)) {
            _finalizeRound(tierId);
            rId = currentRoundIds[tierId];
            r = tierRounds[tierId][rId];
        }

        require(msg.value >= config.minBid, "PicklePots: Bid below tier minimum");

        r.potAmount += msg.value;
        r.leader = msg.sender;
        r.totalBids += 1;
        roundBids[tierId][rId][msg.sender] += msg.value;

        uint256 extended = block.timestamp + config.extensionTime;
        uint256 maxDeadline = block.timestamp + config.maxTimeCap;
        r.deadline = extended > maxDeadline ? maxDeadline : extended;

        emit BidPlaced(tierId, rId, msg.sender, msg.value, r.potAmount, r.deadline);
    }

    function finalizeRound(uint8 tierId) external nonReentrant {
        require(tierId < NUM_TIERS, "PicklePots: Invalid tier");
        uint256 rId = currentRoundIds[tierId];
        Round storage r = tierRounds[tierId][rId];
        require(!r.finalized, "PicklePots: Round already finalized");
        require(block.timestamp >= r.deadline, "PicklePots: Deadline not elapsed");
        require(r.leader != address(0), "PicklePots: No bids placed in this round");

        _finalizeRound(tierId);
    }

    function _finalizeRound(uint8 tierId) internal {
        uint256 rId = currentRoundIds[tierId];
        Round storage r = tierRounds[tierId][rId];
        r.finalized = true;
        r.winner = r.leader;

        uint256 pot = r.potAmount;
        uint256 winnerPayout = (pot * WINNER_BPS) / 10000;
        uint256 seedForNext = (pot * SEED_BPS) / 10000;
        uint256 protocolTake = pot - winnerPayout - seedForNext;

        r.payout = winnerPayout;

        if (address(feeRouter) != address(0) && protocolTake > 0) {
            (uint256 builderShare, uint256 ecosystemShare) = feeRouter.routeProtocolFee{value: protocolTake}(address(this), protocolTake);
            emit ProtocolFeeRouted(tierId, protocolTake, builderShare, ecosystemShare);
        } else if (protocolTake > 0) {
            (bool feeSuccess, ) = feeRecipient.call{value: protocolTake}("");
            require(feeSuccess, "PicklePots: Fee transfer failed");
            emit ProtocolFeeRouted(tierId, protocolTake, protocolTake, 0);
        }

        (bool winSuccess, ) = payable(r.winner).call{value: winnerPayout}("");
        require(winSuccess, "PicklePots: Winner payout failed");

        emit RoundFinalized(tierId, rId, r.winner, winnerPayout, seedForNext, protocolTake);

        _startNewRound(tierId, seedForNext);
    }

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
        require(tierId < NUM_TIERS, "PicklePots: Invalid tier");
        uint256 rId = currentRoundIds[tierId];
        Round storage r = tierRounds[tierId][rId];
        TierConfig memory cfg = tierConfigs[tierId];

        roundId = r.roundId;
        potAmount = r.potAmount;
        leader = r.leader;
        deadline = r.deadline;
        totalBids = r.totalBids;
        tierName = cfg.name;
        minBid = cfg.minBid;

        if (block.timestamp >= r.deadline) {
            timeLeft = 0;
            isExpired = true;
        } else {
            timeLeft = r.deadline - block.timestamp;
            isExpired = false;
        }
    }

    receive() external payable {
        revert("PicklePots: Use dropBid(tierId) to enter");
    }
}

