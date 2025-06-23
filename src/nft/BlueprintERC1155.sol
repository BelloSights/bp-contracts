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

import "@openzeppelin-contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/utils/StringsUpgradeable.sol";

/**
 * @title BlueprintERC1155
 * @dev ERC1155 implementation for blueprint collections with drop functionality, fee distribution,
 * and metadata management. Designed to be deployed as a clone via ERC1155Factory.
 * @custom:oz-upgrades-from BlueprintERC1155
 */
contract BlueprintERC1155 is
    Initializable,
    ERC1155Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using StringsUpgradeable for uint256;

    // ===== ERRORS =====
    error BlueprintERC1155__InvalidStartEndTime();
    error BlueprintERC1155__DropNotActive();
    error BlueprintERC1155__DropNotStarted();
    error BlueprintERC1155__DropEnded();
    error BlueprintERC1155__InsufficientPayment(uint256 required, uint256 provided);
    error BlueprintERC1155__BlueprintFeeTransferFailed();
    error BlueprintERC1155__CreatorFeeTransferFailed();
    error BlueprintERC1155__TreasuryTransferFailed();
    error BlueprintERC1155__RewardPoolFeeTransferFailed();
    error BlueprintERC1155__RefundFailed();
    error BlueprintERC1155__StartAfterEnd();
    error BlueprintERC1155__EndBeforeStart();
    error BlueprintERC1155__BatchLengthMismatch();
    error BlueprintERC1155__ZeroBlueprintRecipient();
    error BlueprintERC1155__ZeroCreatorRecipient();

    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct Drop {
        uint256 price;
        uint256 startTime;
        uint256 endTime;
        bool active;
    }

    struct FeeConfig {
        address blueprintRecipient; // Address of the blueprint recipient
        uint256 blueprintFeeBasisPoints; // Basis points for blueprint fee
        address creatorRecipient; // Address of the creator recipient
        uint256 creatorBasisPoints; // Basis points for creator fee
        address rewardPoolRecipient; // Address of the reward pool recipient
        uint256 rewardPoolBasisPoints; // Basis points for reward pool
        address treasury; // Address of the treasury
    }

    // Name and symbol for the collection (for marketplace/explorer display)
    string private _name;
    string private _symbol;

    // Track the next token ID to be used for new drops
    uint256 public nextTokenId;

    // Track total supply per token ID
    mapping(uint256 => uint256) private _totalSupply;

    // Track total supply across all token IDs
    uint256 private _globalTotalSupply;

    // Map token ID to a custom URI
    mapping(uint256 => string) private _tokenURIs;

    // Collection URI for metadata
    string private _collectionURI;

    mapping(uint256 => Drop) public drops;

    // Default fee configuration for the collection
    FeeConfig public defaultFeeConfig;

    // Per-token fee configurations
    mapping(uint256 => FeeConfig) public tokenFeeConfigs;

    // Track which tokens have custom fee configurations
    mapping(uint256 => bool) public hasCustomFeeConfig;

    event DropCreated(uint256 indexed tokenId, uint256 price, uint256 startTime, uint256 endTime);
    event DropUpdated(
        uint256 indexed tokenId, uint256 price, uint256 startTime, uint256 endTime, bool active
    );
    event TokensMinted(address indexed to, uint256 indexed tokenId, uint256 amount);
    event TokensBatchMinted(address indexed to, uint256[] tokenIds, uint256[] amounts);
    event FeeConfigUpdated(
        address blueprintRecipient,
        uint256 blueprintFeeBasisPoints,
        address creatorRecipient,
        uint256 creatorBasisPoints,
        address rewardPoolRecipient,
        uint256 rewardPoolBasisPoints,
        address treasury
    );
    event TokenFeeConfigUpdated(
        uint256 indexed tokenId,
        address blueprintRecipient,
        uint256 blueprintFeeBasisPoints,
        address creatorRecipient,
        uint256 creatorBasisPoints,
        address rewardPoolRecipient,
        uint256 rewardPoolBasisPoints,
        address treasury
    );
    event TokenFeeConfigRemoved(uint256 indexed tokenId);
    event CollectionURIUpdated(string uri);
    event TokenURIUpdated(uint256 indexed tokenId, string uri);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract with collection details and fee configuration
     * @param _uri Base URI for token metadata
     * @param _admin Address to receive factory role (usually the factory)
     * @param _blueprintRecipient Address to receive platform fees
     * @param _feeBasisPoints Platform fee in basis points (100 = 1%)
     * @param _creatorRecipient Address to receive creator role and creator royalties
     * @param _creatorBasisPoints Creator royalty in basis points (100 = 1%)
     * @param _rewardPoolRecipient Address to receive reward pool fees
     * @param _rewardPoolBasisPoints Reward pool fee in basis points (100 = 1%)
     * @param _treasury Address to receive treasury fees
     */
    function initialize(
        string memory _uri,
        address _admin,
        address _blueprintRecipient,
        uint256 _feeBasisPoints,
        address _creatorRecipient,
        uint256 _creatorBasisPoints,
        address _rewardPoolRecipient,
        uint256 _rewardPoolBasisPoints,
        address _treasury
    ) public initializer {
        __ERC1155_init(_uri);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FACTORY_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        if (_creatorRecipient != address(0)) {
            _grantRole(CREATOR_ROLE, _creatorRecipient);
        }

        // Initialize nextTokenId to 0
        nextTokenId = 0;

        // Initialize global total supply to 0
        _globalTotalSupply = 0;

        // Use the same URI for collection URI as the token base URI
        _collectionURI = _uri;
        defaultFeeConfig = FeeConfig({
            blueprintRecipient: _blueprintRecipient,
            blueprintFeeBasisPoints: _feeBasisPoints,
            creatorRecipient: _creatorRecipient,
            creatorBasisPoints: _creatorBasisPoints,
            rewardPoolRecipient: _rewardPoolRecipient,
            rewardPoolBasisPoints: _rewardPoolBasisPoints,
            treasury: _treasury
        });

        // Set default name and symbol
        _name = "Blueprint";
        _symbol = "BP";
    }

    /**
     * @dev Returns the name of the token collection
     * @return The name of the token
     */
    function name() external view returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token collection
     * @return The symbol of the token
     */
    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Sets the name of the token collection - only callable by factory
     * @param newName New name for the collection
     */
    function setName(string memory newName) external onlyRole(FACTORY_ROLE) {
        _name = newName;
    }

    /**
     * @dev Sets the symbol of the token collection - only callable by factory
     * @param newSymbol New symbol for the collection
     */
    function setSymbol(string memory newSymbol) external onlyRole(FACTORY_ROLE) {
        _symbol = newSymbol;
    }

    /**
     * @dev Returns the URI for a given token ID
     * First checks if there's a token-specific URI set
     * Falls back to the base URI if no specific URI is set
     * @param tokenId The token ID to get the URI for
     * @return The URI string for the token
     */
    function uri(uint256 tokenId) public view virtual override returns (string memory) {
        string memory tokenURI = _tokenURIs[tokenId];

        // If token has a specific URI, return it
        if (bytes(tokenURI).length > 0) {
            return tokenURI;
        }

        // Otherwise return the base URI
        return super.uri(tokenId);
    }

    /**
     * @dev Returns the URI for the collection
     * @return The URI string for the collection
     */
    function collectionURI() public view returns (string memory) {
        return _collectionURI;
    }

    /**
     * @dev Sets the URI for a specific token ID - only callable by factory
     * @param tokenId Token ID to set URI for
     * @param tokenURI New URI for the token
     */
    function setTokenURI(uint256 tokenId, string memory tokenURI) external onlyRole(FACTORY_ROLE) {
        _tokenURIs[tokenId] = tokenURI;
        emit TokenURIUpdated(tokenId, tokenURI);
    }

    /**
     * @dev Sets the URI for the collection - only callable by factory
     * @param newURI New URI for the collection
     */
    function setCollectionURI(string memory newURI) external onlyRole(FACTORY_ROLE) {
        _collectionURI = newURI;
        emit CollectionURIUpdated(newURI);
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
     * @dev Creates a new drop with auto-incrementing token ID - only callable by factory
     * @param price The mint price in wei
     * @param startTime The timestamp when minting becomes available
     * @param endTime The timestamp when minting ends
     * @param active Whether the drop is active and mintable
     * @return tokenId The assigned token ID for the new drop
     */
    function createDrop(uint256 price, uint256 startTime, uint256 endTime, bool active)
        external
        onlyRole(FACTORY_ROLE)
        returns (uint256)
    {
        if (startTime >= endTime && endTime != 0) {
            revert BlueprintERC1155__InvalidStartEndTime();
        }

        uint256 tokenId = nextTokenId;
        nextTokenId++;

        drops[tokenId] =
            Drop({price: price, startTime: startTime, endTime: endTime, active: active});

        emit DropCreated(tokenId, price, startTime, endTime);
        return tokenId;
    }

    /**
     * @dev Creates or updates a drop - only callable by factory
     * @param tokenId The token ID for the drop
     * @param price The mint price in wei
     * @param startTime The timestamp when minting becomes available
     * @param endTime The timestamp when minting ends
     * @param active Whether the drop is active and mintable
     */
    function setDrop(
        uint256 tokenId,
        uint256 price,
        uint256 startTime,
        uint256 endTime,
        bool active
    ) external onlyRole(FACTORY_ROLE) {
        if (startTime >= endTime && endTime != 0) {
            revert BlueprintERC1155__InvalidStartEndTime();
        }

        // Update nextTokenId if necessary
        if (tokenId >= nextTokenId) {
            nextTokenId = tokenId + 1;
        }

        drops[tokenId] =
            Drop({price: price, startTime: startTime, endTime: endTime, active: active});

        emit DropUpdated(tokenId, price, startTime, endTime, active);
    }

    /**
     * @dev Allows creator to update start and end times only
     * @param tokenId The token ID for the drop
     * @param startTime The new start time
     * @param endTime The new end time
     */
    function updateDropTimes(uint256 tokenId, uint256 startTime, uint256 endTime)
        external
        onlyRole(CREATOR_ROLE)
    {
        if (startTime >= endTime) {
            revert BlueprintERC1155__InvalidStartEndTime();
        }

        Drop storage drop = drops[tokenId];
        if (!drop.active) {
            revert BlueprintERC1155__DropNotActive();
        }

        drop.startTime = startTime;
        drop.endTime = endTime;

        emit DropUpdated(tokenId, drop.price, startTime, endTime, drop.active);
    }

    /**
     * @dev Returns the appropriate fee configuration for a token ID
     * @param tokenId The token ID to get fee config for
     * @return The fee configuration to use
     */
    function getFeeConfig(uint256 tokenId) public view returns (FeeConfig memory) {
        if (hasCustomFeeConfig[tokenId]) {
            return tokenFeeConfigs[tokenId];
        }
        return defaultFeeConfig;
    }

    /**
     * @dev Public minting function with payment handling and fee distribution
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param amount Number of tokens to mint
     */
    function mint(address to, uint256 tokenId, uint256 amount) external payable nonReentrant {
        Drop memory drop = drops[tokenId];
        if (!drop.active) {
            revert BlueprintERC1155__DropNotActive();
        }
        if (block.timestamp < drop.startTime) {
            revert BlueprintERC1155__DropNotStarted();
        }
        if (block.timestamp > drop.endTime && drop.endTime != 0) {
            revert BlueprintERC1155__DropEnded();
        }

        uint256 requiredPayment = drop.price * amount;
        if (msg.value < requiredPayment) {
            revert BlueprintERC1155__InsufficientPayment(requiredPayment, msg.value);
        }

        _mint(to, tokenId, amount, "");

        // Update total supply for the token ID
        _totalSupply[tokenId] += amount;

        // Update global total supply
        _globalTotalSupply += amount;

        // Get the appropriate fee config for this token
        FeeConfig memory feeConfig = getFeeConfig(tokenId);

        // Validate essential recipients
        if (feeConfig.blueprintRecipient == address(0)) {
            revert BlueprintERC1155__ZeroBlueprintRecipient();
        }
        if (feeConfig.creatorRecipient == address(0)) {
            revert BlueprintERC1155__ZeroCreatorRecipient();
        }

        // Handle fee distribution
        uint256 totalPrice = drop.price * amount;
        uint256 platformFee = (totalPrice * feeConfig.blueprintFeeBasisPoints) / 10000;
        uint256 creatorFee = (totalPrice * feeConfig.creatorBasisPoints) / 10000;
        uint256 rewardPoolFee = (totalPrice * feeConfig.rewardPoolBasisPoints) / 10000;
        uint256 treasuryAmount = totalPrice - platformFee - creatorFee;

        // Send platform fee
        (bool feeSuccess,) = feeConfig.blueprintRecipient.call{value: platformFee}("");
        if (!feeSuccess) {
            revert BlueprintERC1155__BlueprintFeeTransferFailed();
        }

        // Send creator fee
        (bool creatorSuccess,) = feeConfig.creatorRecipient.call{value: creatorFee}("");
        if (!creatorSuccess) {
            revert BlueprintERC1155__CreatorFeeTransferFailed();
        }

        // Send reward pool fee if recipient is set, otherwise it goes to treasury
        if (rewardPoolFee > 0 && feeConfig.rewardPoolRecipient != address(0)) {
            (bool rewardPoolSuccess,) = feeConfig.rewardPoolRecipient.call{value: rewardPoolFee}("");
            if (!rewardPoolSuccess) {
                revert BlueprintERC1155__RewardPoolFeeTransferFailed();
            }
            // Subtract reward pool fee from treasury amount since it was sent
            treasuryAmount -= rewardPoolFee;
        }

        // Send remaining amount to treasury if set
        if (treasuryAmount > 0 && feeConfig.treasury != address(0)) {
            (bool treasurySuccess,) = feeConfig.treasury.call{value: treasuryAmount}("");
            if (!treasurySuccess) {
                revert BlueprintERC1155__TreasuryTransferFailed();
            }
        }

        // Refund excess payment if any
        if (msg.value > totalPrice) {
            uint256 refund = msg.value - totalPrice;
            (bool refundSuccess,) = msg.sender.call{value: refund}("");
            if (!refundSuccess) {
                revert BlueprintERC1155__RefundFailed();
            }
        }

        emit TokensMinted(to, tokenId, amount);
    }

    /**
     * @dev Public batch minting function with payment handling and fee distribution
     * @param to Recipient address
     * @param tokenIds Array of token IDs to mint
     * @param amounts Array of token amounts to mint
     */
    function batchMint(address to, uint256[] memory tokenIds, uint256[] memory amounts)
        external
        payable
        nonReentrant
    {
        if (tokenIds.length != amounts.length) {
            revert BlueprintERC1155__BatchLengthMismatch();
        }

        uint256 requiredPayment = 0;

        // Calculate required payment and validate drops
        for (uint256 i = 0; i < tokenIds.length; i++) {
            Drop memory drop = drops[tokenIds[i]];
            if (!drop.active) {
                revert BlueprintERC1155__DropNotActive();
            }
            if (block.timestamp < drop.startTime) {
                revert BlueprintERC1155__DropNotStarted();
            }
            if (block.timestamp > drop.endTime && drop.endTime != 0) {
                revert BlueprintERC1155__DropEnded();
            }

            requiredPayment += drop.price * amounts[i];
        }

        if (msg.value < requiredPayment) {
            revert BlueprintERC1155__InsufficientPayment(requiredPayment, msg.value);
        }

        _mintBatch(to, tokenIds, amounts, "");

        // Update total supplies
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _totalSupply[tokenIds[i]] += amounts[i];
            totalAmount += amounts[i];
        }

        // Update global total supply
        _globalTotalSupply += totalAmount;

        // Process payments for each token
        uint256 totalProcessed = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            Drop memory drop = drops[tokenIds[i]];
            uint256 payment = drop.price * amounts[i];

            // Get fee config for this token
            FeeConfig memory config = getFeeConfig(tokenIds[i]);

            // Validate essential recipients
            if (config.blueprintRecipient == address(0)) {
                revert BlueprintERC1155__ZeroBlueprintRecipient();
            }
            if (config.creatorRecipient == address(0)) {
                revert BlueprintERC1155__ZeroCreatorRecipient();
            }

            // Calculate fees
            uint256 platformFee = (payment * config.blueprintFeeBasisPoints) / 10000;
            uint256 creatorFee = (payment * config.creatorBasisPoints) / 10000;
            uint256 rewardPoolFee = (payment * config.rewardPoolBasisPoints) / 10000;
            uint256 treasuryAmount = payment - platformFee - creatorFee;

            // Send platform fee
            (bool feeSuccess,) = config.blueprintRecipient.call{value: platformFee}("");
            if (!feeSuccess) {
                revert BlueprintERC1155__BlueprintFeeTransferFailed();
            }

            // Send creator fee
            (bool creatorSuccess,) = config.creatorRecipient.call{value: creatorFee}("");
            if (!creatorSuccess) {
                revert BlueprintERC1155__CreatorFeeTransferFailed();
            }

            // Send reward pool fee if recipient is set, otherwise it goes to treasury
            if (rewardPoolFee > 0 && config.rewardPoolRecipient != address(0)) {
                (bool rewardPoolSuccess,) =
                    config.rewardPoolRecipient.call{value: rewardPoolFee}("");
                if (!rewardPoolSuccess) {
                    revert BlueprintERC1155__RewardPoolFeeTransferFailed();
                }
                // Subtract reward pool fee from treasury amount since it was sent
                treasuryAmount -= rewardPoolFee;
            }

            // Send treasury amount
            if (treasuryAmount > 0 && config.treasury != address(0)) {
                (bool treasurySuccess,) = config.treasury.call{value: treasuryAmount}("");
                if (!treasurySuccess) {
                    revert BlueprintERC1155__TreasuryTransferFailed();
                }
            }

            totalProcessed += payment;
        }

        // Refund excess payment if any
        if (msg.value > requiredPayment) {
            uint256 refund = msg.value - requiredPayment;
            (bool refundSuccess,) = msg.sender.call{value: refund}("");
            if (!refundSuccess) {
                revert BlueprintERC1155__RefundFailed();
            }
        }

        emit TokensBatchMinted(to, tokenIds, amounts);
    }

    /**
     * @dev Admin-only minting function (no payment required)
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param amount Number of tokens to mint
     */
    function adminMint(address to, uint256 tokenId, uint256 amount)
        external
        onlyRole(FACTORY_ROLE)
    {
        _mint(to, tokenId, amount, "");

        // Update total supply for the token ID
        _totalSupply[tokenId] += amount;

        // Update global total supply
        _globalTotalSupply += amount;

        emit TokensMinted(to, tokenId, amount);
    }

    /**
     * @dev Admin-only batch minting function (no payment required)
     * @param to Recipient address
     * @param tokenIds Array of token IDs to mint
     * @param amounts Array of token amounts to mint
     */
    function adminBatchMint(address to, uint256[] memory tokenIds, uint256[] memory amounts)
        external
        onlyRole(FACTORY_ROLE)
    {
        if (tokenIds.length != amounts.length) {
            revert BlueprintERC1155__BatchLengthMismatch();
        }

        _mintBatch(to, tokenIds, amounts, "");

        // Update total supplies per token ID
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _totalSupply[tokenIds[i]] += amounts[i];
            totalAmount += amounts[i];
        }

        // Update global total supply
        _globalTotalSupply += totalAmount;

        emit TokensBatchMinted(to, tokenIds, amounts);
    }

    /**
     * @dev Returns the total supply of a token ID
     * @param tokenId Token ID to query
     * @return Total supply of the token
     */
    function totalSupply(uint256 tokenId) external view returns (uint256) {
        return _totalSupply[tokenId];
    }

    /**
     * @dev Returns the total supply across all token IDs
     * @return Total supply of all tokens in the collection
     */
    function totalSupply() external view returns (uint256) {
        return _globalTotalSupply;
    }

    /**
     * @dev Updates the default fee configuration - only callable by factory
     * @param _blueprintRecipient Address to receive platform fees
     * @param _feeBasisPoints Platform fee in basis points (100 = 1%)
     * @param _creatorRecipient Address to receive creator royalties
     * @param _creatorBasisPoints Creator royalty in basis points (100 = 1%)
     * @param _rewardPoolRecipient Address to receive reward pool fees
     * @param _rewardPoolBasisPoints Reward pool fee in basis points (100 = 1%)
     * @param _treasury Treasury address
     */
    function setFeeConfig(
        address _blueprintRecipient,
        uint256 _feeBasisPoints,
        address _creatorRecipient,
        uint256 _creatorBasisPoints,
        address _rewardPoolRecipient,
        uint256 _rewardPoolBasisPoints,
        address _treasury
    ) external onlyRole(FACTORY_ROLE) {
        defaultFeeConfig = FeeConfig({
            blueprintRecipient: _blueprintRecipient,
            blueprintFeeBasisPoints: _feeBasisPoints,
            creatorRecipient: _creatorRecipient,
            creatorBasisPoints: _creatorBasisPoints,
            rewardPoolRecipient: _rewardPoolRecipient,
            rewardPoolBasisPoints: _rewardPoolBasisPoints,
            treasury: _treasury
        });

        emit FeeConfigUpdated(
            _blueprintRecipient,
            _feeBasisPoints,
            _creatorRecipient,
            _creatorBasisPoints,
            _rewardPoolRecipient,
            _rewardPoolBasisPoints,
            _treasury
        );
    }

    /**
     * @dev Sets a token-specific fee configuration - only callable by factory
     * @param tokenId Token ID to set fee configuration for
     * @param _blueprintRecipient Address to receive platform fees
     * @param _feeBasisPoints Platform fee in basis points (100 = 1%)
     * @param _creatorRecipient Address to receive creator royalties
     * @param _creatorBasisPoints Creator royalty in basis points (100 = 1%)
     * @param _rewardPoolRecipient Address to receive reward pool fees
     * @param _rewardPoolBasisPoints Reward pool fee in basis points (100 = 1%)
     * @param _treasury Treasury address
     */
    function setTokenFeeConfig(
        uint256 tokenId,
        address _blueprintRecipient,
        uint256 _feeBasisPoints,
        address _creatorRecipient,
        uint256 _creatorBasisPoints,
        address _rewardPoolRecipient,
        uint256 _rewardPoolBasisPoints,
        address _treasury
    ) external onlyRole(FACTORY_ROLE) {
        tokenFeeConfigs[tokenId] = FeeConfig({
            blueprintRecipient: _blueprintRecipient,
            blueprintFeeBasisPoints: _feeBasisPoints,
            creatorRecipient: _creatorRecipient,
            creatorBasisPoints: _creatorBasisPoints,
            rewardPoolRecipient: _rewardPoolRecipient,
            rewardPoolBasisPoints: _rewardPoolBasisPoints,
            treasury: _treasury
        });

        hasCustomFeeConfig[tokenId] = true;

        emit TokenFeeConfigUpdated(
            tokenId,
            _blueprintRecipient,
            _feeBasisPoints,
            _creatorRecipient,
            _creatorBasisPoints,
            _rewardPoolRecipient,
            _rewardPoolBasisPoints,
            _treasury
        );
    }

    /**
     * @dev Removes a token-specific fee configuration, reverting to the default - only callable by factory
     * @param tokenId Token ID to remove custom fee configuration for
     */
    function removeTokenFeeConfig(uint256 tokenId) external onlyRole(FACTORY_ROLE) {
        delete tokenFeeConfigs[tokenId];
        hasCustomFeeConfig[tokenId] = false;

        emit TokenFeeConfigRemoved(tokenId);
    }

    /**
     * @dev Updates the price for a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param price New price in wei
     */
    function setDropPrice(uint256 tokenId, uint256 price) external onlyRole(FACTORY_ROLE) {
        drops[tokenId].price = price;

        emit DropUpdated(
            tokenId, price, drops[tokenId].startTime, drops[tokenId].endTime, drops[tokenId].active
        );
    }

    /**
     * @dev Updates the start time for a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param startTime New start time timestamp
     */
    function setDropStartTime(uint256 tokenId, uint256 startTime) external onlyRole(FACTORY_ROLE) {
        if (startTime >= drops[tokenId].endTime && drops[tokenId].endTime != 0) {
            revert BlueprintERC1155__StartAfterEnd();
        }

        drops[tokenId].startTime = startTime;

        emit DropUpdated(
            tokenId, drops[tokenId].price, startTime, drops[tokenId].endTime, drops[tokenId].active
        );
    }

    /**
     * @dev Updates the end time for a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param endTime New end time timestamp
     */
    function setDropEndTime(uint256 tokenId, uint256 endTime) external onlyRole(FACTORY_ROLE) {
        if (drops[tokenId].startTime >= endTime && endTime != 0) {
            revert BlueprintERC1155__EndBeforeStart();
        }

        drops[tokenId].endTime = endTime;

        emit DropUpdated(
            tokenId, drops[tokenId].price, drops[tokenId].startTime, endTime, drops[tokenId].active
        );
    }

    /**
     * @dev Activates or deactivates a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param active Whether the drop is active and mintable
     */
    function setDropActive(uint256 tokenId, bool active) external onlyRole(FACTORY_ROLE) {
        drops[tokenId].active = active;

        emit DropUpdated(
            tokenId, drops[tokenId].price, drops[tokenId].startTime, drops[tokenId].endTime, active
        );
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Updates creator recipient in the default fee config - only callable by factory
     * @param _creatorRecipient New creator recipient address
     */
    function setCreatorRecipient(address _creatorRecipient) external onlyRole(FACTORY_ROLE) {
        defaultFeeConfig.creatorRecipient = _creatorRecipient;

        emit FeeConfigUpdated(
            defaultFeeConfig.blueprintRecipient,
            defaultFeeConfig.blueprintFeeBasisPoints,
            _creatorRecipient,
            defaultFeeConfig.creatorBasisPoints,
            defaultFeeConfig.rewardPoolRecipient,
            defaultFeeConfig.rewardPoolBasisPoints,
            defaultFeeConfig.treasury
        );
    }

    /**
     * @dev Updates reward pool recipient in the default fee config - only callable by factory
     * @param _rewardPoolRecipient New reward pool recipient address
     */
    function setRewardPoolRecipient(address _rewardPoolRecipient) external onlyRole(FACTORY_ROLE) {
        defaultFeeConfig.rewardPoolRecipient = _rewardPoolRecipient;

        emit FeeConfigUpdated(
            defaultFeeConfig.blueprintRecipient,
            defaultFeeConfig.blueprintFeeBasisPoints,
            defaultFeeConfig.creatorRecipient,
            defaultFeeConfig.creatorBasisPoints,
            _rewardPoolRecipient,
            defaultFeeConfig.rewardPoolBasisPoints,
            defaultFeeConfig.treasury
        );
    }
}
