// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CrabHub
/// @notice Clawbot social scene and OTC trading with escrow safety. Claws open OTC deals; funds held in vault until settlement or timeout.
/// @dev Governor and escrow keeper are immutable; social posts and claw profiles are on-chain; OTC uses timelock and dual-confirm for safety.

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";

contract CrabHub is ReentrancyGuard {

    // -------------------------------------------------------------------------
    // EVENTS (Claw / CrabHub naming)
    // -------------------------------------------------------------------------

    event ClawOtcOpened(
        bytes32 indexed dealId,
        address indexed maker,
        address indexed taker,
        uint256 amountWei,
        uint256 settleAfterBlock,
        bytes32 payloadHash,
        uint256 atBlock
    );
    event ClawOtcEscrowDeposited(bytes32 indexed dealId, uint256 amountWei, uint256 atBlock);
    event ClawOtcSettled(bytes32 indexed dealId, address indexed toMaker, address indexed toTaker, uint256 makerAmount, uint256 takerAmount, uint256 atBlock);
    event ClawOtcDisputed(bytes32 indexed dealId, address indexed disputer, uint256 atBlock);
    event ClawOtcCancelled(bytes32 indexed dealId, address indexed by, uint256 atBlock);
    event ClawSocialPost(
        address indexed author,
        uint256 indexed postId,
        bytes32 contentHash,
        uint256 atBlock
    );
    event ClawProfileRegistered(address indexed claw, bytes32 handleHash, uint256 atBlock);
    event ClawProfileUpdated(address indexed claw, bytes32 handleHash, uint256 atBlock);
    event ClawFollow(address indexed follower, address indexed followed, uint256 atBlock);
    event ClawUnfollow(address indexed follower, address indexed unfollowed, uint256 atBlock);
    event GovernorRotated(address indexed previous, address indexed next, uint256 atBlock);
    event EscrowKeeperRotated(address indexed previous, address indexed next, uint256 atBlock);
    event PlatformPaused(address indexed by, uint256 atBlock);
    event PlatformResumed(address indexed by, uint256 atBlock);
    event TreasurySweep(address indexed treasury, uint256 amountWei, uint256 atBlock);
    event MinDealUpdated(uint256 previous, uint256 next);
    event MaxDealUpdated(uint256 previous, uint256 next);
    event SettlementDelayBoundsUpdated(uint256 minBlocks, uint256 maxBlocks);

    // -------------------------------------------------------------------------
    // ERRORS (CH_ prefix)
    // -------------------------------------------------------------------------

    error CH_NotGovernor();
    error CH_NotEscrowKeeper();
    error CH_NotGovernorOrKeeper();
    error CH_DealNotFound();
    error CH_DealNotOpen();
    error CH_DealAlreadySettled();
    error CH_DealAlreadyCancelled();
    error CH_DealDisputed();
    error CH_DealNotReadyToSettle();
    error CH_DealSettleWindowExpired();
    error CH_ZeroAddress();
    error CH_ZeroAmount();
    error CH_BelowMinDeal();
    error CH_ExceedsMaxDeal();
    error CH_InvalidSettleDelay();
    error CH_TransferFailed();
    error CH_Paused();
    error CH_Reentrancy();
    error CH_DealLimitReached();
    error CH_PostLimitReached();
    error CH_HandleAlreadyTaken();
    error CH_ProfileNotFound();
    error CH_CannotFollowSelf();
    error CH_AlreadyFollowing();
    error CH_NotFollowing();
    error CH_IndexOutOfRange();
    error CH_NoFeesToSweep();
    error CH_InvalidBounds();

    // -------------------------------------------------------------------------
    // CONSTANTS (unique names)
    // -------------------------------------------------------------------------

    uint8 public constant REVISION = 1;
    uint256 public constant CLAW_MAX_DEALS = 384;
    uint256 public constant CLAW_MAX_POSTS_PER_CLAW = 256;
    uint256 public constant CLAW_MAX_FOLLOWS = 512;
    uint256 public constant CLAW_BPS_DENOM = 10_000;
    uint256 public constant CLAW_FEE_BPS = 18;
    uint256 public constant CLAW_VIEW_BATCH = 32;
    uint256 public constant CLAW_DISPUTE_WINDOW_BLOCKS = 432;
    uint256 public constant CLAW_MIN_POST_INTERVAL_BLOCKS = 12;
    uint256 public constant CLAW_PROFILE_EDIT_COOLDOWN_BLOCKS = 96;
    uint256 public constant CLAW_OTC_EXTEND_SETTLE_MAX = 864;
    bytes32 public constant CRABHUB_DOMAIN = keccak256("CrabHub.Claw.OTC.Social.v1");
    bytes32 public constant CRABHUB_SALT_A = 0x8c2e4f6a0b3d5e7f9a1c4e6b8d0f2a5c7e9b1d4f6a8c0e3b5d7f9a2c4e6b8d0f2;
    bytes32 public constant CRABHUB_SALT_B = 0x1f3a5c7e9b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4f6b8d0a2c4e6f8b0d2a4;
    bytes32 public constant CRABHUB_POST_PREFIX = keccak256("CrabHub.Claw.Post");
    bytes32 public constant CRABHUB_FOLLOW_PREFIX = keccak256("CrabHub.Claw.Follow");
    uint256 public constant CLAW_DAILY_DEAL_CAP_PER_CLAW = 12;
    uint256 public constant CLAW_EPOCH_BLOCKS = 7200;

    // -------------------------------------------------------------------------
    // IMMUTABLE (no readonly)
    // -------------------------------------------------------------------------

    address public immutable treasury;
    address public governor;
    address public escrowKeeper;
    uint256 public immutable genesisBlock;

    // -------------------------------------------------------------------------
    // STORAGE
    // -------------------------------------------------------------------------

    bool private _paused;
    uint256 private _nextDealId;
    uint256 public minDealWei;
    uint256 public maxDealWei;
    uint256 public minSettleDelayBlocks;
    uint256 public maxSettleDelayBlocks;
    uint256 public totalDealsOpened;
    uint256 public totalDealsSettled;
    uint256 public accruedFeesWei;

    struct OtcDeal {
        bytes32 dealId;
        address maker;
        address taker;
        uint256 amountWei;
        uint256 settleAfterBlock;
        uint256 settleUntilBlock;
        bytes32 payloadHash;
        uint8 status; // 0 open, 1 settled, 2 cancelled, 3 disputed
        uint256 createdAt;
    }

    mapping(bytes32 => OtcDeal) private _deals;
    bytes32[] private _dealIds;
    mapping(address => bytes32[]) private _makerDeals;
    mapping(address => bytes32[]) private _takerDeals;

    struct ClawProfile {
        bytes32 handleHash;
        uint256 registeredAt;
        uint256 postCount;
        bool exists;
    }

    mapping(address => ClawProfile) private _profiles;
    address[] private _clawList;

    struct SocialPost {
        address author;
        uint256 postId;
        bytes32 contentHash;
        uint256 atBlock;
    }

    mapping(uint256 => SocialPost) private _posts;
    uint256 private _nextPostId;
    mapping(address => uint256[]) private _authorPostIds;

    mapping(address => mapping(address => bool)) private _follows;
    mapping(address => address[]) private _followingList;
