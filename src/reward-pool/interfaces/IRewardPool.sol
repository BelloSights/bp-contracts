// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @title IRewardPool
/// @notice Interface for RewardPool contracts
interface IRewardPool {
    /// @notice Token types supported by RewardPool
    enum TokenType {
        ERC20,   // 0 - ERC20 tokens
        NATIVE   // 1 - Native ETH
    }

    /// @notice Claim data structure for EIP-712 signatures
    struct ClaimData {
        address user;
        uint256 nonce;
        address tokenAddress;
        TokenType tokenType;
    }

    /// @notice Pool information structure
    struct PoolInfo {
        uint256 poolId;
        string name;
        string description;
        bool active;
        uint256 totalXP;
        uint256 userCount;
    }

    // ===== ADMIN FUNCTIONS (Factory Only) =====
    function initialize(
        address factory,
        string memory signingDomain,
        string memory signatureVersion
    ) external;
    function setActive(bool active) external;
    function addUser(address user, uint256 xp) external;
    function updateUserXP(address user, uint256 newXP) external;
    function penalizeUser(address user, uint256 xpToRemove) external;
    function grantSignerRole(address signer) external;
    function revokeSignerRole(address signer) external;

    function takeSnapshot(address[] calldata tokenAddresses) external;
    function takeNativeSnapshot() external;
    function emergencyWithdraw(
        address tokenAddress,
        address to,
        uint256 amount,
        TokenType tokenType
    ) external;

    // ===== PUBLIC FUNCTIONS =====
    function checkClaimEligibility(address user, address tokenAddress, TokenType tokenType)
        external
        view
        returns (bool canClaim, uint256 allocation);

    function claimReward(ClaimData calldata data, bytes calldata signature) external;

    // ===== VIEW FUNCTIONS =====
    function getUserXP(address user) external view returns (uint256);
    function isUser(address user) external view returns (bool);
    function getTotalUsers() external view returns (uint256);
    function getUserAtIndex(uint256 index) external view returns (address);
    function hasClaimed(address user, address tokenAddress, TokenType tokenType)
        external
        view
        returns (bool);
    function getTotalClaimed(address tokenAddress, TokenType tokenType)
        external
        view
        returns (uint256);
    function getAvailableRewards(address tokenAddress, TokenType tokenType)
        external
        view
        returns (uint256);
    function getSnapshotAmount(address tokenAddress, TokenType tokenType)
        external
        view
        returns (uint256);
    function getTotalRewards(address tokenAddress, TokenType tokenType)
        external
        view
        returns (uint256);
    function getUserNonceCounter(address user) external view returns (uint256);
    function isNonceUsed(address user, uint256 nonce) external view returns (bool);
    function getNextNonce(address user) external view returns (uint256);
    function s_active() external view returns (bool);
    function s_totalXP() external view returns (uint256);
    function s_snapshotTaken() external view returns (bool);

    // ===== EVENTS =====
    event PoolActivated();
    event PoolDeactivated();
    event UserAdded(address indexed user, uint256 xp);
    event UserXPUpdated(address indexed user, uint256 oldXP, uint256 newXP);
    event UserPenalized(address indexed user, uint256 xpRemoved);
    event RewardClaimed(
        address indexed user,
        address indexed tokenAddress,
        uint256 amount,
        TokenType tokenType,
        uint256 userXP,
        uint256 totalXP
    );

    event SnapshotTaken(uint256 nativeAmount, address[] tokens, uint256[] tokenAmounts);
}
