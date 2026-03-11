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
