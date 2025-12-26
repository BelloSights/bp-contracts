// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title ICreatorRewardPool
/// @notice Interface for Creator-specific RewardPool contracts with custom allocations
interface ICreatorRewardPool {
    /// @notice Token types supported by CreatorRewardPool
    enum TokenType {
        ERC20, // 0 - ERC20 tokens
        NATIVE // 1 - Native ETH
    }

    /// @notice Claim data structure for EIP-712 signatures
    struct ClaimData {
        address user;
        uint256 nonce;
        address tokenAddress;
        TokenType tokenType;
    }

    // ===== ADMIN FUNCTIONS (Factory Only) =====
    function initialize(
        address factory,
        address creator,
        string memory signingDomain,
        string memory signatureVersion,
        uint256 protocolFeeRate
    ) external;

    function setActive(bool active) external;
    function addUser(
        address user,
        address tokenAddress,
        TokenType tokenType,
        uint256 allocation
    ) external;
    function updateUserAllocation(
        address user,
        address tokenAddress,
        TokenType tokenType,
        uint256 newAllocation
    ) external;
    function removeUser(
        address user,
        address tokenAddress,
        TokenType tokenType
    ) external;
    function grantSignerRole(address signer) external;
    function revokeSignerRole(address signer) external;
    function setProtocolFeeRecipient(address recipient) external;

    // ===== BATCH ADMIN FUNCTIONS (Factory Only) =====
    function batchAddUsers(
        address tokenAddress,
        TokenType tokenType,
        address[] calldata users,
        uint256[] calldata allocations
    ) external;

    function batchUpdateUserAllocations(
        address tokenAddress,
        TokenType tokenType,
        address[] calldata users,
        uint256[] calldata newAllocations
    ) external;

    function batchRemoveUsers(
        address tokenAddress,
        TokenType tokenType,
        address[] calldata users
    ) external;

    function emergencyWithdraw(
        address tokenAddress,
        address to,
        uint256 amount,
        TokenType tokenType
    ) external;

    // ===== PUBLIC FUNCTIONS =====
    function checkClaimEligibility(
        address user,
        address tokenAddress,
        TokenType tokenType
    )
        external
        view
        returns (bool canClaim, uint256 allocation, uint256 protocolFee);

    function claimReward(
        ClaimData calldata data,
        bytes calldata signature
    ) external;

    /// @notice Claim rewards on behalf of a user (relayed claim)
    /// @param data Claim data struct
    /// @param signature EIP-712 signature
    function claimRewardFor(
        ClaimData calldata data,
        bytes calldata signature
    ) external;

    // ===== VIEW FUNCTIONS =====
    function getUserAllocationForToken(
        address user,
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256);
    function isUserForToken(
        address user,
        address tokenAddress,
        TokenType tokenType
    ) external view returns (bool);
    function getTotalUsersForToken(
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256);
    function getUserAtIndexForToken(
        address tokenAddress,
        TokenType tokenType,
        uint256 index
    ) external view returns (address);
    function hasClaimed(
        address user,
        address tokenAddress,
        TokenType tokenType
    ) external view returns (bool);
    function getTotalClaimed(
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256);
    function getProtocolFeesClaimed(
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256);
    function getAvailableRewards(
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256);
    function getUserNonceCounter(address user) external view returns (uint256);
    function isNonceUsed(
        address user,
        uint256 nonce
    ) external view returns (bool);
    function getNextNonce(address user) external view returns (uint256);
    function validateAllocations(
        address tokenAddress,
        TokenType tokenType
    )
        external
        view
        returns (
            bool isValid,
            uint256 totalAllocations,
            uint256 availableBalance
        );
    function getCreator() external view returns (address);
    function getProtocolFeeRate() external view returns (uint256);
    function getProtocolFeeRecipient() external view returns (address);
    function s_active() external view returns (bool);
    function getTotalAllocationsForToken(
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256);

    // ===== EVENTS =====
    event PoolActivated();
    event PoolDeactivated();
    event UserAdded(
        address indexed user,
        address indexed tokenAddress,
        TokenType tokenType,
        uint256 allocation
    );
    event UserAllocationUpdated(
        address indexed user,
        address indexed tokenAddress,
        TokenType tokenType,
        uint256 oldAllocation,
        uint256 newAllocation
    );
    event UserRemoved(
        address indexed user,
        address indexed tokenAddress,
        TokenType tokenType,
        uint256 allocation
    );
    event RewardClaimed(
        address indexed user,
        address indexed tokenAddress,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 protocolFee,
        TokenType tokenType,
        uint256 userAllocation,
        uint256 totalAllocations
    );
    event ProtocolFeeCollected(
        address indexed tokenAddress,
        uint256 amount,
        TokenType tokenType,
        address indexed recipient
    );
    event ProtocolFeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );
    event ProtocolFeeRateUpdated(uint256 oldRate, uint256 newRate);

    // ===== BATCH EVENTS =====
    event BatchUsersAdded(
        address[] users,
        uint256[] allocations,
        uint256 batchSize
    );
    event BatchUsersUpdated(
        address[] users,
        uint256[] oldAllocations,
        uint256[] newAllocations,
        uint256 batchSize
    );
    event BatchUsersRemoved(
        address[] users,
        uint256[] allocations,
        uint256 batchSize
    );

    // Optional event for offchain monitoring of allocation/balance mismatch
    event AllocationValidationWarning(
        address indexed tokenAddress,
        TokenType tokenType,
        uint256 totalAllocations,
        uint256 availableBalance,
        string message
    );
}
