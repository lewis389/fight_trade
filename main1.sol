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
