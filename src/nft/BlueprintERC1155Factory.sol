// SPDX-License-Identifier: Apache-2.0
/*
__________.__                             .__        __   
\______   \  |  __ __   ____ _____________|__| _____/  |_ 
 |    |  _/  | |  |  \_/ __ \\____ \_  __ \  |/    \   __\
 |    |   \  |_|  |  /\  ___/|  |_> >  | \/  |   |  \  |  
 |______  /____/____/  \___  >   __/|__|  |__|___|  /__|  
        \/                 \/|__|                 \/      
*/
pragma solidity 0.8.26;

import "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-contracts/proxy/Clones.sol";
import "./BlueprintERC1155.sol";

/**
 * @title BlueprintERC1155Factory
 * @dev Factory contract for deploying BlueprintERC1155 clones.
 * Uses OpenZeppelin's Clones library for gas-efficient deployment.
 * Can be used to manage and modify ERC1155 collections.
 * @custom:oz-upgrades-from BlueprintERC1155Factory
 */
contract BlueprintERC1155Factory is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    // ===== ERRORS =====
    error BlueprintERC1155Factory__NotDeployedCollection(address collection);
    error BlueprintERC1155Factory__ZeroBlueprintRecipient();
    error BlueprintERC1155Factory__ZeroCreatorRecipient();

    // Roles
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // State variables
    address public implementation;
    address public defaultBlueprintRecipient;
    uint256 public defaultFeeBasisPoints;
    uint256 public defaultMintFee;
    address public defaultTreasury;
    address public defaultRewardPoolRecipient;
    uint256 public defaultRewardPoolBasisPoints;

    // Mapping to track deployed collections
    mapping(address => bool) public isDeployedCollection;

    // Events
    event CollectionCreated(address indexed creator, address indexed collection, string uri);

    event DefaultFeeConfigUpdated(
        address blueprintRecipient,
        uint256 blueprintFeeBasisPoints,
        uint256 defaultMintFee,
        address treasury,
        address rewardPoolRecipient,
        uint256 rewardPoolBasisPoints
    );

    event CollectionUpdated(address indexed collection, string action);

    event DropCreated(address indexed collection, uint256 indexed tokenId, uint256 price);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the factory contract
     * @param _implementation Address of the BlueprintERC1155 implementation
     * @param _defaultBlueprintRecipient Default recipient for platform fees
     * @param _defaultFeeBasisPoints Default platform fee in basis points (100 = 1%)
     * @param _defaultMintFee Default mint fee in wei
     * @param _defaultTreasury Default treasury address
     * @param _defaultRewardPoolRecipient Default reward pool recipient
     * @param _defaultRewardPoolBasisPoints Default reward pool fee in basis points
     * @param _admin Admin address with full control
     */
    function initialize(
        address _implementation,
        address _defaultBlueprintRecipient,
        uint256 _defaultFeeBasisPoints,
        uint256 _defaultMintFee,
        address _defaultTreasury,
        address _defaultRewardPoolRecipient,
        uint256 _defaultRewardPoolBasisPoints,
        address _admin
    ) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        implementation = _implementation;
        defaultBlueprintRecipient = _defaultBlueprintRecipient;
        defaultFeeBasisPoints = _defaultFeeBasisPoints;
        defaultMintFee = _defaultMintFee;
        defaultTreasury = _defaultTreasury;
        defaultRewardPoolRecipient = _defaultRewardPoolRecipient;
        defaultRewardPoolBasisPoints = _defaultRewardPoolBasisPoints;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    /**
     * @dev Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    /**
     * @dev Updates the implementation contract
     * @param _implementation New implementation address
     */
    function setImplementation(address _implementation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        implementation = _implementation;
    }

    /**
     * @dev Creates a new collection by deploying a clone of the implementation
     * @param uri URI for collection metadata and base token metadata
     * @param creatorRecipient Address to receive creator role and royalties
     * @param creatorBasisPoints Creator royalty in basis points (100 = 1%)
     * @return Address of the newly deployed collection
     */
    function createCollection(
        string memory uri,
        address creatorRecipient,
        uint256 creatorBasisPoints
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address) {
        // Validate essential recipients
        if (defaultBlueprintRecipient == address(0)) {
            revert BlueprintERC1155Factory__ZeroBlueprintRecipient();
        }
        if (creatorRecipient == address(0)) {
            revert BlueprintERC1155Factory__ZeroCreatorRecipient();
        }

        address clone = Clones.clone(implementation);

        BlueprintERC1155(clone).initialize(
            uri,
            address(this),
            defaultBlueprintRecipient,
            defaultFeeBasisPoints,
            creatorRecipient,
            creatorBasisPoints,
            defaultRewardPoolRecipient,
            defaultRewardPoolBasisPoints,
            defaultTreasury
        );

        isDeployedCollection[clone] = true;

        emit CollectionCreated(creatorRecipient, clone, uri);
        return clone;
    }

    /**
     * @dev Updates the default fee configuration used for new collections
     * @param _defaultBlueprintRecipient Default recipient for platform fees
     * @param _defaultFeeBasisPoints Default platform fee in basis points (100 = 1%)
     * @param _defaultMintFee Default mint fee in wei
     * @param _defaultTreasury Default treasury address
     * @param _defaultRewardPoolRecipient Default reward pool recipient
     * @param _defaultRewardPoolBasisPoints Default reward pool fee in basis points
     */
    function setDefaultFeeConfig(
        address _defaultBlueprintRecipient,
        uint256 _defaultFeeBasisPoints,
        uint256 _defaultMintFee,
        address _defaultTreasury,
        address _defaultRewardPoolRecipient,
        uint256 _defaultRewardPoolBasisPoints
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_defaultBlueprintRecipient == address(0)) {
            revert BlueprintERC1155Factory__ZeroBlueprintRecipient();
        }

        defaultBlueprintRecipient = _defaultBlueprintRecipient;
        defaultFeeBasisPoints = _defaultFeeBasisPoints;
        defaultMintFee = _defaultMintFee;
        defaultTreasury = _defaultTreasury;
        defaultRewardPoolRecipient = _defaultRewardPoolRecipient;
        defaultRewardPoolBasisPoints = _defaultRewardPoolBasisPoints;

        emit DefaultFeeConfigUpdated(
            _defaultBlueprintRecipient,
            _defaultFeeBasisPoints,
            _defaultMintFee,
            _defaultTreasury,
            _defaultRewardPoolRecipient,
            _defaultRewardPoolBasisPoints
        );
    }

    /**
     * @dev Returns the default fee configuration for new collections
     * @return A struct containing default fee configuration values
     */
    function getDefaultFeeConfig() external view returns (BlueprintERC1155.FeeConfig memory) {
        // For creator values, we return empty defaults since they are set during collection creation
        return BlueprintERC1155.FeeConfig({
            blueprintRecipient: defaultBlueprintRecipient,
            blueprintFeeBasisPoints: defaultFeeBasisPoints,
            creatorRecipient: address(0), // Will be set during collection creation
            creatorBasisPoints: 0, // Will be set during collection creation
            rewardPoolRecipient: defaultRewardPoolRecipient,
            rewardPoolBasisPoints: defaultRewardPoolBasisPoints,
            treasury: defaultTreasury
        });
    }

    /**
     * @dev Returns the total supply of all tokens in a collection
     * @param collection Address of the collection to query
     * @return Total supply of all tokens in the collection
     */
    function getCollectionTotalSupply(address collection) external view returns (uint256) {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        return BlueprintERC1155(collection).totalSupply();
    }

    /**
     * @dev Returns the total supply for a specific token ID in a collection
     * @param collection Address of the collection to query
     * @param tokenId Token ID to query
     * @return Total supply of the specified token ID
     */
    function getTokenTotalSupply(address collection, uint256 tokenId)
        external
        view
        returns (uint256)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        return BlueprintERC1155(collection).totalSupply(tokenId);
    }

    // Collection management functions

    /**
     * @dev Creates a new drop with auto-incremented token ID
     * @param collection Address of the collection
     * @param price Price in wei
     * @param startTime Start time timestamp
     * @param endTime End time timestamp
     * @param active Whether the drop is active
     * @return tokenId The newly created drop's token ID
     */
    function createNewDrop(
        address collection,
        uint256 price,
        uint256 startTime,
        uint256 endTime,
        bool active
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        uint256 tokenId = BlueprintERC1155(collection).createDrop(price, startTime, endTime, active);

        emit DropCreated(collection, tokenId, price);
        return tokenId;
    }

    /**
     * @dev Creates a new drop in a collection with a specific token ID
     * @param collection Address of the collection
     * @param tokenId Token ID for the drop
     * @param price Price in wei
     * @param startTime Start time timestamp
     * @param endTime End time timestamp
     * @param active Whether the drop is active
     */
    function createDrop(
        address collection,
        uint256 tokenId,
        uint256 price,
        uint256 startTime,
        uint256 endTime,
        bool active
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).setDrop(tokenId, price, startTime, endTime, active);

        emit CollectionUpdated(collection, "createDrop");
    }

    /**
     * @dev Updates drop price
     * @param collection Address of the collection
     * @param tokenId Token ID for the drop
     * @param price New price in wei
     */
    function updateDropPrice(address collection, uint256 tokenId, uint256 price)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).setDropPrice(tokenId, price);

        emit CollectionUpdated(collection, "updateDropPrice");
    }

    /**
     * @dev Updates drop start time
     * @param collection Address of the collection
     * @param tokenId Token ID for the drop
     * @param startTime New start time
     */
    function updateDropStartTime(address collection, uint256 tokenId, uint256 startTime)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).setDropStartTime(tokenId, startTime);

        emit CollectionUpdated(collection, "updateDropStartTime");
    }

    /**
     * @dev Updates drop end time
     * @param collection Address of the collection
     * @param tokenId Token ID for the drop
     * @param endTime New end time
     */
    function updateDropEndTime(address collection, uint256 tokenId, uint256 endTime)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).setDropEndTime(tokenId, endTime);

        emit CollectionUpdated(collection, "updateDropEndTime");
    }

    /**
     * @dev Activates or deactivates a drop
     * @param collection Address of the collection
     * @param tokenId Token ID for the drop
     * @param active Whether the drop is active
     */
    function setDropActive(address collection, uint256 tokenId, bool active)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).setDropActive(tokenId, active);

        emit CollectionUpdated(collection, "setDropActive");
    }

    /**
     * @dev Updates collection metadata
     * @param collection Address of the collection
     * @param uri New URI for collection metadata
     */
    function updateCollectionURI(address collection, string memory uri)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).setCollectionURI(uri);

        emit CollectionUpdated(collection, "updateCollectionURI");
    }

    /**
     * @dev Updates the URI for a specific token
     * @param collection Address of the collection
     * @param tokenId Token ID to update URI for
     * @param tokenURI New URI for the token
     */
    function updateTokenURI(address collection, uint256 tokenId, string memory tokenURI)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).setTokenURI(tokenId, tokenURI);

        emit CollectionUpdated(collection, "updateTokenURI");
    }

    /**
     * @dev Updates the collection name
     * @param collection Address of the collection
     * @param name New name for the collection
     */
    function updateCollectionName(address collection, string memory name)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).setName(name);

        emit CollectionUpdated(collection, "updateCollectionName");
    }

    /**
     * @dev Updates the collection symbol
     * @param collection Address of the collection
     * @param symbol New symbol for the collection
     */
    function updateCollectionSymbol(address collection, string memory symbol)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).setSymbol(symbol);

        emit CollectionUpdated(collection, "updateCollectionSymbol");
    }

    /**
     * @dev Updates fee configuration for a collection
     * @param collection Address of the collection
     * @param blueprintRecipient Fee recipient address
     * @param blueprintFeeBasisPoints Fee percentage in basis points (100 = 1%)
     * @param creator Creator fee recipient
     * @param creatorBasisPoints Creator fee percentage in basis points
     * @param rewardPoolRecipient Reward pool recipient address
     * @param rewardPoolBasisPoints Reward pool fee percentage in basis points
     * @param treasury Treasury address
     */
    function updateFeeConfig(
        address collection,
        address blueprintRecipient,
        uint256 blueprintFeeBasisPoints,
        address creator,
        uint256 creatorBasisPoints,
        address rewardPoolRecipient,
        uint256 rewardPoolBasisPoints,
        address treasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        if (blueprintRecipient == address(0)) {
            revert BlueprintERC1155Factory__ZeroBlueprintRecipient();
        }

        if (creator == address(0)) {
            revert BlueprintERC1155Factory__ZeroCreatorRecipient();
        }

        BlueprintERC1155(collection).setFeeConfig(
            blueprintRecipient,
            blueprintFeeBasisPoints,
            creator,
            creatorBasisPoints,
            rewardPoolRecipient,
            rewardPoolBasisPoints,
            treasury
        );

        emit CollectionUpdated(collection, "updateFeeConfig");
    }

    /**
     * @dev Updates fee configuration for a specific token ID
     * @param collection Address of the collection
     * @param tokenId Token ID to set fee configuration for
     * @param blueprintRecipient Fee recipient address
     * @param blueprintFeeBasisPoints Fee percentage in basis points (100 = 1%)
     * @param creator Creator fee recipient
     * @param creatorBasisPoints Creator fee percentage in basis points
     * @param rewardPoolRecipient Reward pool recipient address
     * @param rewardPoolBasisPoints Reward pool fee percentage in basis points
     * @param treasury Treasury address
     */
    function updateTokenFeeConfig(
        address collection,
        uint256 tokenId,
        address blueprintRecipient,
        uint256 blueprintFeeBasisPoints,
        address creator,
        uint256 creatorBasisPoints,
        address rewardPoolRecipient,
        uint256 rewardPoolBasisPoints,
        address treasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        if (blueprintRecipient == address(0)) {
            revert BlueprintERC1155Factory__ZeroBlueprintRecipient();
        }

        if (creator == address(0)) {
            revert BlueprintERC1155Factory__ZeroCreatorRecipient();
        }

        BlueprintERC1155(collection).setTokenFeeConfig(
            tokenId,
            blueprintRecipient,
            blueprintFeeBasisPoints,
            creator,
            creatorBasisPoints,
            rewardPoolRecipient,
            rewardPoolBasisPoints,
            treasury
        );

        emit CollectionUpdated(collection, "updateTokenFeeConfig");
    }

    /**
     * @dev Removes a token-specific fee configuration, reverting to the default
     * @param collection Address of the collection
     * @param tokenId Token ID to remove custom fee configuration for
     */
    function removeTokenFeeConfig(address collection, uint256 tokenId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).removeTokenFeeConfig(tokenId);

        emit CollectionUpdated(collection, "removeTokenFeeConfig");
    }

    /**
     * @dev Updates creator recipient for a collection
     * @param collection Address of the collection
     * @param creator New creator recipient
     */
    function updateCreatorRecipient(address collection, address creator)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        if (creator == address(0)) {
            revert BlueprintERC1155Factory__ZeroCreatorRecipient();
        }

        BlueprintERC1155(collection).setCreatorRecipient(creator);

        emit CollectionUpdated(collection, "updateCreatorRecipient");
    }

    /**
     * @dev Updates reward pool recipient for a collection
     * @param collection Address of the collection
     * @param rewardPoolRecipient New reward pool recipient
     */
    function updateRewardPoolRecipient(address collection, address rewardPoolRecipient)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).setRewardPoolRecipient(rewardPoolRecipient);

        emit CollectionUpdated(collection, "updateRewardPoolRecipient");
    }

    /**
     * @dev Mints tokens without payment (admin only)
     * @param collection Address of the collection
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param amount Number of tokens to mint
     */
    function adminMint(address collection, address to, uint256 tokenId, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).adminMint(to, tokenId, amount);

        emit CollectionUpdated(collection, "adminMint");
    }

    /**
     * @dev Batch mints tokens without payment (admin only)
     * @param collection Address of the collection
     * @param to Recipient address
     * @param tokenIds Array of token IDs to mint
     * @param amounts Array of token amounts to mint
     */
    function adminBatchMint(
        address collection,
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155(collection).adminBatchMint(to, tokenIds, amounts);

        emit CollectionUpdated(collection, "adminBatchMint");
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
