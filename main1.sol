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
