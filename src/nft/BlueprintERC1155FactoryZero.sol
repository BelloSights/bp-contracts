// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "@openzeppelin-contracts/access/AccessControl.sol";
import "./BlueprintERC1155Zero.sol";

/**
 * @title BlueprintERC1155FactoryZero
 * @dev Simplified factory contract for deploying BlueprintERC1155Zero instances on zkSync Era Zero
 */
contract BlueprintERC1155FactoryZero is AccessControl {
    // ===== ERRORS =====
    error BlueprintERC1155Factory__NotDeployedCollection(address collection);
    error BlueprintERC1155Factory__ZeroBlueprintRecipient();
    error BlueprintERC1155Factory__ZeroCreatorRecipient();

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

    constructor(
        address _implementation,
        address _defaultBlueprintRecipient,
        uint256 _defaultFeeBasisPoints,
        uint256 _defaultMintFee,
        address _defaultTreasury,
        address _defaultRewardPoolRecipient,
        uint256 _defaultRewardPoolBasisPoints,
        address _admin
    ) {
        implementation = _implementation;
        defaultBlueprintRecipient = _defaultBlueprintRecipient;
        defaultFeeBasisPoints = _defaultFeeBasisPoints;
        defaultMintFee = _defaultMintFee;
        defaultTreasury = _defaultTreasury;
        defaultRewardPoolRecipient = _defaultRewardPoolRecipient;
        defaultRewardPoolBasisPoints = _defaultRewardPoolBasisPoints;

        // Grant admin role to both the admin address and this contract
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    function createCollection(
        string memory uri,
        address creatorRecipient,
        uint256 creatorBasisPoints
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address) {
        if (defaultBlueprintRecipient == address(0)) {
            revert BlueprintERC1155Factory__ZeroBlueprintRecipient();
        }
        if (creatorRecipient == address(0)) {
            revert BlueprintERC1155Factory__ZeroCreatorRecipient();
        }

        BlueprintERC1155Zero collection = new BlueprintERC1155Zero(
            uri,
            "Blueprint", // Default name
            "BP", // Default symbol
            address(this), // Factory sets itself as the admin
            defaultBlueprintRecipient,
            defaultFeeBasisPoints,
            creatorRecipient,
            creatorBasisPoints,
            defaultRewardPoolRecipient,
            defaultRewardPoolBasisPoints,
            defaultTreasury
        );

        isDeployedCollection[address(collection)] = true;
        emit CollectionCreated(creatorRecipient, address(collection), uri);

        return address(collection);
    }

    function updateDefaultFeeConfig(
        address blueprintRecipient,
        uint256 blueprintFeeBasisPoints,
        uint256 mintFee,
        address treasury,
        address rewardPoolRecipient,
        uint256 rewardPoolBasisPoints
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (blueprintRecipient == address(0)) {
            revert BlueprintERC1155Factory__ZeroBlueprintRecipient();
        }

        defaultBlueprintRecipient = blueprintRecipient;
        defaultFeeBasisPoints = blueprintFeeBasisPoints;
        defaultMintFee = mintFee;
        defaultTreasury = treasury;
        defaultRewardPoolRecipient = rewardPoolRecipient;
        defaultRewardPoolBasisPoints = rewardPoolBasisPoints;

        emit DefaultFeeConfigUpdated(
            blueprintRecipient,
            blueprintFeeBasisPoints,
            mintFee,
            treasury,
            rewardPoolRecipient,
            rewardPoolBasisPoints
        );
    }

    function setImplementation(address _implementation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        implementation = _implementation;
    }

    function getDefaultFeeConfig() external view returns (BlueprintERC1155Zero.FeeConfig memory) {
        return BlueprintERC1155Zero.FeeConfig({
            blueprintRecipient: defaultBlueprintRecipient,
            blueprintFeeBasisPoints: defaultFeeBasisPoints,
            creatorRecipient: address(0), // Will be set during collection creation
            creatorBasisPoints: 0, // Will be set during collection creation
            rewardPoolRecipient: defaultRewardPoolRecipient,
            rewardPoolBasisPoints: defaultRewardPoolBasisPoints,
            treasury: defaultTreasury
        });
    }

    function getCollectionTotalSupply(address collection) external view returns (uint256) {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        return BlueprintERC1155Zero(collection).totalSupply();
    }

    function getTokenTotalSupply(address collection, uint256 tokenId)
        external
        view
        returns (uint256)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        return BlueprintERC1155Zero(collection).totalSupply(tokenId);
    }

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

        uint256 tokenId = BlueprintERC1155Zero(collection).createDrop(price, startTime, endTime, active);

        emit DropCreated(collection, tokenId, price);
        return tokenId;
    }

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

        BlueprintERC1155Zero(collection).setDrop(tokenId, price, startTime, endTime, active);

        emit CollectionUpdated(collection, "createDrop");
    }

    function updateDropPrice(address collection, uint256 tokenId, uint256 price)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155Zero(collection).setDropPrice(tokenId, price);

        emit CollectionUpdated(collection, "updateDropPrice");
    }

    function updateDropStartTime(address collection, uint256 tokenId, uint256 startTime)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155Zero(collection).setDropStartTime(tokenId, startTime);

        emit CollectionUpdated(collection, "updateDropStartTime");
    }

    function updateDropEndTime(address collection, uint256 tokenId, uint256 endTime)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155Zero(collection).setDropEndTime(tokenId, endTime);

        emit CollectionUpdated(collection, "updateDropEndTime");
    }

    function setDropActive(address collection, uint256 tokenId, bool active)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155Zero(collection).setDropActive(tokenId, active);

        emit CollectionUpdated(collection, "setDropActive");
    }

    function updateCollectionURI(address collection, string memory uri)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155Zero(collection).setURI(uri);

        emit CollectionUpdated(collection, "updateCollectionURI");
    }

    function updateTokenURI(address collection, uint256 tokenId, string memory tokenURI)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155Zero(collection).setTokenURI(tokenId, tokenURI);

        emit CollectionUpdated(collection, "updateTokenURI");
    }

    function updateCollectionName(address collection, string memory name)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155Zero(collection).setName(name);

        emit CollectionUpdated(collection, "updateCollectionName");
    }

    function updateCollectionSymbol(address collection, string memory symbol)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155Zero(collection).setSymbol(symbol);

        emit CollectionUpdated(collection, "updateCollectionSymbol");
    }

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

        BlueprintERC1155Zero(collection).setFeeConfig(
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

        BlueprintERC1155Zero(collection).setTokenFeeConfig(
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

    function removeTokenFeeConfig(address collection, uint256 tokenId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155Zero(collection).removeTokenFeeConfig(tokenId);

        emit CollectionUpdated(collection, "removeTokenFeeConfig");
    }

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

        BlueprintERC1155Zero(collection).setCreatorRecipient(creator);

        emit CollectionUpdated(collection, "updateCreatorRecipient");
    }

    function updateRewardPoolRecipient(address collection, address rewardPoolRecipient)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155Zero(collection).setRewardPoolRecipient(rewardPoolRecipient);

        emit CollectionUpdated(collection, "updateRewardPoolRecipient");
    }

    function adminMint(address collection, address to, uint256 tokenId, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155Zero(collection).adminMint(to, tokenId, amount);

        emit CollectionUpdated(collection, "adminMint");
    }

    function adminBatchMint(
        address collection,
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isDeployedCollection[collection]) {
            revert BlueprintERC1155Factory__NotDeployedCollection(collection);
        }

        BlueprintERC1155Zero(collection).adminBatchMint(to, tokenIds, amounts);

        emit CollectionUpdated(collection, "adminBatchMint");
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
} 