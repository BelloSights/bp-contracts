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

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Clones} from "@openzeppelin-contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {CreatorRewardPool} from "./CreatorRewardPool.sol";
import {ICreatorRewardPool} from "./interfaces/ICreatorRewardPool.sol";

/// @title CreatorRewardPoolFactory
/// @notice Factory contract for creating and managing creator-specific reward pools with custom allocations
/// @dev Each creator can have their own reward pool with custom allocation logic and protocol fees
contract CreatorRewardPoolFactory is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    // ===== CONSTANTS =====
    string public constant SIGNING_DOMAIN = "BP_CREATOR_REWARD_POOL";
    string public constant SIGNATURE_VERSION = "1";
    uint256 public constant DEFAULT_PROTOCOL_FEE_RATE = 100; // 1% default

    // ===== ERRORS =====
    error CreatorRewardPoolFactory__OnlyCallableByAdmin();
    error CreatorRewardPoolFactory__NoPoolForCreator();
    error CreatorRewardPoolFactory__PoolAlreadyExists();
    error CreatorRewardPoolFactory__ZeroAddress();
    error CreatorRewardPoolFactory__PoolNotActive();
    error CreatorRewardPoolFactory__InvalidCreator();
    error CreatorRewardPoolFactory__InvalidProtocolFeeRate();

    // ===== STATE =====
    address public implementation;
    address public protocolFeeRecipient;
    uint256 public defaultProtocolFeeRate;

    struct CreatorPoolInfo {
        address creator;
        address pool;
        bool active;
        string name;
        string description;
        uint256 protocolFeeRate;
        uint256 createdAt;
    }

    // Mapping from creator address to their pool info
    mapping(address => CreatorPoolInfo) public s_creatorPools;
    
    // Array to keep track of all creators (for enumeration)
    address[] public s_creators;
    mapping(address => bool) public s_hasPool;

    // ===== EVENTS =====
    event CreatorPoolCreated(
        address indexed creator,
        address indexed pool,
        string name,
        string description,
        uint256 protocolFeeRate
    );
    event CreatorPoolActivated(address indexed creator);
    event CreatorPoolDeactivated(address indexed creator);
    event UserAdded(address indexed creator, address indexed user, uint256 allocation);
    event AllocationUpdated(
        address indexed creator,
        address indexed user,
        uint256 oldAllocation,
        uint256 newAllocation
    );
    event UserRemoved(address indexed creator, address indexed user, uint256 allocation);
    event ProtocolFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event DefaultProtocolFeeRateUpdated(uint256 oldRate, uint256 newRate);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the CreatorRewardPoolFactory contract
    /// @param admin Address to be granted the default admin role
    /// @param _implementation Address of the CreatorRewardPool implementation contract
    /// @param _protocolFeeRecipient Address to receive protocol fees
    function initialize(
        address admin,
        address _implementation,
        address _protocolFeeRecipient
    ) external initializer {
        if (admin == address(0)) revert CreatorRewardPoolFactory__ZeroAddress();
        if (_implementation == address(0)) revert CreatorRewardPoolFactory__ZeroAddress();
        if (_protocolFeeRecipient == address(0)) revert CreatorRewardPoolFactory__ZeroAddress();
        
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        
        implementation = _implementation;
        protocolFeeRecipient = _protocolFeeRecipient;
        defaultProtocolFeeRate = DEFAULT_PROTOCOL_FEE_RATE;
    }

    /// @notice Sets the CreatorRewardPool implementation contract address
    /// @param _implementation New implementation address
    function setImplementation(
        address _implementation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_implementation == address(0)) revert CreatorRewardPoolFactory__ZeroAddress();
        implementation = _implementation;
    }

    /// @notice Sets the protocol fee recipient address
    /// @param _protocolFeeRecipient New protocol fee recipient address
    function setProtocolFeeRecipient(
        address _protocolFeeRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_protocolFeeRecipient == address(0)) revert CreatorRewardPoolFactory__ZeroAddress();
        address oldRecipient = protocolFeeRecipient;
        protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdated(oldRecipient, _protocolFeeRecipient);
    }

    /// @notice Sets the default protocol fee rate for new pools
    /// @param _defaultProtocolFeeRate New default protocol fee rate in basis points
    function setDefaultProtocolFeeRate(
        uint256 _defaultProtocolFeeRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_defaultProtocolFeeRate > 1000) revert CreatorRewardPoolFactory__InvalidProtocolFeeRate(); // Max 10%
        uint256 oldRate = defaultProtocolFeeRate;
        defaultProtocolFeeRate = _defaultProtocolFeeRate;
        emit DefaultProtocolFeeRateUpdated(oldRate, _defaultProtocolFeeRate);
    }

    /// @notice Creates a new creator reward pool
    /// @param creator The creator address who will own this pool
    /// @param name Name of the reward pool
    /// @param description Description of the reward pool
    /// @return pool The address of the newly created pool
    function createCreatorRewardPool(
        address creator,
        string calldata name,
        string calldata description
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address) {
        return _createCreatorRewardPool(creator, name, description, defaultProtocolFeeRate);
    }

    /// @notice Creates a new creator reward pool with custom protocol fee rate
    /// @param creator The creator address who will own this pool
    /// @param name Name of the reward pool
    /// @param description Description of the reward pool
    /// @param protocolFeeRate Custom protocol fee rate in basis points
    /// @return pool The address of the newly created pool
    function createCreatorRewardPoolWithCustomFee(
        address creator,
        string calldata name,
        string calldata description,
        uint256 protocolFeeRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address) {
        if (protocolFeeRate > 1000) revert CreatorRewardPoolFactory__InvalidProtocolFeeRate(); // Max 10%
        return _createCreatorRewardPool(creator, name, description, protocolFeeRate);
    }

    /// @notice Internal function to create a creator reward pool
    /// @param creator The creator address
    /// @param name Pool name
    /// @param description Pool description
    /// @param protocolFeeRate Protocol fee rate
    /// @return pool The address of the newly created pool
    function _createCreatorRewardPool(
        address creator,
        string calldata name,
        string calldata description,
        uint256 protocolFeeRate
    ) internal returns (address) {
        if (implementation == address(0)) revert CreatorRewardPoolFactory__ZeroAddress();
        if (creator == address(0)) revert CreatorRewardPoolFactory__ZeroAddress();
        if (s_hasPool[creator]) revert CreatorRewardPoolFactory__PoolAlreadyExists();

        // Create a clone of the shared implementation
        address clone = Clones.clone(implementation);

        // Initialize the clone
        ICreatorRewardPool(clone).initialize(
            address(this),
            creator,
            SIGNING_DOMAIN,
            SIGNATURE_VERSION,
            protocolFeeRate
        );

        // Set protocol fee recipient on the pool
        ICreatorRewardPool(clone).setProtocolFeeRecipient(protocolFeeRecipient);

        s_creatorPools[creator] = CreatorPoolInfo({
            creator: creator,
            pool: clone,
            active: false, // Pools start inactive
            name: name,
            description: description,
            protocolFeeRate: protocolFeeRate,
            createdAt: block.timestamp
        });

        s_creators.push(creator);
        s_hasPool[creator] = true;

        emit CreatorPoolCreated(creator, clone, name, description, protocolFeeRate);

        return clone;
    }

    /// @notice Activates a creator's reward pool to allow claiming
    /// @param creator The creator address
    function activateCreatorPool(
        address creator
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        info.active = true;
        ICreatorRewardPool(info.pool).setActive(true);
        emit CreatorPoolActivated(creator);
    }

    /// @notice Deactivates a creator's reward pool to prevent claiming
    /// @param creator The creator address
    function deactivateCreatorPool(
        address creator
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        info.active = false;
        ICreatorRewardPool(info.pool).setActive(false);
        emit CreatorPoolDeactivated(creator);
    }

    /// @notice Adds a new user to a creator's reward pool with custom allocation
    /// @param creator The creator address
    /// @param user The user address to add
    /// @param allocation The custom allocation amount for the user
    function addUser(
        address creator,
        address user,
        uint256 allocation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        ICreatorRewardPool(info.pool).addUser(user, allocation);
        emit UserAdded(creator, user, allocation);
    }

    /// @notice Updates allocation for an existing user in a creator's pool
    /// @param creator The creator address
    /// @param user The user address
    /// @param newAllocation The new allocation amount
    function updateUserAllocation(
        address creator,
        address user,
        uint256 newAllocation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        uint256 oldAllocation = ICreatorRewardPool(info.pool).getUserAllocation(user);
        ICreatorRewardPool(info.pool).updateUserAllocation(user, newAllocation);
        emit AllocationUpdated(creator, user, oldAllocation, newAllocation);
    }

    /// @notice Removes a user from a creator's reward pool
    /// @param creator The creator address
    /// @param user The user address to remove
    function removeUser(
        address creator,
        address user
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        uint256 allocation = ICreatorRewardPool(info.pool).getUserAllocation(user);
        ICreatorRewardPool(info.pool).removeUser(user);
        emit UserRemoved(creator, user, allocation);
    }

    // ===== BATCH USER MANAGEMENT FUNCTIONS =====

    /// @notice Adds multiple users to a creator's reward pool with custom allocations in batches
    /// @param creator The creator address
    /// @param users Array of user addresses to add
    /// @param allocations Array of allocation amounts for users
    function batchAddUsers(
        address creator,
        address[] calldata users,
        uint256[] calldata allocations
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        ICreatorRewardPool(info.pool).batchAddUsers(users, allocations);

        // Emit individual events for each user for compatibility
        for (uint256 i = 0; i < users.length; ) {
            emit UserAdded(creator, users[i], allocations[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Updates allocations for multiple existing users in batches
    /// @param creator The creator address
    /// @param users Array of user addresses
    /// @param newAllocations Array of new allocation amounts
    function batchUpdateUserAllocations(
        address creator,
        address[] calldata users,
        uint256[] calldata newAllocations
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        // Get old allocation values for events
        uint256[] memory oldAllocations = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; ) {
            oldAllocations[i] = ICreatorRewardPool(info.pool).getUserAllocation(users[i]);
            unchecked {
                ++i;
            }
        }

        ICreatorRewardPool(info.pool).batchUpdateUserAllocations(users, newAllocations);

        // Emit individual events for each user for compatibility
        for (uint256 i = 0; i < users.length; ) {
            emit AllocationUpdated(creator, users[i], oldAllocations[i], newAllocations[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Removes multiple users from a creator's pool in batches
    /// @param creator The creator address
    /// @param users Array of user addresses to remove
    function batchRemoveUsers(
        address creator,
        address[] calldata users
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        // Get allocation values for events before removal
        uint256[] memory allocations = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; ) {
            allocations[i] = ICreatorRewardPool(info.pool).getUserAllocation(users[i]);
            unchecked {
                ++i;
            }
        }

        ICreatorRewardPool(info.pool).batchRemoveUsers(users);

        // Emit individual events for each user for compatibility
        for (uint256 i = 0; i < users.length; ) {
            emit UserRemoved(creator, users[i], allocations[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Grants signer role to an address for a specific creator's pool
    /// @param creator The creator address
    /// @param signer The address to grant signer role
    function grantSignerRole(
        address creator,
        address signer
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        ICreatorRewardPool(info.pool).grantSignerRole(signer);
    }

    /// @notice Revokes signer role from an address for a specific creator's pool
    /// @param creator The creator address
    /// @param signer The address to revoke signer role from
    function revokeSignerRole(
        address creator,
        address signer
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        ICreatorRewardPool(info.pool).revokeSignerRole(signer);
    }

    /// @notice Takes a snapshot of current balances for reward distribution
    /// @param creator The creator address
    /// @param tokenAddresses Array of ERC20 token addresses to snapshot
    function takeSnapshot(
        address creator,
        address[] calldata tokenAddresses
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        ICreatorRewardPool(info.pool).takeSnapshot(tokenAddresses);
    }

    /// @notice Takes a snapshot of only native ETH for reward distribution
    /// @param creator The creator address
    function takeNativeSnapshot(
        address creator
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        ICreatorRewardPool(info.pool).takeNativeSnapshot();
    }

    /// @notice Emergency withdrawal of funds from a creator's pool
    /// @param creator The creator address
    /// @param tokenAddress Token address (address(0) for native)
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    /// @param tokenType Type of token (NATIVE or ERC20 only)
    function emergencyWithdraw(
        address creator,
        address tokenAddress,
        address to,
        uint256 amount,
        ICreatorRewardPool.TokenType tokenType
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        ICreatorRewardPool(info.pool).emergencyWithdraw(
            tokenAddress,
            to,
            amount,
            tokenType
        );
    }

    /// @notice Updates the protocol fee recipient for all existing pools
    /// @dev This will update the fee recipient for all deployed pools
    function updateProtocolFeeRecipientForAllPools() external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < s_creators.length; ) {
            address creator = s_creators[i];
            CreatorPoolInfo storage info = s_creatorPools[creator];
            if (info.pool != address(0)) {
                ICreatorRewardPool(info.pool).setProtocolFeeRecipient(protocolFeeRecipient);
            }
            unchecked {
                ++i;
            }
        }
    }

    // ===== VIEW FUNCTIONS =====

    /// @notice Gets creator pool information
    /// @param creator The creator address
    /// @return Pool information struct
    function getCreatorPoolInfo(
        address creator
    ) external view returns (CreatorPoolInfo memory) {
        return s_creatorPools[creator];
    }

    /// @notice Gets the pool address for a given creator
    /// @param creator The creator address
    /// @return The pool address
    function getCreatorPoolAddress(address creator) external view returns (address) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();
        return info.pool;
    }

    /// @notice Checks if a creator's pool is active
    /// @param creator The creator address
    /// @return True if pool is active
    function isCreatorPoolActive(address creator) external view returns (bool) {
        return s_creatorPools[creator].active;
    }

    /// @notice Checks if a creator has a pool
    /// @param creator The creator address
    /// @return True if creator has a pool
    function hasCreatorPool(address creator) external view returns (bool) {
        return s_hasPool[creator];
    }

    /// @notice Gets the total number of creator pools
    /// @return Total number of creator pools
    function getTotalCreatorPools() external view returns (uint256) {
        return s_creators.length;
    }

    /// @notice Gets creator at index
    /// @param index The index
    /// @return Creator address at the given index
    function getCreatorAtIndex(uint256 index) external view returns (address) {
        return s_creators[index];
    }

    /// @notice Validates allocations for a creator's pool
    /// @param creator The creator address
    /// @param tokenAddress Token address to validate
    /// @param tokenType Type of token
    /// @return isValid True if allocations are valid
    /// @return totalAllocations Total allocation amount
    /// @return availableBalance Available balance for distribution
    function validateCreatorAllocations(
        address creator,
        address tokenAddress,
        ICreatorRewardPool.TokenType tokenType
    ) external view returns (bool isValid, uint256 totalAllocations, uint256 availableBalance) {
        CreatorPoolInfo storage info = s_creatorPools[creator];
        if (info.pool == address(0)) revert CreatorRewardPoolFactory__NoPoolForCreator();

        return ICreatorRewardPool(info.pool).validateAllocations(tokenAddress, tokenType);
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
} 