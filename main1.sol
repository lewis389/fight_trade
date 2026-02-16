// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FightTradeVexel — On-chain arena for tactical exchange and resolved combat
/// @notice Combines limit-order style trading with commit-reveal battles and territory-based strategy.
/// @dev Vexel protocol: governor-managed fee tiers, battle epochs, and stratagem resolution hashes.

contract FightTradeVexel {
    // ─── Constants (unique namespace) ─────────────────────────────────────────────
    uint256 public constant VEXEL_ORDER_FEE_BPS = 18;
    uint256 public constant VEXEL_BATTLE_FEE_BPS = 45;
    uint256 public constant VEXEL_STRATAGEM_FEE_BPS = 12;
    uint256 public constant VEXEL_MAX_TERRITORIES = 64;
    uint256 public constant VEXEL_MAX_UNITS_PER_SLOT = 255;
    uint256 public constant VEXEL_BATTLE_COOLDOWN_BLOCKS = 120;
    uint256 public constant VEXEL_ORDER_TTL_BLOCKS = 50400;
    uint256 public constant VEXEL_COMMIT_PHASE_BLOCKS = 32;
    uint256 public constant VEXEL_REVEAL_PHASE_BLOCKS = 64;
    uint256 public constant VEXEL_MIN_ORDER_AMOUNT = 1e15;
    uint256 public constant VEXEL_MIN_BATTLE_STAKE = 1e16;
    uint256 public constant VEXEL_BPS_DENOM = 10000;
    bytes32 public constant VEXEL_DOMAIN_TAG = keccak256("FightTradeVexel.v1");
    uint256 public constant VEXEL_SEASON_DURATION_BLOCKS = 201600;
    uint256 public constant VEXEL_MAX_OPEN_ORDERS_PER_USER = 128;
    uint256 public constant VEXEL_MAX_ACTIVE_BATTLES = 256;
    uint256 public constant VEXEL_UNIT_TYPE_COUNT = 8;
    uint256 public constant VEXEL_RESOURCE_TYPE_COUNT = 16;
    uint256 public constant VEXEL_DEFAULT_CREDIT_BONUS_BPS = 0;
    uint256 public constant VEXEL_REFERRAL_BONUS_BPS = 25;
    uint256 public constant VEXEL_LEVEL_UP_THRESHOLD = 1000e18;

    // ─── Immutable governance & treasury (no readonly) ───────────────────────────
    address public immutable vexelGovernor;
    address public immutable vexelTreasury;
    address public immutable vexelVault;

    // ─── State ───────────────────────────────────────────────────────────────────
    uint256 private _locked;
    bool public vexelPaused;
    uint256 public orderNonce;
    uint256 public battleNonce;
    uint256 public stratagemNonce;
    uint256 public totalFeesCollected;
    uint256 public totalBattlesResolved;
    uint256 public totalOrdersFilled;

    struct VexelOrder {
        address maker;
        uint256 amountWei;
        uint256 priceBps;
        uint256 expiryBlock;
        bytes32 resourceId;
        bool isBuy;
        bool filled;
    }
    mapping(uint256 => VexelOrder) public vexelOrders;

    struct VexelBattle {
        address challenger;
        address defender;
        uint256 stakeWei;
        uint256 startBlock;
        bytes32 challengerCommit;
        bytes32 defenderCommit;
        uint8 status; // 0 open, 1 committed, 2 revealed, 3 resolved
        address winner;
    }
    mapping(uint256 => VexelBattle) public vexelBattles;

    struct VexelStratagem {
        address executor;
        uint256 territoryId;
        uint256 unitCount;
        bytes32 moveHash;
        uint256 executedBlock;
        bool resolved;
    }
    mapping(uint256 => VexelStratagem) public vexelStratagems;

    mapping(address => uint256) public vexelCredits;
    mapping(address => uint256) public lastBattleBlock;
    mapping(address => uint256[]) public ordersByMaker;
    mapping(bytes32 => uint256) public territoryResourceSupply;
    mapping(address => mapping(uint256 => uint256)) public territoryUnits;
    mapping(uint256 => uint256) public seasonStartBlock;
    mapping(uint256 => address) public seasonLeader;
    mapping(uint256 => uint256) public seasonLeaderScore;
    mapping(address => uint256) public userLevel;
    mapping(address => uint256) public userExperience;
    mapping(address => address) public referrerOf;
    mapping(address => uint256) public referralCount;
    mapping(uint256 => uint256[]) public battleIdsBySeason;
    mapping(uint256 => uint8) public unitTypeStrength;
    mapping(bytes32 => bool) public resourceIdWhitelist;
    uint256 public currentSeasonId;
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    // ─── Custom errors (unique names) ────────────────────────────────────────────
    error VexelUnauthorized();
    error VexelInsufficientCredits();
    error VexelOrderExpired();
    error VexelOrderAlreadyFilled();
    error VexelOrderAmountTooLow();
    error VexelBattleCooldown();
    error VexelBattleNotOpen();
    error VexelBattleAlreadyCommitted();
    error VexelBattleNotCommitted();
    error VexelRevealMismatch();
    error VexelStratagemAlreadyResolved();
    error VexelTerritoryOutOfRange();
    error VexelUnitsExceedMax();
    error VexelPaused();
    error VexelReentrancy();
    error VexelZeroAddress();
    error VexelInvalidPrice();
    error VexelSelfOrder();
    error VexelInvalidBattleId();
    error VexelInvalidOrderId();
    error VexelMaxOrdersReached();
    error VexelMaxBattlesReached();
    error VexelInvalidSeason();
    error VexelResourceNotWhitelisted();
    error VexelInvalidReferrer();
    error VexelAlreadyReferred();

    // ─── Events (unique names) ───────────────────────────────────────────────────
    event VexelOrderRaised(uint256 indexed orderId, address indexed maker, uint256 amountWei, uint256 priceBps, bytes32 resourceId, bool isBuy);
    event VexelOrderFilled(uint256 indexed orderId, address indexed taker, uint256 amountWei, uint256 feeWei);
    event VexelOrderCancelled(uint256 indexed orderId, address indexed maker);
    event VexelBattleOpened(uint256 indexed battleId, address indexed challenger, address indexed defender, uint256 stakeWei);
    event VexelBattleCommitted(uint256 indexed battleId, address indexed side);
    event VexelBattleSettled(uint256 indexed battleId, address indexed winner, uint256 payoutWei);
    event VexelStratagemExecuted(uint256 indexed stratagemId, address indexed executor, uint256 territoryId, uint256 unitCount);
    event VexelCreditsDeposited(address indexed account, uint256 amountWei);
    event VexelCreditsWithdrawn(address indexed account, uint256 amountWei);
    event VexelFeesSwept(address indexed treasury, uint256 amountWei);
    event VexelPauseToggled(bool paused);
    event VexelTerritorySupplied(bytes32 indexed resourceId, uint256 amount);
    event VexelSeasonAdvanced(uint256 indexed seasonId, uint256 startBlock, address indexed previousLeader, uint256 previousScore);
    event VexelUserLevelUp(address indexed account, uint256 newLevel);
    event VexelReferralSet(address indexed referrer, address indexed referred);
    event VexelResourceWhitelisted(bytes32 indexed resourceId, bool allowed);

    modifier vexelGovernorOnly() {
        if (msg.sender != vexelGovernor) revert VexelUnauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (vexelPaused) revert VexelPaused();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 0) revert VexelReentrancy();
        _locked = 1;
        _;
        _locked = 0;
    }

    constructor() {
        vexelGovernor = 0xAb3c7E2f9d1a4B6c8E0f2A5b7C9d1E3f6A8b0C2d4;
        vexelTreasury = 0xF2e5A8b1C4d7E0f3A6b9C2d5E8f1A4b7C0d3E6f9;
        vexelVault = 0x5C8e1F4a7b0D3e6F9a2C5d8E1f4A7b0C3d6E9f2a;
        orderNonce = 0;
        battleNonce = 0;
        stratagemNonce = 0;
        currentSeasonId = 1;
        seasonStartBlock[1] = block.number;
        unitTypeStrength[0] = 10;
        unitTypeStrength[1] = 25;
        unitTypeStrength[2] = 15;
        unitTypeStrength[3] = 30;
        unitTypeStrength[4] = 20;
        unitTypeStrength[5] = 35;
        unitTypeStrength[6] = 40;
        unitTypeStrength[7] = 50;
        resourceIdWhitelist[keccak256("GOLD")] = true;
        resourceIdWhitelist[keccak256("ORE")] = true;
        resourceIdWhitelist[keccak256("GRAIN")] = true;
        resourceIdWhitelist[keccak256("WOOD")] = true;
    }

    /// @notice Deposit ETH as credits for trading and battles. Optional referrer gets bonus.
    function depositCredits(address referrer) external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert VexelInsufficientCredits();
        totalDeposited += msg.value;
        if (referrer != address(0) && referrer != msg.sender) {
            if (referrerOf[msg.sender] != address(0)) revert VexelAlreadyReferred();
            referrerOf[msg.sender] = referrer;
            referralCount[referrer]++;
            uint256 bonus = (msg.value * VEXEL_REFERRAL_BONUS_BPS) / VEXEL_BPS_DENOM;
            vexelCredits[referrer] += bonus;
            vexelCredits[msg.sender] += (msg.value - bonus);
            emit VexelReferralSet(referrer, msg.sender);
        } else {
            vexelCredits[msg.sender] += msg.value;
        }
        emit VexelCreditsDeposited(msg.sender, msg.value);
    }

    /// @notice Withdraw credits back to caller.
    function withdrawCredits(uint256 amountWei) external nonReentrant {
        if (vexelCredits[msg.sender] < amountWei) revert VexelInsufficientCredits();
        vexelCredits[msg.sender] -= amountWei;
        totalWithdrawn += amountWei;
        (bool ok,) = msg.sender.call{value: amountWei}("");
        if (!ok) revert VexelInsufficientCredits();
        emit VexelCreditsWithdrawn(msg.sender, amountWei);
    }

    /// @notice Place a limit order (buy or sell) for a resource.
    function placeOrder(
        uint256 amountWei,
        uint256 priceBps,
        bytes32 resourceId,
        bool isBuy
    ) external whenNotPaused nonReentrant returns (uint256 orderId) {
        if (amountWei < VEXEL_MIN_ORDER_AMOUNT) revert VexelOrderAmountTooLow();
        if (priceBps == 0 || priceBps > VEXEL_BPS_DENOM) revert VexelInvalidPrice();
        if (!resourceIdWhitelist[resourceId]) revert VexelResourceNotWhitelisted();
        uint256 openCount = 0;
        for (uint256 i = 0; i < ordersByMaker[msg.sender].length; ) {
            if (!vexelOrders[ordersByMaker[msg.sender][i]].filled && vexelOrders[ordersByMaker[msg.sender][i]].amountWei > 0) openCount++;
            unchecked { ++i; }
        }
        if (openCount >= VEXEL_MAX_OPEN_ORDERS_PER_USER) revert VexelMaxOrdersReached();
        if (vexelCredits[msg.sender] < amountWei) revert VexelInsufficientCredits();
        vexelCredits[msg.sender] -= amountWei;
        orderId = ++orderNonce;
        uint256 expiryBlock = block.number + VEXEL_ORDER_TTL_BLOCKS;
        vexelOrders[orderId] = VexelOrder({
            maker: msg.sender,
            amountWei: amountWei,
            priceBps: priceBps,
            expiryBlock: expiryBlock,
            resourceId: resourceId,
            isBuy: isBuy,
            filled: false
        });
        ordersByMaker[msg.sender].push(orderId);
        emit VexelOrderRaised(orderId, msg.sender, amountWei, priceBps, resourceId, isBuy);
        return orderId;
    }

    /// @notice Fill an existing order; taker pays from credits and maker receives (minus fee).
    function fillOrder(uint256 orderId, uint256 takeAmountWei) external whenNotPaused nonReentrant {
        VexelOrder storage o = vexelOrders[orderId];
        if (o.maker == address(0)) revert VexelInvalidOrderId();
        if (o.filled) revert VexelOrderAlreadyFilled();
        if (block.number > o.expiryBlock) revert VexelOrderExpired();
        if (o.maker == msg.sender) revert VexelSelfOrder();
        uint256 fillAmount = takeAmountWei;
        if (fillAmount > o.amountWei) fillAmount = o.amountWei;
        if (fillAmount == 0) revert VexelOrderAmountTooLow();
        uint256 fee = (fillAmount * VEXEL_ORDER_FEE_BPS) / VEXEL_BPS_DENOM;
        uint256 toMaker = fillAmount - fee;
        if (vexelCredits[msg.sender] < fillAmount) revert VexelInsufficientCredits();
        vexelCredits[msg.sender] -= fillAmount;
        vexelCredits[o.maker] += toMaker;
        totalFeesCollected += fee;
        totalOrdersFilled += 1;
        o.amountWei -= fillAmount;
        if (o.amountWei == 0) o.filled = true;
        _addExperience(msg.sender, fillAmount / 1e15);
        _addExperience(o.maker, fillAmount / 1e15);
        emit VexelOrderFilled(orderId, msg.sender, fillAmount, fee);
    }

    /// @notice Cancel an unfilled order and return credits to maker.
    function cancelOrder(uint256 orderId) external nonReentrant {
        VexelOrder storage o = vexelOrders[orderId];
        if (o.maker != msg.sender) revert VexelUnauthorized();
        if (o.filled) revert VexelOrderAlreadyFilled();
        uint256 refund = o.amountWei;
        o.amountWei = 0;
        o.filled = true;
        vexelCredits[msg.sender] += refund;
        emit VexelOrderCancelled(orderId, msg.sender);
    }

    /// @notice Open a battle challenge against defender; both must have at least stake in credits.
    function openBattle(address defender, uint256 stakeWei) external whenNotPaused nonReentrant returns (uint256 battleId) {
        if (defender == address(0) || defender == msg.sender) revert VexelZeroAddress();
        if (stakeWei < VEXEL_MIN_BATTLE_STAKE) revert VexelInsufficientCredits();
        if (block.number < lastBattleBlock[msg.sender] + VEXEL_BATTLE_COOLDOWN_BLOCKS) revert VexelBattleCooldown();
        if (vexelCredits[msg.sender] < stakeWei || vexelCredits[defender] < stakeWei) revert VexelInsufficientCredits();
        vexelCredits[msg.sender] -= stakeWei;
        vexelCredits[defender] -= stakeWei;
        battleId = ++battleNonce;
        vexelBattles[battleId] = VexelBattle({
            challenger: msg.sender,
            defender: defender,
            stakeWei: stakeWei,
            startBlock: block.number,
            challengerCommit: bytes32(0),
            defenderCommit: bytes32(0),
            status: 0,
            winner: address(0)
        });
        lastBattleBlock[msg.sender] = block.number;
        lastBattleBlock[defender] = block.number;
        battleIdsBySeason[currentSeasonId].push(battleId);
        emit VexelBattleOpened(battleId, msg.sender, defender, stakeWei);
        return battleId;
    }

    /// @notice Submit commit hash for a battle (challenger or defender).
    function commitBattle(uint256 battleId, bytes32 commitHash) external whenNotPaused nonReentrant {
        VexelBattle storage b = vexelBattles[battleId];
        if (b.challenger == address(0)) revert VexelInvalidBattleId();
        if (b.status != 0) revert VexelBattleNotOpen();
        uint256 deadline = b.startBlock + VEXEL_COMMIT_PHASE_BLOCKS;
        if (block.number > deadline) revert VexelBattleNotOpen();
        if (msg.sender == b.challenger) {
            if (b.challengerCommit != bytes32(0)) revert VexelBattleAlreadyCommitted();
            b.challengerCommit = commitHash;
        } else if (msg.sender == b.defender) {
            if (b.defenderCommit != bytes32(0)) revert VexelBattleAlreadyCommitted();
            b.defenderCommit = commitHash;
        } else revert VexelUnauthorized();
        if (b.challengerCommit != bytes32(0) && b.defenderCommit != bytes32(0)) b.status = 1;
        emit VexelBattleCommitted(battleId, msg.sender);
    }

    /// @notice Reveal move and resolve battle; winner takes 2*stake minus fee.
    function revealBattle(uint256 battleId, bytes32 moveNonceChallenger, bytes32 moveNonceDefender) external whenNotPaused nonReentrant {
        VexelBattle storage b = vexelBattles[battleId];
        if (b.challenger == address(0)) revert VexelInvalidBattleId();
        if (b.status != 1) revert VexelBattleNotCommitted();
        uint256 revealStart = b.startBlock + VEXEL_COMMIT_PHASE_BLOCKS;
        uint256 revealEnd = revealStart + VEXEL_REVEAL_PHASE_BLOCKS;
        if (block.number < revealStart || block.number > revealEnd) revert VexelBattleNotCommitted();
        if (keccak256(abi.encodePacked(msg.sender, moveNonceChallenger, VEXEL_DOMAIN_TAG)) != b.challengerCommit && msg.sender != b.defender) revert VexelRevealMismatch();
        if (keccak256(abi.encodePacked(b.defender, moveNonceDefender, VEXEL_DOMAIN_TAG)) != b.defenderCommit) revert VexelRevealMismatch();
        b.status = 2;
        uint256 combinedStake = b.stakeWei * 2;
        uint256 fee = (combinedStake * VEXEL_BATTLE_FEE_BPS) / VEXEL_BPS_DENOM;
        uint256 payout = combinedStake - fee;
        totalFeesCollected += fee;
        totalBattlesResolved += 1;
        address winner = _resolveWinner(moveNonceChallenger, moveNonceDefender, b.challenger, b.defender);
        b.winner = winner;
        b.status = 3;
        vexelCredits[winner] += payout;
        _addExperience(winner, b.stakeWei / 1e15);
        emit VexelBattleSettled(battleId, winner, payout);
    }

    function _addExperience(address account, uint256 xp) internal {
        if (account == address(0)) return;
        userExperience[account] += xp;
        while (userExperience[account] >= (userLevel[account] + 1) * VEXEL_LEVEL_UP_THRESHOLD) {
            userLevel[account]++;
            emit VexelUserLevelUp(account, userLevel[account]);
        }
    }

    function _resolveWinner(bytes32 c, bytes32 d, address challenger, address defender) internal pure returns (address) {
        uint256 cc = uint256(c) % 100;
        uint256 dd = uint256(d) % 100;
        if (cc > dd) return challenger;
        if (dd > cc) return defender;
        return challenger;
    }

    /// @notice Execute a stratagem (territory move); consumes credits and records move hash.
    function executeStratagem(
        uint256 territoryId,
        uint256 unitCount,
        bytes32 moveHash
    ) external whenNotPaused nonReentrant returns (uint256 stratagemId) {
        if (territoryId >= VEXEL_MAX_TERRITORIES) revert VexelTerritoryOutOfRange();
        if (unitCount > VEXEL_MAX_UNITS_PER_SLOT) revert VexelUnitsExceedMax();
        uint256 cost = unitCount * 1e14;
        if (vexelCredits[msg.sender] < cost) revert VexelInsufficientCredits();
        vexelCredits[msg.sender] -= cost;
        uint256 fee = (cost * VEXEL_STRATAGEM_FEE_BPS) / VEXEL_BPS_DENOM;
        totalFeesCollected += fee;
        stratagemId = ++stratagemNonce;
        vexelStratagems[stratagemId] = VexelStratagem({
            executor: msg.sender,
            territoryId: territoryId,
            unitCount: unitCount,
            moveHash: moveHash,
            executedBlock: block.number,
            resolved: false
        });
        territoryUnits[msg.sender][territoryId] += unitCount;
        emit VexelStratagemExecuted(stratagemId, msg.sender, territoryId, unitCount);
        return stratagemId;
    }

    /// @notice Mark stratagem as resolved (e.g. after off-chain verification).
    function resolveStratagem(uint256 stratagemId) external vexelGovernorOnly {
        VexelStratagem storage s = vexelStratagems[stratagemId];
        if (s.executor == address(0)) revert VexelTerritoryOutOfRange();
        if (s.resolved) revert VexelStratagemAlreadyResolved();
        s.resolved = true;
    }

    /// @notice Top up resource supply for a territory resource (governor).
    function supplyTerritoryResource(bytes32 resourceId, uint256 amount) external vexelGovernorOnly {
        territoryResourceSupply[resourceId] += amount;
        emit VexelTerritorySupplied(resourceId, amount);
    }

    /// @notice Pause trading and battles.
    function setPaused(bool paused) external vexelGovernorOnly {
        vexelPaused = paused;
        emit VexelPauseToggled(paused);
    }

    /// @notice Governor: advance to next season and record leader.
    function advanceSeason() external vexelGovernorOnly {
        uint256 prev = currentSeasonId;
        address leader = seasonLeader[prev];
        uint256 score = seasonLeaderScore[prev];
        currentSeasonId++;
        seasonStartBlock[currentSeasonId] = block.number;
        emit VexelSeasonAdvanced(currentSeasonId, block.number, leader, score);
    }

    /// @notice Governor: set season leader and score for a season.
    function setSeasonLeader(uint256 seasonId, address leader, uint256 score) external vexelGovernorOnly {
        seasonLeader[seasonId] = leader;
        seasonLeaderScore[seasonId] = score;
    }

    /// @notice Governor: whitelist or remove a resource for orders.
    function setResourceWhitelist(bytes32 resourceId, bool allowed) external vexelGovernorOnly {
        resourceIdWhitelist[resourceId] = allowed;
        emit VexelResourceWhitelisted(resourceId, allowed);
    }

    /// @notice Governor: grant experience to an account (e.g. events or migration).
    function grantExperience(address account, uint256 xp) external vexelGovernorOnly {
        if (account == address(0)) revert VexelZeroAddress();
        _addExperience(account, xp);
    }

    /// @notice Governor: set unit type strength for strategy resolution.
    function setUnitTypeStrength(uint256 unitType, uint8 strength) external vexelGovernorOnly {
        if (unitType >= VEXEL_UNIT_TYPE_COUNT) revert VexelTerritoryOutOfRange();
        unitTypeStrength[unitType] = strength;
    }

    /// @notice Sweep accumulated fees to treasury.
    function sweepFees() external nonReentrant {
        uint256 amount = totalFeesCollected;
        if (amount == 0) return;
        totalFeesCollected = 0;
        (bool ok,) = vexelTreasury.call{value: amount}("");
        if (!ok) revert VexelInsufficientCredits();
        emit VexelFeesSwept(vexelTreasury, amount);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────────
    function getOrder(uint256 orderId) external view returns (
        address maker,
        uint256 amountWei,
        uint256 priceBps,
        uint256 expiryBlock,
        bytes32 resourceId,
        bool isBuy,
        bool filled
    ) {
        VexelOrder storage o = vexelOrders[orderId];
        return (o.maker, o.amountWei, o.priceBps, o.expiryBlock, o.resourceId, o.isBuy, o.filled);
    }

    function getBattle(uint256 battleId) external view returns (
        address challenger,
        address defender,
        uint256 stakeWei,
        uint256 startBlock,
        bytes32 challengerCommit,
        bytes32 defenderCommit,
        uint8 status,
        address winner
    ) {
        VexelBattle storage b = vexelBattles[battleId];
        return (b.challenger, b.defender, b.stakeWei, b.startBlock, b.challengerCommit, b.defenderCommit, b.status, b.winner);
    }

    function getStratagem(uint256 stratagemId) external view returns (
        address executor,
        uint256 territoryId,
        uint256 unitCount,
        bytes32 moveHash,
        uint256 executedBlock,
        bool resolved
    ) {
        VexelStratagem storage s = vexelStratagems[stratagemId];
        return (s.executor, s.territoryId, s.unitCount, s.moveHash, s.executedBlock, s.resolved);
    }

    function getMakerOrderIds(address maker) external view returns (uint256[] memory) {
        return ordersByMaker[maker];
    }

    function getTerritoryUnits(address account, uint256 territoryId) external view returns (uint256) {
        return territoryUnits[account][territoryId];
    }

    function getResourceSupply(bytes32 resourceId) external view returns (uint256) {
        return territoryResourceSupply[resourceId];
    }

    function getSeasonInfo(uint256 seasonId) external view returns (uint256 startBlock, address leader, uint256 leaderScore) {
        return (seasonStartBlock[seasonId], seasonLeader[seasonId], seasonLeaderScore[seasonId]);
    }

    function getCurrentSeasonBlocksRemaining() external view returns (uint256) {
        uint256 end = seasonStartBlock[currentSeasonId] + VEXEL_SEASON_DURATION_BLOCKS;
        if (block.number >= end) return 0;
        return end - block.number;
    }

    function getBatchOrders(uint256[] calldata orderIds) external view returns (
        address[] memory makers,
        uint256[] memory amounts,
        uint256[] memory priceBps,
        uint256[] memory expiryBlocks,
        bytes32[] memory resourceIds,
        bool[] memory isBuys,
        bool[] memory filled
    ) {
        uint256 n = orderIds.length;
        makers = new address[](n);
        amounts = new uint256[](n);
