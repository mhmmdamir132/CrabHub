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
    mapping(address => address[]) private _followerList;

    mapping(address => uint256) private _dealsOpenedThisEpoch;
    mapping(address => uint256) private _lastEpochIndexByClaw;
    mapping(address => uint256) private _lastPostBlock;
    mapping(address => uint256) private _lastProfileEditBlock;
    mapping(bytes32 => uint256) private _disputeOpenedAtBlock;
    mapping(bytes32 => address) private _disputeRaisedBy;

    uint256 public constant STATUS_OPEN = 0;
    uint256 public constant STATUS_SETTLED = 1;
    uint256 public constant STATUS_CANCELLED = 2;
    uint256 public constant STATUS_DISPUTED = 3;

    modifier onlyGovernor() {
        if (msg.sender != governor) revert CH_NotGovernor();
        _;
    }

    modifier onlyEscrowKeeper() {
        if (msg.sender != escrowKeeper) revert CH_NotEscrowKeeper();
        _;
    }

    modifier onlyGovernorOrKeeper() {
        if (msg.sender != governor && msg.sender != escrowKeeper) revert CH_NotGovernorOrKeeper();
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert CH_Paused();
        _;
    }

    constructor() {
        treasury = address(0x7B2d4F6a8C0e2A4c6E8b0d2F4a6C8e0B2d4F6a8C0);
        governor = address(0x9E3c5A7b0d2F4a6C8e1B3d5F7a9c2E4b6D8f0A2c4);
        escrowKeeper = address(0xD1f4a7C0e3B6d9F2b5E8c1A4d7F0b3E6a9C2e5F8);
        genesisBlock = block.number;
        if (treasury == address(0) || governor == address(0) || escrowKeeper == address(0)) revert CH_ZeroAddress();
        minDealWei = 317 * 1e15;
        maxDealWei = 2847 * 1e18;
        minSettleDelayBlocks = 186;
        maxSettleDelayBlocks = 4128;
    }

    // -------------------------------------------------------------------------
    // OTC: open deal (maker proposes; taker must deposit into escrow)
    // -------------------------------------------------------------------------

    function openOtcDeal(
        address taker,
        uint256 settleDelayBlocks,
        bytes32 payloadHash
    ) external payable whenNotPaused nonReentrant returns (bytes32 dealId) {
        if (taker == address(0)) revert CH_ZeroAddress();
        if (msg.value == 0) revert CH_ZeroAmount();
        if (msg.value < minDealWei) revert CH_BelowMinDeal();
        if (msg.value > maxDealWei) revert CH_ExceedsMaxDeal();
        if (settleDelayBlocks < minSettleDelayBlocks || settleDelayBlocks > maxSettleDelayBlocks) revert CH_InvalidSettleDelay();
        if (totalDealsOpened >= CLAW_MAX_DEALS) revert CH_DealLimitReached();
        uint256 epochIdx = (block.number - genesisBlock) / CLAW_EPOCH_BLOCKS;
        if (_lastEpochIndexByClaw[msg.sender] != epochIdx) {
            _lastEpochIndexByClaw[msg.sender] = epochIdx;
            _dealsOpenedThisEpoch[msg.sender] = 0;
        }
        if (_dealsOpenedThisEpoch[msg.sender] >= CLAW_DAILY_DEAL_CAP_PER_CLAW) revert CH_DealLimitReached();
        _dealsOpenedThisEpoch[msg.sender]++;

        dealId = keccak256(abi.encodePacked(block.number, block.timestamp, _nextDealId++, msg.sender, taker, msg.value));
        uint256 settleAfter = block.number + settleDelayBlocks;
        uint256 settleUntil = settleAfter + 1728;

        _deals[dealId] = OtcDeal({
            dealId: dealId,
            maker: msg.sender,
            taker: taker,
            amountWei: msg.value,
            settleAfterBlock: settleAfter,
            settleUntilBlock: settleUntil,
            payloadHash: payloadHash,
            status: STATUS_OPEN,
            createdAt: block.number
        });
        _dealIds.push(dealId);
        _makerDeals[msg.sender].push(dealId);
        _takerDeals[taker].push(dealId);
        totalDealsOpened++;

        uint256 fee = (msg.value * CLAW_FEE_BPS) / CLAW_BPS_DENOM;
        if (fee > 0) accruedFeesWei += fee;

        emit ClawOtcEscrowDeposited(dealId, msg.value, block.number);
        emit ClawOtcOpened(dealId, msg.sender, taker, msg.value, settleAfter, payloadHash, block.number);
        return dealId;
    }

    function settleOtcDeal(
        bytes32 dealId,
        uint256 makerAmount,
        uint256 takerAmount
    ) external onlyEscrowKeeper nonReentrant {
        OtcDeal storage d = _deals[dealId];
        if (d.maker == address(0)) revert CH_DealNotFound();
        if (d.status != STATUS_OPEN) revert CH_DealNotOpen();
        if (block.number < d.settleAfterBlock) revert CH_DealNotReadyToSettle();
        if (block.number > d.settleUntilBlock) revert CH_DealSettleWindowExpired();
        if (makerAmount + takerAmount != d.amountWei) revert CH_InvalidBounds();

        d.status = STATUS_SETTLED;
        totalDealsSettled++;

        (bool ok1,) = d.maker.call{value: makerAmount}("");
        if (!ok1) revert CH_TransferFailed();
        (bool ok2,) = d.taker.call{value: takerAmount}("");
        if (!ok2) revert CH_TransferFailed();

        emit ClawOtcSettled(dealId, d.maker, d.taker, makerAmount, takerAmount, block.number);
    }

    function cancelOtcDeal(bytes32 dealId) external nonReentrant {
        OtcDeal storage d = _deals[dealId];
        if (d.maker == address(0)) revert CH_DealNotFound();
        if (d.status != STATUS_OPEN) revert CH_DealNotOpen();
        if (msg.sender != d.maker && msg.sender != governor) revert CH_NotGovernor();

        d.status = STATUS_CANCELLED;
        (bool ok,) = d.maker.call{value: d.amountWei}("");
        if (!ok) revert CH_TransferFailed();

        emit ClawOtcCancelled(dealId, msg.sender, block.number);
    }

    function disputeOtcDeal(bytes32 dealId) external {
        OtcDeal storage d = _deals[dealId];
        if (d.maker == address(0)) revert CH_DealNotFound();
        if (d.status != STATUS_OPEN) revert CH_DealNotOpen();
        if (msg.sender != d.maker && msg.sender != d.taker) revert CH_DealNotFound();

        d.status = STATUS_DISPUTED;
        _disputeOpenedAtBlock[dealId] = block.number;
        _disputeRaisedBy[dealId] = msg.sender;
        emit ClawOtcDisputed(dealId, msg.sender, block.number);
    }

    // -------------------------------------------------------------------------
    // SOCIAL: claw profile
    // -------------------------------------------------------------------------

    function registerClawProfile(bytes32 handleHash) external whenNotPaused {
        if (_profiles[msg.sender].exists) revert CH_HandleAlreadyTaken();
        for (uint256 i = 0; i < _clawList.length; i++) {
            if (_profiles[_clawList[i]].handleHash == handleHash) revert CH_HandleAlreadyTaken();
        }
        _profiles[msg.sender] = ClawProfile({
            handleHash: handleHash,
            registeredAt: block.number,
            postCount: 0,
            exists: true
        });
        _clawList.push(msg.sender);
        emit ClawProfileRegistered(msg.sender, handleHash, block.number);
    }

    function updateClawProfile(bytes32 handleHash) external {
        if (!_profiles[msg.sender].exists) revert CH_ProfileNotFound();
