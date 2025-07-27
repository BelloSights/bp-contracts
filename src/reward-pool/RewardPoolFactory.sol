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
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Clones} from "@openzeppelin-contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {RewardPool} from "./RewardPool.sol";
import {IRewardPool} from "./interfaces/IRewardPool.sol";

/// @title RewardPoolFactory
/// @notice Factory contract for creating and managing XP-based reward pools
/// @dev Follows the same pattern as the existing Factory.sol but for reward pool management
contract RewardPoolFactory is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    // ===== CONSTANTS =====
    string public constant SIGNING_DOMAIN = "BP_REWARD_POOL";
    string public constant SIGNATURE_VERSION = "1";

    // ===== ERRORS =====
    error RewardPoolFactory__OnlyCallableByAdmin();
    error RewardPoolFactory__NoPoolForId();
    error RewardPoolFactory__PoolAlreadyExists();
    error RewardPoolFactory__ZeroAddress();
    error RewardPoolFactory__PoolNotActive();
    error RewardPoolFactory__InvalidPoolId();

    // ===== STATE =====
    uint256 public s_nextPoolId;
    address public implementation;

    struct PoolInfo {
        uint256 poolId;
        address pool;
        bool active;
        string name;
        string description;
    }

    // Mapping from poolId to its info
    mapping(uint256 => PoolInfo) public s_pools;

    // ===== EVENTS =====
    event PoolCreated(
        uint256 indexed poolId,
        address indexed pool,
        string name,
        string description
    );
    event PoolActivated(uint256 indexed poolId);
    event PoolDeactivated(uint256 indexed poolId);
    event UserAdded(uint256 indexed poolId, address indexed user, uint256 xp);
    event XPUpdated(
        uint256 indexed poolId,
        address indexed user,
        uint256 oldXP,
        uint256 newXP
    );
    event UserPenalized(
        uint256 indexed poolId,
        address indexed user,
        uint256 xpRemoved
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the RewardPoolFactory contract
    /// @param admin Address to be granted the default admin role
    /// @param _implementation Address of the RewardPool implementation contract
    function initialize(
        address admin,
        address _implementation
    ) external initializer {
        if (admin == address(0)) revert RewardPoolFactory__ZeroAddress();
        if (_implementation == address(0))
            revert RewardPoolFactory__ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        implementation = _implementation;
        s_nextPoolId = 1;
    }

    /// @notice Sets the RewardPool implementation contract address
    /// @param _implementation New implementation address
    function setImplementation(
        address _implementation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_implementation == address(0))
            revert RewardPoolFactory__ZeroAddress();
        implementation = _implementation;
    }

    /// @notice Creates a new reward pool
    /// @param name Name of the reward pool
    /// @param description Description of the reward pool
    /// @return poolId The unique identifier of the newly created pool
    function createRewardPool(
        string calldata name,
        string calldata description
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
        if (implementation == address(0))
            revert RewardPoolFactory__ZeroAddress();

        uint256 poolId = s_nextPoolId;

        // Create a clone of the shared implementation
        address clone = Clones.clone(implementation);

        // Initialize the clone
        IRewardPool(clone).initialize(
            address(this),
            SIGNING_DOMAIN,
            SIGNATURE_VERSION
        );

        s_pools[poolId] = PoolInfo({
            poolId: poolId,
            pool: clone,
            active: false, // Pools start inactive
            name: name,
            description: description
        });

        emit PoolCreated(poolId, clone, name, description);

        unchecked {
            s_nextPoolId++;
        }

        return poolId;
    }

    /// @notice Activates a reward pool to allow claiming
    /// @param poolId The identifier of the pool to activate
    function activatePool(
        uint256 poolId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        info.active = true;
        IRewardPool(info.pool).setActive(true);
        emit PoolActivated(poolId);
    }

    /// @notice Deactivates a reward pool to prevent claiming
    /// @param poolId The identifier of the pool to deactivate
    function deactivatePool(
        uint256 poolId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        info.active = false;
        IRewardPool(info.pool).setActive(false);
        emit PoolDeactivated(poolId);
    }

    /// @notice Adds a new user to a reward pool with initial XP
    /// @param poolId The pool identifier
    /// @param user The user address to add
    /// @param xp The initial XP amount for the user
    function addUser(
        uint256 poolId,
        address user,
        uint256 xp
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        IRewardPool(info.pool).addUser(user, xp);
        emit UserAdded(poolId, user, xp);
    }

    /// @notice Updates XP for an existing user
    /// @param poolId The pool identifier
    /// @param user The user address
    /// @param newXP The new XP amount
    function updateUserXP(
        uint256 poolId,
        address user,
        uint256 newXP
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        uint256 oldXP = IRewardPool(info.pool).getUserXP(user);
        IRewardPool(info.pool).updateUserXP(user, newXP);
        emit XPUpdated(poolId, user, oldXP, newXP);
    }

    /// @notice Penalizes a user by removing XP
    /// @param poolId The pool identifier
    /// @param user The user address
    /// @param xpToRemove Amount of XP to remove
    function penalizeUser(
        uint256 poolId,
        address user,
        uint256 xpToRemove
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        IRewardPool(info.pool).penalizeUser(user, xpToRemove);
        emit UserPenalized(poolId, user, xpToRemove);
    }

    // ===== BATCH USER MANAGEMENT FUNCTIONS =====

    /// @notice Adds multiple users to a reward pool with initial XP in batches
    /// @param poolId The pool identifier
    /// @param users Array of user addresses to add
    /// @param xpAmounts Array of initial XP amounts for users
    /// @dev Gas-optimized for large user sets. Arrays must be same length.
    function batchAddUsers(
        uint256 poolId,
        address[] calldata users,
        uint256[] calldata xpAmounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        IRewardPool(info.pool).batchAddUsers(users, xpAmounts);

        // Emit individual events for each user for compatibility
        for (uint256 i = 0; i < users.length; ) {
            emit UserAdded(poolId, users[i], xpAmounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Updates XP for multiple existing users in batches
    /// @param poolId The pool identifier
    /// @param users Array of user addresses
    /// @param newXPAmounts Array of new XP amounts
    /// @dev Gas-optimized for large user sets. Arrays must be same length.
    function batchUpdateUserXP(
        uint256 poolId,
        address[] calldata users,
        uint256[] calldata newXPAmounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        // Get old XP values for events
        uint256[] memory oldXPAmounts = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; ) {
            oldXPAmounts[i] = IRewardPool(info.pool).getUserXP(users[i]);
            unchecked {
                ++i;
            }
        }

        IRewardPool(info.pool).batchUpdateUserXP(users, newXPAmounts);

        // Emit individual events for each user for compatibility
        for (uint256 i = 0; i < users.length; ) {
            emit XPUpdated(poolId, users[i], oldXPAmounts[i], newXPAmounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Penalizes multiple users by removing XP in batches
    /// @param poolId The pool identifier
    /// @param users Array of user addresses
    /// @param xpToRemove Array of XP amounts to remove
    /// @dev Gas-optimized for large user sets. Arrays must be same length.
    function batchPenalizeUsers(
        uint256 poolId,
        address[] calldata users,
        uint256[] calldata xpToRemove
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        IRewardPool(info.pool).batchPenalizeUsers(users, xpToRemove);

        // Emit individual events for each user for compatibility
        for (uint256 i = 0; i < users.length; ) {
            emit UserPenalized(poolId, users[i], xpToRemove[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Grants signer role to an address for a specific pool
    /// @param poolId The pool identifier
    /// @param signer The address to grant signer role
    function grantSignerRole(
        uint256 poolId,
        address signer
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        IRewardPool(info.pool).grantSignerRole(signer);
    }

    /// @notice Revokes signer role from an address for a specific pool
    /// @param poolId The pool identifier
    /// @param signer The address to revoke signer role from
    function revokeSignerRole(
        uint256 poolId,
        address signer
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        IRewardPool(info.pool).revokeSignerRole(signer);
    }

    /// @notice Takes a snapshot of current balances for reward distribution
    /// @param poolId The pool identifier
    /// @param tokenAddresses Array of ERC20 token addresses to snapshot
    function takeSnapshot(
        uint256 poolId,
        address[] calldata tokenAddresses
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        IRewardPool(info.pool).takeSnapshot(tokenAddresses);
    }

    /// @notice Takes a snapshot of only native ETH for reward distribution
    /// @param poolId The pool identifier
    function takeNativeSnapshot(
        uint256 poolId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        IRewardPool(info.pool).takeNativeSnapshot();
    }

    /// @notice Emergency withdrawal of funds from a pool
    /// @param poolId The pool identifier
    /// @param tokenAddress Token address (address(0) for native)
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    /// @param tokenType Type of token (NATIVE or ERC20 only)
    function emergencyWithdraw(
        uint256 poolId,
        address tokenAddress,
        address to,
        uint256 amount,
        IRewardPool.TokenType tokenType
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();

        IRewardPool(info.pool).emergencyWithdraw(
            tokenAddress,
            to,
            amount,
            tokenType
        );
    }

    /// @notice Gets pool information
    /// @param poolId The pool identifier
    /// @return Pool information struct
    function getPoolInfo(
        uint256 poolId
    ) external view returns (PoolInfo memory) {
        return s_pools[poolId];
    }

    /// @notice Gets the pool address for a given pool ID
    /// @param poolId The pool identifier
    /// @return The pool address
    function getPoolAddress(uint256 poolId) external view returns (address) {
        PoolInfo storage info = s_pools[poolId];
        if (info.pool == address(0)) revert RewardPoolFactory__NoPoolForId();
        return info.pool;
    }

    /// @notice Checks if a pool is active
    /// @param poolId The pool identifier
    /// @return True if pool is active
    function isPoolActive(uint256 poolId) external view returns (bool) {
        return s_pools[poolId].active;
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
