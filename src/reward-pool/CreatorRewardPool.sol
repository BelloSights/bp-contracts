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
    error CreatorRewardPool__InvalidNonce();
    error CreatorRewardPool__InsufficientRewards();
    error CreatorRewardPool__ZeroAddress();
    error CreatorRewardPool__ZeroAllocation();
    error CreatorRewardPool__UserAlreadyExists();
    error CreatorRewardPool__TransferFailed();
    error CreatorRewardPool__InvalidTokenType();
    error CreatorRewardPool__InvalidAllocationAmount();
    error CreatorRewardPool__AlreadyClaimed();
    error CreatorRewardPool__CannotUpdateAllocationsWhenActive();
    error CreatorRewardPool__InsufficientPoolBalance();
    error CreatorRewardPool__CannotWithdrawWhenActive();
    error CreatorRewardPool__InvalidProtocolFeeRate();
    error CreatorRewardPool__AllocationsExceedBalance();

    // ===== CONSTANTS =====
    uint256 public constant MAX_PROTOCOL_FEE_RATE = 1000; // 10% maximum
    uint256 public constant DEFAULT_PROTOCOL_FEE_RATE = 100; // 1% default
    uint256 public constant FEE_PRECISION = 10000; // 0.01% precision (basis points)

    // ===== STATE VARIABLES =====
    address public s_factory;
    address public s_creator;
    bool public s_active;
    uint256 public s_protocolFeeRate; // Fee rate in basis points (100 = 1%)
    address public s_protocolFeeRecipient;

    // EIP-712 domain separator components
    string public s_signingDomain;
    string public s_signatureVersion;

    // Allocation tracking (replaces XP system)
    mapping(address => uint256) public s_userAllocations;
    address[] public s_users;
    mapping(address => bool) public s_isUser;
    uint256 public s_totalAllocations;

    // Nonce tracking for replay protection (per-user)
    mapping(address => mapping(uint256 => bool)) public s_usedNonces;
    mapping(address => uint256) public s_userNonceCounter;

    // Snapshot system for reward distribution
    mapping(address => uint256) public s_rewardSnapshots; // ERC20 snapshots
    uint256 public s_nativeRewardSnapshot; // ETH snapshot
    bool public s_snapshotTaken; // Whether snapshot has been taken

    // Claim tracking to prevent double claiming
    mapping(address => mapping(address => mapping(TokenType => bool)))
        public s_hasClaimed;

    // Track total claimed amounts and protocol fees
    mapping(address => mapping(TokenType => uint256)) public s_totalClaimed;
    mapping(address => mapping(TokenType => uint256)) public s_protocolFeesClaimed;

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
    /// @param protocolFeeRate The protocol fee rate in basis points
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
        s_signingDomain = signingDomain;
        s_signatureVersion = signatureVersion;
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

    /// @notice Takes a snapshot of current balances for reward distribution
    /// @param tokenAddresses Array of ERC20 token addresses to snapshot
    function takeSnapshot(
        address[] calldata tokenAddresses
    ) external onlyFactory {
        _takeSnapshotWithTokens(tokenAddresses);
    }

    /// @notice Takes a snapshot of only native ETH for reward distribution
    function takeNativeSnapshot() external onlyFactory {
        _takeSnapshot();
    }

    /// @notice Internal function to take snapshot of native ETH only
    function _takeSnapshot() internal {
        s_nativeRewardSnapshot = address(this).balance;
        s_snapshotTaken = true;

        // Emit event with empty token arrays
        address[] memory emptyTokens = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);
        emit SnapshotTaken(s_nativeRewardSnapshot, emptyTokens, emptyAmounts);
    }

    /// @notice Internal function to take snapshot with specific tokens
    /// @param tokenAddresses Array of ERC20 token addresses to snapshot
    function _takeSnapshotWithTokens(
        address[] calldata tokenAddresses
    ) internal {
        // Snapshot native ETH
        s_nativeRewardSnapshot = address(this).balance;

        // Snapshot ERC20 tokens
        uint256[] memory tokenAmounts = new uint256[](tokenAddresses.length);
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            uint256 balance = IERC20(tokenAddresses[i]).balanceOf(
                address(this)
            );
            s_rewardSnapshots[tokenAddresses[i]] = balance;
            tokenAmounts[i] = balance;
        }

        s_snapshotTaken = true;
        emit SnapshotTaken(
            s_nativeRewardSnapshot,
            tokenAddresses,
            tokenAmounts
        );
    }

    /// @notice Adds a new user to the pool with custom allocation
    /// @param user User address
    /// @param allocation Custom allocation amount
    function addUser(address user, uint256 allocation) external onlyFactory {
        if (s_active) revert CreatorRewardPool__CannotUpdateAllocationsWhenActive();
        if (user == address(0)) revert CreatorRewardPool__ZeroAddress();
        if (allocation == 0) revert CreatorRewardPool__ZeroAllocation();
        if (s_isUser[user]) revert CreatorRewardPool__UserAlreadyExists();

        s_userAllocations[user] = allocation;
        s_users.push(user);
        s_isUser[user] = true;
        s_totalAllocations += allocation;

        emit UserAdded(user, allocation);
    }

    /// @notice Updates allocation for an existing user
    /// @param user User address
    /// @param newAllocation New allocation amount
    function updateUserAllocation(address user, uint256 newAllocation) external onlyFactory {
        if (s_active) revert CreatorRewardPool__CannotUpdateAllocationsWhenActive();
        if (!s_isUser[user]) revert CreatorRewardPool__UserNotInPool();

        uint256 oldAllocation = s_userAllocations[user];
        s_totalAllocations = s_totalAllocations - oldAllocation + newAllocation;
        s_userAllocations[user] = newAllocation;

        // Remove user if allocation becomes 0
        if (newAllocation == 0) {
            s_isUser[user] = false;
            // Note: We keep them in s_users array for historical tracking
        }

        emit UserAllocationUpdated(user, oldAllocation, newAllocation);
    }

    /// @notice Removes a user from the pool
    /// @param user User address to remove
    function removeUser(address user) external onlyFactory {
        if (s_active) revert CreatorRewardPool__CannotUpdateAllocationsWhenActive();
        if (!s_isUser[user]) revert CreatorRewardPool__UserNotInPool();

        uint256 allocation = s_userAllocations[user];
        s_totalAllocations -= allocation;
        s_userAllocations[user] = 0;
        s_isUser[user] = false;

        emit UserRemoved(user, allocation);
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
    ) external view returns (bool isValid, uint256 totalAllocations, uint256 availableBalance) {
        // CRITICAL: Validate tokenAddress and tokenType combination
        if (tokenType == TokenType.NATIVE) {
            if (tokenAddress != address(0)) return (false, 0, 0);
            availableBalance = s_nativeRewardSnapshot;
        } else if (tokenType == TokenType.ERC20) {
            if (tokenAddress == address(0)) return (false, 0, 0);
            availableBalance = s_rewardSnapshots[tokenAddress];
        } else {
            return (false, 0, 0);
        }

        totalAllocations = s_totalAllocations;
        isValid = totalAllocations <= availableBalance;
        
        if (!isValid && availableBalance > 0) {
            // Optional: This could trigger a warning event
            // emit AllocationValidationWarning(tokenAddress, tokenType, totalAllocations, availableBalance, "Total allocations exceed available balance");
        }
        
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
    ) external view returns (bool canClaim, uint256 allocation, uint256 protocolFee) {
        if (
            !s_active || !s_isUser[user] || s_totalAllocations == 0 || !s_snapshotTaken
        ) {
            return (false, 0, 0);
        }

        // Check if user has already claimed this token type
        if (s_hasClaimed[user][tokenAddress][tokenType]) {
            return (false, 0, 0);
        }

        uint256 userAllocation = s_userAllocations[user];
        if (userAllocation == 0) {
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

        // Get snapshot amount for this token type
        uint256 snapshotAmount;
        if (tokenType == TokenType.NATIVE) {
            snapshotAmount = s_nativeRewardSnapshot;
        } else if (tokenType == TokenType.ERC20) {
            snapshotAmount = s_rewardSnapshots[tokenAddress];
        }

        if (snapshotAmount == 0) {
            return (false, 0, 0);
        }

        // Calculate user's allocation: (userAllocation / totalAllocations) * snapshotAmount
        allocation = (snapshotAmount * userAllocation) / s_totalAllocations;
        
        // Calculate protocol fee (e.g., 1% = 100 basis points)
        protocolFee = (allocation * s_protocolFeeRate) / FEE_PRECISION;
        
        // Check if there are sufficient available rewards
        uint256 availableRewards;
        if (tokenType == TokenType.NATIVE) {
            availableRewards = address(this).balance;
        } else if (tokenType == TokenType.ERC20) {
            availableRewards = IERC20(tokenAddress).balanceOf(address(this));
        }

        // Total amount needed (user gets allocation - protocolFee, protocol gets protocolFee)
        if (availableRewards < allocation) {
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
        // Verify the user is in the pool
        if (!s_isUser[data.user]) revert CreatorRewardPool__UserNotInPool();
        if (data.user != msg.sender) revert CreatorRewardPool__InvalidSignature();

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
        (bool canClaim, uint256 grossAmount, uint256 protocolFee) = this.checkClaimEligibility(
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
                (bool success, ) = payable(data.user).call{value: netAmount}("");
                if (!success) revert CreatorRewardPool__TransferFailed();
            }

            // Transfer protocol fee to fee recipient
            if (protocolFee > 0) {
                (bool success, ) = payable(s_protocolFeeRecipient).call{value: protocolFee}("");
                if (!success) revert CreatorRewardPool__TransferFailed();
            }
        } else if (data.tokenType == TokenType.ERC20) {
            uint256 contractBalance = IERC20(data.tokenAddress).balanceOf(address(this));
            if (contractBalance < grossAmount)
                revert CreatorRewardPool__InsufficientPoolBalance();

            // Transfer net amount to user
            if (netAmount > 0) {
                IERC20(data.tokenAddress).transfer(data.user, netAmount);
            }

            // Transfer protocol fee to fee recipient
            if (protocolFee > 0) {
                IERC20(data.tokenAddress).transfer(s_protocolFeeRecipient, protocolFee);
            }
        }

        // Mark as claimed and update tracking
        s_hasClaimed[data.user][data.tokenAddress][data.tokenType] = true;
        s_totalClaimed[data.tokenAddress][data.tokenType] += grossAmount;
        s_protocolFeesClaimed[data.tokenAddress][data.tokenType] += protocolFee;

        // Emit events
        emit RewardClaimed(
            data.user,
            data.tokenAddress,
            grossAmount,
            netAmount,
            protocolFee,
            data.tokenType,
            s_userAllocations[data.user],
            s_totalAllocations
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
            uint256 contractBalance = IERC20(tokenAddress).balanceOf(address(this));
            if (contractBalance < amount) {
                revert CreatorRewardPool__InsufficientPoolBalance();
            }
            IERC20(tokenAddress).transfer(to, amount);
        }

        // Update total claimed to maintain accounting consistency
        s_totalClaimed[tokenAddress][tokenType] += amount;
    }

    // ===== VIEW FUNCTIONS =====

    /// @notice Gets user allocation
    /// @param user User address
    /// @return User's allocation amount
    function getUserAllocation(address user) external view returns (uint256) {
        return s_userAllocations[user];
    }

    /// @notice Checks if user is in the pool
    /// @param user User address
    /// @return True if user is in the pool
    function isUser(address user) external view returns (bool) {
        return s_isUser[user];
    }

    /// @notice Gets total number of users
    /// @return Total number of users in the pool
    function getTotalUsers() external view returns (uint256) {
        return s_users.length;
    }

    /// @notice Gets user at index
    /// @param index User index
    /// @return User address at the given index
    function getUserAtIndex(uint256 index) external view returns (address) {
        return s_users[index];
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

    /// @notice Gets the snapshot amount for a token type
    /// @param tokenAddress Token address (use address(0) for native)
    /// @param tokenType The token type (NATIVE or ERC20)
    /// @return amount The snapshot amount
    function getSnapshotAmount(
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256 amount) {
        if (tokenType == TokenType.NATIVE) {
            if (tokenAddress != address(0)) return 0;
            return s_nativeRewardSnapshot;
        } else if (tokenType == TokenType.ERC20) {
            if (tokenAddress == address(0)) return 0;
            return s_rewardSnapshots[tokenAddress];
        }
        return 0;
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

    /// @notice Gets total rewards from snapshot + claimed amount
    /// @param tokenAddress Token address (use address(0) for native)
    /// @param tokenType The token type (NATIVE or ERC20)
    /// @return total The total rewards (snapshot + claimed)
    function getTotalRewards(
        address tokenAddress,
        TokenType tokenType
    ) external view returns (uint256 total) {
        if (tokenType == TokenType.NATIVE) {
            if (tokenAddress != address(0)) return 0;
        } else if (tokenType == TokenType.ERC20) {
            if (tokenAddress == address(0)) return 0;
        } else {
            return 0;
        }

        uint256 snapshotAmount;
        if (tokenType == TokenType.NATIVE) {
            snapshotAmount = s_nativeRewardSnapshot;
        } else if (tokenType == TokenType.ERC20) {
            snapshotAmount = s_rewardSnapshots[tokenAddress];
        }
        return snapshotAmount + s_totalClaimed[tokenAddress][tokenType];
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

    /// @notice Adds multiple users to the pool with custom allocations in batches
    /// @param users Array of user addresses
    /// @param allocations Array of allocation amounts
    function batchAddUsers(
        address[] calldata users,
        uint256[] calldata allocations
    ) external onlyFactory {
        if (s_active) revert CreatorRewardPool__CannotUpdateAllocationsWhenActive();
        if (users.length != allocations.length || users.length == 0)
            revert CreatorRewardPool__InvalidAllocationAmount();

        uint256 totalAllocationsToAdd = 0;
        uint256 batchSize = users.length;

        // First pass: validate all inputs and calculate total allocations
        for (uint256 i = 0; i < batchSize; ) {
            address user = users[i];
            uint256 allocation = allocations[i];

            if (user == address(0)) revert CreatorRewardPool__ZeroAddress();
            if (allocation == 0) revert CreatorRewardPool__ZeroAllocation();
            if (s_isUser[user]) revert CreatorRewardPool__UserAlreadyExists();

            totalAllocationsToAdd += allocation;

            unchecked {
                ++i;
            }
        }

        // Second pass: add all users
        for (uint256 i = 0; i < batchSize; ) {
            address user = users[i];
            uint256 allocation = allocations[i];

            s_userAllocations[user] = allocation;
            s_users.push(user);
            s_isUser[user] = true;

            emit UserAdded(user, allocation);

            unchecked {
                ++i;
            }
        }

        s_totalAllocations += totalAllocationsToAdd;
        emit BatchUsersAdded(users, allocations, batchSize);
    }

    /// @notice Updates allocations for multiple existing users in batches
    /// @param users Array of user addresses
    /// @param newAllocations Array of new allocation amounts
    function batchUpdateUserAllocations(
        address[] calldata users,
        uint256[] calldata newAllocations
    ) external onlyFactory {
        if (s_active) revert CreatorRewardPool__CannotUpdateAllocationsWhenActive();
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

            if (!s_isUser[user]) revert CreatorRewardPool__UserNotInPool();

            uint256 oldAllocation = s_userAllocations[user];
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
                    if (totalAllocationChange >= (oldAllocation - newAllocation)) {
                        totalAllocationChange -= (oldAllocation - newAllocation);
                    } else {
                        totalAllocationChange = (oldAllocation - newAllocation) - totalAllocationChange;
                        isIncreasing = false;
                    }
                } else if (!isIncreasing && newAllocation <= oldAllocation) {
                    totalAllocationChange += (oldAllocation - newAllocation);
                } else if (!isIncreasing && newAllocation > oldAllocation) {
                    if (totalAllocationChange >= (newAllocation - oldAllocation)) {
                        totalAllocationChange -= (newAllocation - oldAllocation);
                    } else {
                        totalAllocationChange = (newAllocation - oldAllocation) - totalAllocationChange;
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

            s_userAllocations[user] = newAllocation;

            if (newAllocation == 0) {
                s_isUser[user] = false;
            }

            emit UserAllocationUpdated(user, oldAllocation, newAllocation);

            unchecked {
                ++i;
            }
        }

        // Update total allocations
        if (isIncreasing) {
            s_totalAllocations += totalAllocationChange;
        } else {
            s_totalAllocations = s_totalAllocations >= totalAllocationChange
                ? s_totalAllocations - totalAllocationChange
                : 0;
        }

        emit BatchUsersUpdated(users, oldAllocations, newAllocations, batchSize);
    }

    /// @notice Removes multiple users from the pool in batches
    /// @param users Array of user addresses to remove
    function batchRemoveUsers(address[] calldata users) external onlyFactory {
        if (s_active) revert CreatorRewardPool__CannotUpdateAllocationsWhenActive();
        if (users.length == 0) revert CreatorRewardPool__InvalidAllocationAmount();

        uint256 batchSize = users.length;
        uint256[] memory allocations = new uint256[](batchSize);
        uint256 totalAllocationsToRemove = 0;

        // First pass: validate and calculate total allocations to remove
        for (uint256 i = 0; i < batchSize; ) {
            address user = users[i];
            if (!s_isUser[user]) revert CreatorRewardPool__UserNotInPool();

            uint256 allocation = s_userAllocations[user];
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

            s_userAllocations[user] = 0;
            s_isUser[user] = false;

            emit UserRemoved(user, allocation);

            unchecked {
                ++i;
            }
        }

        s_totalAllocations -= totalAllocationsToRemove;
        emit BatchUsersRemoved(users, allocations, batchSize);
    }
} 