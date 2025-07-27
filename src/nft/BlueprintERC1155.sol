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

import "@openzeppelin-contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/utils/StringsUpgradeable.sol";
import "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

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
    using SafeERC20 for IERC20;

    // ===== ERRORS =====
    error BlueprintERC1155__InvalidStartEndTime();
    error BlueprintERC1155__DropNotActive();
    error BlueprintERC1155__DropNotStarted();
    error BlueprintERC1155__DropEnded();
    error BlueprintERC1155__InsufficientPayment(
        uint256 required,
        uint256 provided
    );
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
    error BlueprintERC1155__InvalidERC20Address();
    error BlueprintERC1155__ERC20NotEnabled();
    error BlueprintERC1155__ETHNotEnabled();
    error BlueprintERC1155__InsufficientERC20Allowance(
        uint256 required,
        uint256 allowance
    );
    error BlueprintERC1155__InsufficientERC20Balance(
        uint256 required,
        uint256 balance
    );

    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct Drop {
        uint256 price; // ETH price in wei
        uint256 erc20Price; // ERC20 price in token units
        address acceptedERC20; // ERC20 token address (address(0) means ERC20 not enabled)
        uint256 startTime;
        uint256 endTime;
        bool active;
        bool ethEnabled; // Whether ETH payments are enabled
        bool erc20Enabled; // Whether ERC20 payments are enabled
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

    event DropCreated(
        uint256 indexed tokenId,
        uint256 price,
        uint256 startTime,
        uint256 endTime
    );
    event DropUpdated(
        uint256 indexed tokenId,
        uint256 price,
        uint256 startTime,
        uint256 endTime,
        bool active
    );
    event TokensMinted(
        address indexed to,
        uint256 indexed tokenId,
        uint256 amount
    );
    event TokensBatchMinted(
        address indexed to,
        uint256[] tokenIds,
        uint256[] amounts
    );

    // Enhanced events for payment tracking
    event TokensMintedWithPayment(
        address indexed to,
        uint256 indexed tokenId,
        uint256 amount,
        address indexed paymentToken, // address(0) for ETH
        uint256 amountPaidWei, // amount paid in wei (for ETH) or token units (for ERC20)
        uint256 timestamp
    );
    event TokensBatchMintedWithPayment(
        address indexed to,
        uint256[] tokenIds,
        uint256[] amounts,
        address indexed paymentToken, // address(0) for ETH
        uint256 totalAmountPaidWei, // total amount paid in wei (for ETH) or token units (for ERC20)
        uint256 timestamp
    );
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
    function setSymbol(
        string memory newSymbol
    ) external onlyRole(FACTORY_ROLE) {
        _symbol = newSymbol;
    }

    /**
     * @dev Returns the URI for a given token ID
     * First checks if there's a token-specific URI set
     * Falls back to the base URI if no specific URI is set
     * @param tokenId The token ID to get the URI for
     * @return The URI string for the token
     */
    function uri(
        uint256 tokenId
    ) public view virtual override returns (string memory) {
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
    function setTokenURI(
        uint256 tokenId,
        string memory tokenURI
    ) external onlyRole(FACTORY_ROLE) {
        _tokenURIs[tokenId] = tokenURI;
        emit TokenURIUpdated(tokenId, tokenURI);
    }

    /**
     * @dev Sets the URI for the collection - only callable by factory
     * @param newURI New URI for the collection
     */
    function setCollectionURI(
        string memory newURI
    ) external onlyRole(FACTORY_ROLE) {
        _collectionURI = newURI;
        emit CollectionURIUpdated(newURI);
    }

    /**
     * @dev Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    /**
     * @dev Creates a new drop with auto-incrementing token ID - only callable by factory
     * @param price The mint price in wei
     * @param startTime The timestamp when minting becomes available
     * @param endTime The timestamp when minting ends
     * @param active Whether the drop is active and mintable
     * @return tokenId The assigned token ID for the new drop
     */
    function createDrop(
        uint256 price,
        uint256 startTime,
        uint256 endTime,
        bool active
    ) external onlyRole(FACTORY_ROLE) returns (uint256) {
        if (startTime >= endTime && endTime != 0) {
            revert BlueprintERC1155__InvalidStartEndTime();
        }

        uint256 tokenId = nextTokenId;
        nextTokenId++;

        drops[tokenId] = Drop({
            price: price,
            erc20Price: 0,
            acceptedERC20: address(0),
            startTime: startTime,
            endTime: endTime,
            active: active,
            ethEnabled: true,
            erc20Enabled: false
        });

        emit DropCreated(tokenId, price, startTime, endTime);
        return tokenId;
    }

    /**
     * @dev Creates a new drop with auto-incrementing token ID and ERC20 support - only callable by factory
     * @param price The ETH mint price in wei
     * @param erc20Price The ERC20 mint price in token units
     * @param acceptedERC20 The ERC20 token address (address(0) to disable ERC20)
     * @param startTime The timestamp when minting becomes available
     * @param endTime The timestamp when minting ends
     * @param active Whether the drop is active and mintable
     * @param ethEnabled Whether ETH payments are enabled
     * @param erc20Enabled Whether ERC20 payments are enabled
     * @return tokenId The assigned token ID for the new drop
     */
    function createDropWithERC20(
        uint256 price,
        uint256 erc20Price,
        address acceptedERC20,
        uint256 startTime,
        uint256 endTime,
        bool active,
        bool ethEnabled,
        bool erc20Enabled
    ) external onlyRole(FACTORY_ROLE) returns (uint256) {
        if (startTime >= endTime && endTime != 0) {
            revert BlueprintERC1155__InvalidStartEndTime();
        }
        if (erc20Enabled && acceptedERC20 == address(0)) {
            revert BlueprintERC1155__InvalidERC20Address();
        }

        uint256 tokenId = nextTokenId;
        nextTokenId++;

        drops[tokenId] = Drop({
            price: price,
            erc20Price: erc20Price,
            acceptedERC20: acceptedERC20,
            startTime: startTime,
            endTime: endTime,
            active: active,
            ethEnabled: ethEnabled,
            erc20Enabled: erc20Enabled
        });

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

        drops[tokenId] = Drop({
            price: price,
            erc20Price: 0,
            acceptedERC20: address(0),
            startTime: startTime,
            endTime: endTime,
            active: active,
            ethEnabled: true,
            erc20Enabled: false
        });

        emit DropUpdated(tokenId, price, startTime, endTime, active);
    }

    /**
     * @dev Creates or updates a drop with ERC20 support - only callable by factory
     * @param tokenId The token ID for the drop
     * @param price The ETH mint price in wei
     * @param erc20Price The ERC20 mint price in token units
     * @param acceptedERC20 The ERC20 token address (address(0) to disable ERC20)
     * @param startTime The timestamp when minting becomes available
     * @param endTime The timestamp when minting ends
     * @param active Whether the drop is active and mintable
     * @param ethEnabled Whether ETH payments are enabled
     * @param erc20Enabled Whether ERC20 payments are enabled
     */
    function setDropWithERC20(
        uint256 tokenId,
        uint256 price,
        uint256 erc20Price,
        address acceptedERC20,
        uint256 startTime,
        uint256 endTime,
        bool active,
        bool ethEnabled,
        bool erc20Enabled
    ) external onlyRole(FACTORY_ROLE) {
        if (startTime >= endTime && endTime != 0) {
            revert BlueprintERC1155__InvalidStartEndTime();
        }
        if (erc20Enabled && acceptedERC20 == address(0)) {
            revert BlueprintERC1155__InvalidERC20Address();
        }

        // Update nextTokenId if necessary
        if (tokenId >= nextTokenId) {
            nextTokenId = tokenId + 1;
        }

        drops[tokenId] = Drop({
            price: price,
            erc20Price: erc20Price,
            acceptedERC20: acceptedERC20,
            startTime: startTime,
            endTime: endTime,
            active: active,
            ethEnabled: ethEnabled,
            erc20Enabled: erc20Enabled
        });

        emit DropUpdated(tokenId, price, startTime, endTime, active);
    }

    /**
     * @dev Allows creator to update start and end times only
     * @param tokenId The token ID for the drop
     * @param startTime The new start time
     * @param endTime The new end time
     */
    function updateDropTimes(
        uint256 tokenId,
        uint256 startTime,
        uint256 endTime
    ) external onlyRole(CREATOR_ROLE) {
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
    function getFeeConfig(
        uint256 tokenId
    ) public view returns (FeeConfig memory) {
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
    function mint(
        address to,
        uint256 tokenId,
        uint256 amount
    ) external payable nonReentrant {
        Drop memory drop = drops[tokenId];
        if (!drop.active) {
            revert BlueprintERC1155__DropNotActive();
        }
        if (!drop.ethEnabled) {
            revert BlueprintERC1155__ETHNotEnabled();
        }
        if (block.timestamp < drop.startTime) {
            revert BlueprintERC1155__DropNotStarted();
        }
        if (block.timestamp > drop.endTime && drop.endTime != 0) {
            revert BlueprintERC1155__DropEnded();
        }

        uint256 requiredPayment = drop.price * amount;
        if (msg.value < requiredPayment) {
            revert BlueprintERC1155__InsufficientPayment(
                requiredPayment,
                msg.value
            );
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
        uint256 platformFee = (totalPrice * feeConfig.blueprintFeeBasisPoints) /
            10000;
        uint256 creatorFee = (totalPrice * feeConfig.creatorBasisPoints) /
            10000;
        uint256 rewardPoolFee = (totalPrice * feeConfig.rewardPoolBasisPoints) /
            10000;
        uint256 treasuryAmount = totalPrice - platformFee - creatorFee;

        // Send platform fee
        (bool feeSuccess, ) = feeConfig.blueprintRecipient.call{
            value: platformFee
        }("");
        if (!feeSuccess) {
            revert BlueprintERC1155__BlueprintFeeTransferFailed();
        }

        // Send creator fee
        (bool creatorSuccess, ) = feeConfig.creatorRecipient.call{
            value: creatorFee
        }("");
        if (!creatorSuccess) {
            revert BlueprintERC1155__CreatorFeeTransferFailed();
        }

        // Send reward pool fee if recipient is set, otherwise it goes to treasury
        if (rewardPoolFee > 0 && feeConfig.rewardPoolRecipient != address(0)) {
            (bool rewardPoolSuccess, ) = feeConfig.rewardPoolRecipient.call{
                value: rewardPoolFee
            }("");
            if (!rewardPoolSuccess) {
                revert BlueprintERC1155__RewardPoolFeeTransferFailed();
            }
            // Subtract reward pool fee from treasury amount since it was sent
            treasuryAmount -= rewardPoolFee;
        }

        // Send remaining amount to treasury if set
        if (treasuryAmount > 0 && feeConfig.treasury != address(0)) {
            (bool treasurySuccess, ) = feeConfig.treasury.call{
                value: treasuryAmount
            }("");
            if (!treasurySuccess) {
                revert BlueprintERC1155__TreasuryTransferFailed();
            }
        }

        // Refund excess payment if any
        if (msg.value > totalPrice) {
            uint256 refund = msg.value - totalPrice;
            (bool refundSuccess, ) = msg.sender.call{value: refund}("");
            if (!refundSuccess) {
                revert BlueprintERC1155__RefundFailed();
            }
        }

        emit TokensMinted(to, tokenId, amount);
        emit TokensMintedWithPayment(
            to,
            tokenId,
            amount,
            address(0),
            totalPrice,
            block.timestamp
        );
    }

    /**
     * @dev Public minting function with ERC20 payment handling and fee distribution
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param amount Number of tokens to mint
     */
    function mintWithERC20(
        address to,
        uint256 tokenId,
        uint256 amount
    ) external nonReentrant {
        Drop memory drop = drops[tokenId];
        if (!drop.active) {
            revert BlueprintERC1155__DropNotActive();
        }
        if (!drop.erc20Enabled) {
            revert BlueprintERC1155__ERC20NotEnabled();
        }
        if (drop.acceptedERC20 == address(0)) {
            revert BlueprintERC1155__InvalidERC20Address();
        }
        if (block.timestamp < drop.startTime) {
            revert BlueprintERC1155__DropNotStarted();
        }
        if (block.timestamp > drop.endTime && drop.endTime != 0) {
            revert BlueprintERC1155__DropEnded();
        }

        uint256 requiredPayment = drop.erc20Price * amount;
        IERC20 erc20Token = IERC20(drop.acceptedERC20);

        // Check user balance
        uint256 userBalance = erc20Token.balanceOf(msg.sender);
        if (userBalance < requiredPayment) {
            revert BlueprintERC1155__InsufficientERC20Balance(
                requiredPayment,
                userBalance
            );
        }

        // Check allowance
        uint256 allowance = erc20Token.allowance(msg.sender, address(this));
        if (allowance < requiredPayment) {
            revert BlueprintERC1155__InsufficientERC20Allowance(
                requiredPayment,
                allowance
            );
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

        // Handle ERC20 fee distribution
        uint256 totalPrice = drop.erc20Price * amount;
        uint256 platformFee = (totalPrice * feeConfig.blueprintFeeBasisPoints) /
            10000;
        uint256 creatorFee = (totalPrice * feeConfig.creatorBasisPoints) /
            10000;
        uint256 rewardPoolFee = (totalPrice * feeConfig.rewardPoolBasisPoints) /
            10000;
        uint256 treasuryAmount = totalPrice - platformFee - creatorFee;

        // Transfer platform fee
        erc20Token.safeTransferFrom(
            msg.sender,
            feeConfig.blueprintRecipient,
            platformFee
        );

        // Transfer creator fee
        erc20Token.safeTransferFrom(
            msg.sender,
            feeConfig.creatorRecipient,
            creatorFee
        );

        // Transfer reward pool fee if recipient is set, otherwise it goes to treasury
        if (rewardPoolFee > 0 && feeConfig.rewardPoolRecipient != address(0)) {
            erc20Token.safeTransferFrom(
                msg.sender,
                feeConfig.rewardPoolRecipient,
                rewardPoolFee
            );
            // Subtract reward pool fee from treasury amount since it was sent
            treasuryAmount -= rewardPoolFee;
        }

        // Transfer remaining amount to treasury if set
        if (treasuryAmount > 0 && feeConfig.treasury != address(0)) {
            erc20Token.safeTransferFrom(
                msg.sender,
                feeConfig.treasury,
                treasuryAmount
            );
        }

        emit TokensMinted(to, tokenId, amount);
        emit TokensMintedWithPayment(
            to,
            tokenId,
            amount,
            drop.acceptedERC20,
            totalPrice,
            block.timestamp
        );
    }

    /**
     * @dev Public batch minting function with payment handling and fee distribution
     * @param to Recipient address
     * @param tokenIds Array of token IDs to mint
     * @param amounts Array of token amounts to mint
     */
    function batchMint(
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts
    ) external payable nonReentrant {
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
            if (!drop.ethEnabled) {
                revert BlueprintERC1155__ETHNotEnabled();
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
            revert BlueprintERC1155__InsufficientPayment(
                requiredPayment,
                msg.value
            );
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
            uint256 platformFee = (payment * config.blueprintFeeBasisPoints) /
                10000;
            uint256 creatorFee = (payment * config.creatorBasisPoints) / 10000;
            uint256 rewardPoolFee = (payment * config.rewardPoolBasisPoints) /
                10000;
            uint256 treasuryAmount = payment - platformFee - creatorFee;

            // Send platform fee
            (bool feeSuccess, ) = config.blueprintRecipient.call{
                value: platformFee
            }("");
            if (!feeSuccess) {
                revert BlueprintERC1155__BlueprintFeeTransferFailed();
            }

            // Send creator fee
            (bool creatorSuccess, ) = config.creatorRecipient.call{
                value: creatorFee
            }("");
            if (!creatorSuccess) {
                revert BlueprintERC1155__CreatorFeeTransferFailed();
            }

            // Send reward pool fee if recipient is set, otherwise it goes to treasury
            if (rewardPoolFee > 0 && config.rewardPoolRecipient != address(0)) {
                (bool rewardPoolSuccess, ) = config.rewardPoolRecipient.call{
                    value: rewardPoolFee
                }("");
                if (!rewardPoolSuccess) {
                    revert BlueprintERC1155__RewardPoolFeeTransferFailed();
                }
                // Subtract reward pool fee from treasury amount since it was sent
                treasuryAmount -= rewardPoolFee;
            }

            // Send treasury amount
            if (treasuryAmount > 0 && config.treasury != address(0)) {
                (bool treasurySuccess, ) = config.treasury.call{
                    value: treasuryAmount
                }("");
                if (!treasurySuccess) {
                    revert BlueprintERC1155__TreasuryTransferFailed();
                }
            }

            totalProcessed += payment;
        }

        // Refund excess payment if any
        if (msg.value > requiredPayment) {
            uint256 refund = msg.value - requiredPayment;
            (bool refundSuccess, ) = msg.sender.call{value: refund}("");
            if (!refundSuccess) {
                revert BlueprintERC1155__RefundFailed();
            }
        }

        emit TokensBatchMinted(to, tokenIds, amounts);
        emit TokensBatchMintedWithPayment(
            to,
            tokenIds,
            amounts,
            address(0),
            requiredPayment,
            block.timestamp
        );
    }

    /**
     * @dev Public batch minting function with ERC20 payment handling and fee distribution
     * @param to Recipient address
     * @param tokenIds Array of token IDs to mint
     * @param amounts Array of token amounts to mint
     */
    function batchMintWithERC20(
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts
    ) external nonReentrant {
        if (tokenIds.length != amounts.length) {
            revert BlueprintERC1155__BatchLengthMismatch();
        }

        uint256 requiredPayment = 0;
        address erc20Address = address(0);

        // Calculate required payment and validate drops
        for (uint256 i = 0; i < tokenIds.length; i++) {
            Drop memory drop = drops[tokenIds[i]];
            if (!drop.active) {
                revert BlueprintERC1155__DropNotActive();
            }
            if (!drop.erc20Enabled) {
                revert BlueprintERC1155__ERC20NotEnabled();
            }
            if (drop.acceptedERC20 == address(0)) {
                revert BlueprintERC1155__InvalidERC20Address();
            }

            // Ensure all drops use the same ERC20 token
            if (i == 0) {
                erc20Address = drop.acceptedERC20;
            } else if (erc20Address != drop.acceptedERC20) {
                revert BlueprintERC1155__InvalidERC20Address(); // Mixed ERC20 tokens not supported
            }

            if (block.timestamp < drop.startTime) {
                revert BlueprintERC1155__DropNotStarted();
            }
            if (block.timestamp > drop.endTime && drop.endTime != 0) {
                revert BlueprintERC1155__DropEnded();
            }

            requiredPayment += drop.erc20Price * amounts[i];
        }

        IERC20 erc20Token = IERC20(erc20Address);

        // Check user balance
        uint256 userBalance = erc20Token.balanceOf(msg.sender);
        if (userBalance < requiredPayment) {
            revert BlueprintERC1155__InsufficientERC20Balance(
                requiredPayment,
                userBalance
            );
        }

        // Check allowance
        uint256 allowance = erc20Token.allowance(msg.sender, address(this));
        if (allowance < requiredPayment) {
            revert BlueprintERC1155__InsufficientERC20Allowance(
                requiredPayment,
                allowance
            );
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

        // Process ERC20 payments for each token
        for (uint256 i = 0; i < tokenIds.length; i++) {
            Drop memory drop = drops[tokenIds[i]];
            uint256 payment = drop.erc20Price * amounts[i];

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
            uint256 platformFee = (payment * config.blueprintFeeBasisPoints) /
                10000;
            uint256 creatorFee = (payment * config.creatorBasisPoints) / 10000;
            uint256 rewardPoolFee = (payment * config.rewardPoolBasisPoints) /
                10000;
            uint256 treasuryAmount = payment - platformFee - creatorFee;

            // Transfer platform fee
            erc20Token.safeTransferFrom(
                msg.sender,
                config.blueprintRecipient,
                platformFee
            );

            // Transfer creator fee
            erc20Token.safeTransferFrom(
                msg.sender,
                config.creatorRecipient,
                creatorFee
            );

            // Transfer reward pool fee if recipient is set, otherwise it goes to treasury
            if (rewardPoolFee > 0 && config.rewardPoolRecipient != address(0)) {
                erc20Token.safeTransferFrom(
                    msg.sender,
                    config.rewardPoolRecipient,
                    rewardPoolFee
                );
                // Subtract reward pool fee from treasury amount since it was sent
                treasuryAmount -= rewardPoolFee;
            }

            // Transfer treasury amount
            if (treasuryAmount > 0 && config.treasury != address(0)) {
                erc20Token.safeTransferFrom(
                    msg.sender,
                    config.treasury,
                    treasuryAmount
                );
            }
        }

        emit TokensBatchMinted(to, tokenIds, amounts);
        emit TokensBatchMintedWithPayment(
            to,
            tokenIds,
            amounts,
            erc20Address,
            requiredPayment,
            block.timestamp
        );
    }

    /**
     * @dev EIP-5792 compatible batch-friendly ERC20 mint function with enhanced safeguards
     * Designed to work optimally with batch transactions that include approval + mint
     * Protects against fee-on-transfer tokens and other weird ERC20 behaviors
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param amount Number of tokens to mint
     * @param allowFeeOnTransfer Whether to allow fee-on-transfer tokens (if false, reverts on any fee)
     */
    function mintWithERC20BatchSafe(
        address to,
        uint256 tokenId,
        uint256 amount,
        bool allowFeeOnTransfer
    ) external nonReentrant {
        Drop memory drop = drops[tokenId];
        if (!drop.active) {
            revert BlueprintERC1155__DropNotActive();
        }
        if (!drop.erc20Enabled) {
            revert BlueprintERC1155__ERC20NotEnabled();
        }
        if (drop.acceptedERC20 == address(0)) {
            revert BlueprintERC1155__InvalidERC20Address();
        }
        if (block.timestamp < drop.startTime) {
            revert BlueprintERC1155__DropNotStarted();
        }
        if (block.timestamp > drop.endTime && drop.endTime != 0) {
            revert BlueprintERC1155__DropEnded();
        }

        uint256 requiredPayment = drop.erc20Price * amount;
        IERC20 erc20Token = IERC20(drop.acceptedERC20);

        // Enhanced checks for weird ERC20 behaviors
        uint256 userBalance = erc20Token.balanceOf(msg.sender);
        if (userBalance < requiredPayment) {
            revert BlueprintERC1155__InsufficientERC20Balance(
                requiredPayment,
                userBalance
            );
        }

        uint256 allowance = erc20Token.allowance(msg.sender, address(this));
        if (allowance < requiredPayment) {
            revert BlueprintERC1155__InsufficientERC20Allowance(
                requiredPayment,
                allowance
            );
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

        // Handle ERC20 fee distribution with fee-on-transfer protection
        uint256 totalPrice = drop.erc20Price * amount;
        uint256 platformFee = (totalPrice * feeConfig.blueprintFeeBasisPoints) /
            10000;
        uint256 creatorFee = (totalPrice * feeConfig.creatorBasisPoints) /
            10000;
        uint256 rewardPoolFee = (totalPrice * feeConfig.rewardPoolBasisPoints) /
            10000;
        uint256 treasuryAmount = totalPrice - platformFee - creatorFee;

        // Enhanced transfers with fee-on-transfer detection
        if (allowFeeOnTransfer) {
            // Allow fee-on-transfer tokens - use regular SafeERC20
            erc20Token.safeTransferFrom(
                msg.sender,
                feeConfig.blueprintRecipient,
                platformFee
            );
            erc20Token.safeTransferFrom(
                msg.sender,
                feeConfig.creatorRecipient,
                creatorFee
            );

            if (
                rewardPoolFee > 0 && feeConfig.rewardPoolRecipient != address(0)
            ) {
                erc20Token.safeTransferFrom(
                    msg.sender,
                    feeConfig.rewardPoolRecipient,
                    rewardPoolFee
                );
                treasuryAmount -= rewardPoolFee;
            }

            if (treasuryAmount > 0 && feeConfig.treasury != address(0)) {
                erc20Token.safeTransferFrom(
                    msg.sender,
                    feeConfig.treasury,
                    treasuryAmount
                );
            }
        } else {
            // Strict mode - verify exact amounts transferred (rejects fee-on-transfer tokens)
            _safeTransferWithVerification(
                erc20Token,
                msg.sender,
                feeConfig.blueprintRecipient,
                platformFee
            );
            _safeTransferWithVerification(
                erc20Token,
                msg.sender,
                feeConfig.creatorRecipient,
                creatorFee
            );

            if (
                rewardPoolFee > 0 && feeConfig.rewardPoolRecipient != address(0)
            ) {
                _safeTransferWithVerification(
                    erc20Token,
                    msg.sender,
                    feeConfig.rewardPoolRecipient,
                    rewardPoolFee
                );
                treasuryAmount -= rewardPoolFee;
            }

            if (treasuryAmount > 0 && feeConfig.treasury != address(0)) {
                _safeTransferWithVerification(
                    erc20Token,
                    msg.sender,
                    feeConfig.treasury,
                    treasuryAmount
                );
            }
        }

        emit TokensMinted(to, tokenId, amount);
        emit TokensMintedWithPayment(
            to,
            tokenId,
            amount,
            drop.acceptedERC20,
            totalPrice,
            block.timestamp
        );
    }

    /**
     * @dev Internal function for safe ERC20 transfers with balance verification
     * Handles tokens that may not revert on failure or transfer less than requested
     */
    function _safeTransferWithVerification(
        IERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal {
        if (amount == 0) return; // Skip zero transfers to avoid issues with some tokens

        uint256 balanceBefore = token.balanceOf(to);
        token.safeTransferFrom(from, to, amount);
        uint256 balanceAfter = token.balanceOf(to);

        // Verify the actual amount transferred
        require(
            balanceAfter >= balanceBefore + amount,
            "Transfer verification failed"
        );
    }

    /**
     * @dev Get required payment amount and token address for batch transaction preparation
     * Useful for frontends preparing batch transactions
     * @param tokenId Token ID to query
     * @param amount Number of tokens to mint
     * @return paymentToken Address of the ERC20 token required (address(0) for ETH)
     * @return paymentAmount Amount of tokens required for payment
     * @return ethEnabled Whether ETH payments are enabled
     * @return erc20Enabled Whether ERC20 payments are enabled
     */
    function getPaymentInfo(
        uint256 tokenId,
        uint256 amount
    )
        external
        view
        returns (
            address paymentToken,
            uint256 paymentAmount,
            bool ethEnabled,
            bool erc20Enabled
        )
    {
        Drop memory drop = drops[tokenId];
        return (
            drop.acceptedERC20,
            drop.erc20Price * amount,
            drop.ethEnabled,
            drop.erc20Enabled
        );
    }

    /**
     * @dev Batch-friendly function to check if user can mint with current balances/allowances
     * @param user Address to check
     * @param tokenId Token ID to check
     * @param amount Amount to mint
     * @return canMintETH Whether user can mint with ETH
     * @return canMintERC20 Whether user can mint with ERC20
     * @return requiredETH Required ETH amount
     * @return requiredERC20 Required ERC20 amount
     * @return currentAllowance Current ERC20 allowance
     * @return currentBalance Current ERC20 balance
     */
    function checkMintEligibility(
        address user,
        uint256 tokenId,
        uint256 amount
    )
        external
        view
        returns (
            bool canMintETH,
            bool canMintERC20,
            uint256 requiredETH,
            uint256 requiredERC20,
            uint256 currentAllowance,
            uint256 currentBalance
        )
    {
        Drop memory drop = drops[tokenId];

        requiredETH = drop.price * amount;
        requiredERC20 = drop.erc20Price * amount;

        canMintETH =
            drop.active &&
            drop.ethEnabled &&
            block.timestamp >= drop.startTime &&
            (drop.endTime == 0 || block.timestamp <= drop.endTime) &&
            user.balance >= requiredETH;

        if (drop.acceptedERC20 != address(0)) {
            IERC20 erc20Token = IERC20(drop.acceptedERC20);
            currentBalance = erc20Token.balanceOf(user);
            currentAllowance = erc20Token.allowance(user, address(this));

            canMintERC20 =
                drop.active &&
                drop.erc20Enabled &&
                block.timestamp >= drop.startTime &&
                (drop.endTime == 0 || block.timestamp <= drop.endTime) &&
                currentBalance >= requiredERC20 &&
                currentAllowance >= requiredERC20;
        }
    }

    /**
     * @dev Admin-only minting function (no payment required)
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param amount Number of tokens to mint
     */
    function adminMint(
        address to,
        uint256 tokenId,
        uint256 amount
    ) external onlyRole(FACTORY_ROLE) {
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
    function adminBatchMint(
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts
    ) external onlyRole(FACTORY_ROLE) {
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
    function removeTokenFeeConfig(
        uint256 tokenId
    ) external onlyRole(FACTORY_ROLE) {
        delete tokenFeeConfigs[tokenId];
        hasCustomFeeConfig[tokenId] = false;

        emit TokenFeeConfigRemoved(tokenId);
    }

    /**
     * @dev Updates the price for a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param price New price in wei
     */
    function setDropPrice(
        uint256 tokenId,
        uint256 price
    ) external onlyRole(FACTORY_ROLE) {
        drops[tokenId].price = price;

        emit DropUpdated(
            tokenId,
            price,
            drops[tokenId].startTime,
            drops[tokenId].endTime,
            drops[tokenId].active
        );
    }

    /**
     * @dev Updates the start time for a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param startTime New start time timestamp
     */
    function setDropStartTime(
        uint256 tokenId,
        uint256 startTime
    ) external onlyRole(FACTORY_ROLE) {
        if (
            startTime >= drops[tokenId].endTime && drops[tokenId].endTime != 0
        ) {
            revert BlueprintERC1155__StartAfterEnd();
        }

        drops[tokenId].startTime = startTime;

        emit DropUpdated(
            tokenId,
            drops[tokenId].price,
            startTime,
            drops[tokenId].endTime,
            drops[tokenId].active
        );
    }

    /**
     * @dev Updates the end time for a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param endTime New end time timestamp
     */
    function setDropEndTime(
        uint256 tokenId,
        uint256 endTime
    ) external onlyRole(FACTORY_ROLE) {
        if (drops[tokenId].startTime >= endTime && endTime != 0) {
            revert BlueprintERC1155__EndBeforeStart();
        }

        drops[tokenId].endTime = endTime;

        emit DropUpdated(
            tokenId,
            drops[tokenId].price,
            drops[tokenId].startTime,
            endTime,
            drops[tokenId].active
        );
    }

    /**
     * @dev Activates or deactivates a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param active Whether the drop is active and mintable
     */
    function setDropActive(
        uint256 tokenId,
        bool active
    ) external onlyRole(FACTORY_ROLE) {
        drops[tokenId].active = active;

        emit DropUpdated(
            tokenId,
            drops[tokenId].price,
            drops[tokenId].startTime,
            drops[tokenId].endTime,
            active
        );
    }

    /**
     * @dev Updates the ERC20 price for a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param erc20Price New ERC20 price in token units
     */
    function setDropERC20Price(
        uint256 tokenId,
        uint256 erc20Price
    ) external onlyRole(FACTORY_ROLE) {
        drops[tokenId].erc20Price = erc20Price;

        emit DropUpdated(
            tokenId,
            drops[tokenId].price,
            drops[tokenId].startTime,
            drops[tokenId].endTime,
            drops[tokenId].active
        );
    }

    /**
     * @dev Updates the accepted ERC20 token for a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param acceptedERC20 Address of the ERC20 token to accept (address(0) to disable)
     */
    function setDropAcceptedERC20(
        uint256 tokenId,
        address acceptedERC20
    ) external onlyRole(FACTORY_ROLE) {
        drops[tokenId].acceptedERC20 = acceptedERC20;

        // If setting to address(0), disable ERC20 payments
        if (acceptedERC20 == address(0)) {
            drops[tokenId].erc20Enabled = false;
        }

        emit DropUpdated(
            tokenId,
            drops[tokenId].price,
            drops[tokenId].startTime,
            drops[tokenId].endTime,
            drops[tokenId].active
        );
    }

    /**
     * @dev Enables or disables ETH payments for a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param ethEnabled Whether ETH payments are enabled
     */
    function setDropETHEnabled(
        uint256 tokenId,
        bool ethEnabled
    ) external onlyRole(FACTORY_ROLE) {
        drops[tokenId].ethEnabled = ethEnabled;

        emit DropUpdated(
            tokenId,
            drops[tokenId].price,
            drops[tokenId].startTime,
            drops[tokenId].endTime,
            drops[tokenId].active
        );
    }

    /**
     * @dev Enables or disables ERC20 payments for a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param erc20Enabled Whether ERC20 payments are enabled
     */
    function setDropERC20Enabled(
        uint256 tokenId,
        bool erc20Enabled
    ) external onlyRole(FACTORY_ROLE) {
        // If enabling ERC20, ensure an ERC20 token is set
        if (erc20Enabled && drops[tokenId].acceptedERC20 == address(0)) {
            revert BlueprintERC1155__InvalidERC20Address();
        }

        drops[tokenId].erc20Enabled = erc20Enabled;

        emit DropUpdated(
            tokenId,
            drops[tokenId].price,
            drops[tokenId].startTime,
            drops[tokenId].endTime,
            drops[tokenId].active
        );
    }

    /**
     * @dev Updates both ETH and ERC20 prices for a drop - only callable by factory
     * @param tokenId Token ID of the drop
     * @param ethPrice New ETH price in wei
     * @param erc20Price New ERC20 price in token units
     */
    function setDropPrices(
        uint256 tokenId,
        uint256 ethPrice,
        uint256 erc20Price
    ) external onlyRole(FACTORY_ROLE) {
        drops[tokenId].price = ethPrice;
        drops[tokenId].erc20Price = erc20Price;

        emit DropUpdated(
            tokenId,
            ethPrice,
            drops[tokenId].startTime,
            drops[tokenId].endTime,
            drops[tokenId].active
        );
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(
        bytes4 interfaceId
    )
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
    function setCreatorRecipient(
        address _creatorRecipient
    ) external onlyRole(FACTORY_ROLE) {
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
    function setRewardPoolRecipient(
        address _rewardPoolRecipient
    ) external onlyRole(FACTORY_ROLE) {
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
