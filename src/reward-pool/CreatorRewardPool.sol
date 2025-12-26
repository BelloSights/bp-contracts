// SPDX-License-Identifier: Apache-2.0
/*
__________.__                             .__        __   
\______   \  |  __ __   ____ _____________|__| _____/  |_ 
 |    |  _/  | |  |  \_/ __ \\____ \_  __ \  |/    \   __\
 |    |   \  |_|  |  /\  ___/|  |_> >  | \/  |   |  \  |  
 |______  /____/____/  \___  >   __/|__|  |__|___|  /__|  
        \/                 \/|__|                 \/      
*/

pragma solidity 0.8.28;

import {EIP712Upgradeable} from "@openzeppelin-contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin-contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {ICreatorRewardPool} from "./interfaces/ICreatorRewardPool.sol";

/// @title CreatorRewardPool
/// @notice Custom allocation-based reward pool for creators with protocol fees
/// @dev Creators set custom reward allocations for users, with 1% protocol fee on claims
contract CreatorRewardPool is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuardUpgradeable,
    ICreatorRewardPool
{
    using ECDSA for bytes32;

    // ===== ERRORS =====
    error CreatorRewardPool__OnlyFactory();
    error CreatorRewardPool__PoolNotActive();
    error CreatorRewardPool__UserNotInPool();
    error CreatorRewardPool__InvalidSignature();
    error CreatorRewardPool__NonceAlreadyUsed();
    error CreatorRewardPool__InsufficientRewards();
    error CreatorRewardPool__ZeroAddress();
    error CreatorRewardPool__UserAlreadyExists();
    error CreatorRewardPool__TransferFailed();
    error CreatorRewardPool__InvalidTokenType();
    error CreatorRewardPool__InvalidAllocationAmount();
    error CreatorRewardPool__AlreadyClaimed();
    error CreatorRewardPool__CannotUpdateAllocationsWhenActive();
    error CreatorRewardPool__InsufficientPoolBalance();
    error CreatorRewardPool__CannotWithdrawWhenActive();
    error CreatorRewardPool__InvalidProtocolFeeRate();

    // ===== CONSTANTS =====
    uint256 public constant MAX_PROTOCOL_FEE_RATE = 1000; // 10% maximum
    uint256 public constant FEE_PRECISION = 10000; // 0.01% precision (basis points)

    // ===== STATE VARIABLES =====
    address public s_factory;
    address public s_creator;
    bool public s_active;
    uint256 public s_protocolFeeRate; // Fee rate in basis points (100 = 1%)
    address public s_protocolFeeRecipient;

    // Per-token allocation tracking
    mapping(address => mapping(TokenType => mapping(address => uint256)))
        public s_userAllocationsByToken;

    // Per-token user tracking
    mapping(address => mapping(TokenType => address[])) public s_usersByToken;
    mapping(address => mapping(TokenType => mapping(address => bool)))
        public s_isUserByToken;

    // Per-token total allocations
    mapping(address => mapping(TokenType => uint256))
        public s_totalAllocationsByToken;

    // Nonce tracking for replay protection (per-user)
    mapping(address => mapping(uint256 => bool)) public s_usedNonces;
    mapping(address => uint256) public s_userNonceCounter;

    // Claim tracking to prevent double claiming
    mapping(address => mapping(address => mapping(TokenType => bool)))
        public s_hasClaimed;

    // Track total claimed amounts and protocol fees
    mapping(address => mapping(TokenType => uint256)) public s_totalClaimed;
    mapping(address => mapping(TokenType => uint256))
        public s_protocolFeesClaimed;

    // Roles
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER");

    // EIP-712 typehashes
    bytes32 internal constant CLAIM_DATA_HASH =
        keccak256(
            "ClaimData(address user,uint256 nonce,address tokenAddress,uint8 tokenType)"
        );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the creator reward pool
    /// @param factory The factory contract address
    /// @param creator The creator address who owns this pool
    /// @param signingDomain The EIP-712 signing domain
    /// @param signatureVersion The signature version
    /// @param protocolFeeRate The protocol fee rate in basis points (0 = no fees, max 1000 = 10%)
    function initialize(
        address factory,
        address creator,
        string calldata signingDomain,
        string calldata signatureVersion,
        uint256 protocolFeeRate
    ) external initializer {
        if (factory == address(0)) revert CreatorRewardPool__ZeroAddress();
        if (creator == address(0)) revert CreatorRewardPool__ZeroAddress();
        if (protocolFeeRate > MAX_PROTOCOL_FEE_RATE)
            revert CreatorRewardPool__InvalidProtocolFeeRate();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __EIP712_init(signingDomain, signatureVersion);
        __ReentrancyGuard_init();

        s_factory = factory;
        s_creator = creator;
        s_protocolFeeRate = protocolFeeRate;
        s_protocolFeeRecipient = factory; // Default to factory
        s_active = false;

        // Grant admin role to factory
        _grantRole(DEFAULT_ADMIN_ROLE, s_factory);
    }

    /// @notice Modifier to ensure only factory can call admin functions
    modifier onlyFactory() {
        if (msg.sender != s_factory) revert CreatorRewardPool__OnlyFactory();
        _;
    }

    /// @notice Modifier to ensure pool is active
    modifier onlyActive() {
        if (!s_active) revert CreatorRewardPool__PoolNotActive();
        _;
    }

    /// @notice Sets the active state of the pool
    /// @param active True to activate, false to deactivate
    function setActive(bool active) external onlyFactory {
        s_active = active;
        if (active) {
            emit PoolActivated();
        } else {
            emit PoolDeactivated();
        }
    }

    /// @notice Sets the protocol fee recipient
    /// @param recipient New protocol fee recipient address
    function setProtocolFeeRecipient(address recipient) external onlyFactory {
        if (recipient == address(0)) revert CreatorRewardPool__ZeroAddress();
        address oldRecipient = s_protocolFeeRecipient;
        s_protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(oldRecipient, recipient);
    }

    /// @notice Adds a new user to the pool with custom allocation for a specific token
    /// @param user User address
    /// @param tokenAddress Token address (address(0) for native)
    /// @param tokenType Token type (NATIVE or ERC20)
    /// @param allocation Absolute allocation amount for this token
    function addUser(
        address user,
        address tokenAddress,
        TokenType tokenType,
        uint256 allocation
    ) external onlyFactory {
        if (s_active)
            revert CreatorRewardPool__CannotUpdateAllocationsWhenActive();
        if (user == address(0)) revert CreatorRewardPool__ZeroAddress();

        // Validate token parameters
        if (tokenType == TokenType.NATIVE) {
            if (tokenAddress != address(0))
                revert CreatorRewardPool__InvalidTokenType();
        } else if (tokenType == TokenType.ERC20) {
            if (tokenAddress == address(0))
                revert CreatorRewardPool__InvalidTokenType();
        } else {
            revert CreatorRewardPool__InvalidTokenType();
        }

        if (s_isUserByToken[tokenAddress][tokenType][user])
            revert CreatorRewardPool__UserAlreadyExists();

        s_userAllocationsByToken[tokenAddress][tokenType][user] = allocation;
        s_usersByToken[tokenAddress][tokenType].push(user);
        s_isUserByToken[tokenAddress][tokenType][user] = true;
        if (allocation > 0) {
            s_totalAllocationsByToken[tokenAddress][tokenType] += allocation;
        }

        emit UserAdded(user, tokenAddress, tokenType, allocation);
    }

    /// @notice Updates allocation for an existing user scoped to token
    /// @param user User address
    /// @param tokenAddress Token address (address(0) for native)
    /// @param tokenType Token type
    /// @param newAllocation New allocation amount
    function updateUserAllocation(
        address user,
        address tokenAddress,
        TokenType tokenType,
        uint256 newAllocation
    ) external onlyFactory {
        if (s_active)
            revert CreatorRewardPool__CannotUpdateAllocationsWhenActive();
        if (!s_isUserByToken[tokenAddress][tokenType][user])
            revert CreatorRewardPool__UserNotInPool();

        uint256 oldAllocation = s_userAllocationsByToken[tokenAddress][
            tokenType
        ][user];
        s_totalAllocationsByToken[tokenAddress][tokenType] =
            s_totalAllocationsByToken[tokenAddress][tokenType] -
            oldAllocation +
            newAllocation;
        s_userAllocationsByToken[tokenAddress][tokenType][user] = newAllocation;

        // Remove user for this token if allocation becomes 0
        if (newAllocation == 0) {
            s_isUserByToken[tokenAddress][tokenType][user] = false;
        }

        emit UserAllocationUpdated(
            user,
            tokenAddress,
            tokenType,
            oldAllocation,
            newAllocation
        );
    }

    /// @notice Removes a user from the pool for a specific token
    /// @param user User address to remove
    /// @param tokenAddress Token address (address(0) for native)
    /// @param tokenType Token type
    function removeUser(
        address user,
        address tokenAddress,
        TokenType tokenType
    ) external onlyFactory {
        if (s_active)
            revert CreatorRewardPool__CannotUpdateAllocationsWhenActive();
        if (!s_isUserByToken[tokenAddress][tokenType][user])
            revert CreatorRewardPool__UserNotInPool();

        uint256 allocation = s_userAllocationsByToken[tokenAddress][tokenType][
            user
        ];
        s_totalAllocationsByToken[tokenAddress][tokenType] -= allocation;
        s_userAllocationsByToken[tokenAddress][tokenType][user] = 0;
        s_isUserByToken[tokenAddress][tokenType][user] = false;

        emit UserRemoved(user, tokenAddress, tokenType, allocation);
    }

    /// @notice Grants signer role to an address
    /// @param signer Address to grant signer role
    function grantSignerRole(address signer) external onlyFactory {
        _grantRole(SIGNER_ROLE, signer);
    }

    /// @notice Revokes signer role from an address
    /// @param signer Address to revoke signer role
    function revokeSignerRole(address signer) external onlyFactory {
        _revokeRole(SIGNER_ROLE, signer);
    }

    /// @notice Validates that allocations don't exceed available balance
    /// @param tokenAddress Token address to validate
    /// @param tokenType Type of token
    /// @return isValid True if allocations are valid
    /// @return totalAllocations Total allocation amount
    /// @return availableBalance Available balance for distribution
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
        )
    {
        // Validate token parameters and read current balances
        if (tokenType == TokenType.NATIVE) {
            if (tokenAddress != address(0)) return (false, 0, 0);
            availableBalance = address(this).balance;
        } else if (tokenType == TokenType.ERC20) {
            if (tokenAddress == address(0)) return (false, 0, 0);
            availableBalance = IERC20(tokenAddress).balanceOf(address(this));
        } else {
            return (false, 0, 0);
        }

        totalAllocations = s_totalAllocationsByToken[tokenAddress][tokenType];
        isValid = totalAllocations <= availableBalance;

        return (isValid, totalAllocations, availableBalance);
    }

    /// @notice Checks if a user can claim rewards and calculates their allocation
    /// @param user User address
    /// @param tokenAddress Token address
    /// @param tokenType Type of token
    /// @return canClaim True if user can claim
    /// @return allocation User's reward allocation (before fees)
    /// @return protocolFee Protocol fee amount
    function checkClaimEligibility(
        address user,
        address tokenAddress,
        TokenType tokenType
    )
        external
        view
        returns (bool canClaim, uint256 allocation, uint256 protocolFee)
    {
        if (!s_active) {
            return (false, 0, 0);
        }

        // Must be a user for this token
        if (!s_isUserByToken[tokenAddress][tokenType][user]) {
            return (false, 0, 0);
        }

        // Check if user has already claimed this token type
        if (s_hasClaimed[user][tokenAddress][tokenType]) {
            return (false, 0, 0);
        }

        // CRITICAL: Validate tokenAddress and tokenType combination
        if (tokenType == TokenType.NATIVE) {
            if (tokenAddress != address(0)) return (false, 0, 0);
        } else if (tokenType == TokenType.ERC20) {
            if (tokenAddress == address(0)) return (false, 0, 0);
        } else {
            return (false, 0, 0);
        }

        // Determine current pool balance for this token type
        uint256 poolBalance;
        if (tokenType == TokenType.NATIVE) {
            poolBalance = address(this).balance;
        } else if (tokenType == TokenType.ERC20) {
            poolBalance = IERC20(tokenAddress).balanceOf(address(this));
        }

        if (poolBalance == 0) {
            return (false, 0, 0);
        }

        // Per-token absolute allocation only
        if (s_totalAllocationsByToken[tokenAddress][tokenType] == 0) {
            return (false, 0, 0);
        }
        uint256 userAllocation = s_userAllocationsByToken[tokenAddress][
            tokenType
        ][user];
        if (userAllocation == 0) return (false, 0, 0);
        allocation = userAllocation;

        // Calculate protocol fee (e.g., 1% = 100 basis points, 0% = 0 basis points for no fees)
        protocolFee = (allocation * s_protocolFeeRate) / FEE_PRECISION;

        // Ensure sufficient balance for the gross allocation
        if (poolBalance < allocation) {
            return (false, 0, 0);
        }

        canClaim = allocation > 0;
        return (canClaim, allocation, protocolFee);
    }

    /// @notice Claims rewards based on custom allocation
    /// @param data Claim data struct
    /// @param signature EIP-712 signature
    function claimReward(
        ClaimData calldata data,
        bytes calldata signature
    ) external nonReentrant onlyActive {
        // Verify the user is in the pool for this token
        if (!s_isUserByToken[data.tokenAddress][data.tokenType][data.user])
            revert CreatorRewardPool__UserNotInPool();
        if (data.user != msg.sender)
            revert CreatorRewardPool__InvalidSignature();

        // CRITICAL: Validate tokenAddress and tokenType combination
        if (data.tokenType == TokenType.NATIVE) {
            if (data.tokenAddress != address(0))
                revert CreatorRewardPool__InvalidTokenType();
        } else if (data.tokenType == TokenType.ERC20) {
            if (data.tokenAddress == address(0))
                revert CreatorRewardPool__InvalidTokenType();
        } else {
            revert CreatorRewardPool__InvalidTokenType();
        }

        // Check if user has already claimed this token type
        if (s_hasClaimed[data.user][data.tokenAddress][data.tokenType]) {
            revert CreatorRewardPool__AlreadyClaimed();
        }

        // Verify signature and nonce
        _validateSignature(data, signature);

        // Calculate user's reward allocation and protocol fee
        (bool canClaim, uint256 grossAmount, uint256 protocolFee) = this
            .checkClaimEligibility(
                data.user,
                data.tokenAddress,
                data.tokenType
            );

        if (!canClaim || grossAmount == 0)
            revert CreatorRewardPool__InsufficientRewards();

        uint256 netAmount = grossAmount - protocolFee;

        // Validate sufficient balance exists
        if (data.tokenType == TokenType.NATIVE) {
            if (address(this).balance < grossAmount)
                revert CreatorRewardPool__InsufficientPoolBalance();

            // Transfer net amount to user
            if (netAmount > 0) {
                (bool success, ) = payable(data.user).call{value: netAmount}(
                    ""
                );
                if (!success) revert CreatorRewardPool__TransferFailed();
            }

            // Transfer protocol fee to fee recipient (only if protocol fee > 0)
            if (protocolFee > 0) {
                (bool success, ) = payable(s_protocolFeeRecipient).call{
                    value: protocolFee
                }("");
                if (!success) revert CreatorRewardPool__TransferFailed();
            }
        } else if (data.tokenType == TokenType.ERC20) {
            uint256 contractBalance = IERC20(data.tokenAddress).balanceOf(
                address(this)
            );
            if (contractBalance < grossAmount)
                revert CreatorRewardPool__InsufficientPoolBalance();

            // Transfer net amount to user
            if (netAmount > 0) {
                IERC20(data.tokenAddress).transfer(data.user, netAmount);
            }

            // Transfer protocol fee to fee recipient (only if protocol fee > 0)
            if (protocolFee > 0) {
                IERC20(data.tokenAddress).transfer(
                    s_protocolFeeRecipient,
                    protocolFee
                );
            }
        }

        // Mark as claimed and update tracking
        s_hasClaimed[data.user][data.tokenAddress][data.tokenType] = true;
        s_totalClaimed[data.tokenAddress][data.tokenType] += grossAmount;
        s_protocolFeesClaimed[data.tokenAddress][data.tokenType] += protocolFee;

        // Emit events using per-token allocation context only
        uint256 eventUserAllocation = s_userAllocationsByToken[
            data.tokenAddress
        ][data.tokenType][data.user];
        uint256 eventTotalAllocations = s_totalAllocationsByToken[
            data.tokenAddress
        ][data.tokenType];

        emit RewardClaimed(
            data.user,
            data.tokenAddress,
            grossAmount,
            netAmount,
            protocolFee,
            data.tokenType,
            eventUserAllocation,
            eventTotalAllocations
        );

        // Only emit protocol fee event if there was actually a fee collected
        if (protocolFee > 0) {
            emit ProtocolFeeCollected(
                data.tokenAddress,
                protocolFee,
                data.tokenType,
                s_protocolFeeRecipient
            );
        }
    }

    /// @notice Relayed claim entrypoint to allow third-parties (e.g., factory) to claim on behalf of a user
    /// @dev Signature + nonce enforcement remains via signer.
    function claimRewardFor(
        ClaimData calldata data,
        bytes calldata signature
    ) external nonReentrant onlyActive {
        if (!s_isUserByToken[data.tokenAddress][data.tokenType][data.user])
            revert CreatorRewardPool__UserNotInPool();

        // Validate token parameters
        if (data.tokenType == TokenType.NATIVE) {
            if (data.tokenAddress != address(0))
                revert CreatorRewardPool__InvalidTokenType();
        } else if (data.tokenType == TokenType.ERC20) {
            if (data.tokenAddress == address(0))
                revert CreatorRewardPool__InvalidTokenType();
        } else {
            revert CreatorRewardPool__InvalidTokenType();
        }

        if (s_hasClaimed[data.user][data.tokenAddress][data.tokenType]) {
            revert CreatorRewardPool__AlreadyClaimed();
        }

        // Verify signature and nonce
        _validateSignature(data, signature);

        // Calculate user's reward allocation and protocol fee
        (bool canClaim, uint256 grossAmount, uint256 protocolFee) = this
            .checkClaimEligibility(
                data.user,
                data.tokenAddress,
                data.tokenType
            );

        if (!canClaim || grossAmount == 0)
            revert CreatorRewardPool__InsufficientRewards();

        uint256 netAmount = grossAmount - protocolFee;

        if (data.tokenType == TokenType.NATIVE) {
            if (address(this).balance < grossAmount)
                revert CreatorRewardPool__InsufficientPoolBalance();

            if (netAmount > 0) {
                (bool successUser, ) = payable(data.user).call{
                    value: netAmount
                }("");
                if (!successUser) revert CreatorRewardPool__TransferFailed();
            }
            if (protocolFee > 0) {
                (bool successFee, ) = payable(s_protocolFeeRecipient).call{
                    value: protocolFee
                }("");
                if (!successFee) revert CreatorRewardPool__TransferFailed();
            }
        } else {
            uint256 contractBalance = IERC20(data.tokenAddress).balanceOf(
                address(this)
            );
            if (contractBalance < grossAmount)
                revert CreatorRewardPool__InsufficientPoolBalance();
            if (netAmount > 0) {
                IERC20(data.tokenAddress).transfer(data.user, netAmount);
            }
            if (protocolFee > 0) {
                IERC20(data.tokenAddress).transfer(
                    s_protocolFeeRecipient,
                    protocolFee
                );
            }
        }

        // Mark as claimed and update tracking
        s_hasClaimed[data.user][data.tokenAddress][data.tokenType] = true;
        s_totalClaimed[data.tokenAddress][data.tokenType] += grossAmount;
        s_protocolFeesClaimed[data.tokenAddress][data.tokenType] += protocolFee;

        uint256 eventUserAllocation2;
        uint256 eventTotalAllocations2;
        eventUserAllocation2 = s_userAllocationsByToken[data.tokenAddress][
            data.tokenType
        ][data.user];
        eventTotalAllocations2 = s_totalAllocationsByToken[data.tokenAddress][
            data.tokenType
        ];

        emit RewardClaimed(
            data.user,
            data.tokenAddress,
            grossAmount,
            netAmount,
            protocolFee,
            data.tokenType,
            eventUserAllocation2,
            eventTotalAllocations2
        );

        if (protocolFee > 0) {
            emit ProtocolFeeCollected(
                data.tokenAddress,
                protocolFee,
                data.tokenType,
                s_protocolFeeRecipient
            );
        }
    }

    /// @notice Emergency withdrawal function (factory only)
    /// @param tokenAddress Token address (address(0) for native)
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    /// @param tokenType Type of token
    function emergencyWithdraw(
        address tokenAddress,
        address to,
        uint256 amount,
        TokenType tokenType
    ) external onlyFactory {
        if (s_active) revert CreatorRewardPool__CannotWithdrawWhenActive();

        // CRITICAL: Validate tokenAddress and tokenType combination
        if (tokenType == TokenType.NATIVE) {
            if (tokenAddress != address(0))
                revert CreatorRewardPool__InvalidTokenType();
        } else if (tokenType == TokenType.ERC20) {
            if (tokenAddress == address(0))
                revert CreatorRewardPool__InvalidTokenType();
        } else {
            revert CreatorRewardPool__InvalidTokenType();
        }

        if (tokenType == TokenType.NATIVE) {
            if (address(this).balance < amount)
                revert CreatorRewardPool__InsufficientPoolBalance();
            (bool success, ) = payable(to).call{value: amount}("");
            if (!success) revert CreatorRewardPool__TransferFailed();
        } else if (tokenType == TokenType.ERC20) {
            uint256 contractBalance = IERC20(tokenAddress).balanceOf(
                address(this)
            );
            if (contractBalance < amount) {
                revert CreatorRewardPool__InsufficientPoolBalance();
            }
            IERC20(tokenAddress).transfer(to, amount);
        }

        // Update total claimed to maintain accounting consistency
        s_totalClaimed[tokenAddress][tokenType] += amount;
    }

    // ===== VIEW FUNCTIONS =====

    /// @notice Gets user allocation for specific token
    function getUserAllocationForToken(
        address user,
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256) {
        return s_userAllocationsByToken[tokenAddress][tokenType][user];
    }

    /// @notice Checks if user is in the pool for specific token
    function isUserForToken(
        address user,
        address tokenAddress,
        TokenType tokenType
    ) external view returns (bool) {
        return s_isUserByToken[tokenAddress][tokenType][user];
    }

    /// @notice Gets total number of users for specific token
    function getTotalUsersForToken(
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256) {
        return s_usersByToken[tokenAddress][tokenType].length;
    }

    /// @notice Gets user at index for specific token
    function getUserAtIndexForToken(
        address tokenAddress,
        TokenType tokenType,
        uint256 index
    ) external view returns (address) {
        return s_usersByToken[tokenAddress][tokenType][index];
    }

    /// @notice Checks if a user has already claimed rewards for a specific token
    /// @param user User address
    /// @param tokenAddress Token address
    /// @param tokenType Type of token
    /// @return True if user has already claimed
    function hasClaimed(
        address user,
        address tokenAddress,
        TokenType tokenType
    ) external view returns (bool) {
        return s_hasClaimed[user][tokenAddress][tokenType];
    }

    /// @notice Gets total amount claimed for a specific token
    /// @param tokenAddress Token address
    /// @param tokenType Type of token
    /// @return Total amount claimed
    function getTotalClaimed(
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256) {
        return s_totalClaimed[tokenAddress][tokenType];
    }

    /// @notice Gets total protocol fees claimed for a specific token
    /// @param tokenAddress Token address
    /// @param tokenType Type of token
    /// @return Total protocol fees claimed
    function getProtocolFeesClaimed(
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256) {
        return s_protocolFeesClaimed[tokenAddress][tokenType];
    }

    /// @notice Gets the current available balance
    /// @param tokenAddress Token address (use address(0) for native)
    /// @param tokenType The token type (NATIVE or ERC20)
    /// @return balance The current available balance
    function getAvailableRewards(
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256 balance) {
        if (tokenType == TokenType.NATIVE) {
            if (tokenAddress != address(0)) return 0;
            return address(this).balance;
        } else if (tokenType == TokenType.ERC20) {
            if (tokenAddress == address(0)) return 0;
            return IERC20(tokenAddress).balanceOf(address(this));
        }
        return 0;
    }

    /// @notice Gets total allocations configured for a specific token
    /// @param tokenAddress Token address (address(0) for native)
    /// @param tokenType Token type
    function getTotalAllocationsForToken(
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256) {
        return s_totalAllocationsByToken[tokenAddress][tokenType];
    }

    /// @notice Gets the current nonce counter for a user
    /// @param user User address
    /// @return Current nonce counter
    function getUserNonceCounter(address user) external view returns (uint256) {
        return s_userNonceCounter[user];
    }

    /// @notice Checks if a user has used a specific nonce
    /// @param user User address
    /// @param nonce Nonce to check
    /// @return True if nonce has been used
    function isNonceUsed(
        address user,
        uint256 nonce
    ) external view returns (bool) {
        return s_usedNonces[user][nonce];
    }

    /// @notice Gets the next available nonce for a user
    /// @param user User address
    /// @return Next available nonce (current counter + 1)
    function getNextNonce(address user) external view returns (uint256) {
        return s_userNonceCounter[user] + 1;
    }

    /// @notice Gets the creator address
    /// @return Creator address
    function getCreator() external view returns (address) {
        return s_creator;
    }

    /// @notice Gets the protocol fee rate
    /// @return Protocol fee rate in basis points
    function getProtocolFeeRate() external view returns (uint256) {
        return s_protocolFeeRate;
    }

    /// @notice Gets the protocol fee recipient
    /// @return Protocol fee recipient address
    function getProtocolFeeRecipient() external view returns (address) {
        return s_protocolFeeRecipient;
    }

    /// @notice Gets the domain separator for EIP-712 signatures
    /// @return Domain separator
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Validates EIP-712 signature and nonce
    /// @param data Claim data
    /// @param signature Signature to validate
    function _validateSignature(
        ClaimData calldata data,
        bytes calldata signature
    ) internal {
        if (s_usedNonces[data.user][data.nonce])
            revert CreatorRewardPool__NonceAlreadyUsed();

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    CLAIM_DATA_HASH,
                    data.user,
                    data.nonce,
                    data.tokenAddress,
                    data.tokenType
                )
            )
        );

        address signer = digest.recover(signature);
        if (!hasRole(SIGNER_ROLE, signer))
            revert CreatorRewardPool__InvalidSignature();

        s_usedNonces[data.user][data.nonce] = true;

        if (data.nonce > s_userNonceCounter[data.user]) {
            s_userNonceCounter[data.user] = data.nonce;
        }
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation New implementation address
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @notice Supports interface check
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /// @notice Fallback function to receive native tokens
    receive() external payable {}

    /// @notice Fallback function
    fallback() external payable {}

    // ===== BATCH USER MANAGEMENT FUNCTIONS =====

    /// @notice Adds multiple users to the pool with custom allocations in batches for a specific token
    function batchAddUsers(
        address tokenAddress,
        TokenType tokenType,
        address[] calldata users,
        uint256[] calldata allocations
    ) external onlyFactory {
        if (s_active)
            revert CreatorRewardPool__CannotUpdateAllocationsWhenActive();
        if (users.length != allocations.length || users.length == 0)
            revert CreatorRewardPool__InvalidAllocationAmount();

        uint256 totalAllocationsToAdd = 0;
        uint256 batchSize = users.length;

        // First pass: validate all inputs and calculate total allocations
        for (uint256 i = 0; i < batchSize; ) {
            address user = users[i];
            uint256 allocation = allocations[i];

            if (user == address(0)) revert CreatorRewardPool__ZeroAddress();
            if (s_isUserByToken[tokenAddress][tokenType][user])
                revert CreatorRewardPool__UserAlreadyExists();

            // Only count non-zero allocations into total
            if (allocation > 0) {
                totalAllocationsToAdd += allocation;
            }

            unchecked {
                ++i;
            }
        }

        // Second pass: add all users
        for (uint256 i = 0; i < batchSize; ) {
            address user = users[i];
            uint256 allocation = allocations[i];

            s_userAllocationsByToken[tokenAddress][tokenType][
                user
            ] = allocation;
            s_usersByToken[tokenAddress][tokenType].push(user);
            s_isUserByToken[tokenAddress][tokenType][user] = true;

            emit UserAdded(user, tokenAddress, tokenType, allocation);

            unchecked {
                ++i;
            }
        }

        s_totalAllocationsByToken[tokenAddress][
            tokenType
        ] += totalAllocationsToAdd;
        emit BatchUsersAdded(users, allocations, batchSize);
    }

    /// @notice Updates allocations for multiple existing users in batches for a specific token
    function batchUpdateUserAllocations(
        address tokenAddress,
        TokenType tokenType,
        address[] calldata users,
        uint256[] calldata newAllocations
    ) external onlyFactory {
        if (s_active)
            revert CreatorRewardPool__CannotUpdateAllocationsWhenActive();
        if (users.length != newAllocations.length || users.length == 0)
            revert CreatorRewardPool__InvalidAllocationAmount();

        uint256 batchSize = users.length;
        uint256[] memory oldAllocations = new uint256[](batchSize);
        uint256 totalAllocationChange = 0;
        bool isIncreasing = true;

        // First pass: validate and calculate allocation changes
        for (uint256 i = 0; i < batchSize; ) {
            address user = users[i];
            uint256 newAllocation = newAllocations[i];

            if (!s_isUserByToken[tokenAddress][tokenType][user])
                revert CreatorRewardPool__UserNotInPool();

            uint256 oldAllocation = s_userAllocationsByToken[tokenAddress][
                tokenType
            ][user];
            oldAllocations[i] = oldAllocation;

            if (i == 0) {
                isIncreasing = newAllocation >= oldAllocation;
                totalAllocationChange = isIncreasing
                    ? (newAllocation - oldAllocation)
                    : (oldAllocation - newAllocation);
            } else {
                if (isIncreasing && newAllocation >= oldAllocation) {
                    totalAllocationChange += (newAllocation - oldAllocation);
                } else if (isIncreasing && newAllocation < oldAllocation) {
                    if (
                        totalAllocationChange >= (oldAllocation - newAllocation)
                    ) {
                        totalAllocationChange -= (oldAllocation -
                            newAllocation);
                    } else {
                        totalAllocationChange =
                            (oldAllocation - newAllocation) -
                            totalAllocationChange;
                        isIncreasing = false;
                    }
                } else if (!isIncreasing && newAllocation <= oldAllocation) {
                    totalAllocationChange += (oldAllocation - newAllocation);
                } else if (!isIncreasing && newAllocation > oldAllocation) {
                    if (
                        totalAllocationChange >= (newAllocation - oldAllocation)
                    ) {
                        totalAllocationChange -= (newAllocation -
                            oldAllocation);
                    } else {
                        totalAllocationChange =
                            (newAllocation - oldAllocation) -
                            totalAllocationChange;
                        isIncreasing = true;
                    }
                }
            }

            unchecked {
                ++i;
            }
        }

        // Second pass: update user allocations
        for (uint256 i = 0; i < batchSize; ) {
            address user = users[i];
            uint256 newAllocation = newAllocations[i];
            uint256 oldAllocation = oldAllocations[i];

            s_userAllocationsByToken[tokenAddress][tokenType][
                user
            ] = newAllocation;

            if (newAllocation == 0) {
                s_isUserByToken[tokenAddress][tokenType][user] = false;
            }

            emit UserAllocationUpdated(
                user,
                tokenAddress,
                tokenType,
                oldAllocation,
                newAllocation
            );

            unchecked {
                ++i;
            }
        }

        // Update total allocations
        if (isIncreasing) {
            s_totalAllocationsByToken[tokenAddress][
                tokenType
            ] += totalAllocationChange;
        } else {
            uint256 currentTotal = s_totalAllocationsByToken[tokenAddress][
                tokenType
            ];
            s_totalAllocationsByToken[tokenAddress][tokenType] = currentTotal >=
                totalAllocationChange
                ? currentTotal - totalAllocationChange
                : 0;
        }

        emit BatchUsersUpdated(
            users,
            oldAllocations,
            newAllocations,
            batchSize
        );
    }

    /// @notice Removes multiple users from the pool in batches for a specific token
    function batchRemoveUsers(
        address tokenAddress,
        TokenType tokenType,
        address[] calldata users
    ) external onlyFactory {
        if (s_active)
            revert CreatorRewardPool__CannotUpdateAllocationsWhenActive();
        if (users.length == 0)
            revert CreatorRewardPool__InvalidAllocationAmount();

        uint256 batchSize = users.length;
        uint256[] memory allocations = new uint256[](batchSize);
        uint256 totalAllocationsToRemove = 0;

        // First pass: validate and calculate total allocations to remove
        for (uint256 i = 0; i < batchSize; ) {
            address user = users[i];
            if (!s_isUserByToken[tokenAddress][tokenType][user])
                revert CreatorRewardPool__UserNotInPool();

            uint256 allocation = s_userAllocationsByToken[tokenAddress][
                tokenType
            ][user];
            allocations[i] = allocation;
            totalAllocationsToRemove += allocation;

            unchecked {
                ++i;
            }
        }

        // Second pass: remove users
        for (uint256 i = 0; i < batchSize; ) {
            address user = users[i];
            uint256 allocation = allocations[i];

            s_userAllocationsByToken[tokenAddress][tokenType][user] = 0;
            s_isUserByToken[tokenAddress][tokenType][user] = false;

            emit UserRemoved(user, tokenAddress, tokenType, allocation);

            unchecked {
                ++i;
            }
        }

        s_totalAllocationsByToken[tokenAddress][
            tokenType
        ] -= totalAllocationsToRemove;
        emit BatchUsersRemoved(users, allocations, batchSize);
    }
}
