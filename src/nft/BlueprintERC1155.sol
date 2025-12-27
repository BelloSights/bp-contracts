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
import "@openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
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
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
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
    error BlueprintERC1155__InsufficientERC20Allowance(
        uint256 required,
        uint256 allowance
    );
    error BlueprintERC1155__InsufficientERC20Balance(
        uint256 required,
        uint256 balance
    );
    error BlueprintERC1155__InvalidBasisPoints(uint256 total);
    error BlueprintERC1155__ZeroAdminAddress();
    error BlueprintERC1155__NoStuckETH();
    error BlueprintERC1155__NoStuckERC20();
    error BlueprintERC1155__WithdrawFailed();
    error BlueprintERC1155__ZeroRecipientAddress();
    error BlueprintERC1155__ExceedsMaxMintAmount(uint256 requested, uint256 max);

    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Maximum mint amount per transaction to prevent overflow in fee calculations
    uint256 public constant MAX_MINT_AMOUNT = 10000;

    /// @notice Maximum basis points (100% = 10000)
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;

    struct Drop {
        uint256 price; // ETH price in wei (0 = free mint with protocol fee)
        uint256 startTime;
        uint256 endTime;
        bool active;
        // ETH is always enabled - ERC20 is optional via erc20Prices mapping
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

    // Multi-ERC20 support: tokenId => erc20Address => price (0 = not accepted)
    mapping(uint256 => mapping(address => uint256)) public erc20Prices;

    // Default fee configuration for the collection
    FeeConfig public defaultFeeConfig;

    // Per-token fee configurations
    mapping(uint256 => FeeConfig) public tokenFeeConfigs;

    // Track which tokens have custom fee configurations
    mapping(uint256 => bool) public hasCustomFeeConfig;

    // Protocol fees for free mints (price = 0)
    // These fees go 100% to blueprintRecipient
    uint256 public protocolFeeETH; // Protocol fee in wei for free ETH mints (default: 111000000000000 = 0.000111 ETH)
    mapping(address => uint256) public protocolFeeERC20; // Protocol fee per ERC20 token for free mints (e.g., USDC: 300000 = $0.30)

    // Track which ERC20 tokens are explicitly enabled for each token ID (allows truly free mints when price = 0 and protocolFee = 0)
    mapping(uint256 => mapping(address => bool)) public isERC20Enabled;

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
    // Referral events for indexing when a referrer is provided by the caller
    event ReferredMint(
        address indexed minter,
        address indexed referrer,
        address indexed to,
        uint256 tokenId,
        uint256 amount,
        address paymentToken, // address(0) for ETH
        uint256 amountPaidWeiOrTokenUnits,
        uint256 timestamp
    );
    event ReferredBatchMint(
        address indexed minter,
        address indexed referrer,
        address indexed to,
        uint256[] tokenIds,
        uint256[] amounts,
        address paymentToken, // address(0) for ETH
        uint256 totalAmountPaidWeiOrTokenUnits,
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
    event ERC20PriceSet(
        uint256 indexed tokenId,
        address indexed erc20Token,
        uint256 price
    );
    event ProtocolFeeETHUpdated(uint256 newFee);
    event ProtocolFeeERC20Updated(address indexed erc20Token, uint256 newFee);

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
        // Validate critical addresses
        if (_admin == address(0)) {
            revert BlueprintERC1155__ZeroAdminAddress();
        }
        if (_blueprintRecipient == address(0)) {
            revert BlueprintERC1155__ZeroBlueprintRecipient();
        }
        if (_creatorRecipient == address(0)) {
            revert BlueprintERC1155__ZeroCreatorRecipient();
        }

        // Validate total basis points don't exceed 100%
        uint256 totalBasisPoints = _feeBasisPoints + _creatorBasisPoints + _rewardPoolBasisPoints;
        if (totalBasisPoints > BASIS_POINTS_DENOMINATOR) {
            revert BlueprintERC1155__InvalidBasisPoints(totalBasisPoints);
        }

        __ERC1155_init(_uri);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FACTORY_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(CREATOR_ROLE, _creatorRecipient);

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

        // Initialize protocol fees for free mints
        protocolFeeETH = 111000000000000; // 0.000111 ETH in wei
        // ERC20 protocol fees are set per-token via setProtocolFeeERC20()

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
    ) internal view override onlyRole(UPGRADER_ROLE) {
        // Ensure new implementation is a valid contract
        require(newImplementation.code.length > 0, "Invalid implementation");
    }

    /**
     * @dev Creates a new drop with auto-incrementing token ID - only callable by factory
     * @param price The mint price in wei
     * @param startTime The timestamp when minting becomes available
     * @param endTime The timestamp when minting ends (set to 0 for infinite/no-end drops)
     * @param active Whether the drop is active and mintable
     * @return tokenId The assigned token ID for the new drop
     * @notice When endTime is set to 0, the drop will never expire and minting remains open
     *         indefinitely as long as the drop is active. This is useful for open editions.
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
            startTime: startTime,
            endTime: endTime,
            active: active
        });

        emit DropCreated(tokenId, price, startTime, endTime);
        return tokenId;
    }

    /**
     * @dev Creates a new drop with auto-incrementing token ID and optional ERC20 support - only callable by factory
     * @param price The ETH mint price in wei (0 = free mint with protocol fee)
     * @param erc20Token ERC20 token address (address(0) to skip ERC20 setup)
     * @param erc20Price The ERC20 mint price in token units
     * @param startTime The timestamp when minting becomes available
     * @param endTime The timestamp when minting ends (set to 0 for infinite/no-end drops)
     * @param active Whether the drop is active and mintable
     * @return tokenId The assigned token ID for the new drop
     * @notice ETH is always enabled. To add more ERC20 tokens, call setERC20Price after creation.
     *         When endTime is set to 0, the drop will never expire (useful for open editions).
     */
    function createDropWithERC20(
        uint256 price,
        address erc20Token,
        uint256 erc20Price,
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
            startTime: startTime,
            endTime: endTime,
            active: active
        });

        // Set ERC20 price if token provided (allows 0 for free mints with protocol fee)
        if (erc20Token != address(0)) {
            erc20Prices[tokenId][erc20Token] = erc20Price;
            isERC20Enabled[tokenId][erc20Token] = true;
            emit ERC20PriceSet(tokenId, erc20Token, erc20Price);
        }

        emit DropCreated(tokenId, price, startTime, endTime);
        return tokenId;
    }

    /**
     * @dev Creates or updates a drop - only callable by factory
     * @param tokenId The token ID for the drop
     * @param price The mint price in wei
     * @param startTime The timestamp when minting becomes available
     * @param endTime The timestamp when minting ends (set to 0 for infinite/no-end drops)
     * @param active Whether the drop is active and mintable
     * @notice When endTime is set to 0, the drop will never expire (useful for open editions).
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
            startTime: startTime,
            endTime: endTime,
            active: active
        });

        emit DropUpdated(tokenId, price, startTime, endTime, active);
    }

    /**
     * @dev Creates or updates a drop with optional ERC20 support - only callable by factory
     * @param tokenId The token ID for the drop
     * @param price The ETH mint price in wei (0 = free mint with protocol fee)
     * @param erc20Token ERC20 token address (address(0) to skip ERC20 setup)
     * @param erc20Price The ERC20 mint price in token units
     * @param startTime The timestamp when minting becomes available
     * @param endTime The timestamp when minting ends (set to 0 for infinite/no-end drops)
     * @param active Whether the drop is active and mintable
     * @notice ETH is always enabled. To add more ERC20 tokens, call setERC20Price separately.
     *         When endTime is set to 0, the drop will never expire (useful for open editions).
     */
    function setDropWithERC20(
        uint256 tokenId,
        uint256 price,
        address erc20Token,
        uint256 erc20Price,
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
            startTime: startTime,
            endTime: endTime,
            active: active
        });

        // Set ERC20 price if token provided (allows 0 for free mints with protocol fee)
        if (erc20Token != address(0)) {
            erc20Prices[tokenId][erc20Token] = erc20Price;
            isERC20Enabled[tokenId][erc20Token] = true;
            emit ERC20PriceSet(tokenId, erc20Token, erc20Price);
        }

        emit DropUpdated(tokenId, price, startTime, endTime, active);
    }

    /**
     * @dev Sets or updates ERC20 price for a specific token - only callable by factory
     * @param tokenId Token ID to configure
     * @param erc20Token ERC20 token address
     * @param price Price in ERC20 token units (0 = free mint, no protocol fee unless protocolFeeERC20 is set)
     */
    function setERC20Price(
        uint256 tokenId,
        address erc20Token,
        uint256 price
    ) external onlyRole(FACTORY_ROLE) {
        if (erc20Token == address(0)) {
            revert BlueprintERC1155__InvalidERC20Address();
        }
        erc20Prices[tokenId][erc20Token] = price;
        isERC20Enabled[tokenId][erc20Token] = true;
        emit ERC20PriceSet(tokenId, erc20Token, price);
    }

    /**
     * @dev Disables ERC20 token for a specific token ID - only callable by factory
     * @param tokenId Token ID to configure
     * @param erc20Token ERC20 token address to disable
     */
    function disableERC20(
        uint256 tokenId,
        address erc20Token
    ) external onlyRole(FACTORY_ROLE) {
        if (erc20Token == address(0)) {
            revert BlueprintERC1155__InvalidERC20Address();
        }
        erc20Prices[tokenId][erc20Token] = 0;
        isERC20Enabled[tokenId][erc20Token] = false;
        emit ERC20PriceSet(tokenId, erc20Token, 0);
    }

    /**
     * @dev Allows creator to update start and end times only
     * @param tokenId The token ID for the drop
     * @param startTime The new start time
     * @param endTime The new end time (set to 0 for infinite/no-end drops)
     * @notice When endTime is set to 0, the drop will never expire (useful for open editions).
     */
    function updateDropTimes(
        uint256 tokenId,
        uint256 startTime,
        uint256 endTime
    ) external onlyRole(CREATOR_ROLE) {
        if (startTime >= endTime && endTime != 0) {
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
    ) external payable nonReentrant whenNotPaused {
        _mintETHInternal(to, tokenId, amount, address(0));
    }

    /**
     * @dev Public minting function with optional referrer for indexing purposes (ETH payments)
     *      Logic is identical to {mint} with an extra referral event when referrer != address(0)
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param amount Number of tokens to mint
     * @param referrer Address of the referrer (set to address(0) if none)
     */
    function mint(
        address to,
        uint256 tokenId,
        uint256 amount,
        address referrer
    ) external payable nonReentrant whenNotPaused {
        _mintETHInternal(to, tokenId, amount, referrer);
    }

    /**
     * @dev Public minting function with ERC20 payment handling and fee distribution
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param amount Number of tokens to mint
     * @param erc20Token ERC20 token address to use for payment
     */
    function mintWithERC20(
        address to,
        uint256 tokenId,
        uint256 amount,
        address erc20Token
    ) external nonReentrant whenNotPaused {
        _mintERC20Internal(to, tokenId, amount, erc20Token, address(0));
    }

    /**
     * @dev Public minting function with ERC20 payment and optional referrer for indexing
     *      Logic is identical to {mintWithERC20} with an extra referral event when referrer != address(0)
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param amount Number of tokens to mint
     * @param erc20Token ERC20 token address to use for payment
     * @param referrer Address of the referrer (set to address(0) if none)
     */
    function mintWithERC20(
        address to,
        uint256 tokenId,
        uint256 amount,
        address erc20Token,
        address referrer
    ) external nonReentrant whenNotPaused {
        _mintERC20Internal(to, tokenId, amount, erc20Token, referrer);
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
    ) external payable nonReentrant whenNotPaused {
        _batchMintETHInternal(to, tokenIds, amounts, address(0));
    }

    /**
     * @dev Public batch minting with ETH and optional referrer for indexing
     *      Logic is identical to {batchMint} with an extra referral event when referrer != address(0)
     * @param to Recipient address
     * @param tokenIds Array of token IDs to mint
     * @param amounts Array of token amounts to mint
     * @param referrer Address of the referrer (set to address(0) if none)
     */
    function batchMint(
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        address referrer
    ) external payable nonReentrant whenNotPaused {
        _batchMintETHInternal(to, tokenIds, amounts, referrer);
    }

    /**
     * @dev Public batch minting function with ERC20 payment handling and fee distribution
     * @param to Recipient address
     * @param tokenIds Array of token IDs to mint
     * @param amounts Array of token amounts to mint
     * @param erc20Token ERC20 token address to use for payment
     * @notice All tokens in the batch must accept the same ERC20 token
     */
    function batchMintWithERC20(
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        address erc20Token
    ) external nonReentrant whenNotPaused {
        _batchMintERC20Internal(to, tokenIds, amounts, erc20Token, address(0));
    }

    /**
     * @dev Public batch minting with ERC20 and optional referrer for indexing
     *      Logic is identical to {batchMintWithERC20} with an extra referral event when referrer != address(0)
     * @param to Recipient address
     * @param tokenIds Array of token IDs to mint
     * @param amounts Array of token amounts to mint
     * @param erc20Token ERC20 token address to use for payment
     * @param referrer Address of the referrer (set to address(0) if none)
     * @notice All tokens in the batch must accept the same ERC20 token
     */
    function batchMintWithERC20(
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        address erc20Token,
        address referrer
    ) external nonReentrant whenNotPaused {
        _batchMintERC20Internal(to, tokenIds, amounts, erc20Token, referrer);
    }

    /**
     * @dev EIP-5792 compatible batch-friendly ERC20 mint function with enhanced safeguards
     * Designed to work optimally with batch transactions that include approval + mint
     * Protects against fee-on-transfer tokens and other weird ERC20 behaviors
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param amount Number of tokens to mint
     * @param erc20Token ERC20 token address to use for payment
     * @param allowFeeOnTransfer Whether to allow fee-on-transfer tokens (if false, reverts on any fee)
     */
    function mintWithERC20BatchSafe(
        address to,
        uint256 tokenId,
        uint256 amount,
        address erc20Token,
        bool allowFeeOnTransfer
    ) external nonReentrant whenNotPaused {
        _mintERC20BatchSafeInternal(
            to,
            tokenId,
            amount,
            erc20Token,
            allowFeeOnTransfer,
            address(0)
        );
    }

    /**
     * @dev EIP-5792 compatible ERC20 mint with optional referrer for indexing and enhanced safeguards
     *      Logic is identical to {mintWithERC20BatchSafe} with an extra referral event when referrer != address(0)
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param amount Number of tokens to mint
     * @param erc20Token ERC20 token address to use for payment
     * @param allowFeeOnTransfer Whether to allow fee-on-transfer tokens
     * @param referrer Address of the referrer (set to address(0) if none)
     */
    function mintWithERC20BatchSafe(
        address to,
        uint256 tokenId,
        uint256 amount,
        address erc20Token,
        bool allowFeeOnTransfer,
        address referrer
    ) external nonReentrant whenNotPaused {
        _mintERC20BatchSafeInternal(
            to,
            tokenId,
            amount,
            erc20Token,
            allowFeeOnTransfer,
            referrer
        );
    }

    // ===== Internal helpers to reduce duplication =====

    function _mintETHInternal(
        address to,
        uint256 tokenId,
        uint256 amount,
        address referrer
    ) internal {
        // Validate recipient address
        if (to == address(0)) {
            revert BlueprintERC1155__ZeroRecipientAddress();
        }
        // Validate amount to prevent overflow in fee calculations
        if (amount > MAX_MINT_AMOUNT) {
            revert BlueprintERC1155__ExceedsMaxMintAmount(amount, MAX_MINT_AMOUNT);
        }

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

        // Get the appropriate fee config for this token
        FeeConfig memory feeConfig = getFeeConfig(tokenId);

        // Validate essential recipients
        if (feeConfig.blueprintRecipient == address(0)) {
            revert BlueprintERC1155__ZeroBlueprintRecipient();
        }
        if (feeConfig.creatorRecipient == address(0)) {
            revert BlueprintERC1155__ZeroCreatorRecipient();
        }

        // Determine payment amounts based on whether this is a free mint
        uint256 requiredPayment;
        uint256 platformFee;
        uint256 creatorFee;
        uint256 rewardPoolFee;
        uint256 treasuryAmount;

        if (drop.price == 0) {
            // FREE MINT: Charge fixed protocol fee, 100% goes to Blueprint
            requiredPayment = protocolFeeETH * amount;
            platformFee = requiredPayment;
            creatorFee = 0;
            rewardPoolFee = 0;
            treasuryAmount = 0;
        } else {
            // PAID MINT: Normal fee distribution
            requiredPayment = drop.price * amount;
            uint256 totalPrice = requiredPayment;
            platformFee =
                (totalPrice * feeConfig.blueprintFeeBasisPoints) /
                BASIS_POINTS_DENOMINATOR;
            creatorFee = (totalPrice * feeConfig.creatorBasisPoints) / BASIS_POINTS_DENOMINATOR;
            rewardPoolFee =
                (totalPrice * feeConfig.rewardPoolBasisPoints) /
                BASIS_POINTS_DENOMINATOR;
            // Treasury gets remainder (rewardPoolFee goes to treasury if no recipient is set)
            treasuryAmount = totalPrice - platformFee - creatorFee;
        }

        // Validate payment
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

        // Send reward pool fee if recipient is set, otherwise it stays in treasury
        if (rewardPoolFee > 0 && feeConfig.rewardPoolRecipient != address(0)) {
            (bool rewardPoolSuccess, ) = feeConfig.rewardPoolRecipient.call{
                value: rewardPoolFee
            }("");
            if (!rewardPoolSuccess) {
                revert BlueprintERC1155__RewardPoolFeeTransferFailed();
            }
            treasuryAmount -= rewardPoolFee;
        }

        // Send treasury amount if set
        if (treasuryAmount > 0 && feeConfig.treasury != address(0)) {
            (bool treasurySuccess, ) = feeConfig.treasury.call{
                value: treasuryAmount
            }("");
            if (!treasurySuccess) {
                revert BlueprintERC1155__TreasuryTransferFailed();
            }
        }

        // Refund excess payment if any
        if (msg.value > requiredPayment) {
            uint256 refund = msg.value - requiredPayment;
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
            requiredPayment,
            block.timestamp
        );
        if (referrer != address(0)) {
            emit ReferredMint(
                msg.sender,
                referrer,
                to,
                tokenId,
                amount,
                address(0),
                requiredPayment,
                block.timestamp
            );
        }
    }

    function _mintERC20Internal(
        address to,
        uint256 tokenId,
        uint256 amount,
        address erc20TokenAddress,
        address referrer
    ) internal {
        // Validate recipient address
        if (to == address(0)) {
            revert BlueprintERC1155__ZeroRecipientAddress();
        }
        // Validate amount to prevent overflow in fee calculations
        if (amount > MAX_MINT_AMOUNT) {
            revert BlueprintERC1155__ExceedsMaxMintAmount(amount, MAX_MINT_AMOUNT);
        }

        Drop memory drop = drops[tokenId];
        if (!drop.active) {
            revert BlueprintERC1155__DropNotActive();
        }
        if (erc20TokenAddress == address(0)) {
            revert BlueprintERC1155__InvalidERC20Address();
        }

        uint256 erc20Price = erc20Prices[tokenId][erc20TokenAddress];
        uint256 protocolFee = protocolFeeERC20[erc20TokenAddress];

        // Check if ERC20 is explicitly enabled for this token
        if (!isERC20Enabled[tokenId][erc20TokenAddress]) {
            revert BlueprintERC1155__ERC20NotEnabled();
        }

        if (block.timestamp < drop.startTime) {
            revert BlueprintERC1155__DropNotStarted();
        }
        if (block.timestamp > drop.endTime && drop.endTime != 0) {
            revert BlueprintERC1155__DropEnded();
        }

        // Handle ERC20 fee distribution
        FeeConfig memory feeConfig = getFeeConfig(tokenId);
        if (feeConfig.blueprintRecipient == address(0)) {
            revert BlueprintERC1155__ZeroBlueprintRecipient();
        }
        if (feeConfig.creatorRecipient == address(0)) {
            revert BlueprintERC1155__ZeroCreatorRecipient();
        }

        // Determine payment amounts based on whether this is a free mint
        uint256 requiredPayment;
        uint256 platformFee;
        uint256 creatorFee;
        uint256 rewardPoolFee;
        uint256 treasuryAmount;

        if (erc20Price == 0) {
            // FREE MINT: Charge fixed protocol fee, 100% goes to Blueprint
            requiredPayment = protocolFee * amount;
            platformFee = requiredPayment;
            creatorFee = 0;
            rewardPoolFee = 0;
            treasuryAmount = 0;
        } else {
            // PAID MINT: Normal fee distribution
            requiredPayment = erc20Price * amount;
            platformFee =
                (requiredPayment * feeConfig.blueprintFeeBasisPoints) /
                BASIS_POINTS_DENOMINATOR;
            creatorFee =
                (requiredPayment * feeConfig.creatorBasisPoints) /
                BASIS_POINTS_DENOMINATOR;
            rewardPoolFee =
                (requiredPayment * feeConfig.rewardPoolBasisPoints) /
                BASIS_POINTS_DENOMINATOR;
            // Treasury gets remainder (rewardPoolFee goes to treasury if no recipient is set)
            treasuryAmount = requiredPayment - platformFee - creatorFee;
        }

        IERC20 erc20Token = IERC20(erc20TokenAddress);

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

        // Send platform fee
        erc20Token.safeTransferFrom(
            msg.sender,
            feeConfig.blueprintRecipient,
            platformFee
        );

        // Send creator fee
        erc20Token.safeTransferFrom(
            msg.sender,
            feeConfig.creatorRecipient,
            creatorFee
        );

        // Send reward pool fee if recipient is set, otherwise it stays in treasury
        if (rewardPoolFee > 0 && feeConfig.rewardPoolRecipient != address(0)) {
            erc20Token.safeTransferFrom(
                msg.sender,
                feeConfig.rewardPoolRecipient,
                rewardPoolFee
            );
            treasuryAmount -= rewardPoolFee;
        }

        // Send treasury amount if set
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
            erc20TokenAddress,
            requiredPayment,
            block.timestamp
        );
        if (referrer != address(0)) {
            emit ReferredMint(
                msg.sender,
                referrer,
                to,
                tokenId,
                amount,
                erc20TokenAddress,
                requiredPayment,
                block.timestamp
            );
        }
    }

    function _batchMintETHInternal(
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        address referrer
    ) internal {
        // Validate recipient address
        if (to == address(0)) {
            revert BlueprintERC1155__ZeroRecipientAddress();
        }
        if (tokenIds.length != amounts.length) {
            revert BlueprintERC1155__BatchLengthMismatch();
        }

        uint256 requiredPayment = 0;
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
            // Calculate payment: use protocol fee for free mints, regular price otherwise
            if (drop.price == 0) {
                requiredPayment += protocolFeeETH * amounts[i];
            } else {
                requiredPayment += drop.price * amounts[i];
            }
        }

        if (msg.value < requiredPayment) {
            revert BlueprintERC1155__InsufficientPayment(
                requiredPayment,
                msg.value
            );
        }

        _mintBatch(to, tokenIds, amounts, "");

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _totalSupply[tokenIds[i]] += amounts[i];
            totalAmount += amounts[i];
        }
        _globalTotalSupply += totalAmount;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            Drop memory drop = drops[tokenIds[i]];
            FeeConfig memory config = getFeeConfig(tokenIds[i]);
            if (config.blueprintRecipient == address(0)) {
                revert BlueprintERC1155__ZeroBlueprintRecipient();
            }
            if (config.creatorRecipient == address(0)) {
                revert BlueprintERC1155__ZeroCreatorRecipient();
            }

            uint256 payment;
            uint256 platformFee;
            uint256 creatorFee;
            uint256 rewardPoolFee;
            uint256 treasuryAmount;

            if (drop.price == 0) {
                // FREE MINT: Protocol fee goes 100% to Blueprint
                payment = protocolFeeETH * amounts[i];
                platformFee = payment;
                creatorFee = 0;
                rewardPoolFee = 0;
                treasuryAmount = 0;
            } else {
                // PAID MINT: Normal fee distribution
                payment = drop.price * amounts[i];
                platformFee =
                    (payment * config.blueprintFeeBasisPoints) /
                    BASIS_POINTS_DENOMINATOR;
                creatorFee = (payment * config.creatorBasisPoints) / BASIS_POINTS_DENOMINATOR;
                rewardPoolFee =
                    (payment * config.rewardPoolBasisPoints) /
                    BASIS_POINTS_DENOMINATOR;
                // Treasury gets remainder (rewardPoolFee goes to treasury if no recipient is set)
                treasuryAmount = payment - platformFee - creatorFee;
            }

            (bool feeSuccess, ) = config.blueprintRecipient.call{
                value: platformFee
            }("");
            if (!feeSuccess) {
                revert BlueprintERC1155__BlueprintFeeTransferFailed();
            }
            (bool creatorSuccess, ) = config.creatorRecipient.call{
                value: creatorFee
            }("");
            if (!creatorSuccess) {
                revert BlueprintERC1155__CreatorFeeTransferFailed();
            }
            if (rewardPoolFee > 0 && config.rewardPoolRecipient != address(0)) {
                (bool rewardPoolSuccess, ) = config.rewardPoolRecipient.call{
                    value: rewardPoolFee
                }("");
                if (!rewardPoolSuccess) {
                    revert BlueprintERC1155__RewardPoolFeeTransferFailed();
                }
                treasuryAmount -= rewardPoolFee;
            }
            if (treasuryAmount > 0 && config.treasury != address(0)) {
                (bool treasurySuccess, ) = config.treasury.call{
                    value: treasuryAmount
                }("");
                if (!treasurySuccess) {
                    revert BlueprintERC1155__TreasuryTransferFailed();
                }
            }
        }

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
        if (referrer != address(0)) {
            emit ReferredBatchMint(
                msg.sender,
                referrer,
                to,
                tokenIds,
                amounts,
                address(0),
                requiredPayment,
                block.timestamp
            );
        }
    }

    function _batchMintERC20Internal(
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        address erc20TokenAddress,
        address referrer
    ) internal {
        // Validate recipient address
        if (to == address(0)) {
            revert BlueprintERC1155__ZeroRecipientAddress();
        }
        if (tokenIds.length != amounts.length) {
            revert BlueprintERC1155__BatchLengthMismatch();
        }
        if (erc20TokenAddress == address(0)) {
            revert BlueprintERC1155__InvalidERC20Address();
        }

        uint256 requiredPayment = 0;
        uint256 protocolFee = protocolFeeERC20[erc20TokenAddress];
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            Drop memory drop = drops[tokenIds[i]];
            if (!drop.active) {
                revert BlueprintERC1155__DropNotActive();
            }

            uint256 erc20Price = erc20Prices[tokenIds[i]][erc20TokenAddress];
            
            // Check if ERC20 is explicitly enabled for this token
            if (!isERC20Enabled[tokenIds[i]][erc20TokenAddress]) {
                revert BlueprintERC1155__ERC20NotEnabled();
            }

            if (block.timestamp < drop.startTime) {
                revert BlueprintERC1155__DropNotStarted();
            }
            if (block.timestamp > drop.endTime && drop.endTime != 0) {
                revert BlueprintERC1155__DropEnded();
            }
            
            // Calculate payment: use protocol fee for free mints, regular price otherwise
            if (erc20Price == 0) {
                requiredPayment += protocolFee * amounts[i];
            } else {
                requiredPayment += erc20Price * amounts[i];
            }
        }

        IERC20 erc20Token = IERC20(erc20TokenAddress);
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

        _mintBatch(to, tokenIds, amounts, "");

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _totalSupply[tokenIds[i]] += amounts[i];
            totalAmount += amounts[i];
        }
        _globalTotalSupply += totalAmount;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 erc20Price = erc20Prices[tokenIds[i]][erc20TokenAddress];
            FeeConfig memory config = getFeeConfig(tokenIds[i]);
            if (config.blueprintRecipient == address(0)) {
                revert BlueprintERC1155__ZeroBlueprintRecipient();
            }
            if (config.creatorRecipient == address(0)) {
                revert BlueprintERC1155__ZeroCreatorRecipient();
            }
            
            uint256 payment;
            uint256 platformFee;
            uint256 creatorFee;
            uint256 rewardPoolFee;
            uint256 treasuryAmount;
            
            if (erc20Price == 0) {
                // FREE MINT: Protocol fee goes 100% to Blueprint
                payment = protocolFee * amounts[i];
                platformFee = payment;
                creatorFee = 0;
                rewardPoolFee = 0;
                treasuryAmount = 0;
            } else {
                // PAID MINT: Normal fee distribution
                payment = erc20Price * amounts[i];
                platformFee = (payment * config.blueprintFeeBasisPoints) /
                    BASIS_POINTS_DENOMINATOR;
                creatorFee = (payment * config.creatorBasisPoints) / BASIS_POINTS_DENOMINATOR;
                rewardPoolFee = (payment * config.rewardPoolBasisPoints) /
                    BASIS_POINTS_DENOMINATOR;
                // Treasury gets remainder (rewardPoolFee goes to treasury if no recipient is set)
                treasuryAmount = payment - platformFee - creatorFee;
            }

            erc20Token.safeTransferFrom(
                msg.sender,
                config.blueprintRecipient,
                platformFee
            );
            erc20Token.safeTransferFrom(
                msg.sender,
                config.creatorRecipient,
                creatorFee
            );
            if (rewardPoolFee > 0 && config.rewardPoolRecipient != address(0)) {
                erc20Token.safeTransferFrom(
                    msg.sender,
                    config.rewardPoolRecipient,
                    rewardPoolFee
                );
                treasuryAmount -= rewardPoolFee;
            }
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
            erc20TokenAddress,
            requiredPayment,
            block.timestamp
        );
        if (referrer != address(0)) {
            emit ReferredBatchMint(
                msg.sender,
                referrer,
                to,
                tokenIds,
                amounts,
                erc20TokenAddress,
                requiredPayment,
                block.timestamp
            );
        }
    }

    function _mintERC20BatchSafeInternal(
        address to,
        uint256 tokenId,
        uint256 amount,
        address erc20TokenAddress,
        bool allowFeeOnTransfer,
        address referrer
    ) internal {
        // Validate recipient address
        if (to == address(0)) {
            revert BlueprintERC1155__ZeroRecipientAddress();
        }
        // Validate amount to prevent overflow in fee calculations
        if (amount > MAX_MINT_AMOUNT) {
            revert BlueprintERC1155__ExceedsMaxMintAmount(amount, MAX_MINT_AMOUNT);
        }

        Drop memory drop = drops[tokenId];
        if (!drop.active) {
            revert BlueprintERC1155__DropNotActive();
        }
        if (erc20TokenAddress == address(0)) {
            revert BlueprintERC1155__InvalidERC20Address();
        }

        uint256 erc20Price = erc20Prices[tokenId][erc20TokenAddress];
        uint256 protocolFee = protocolFeeERC20[erc20TokenAddress];

        // Check if ERC20 is explicitly enabled for this token
        if (!isERC20Enabled[tokenId][erc20TokenAddress]) {
            revert BlueprintERC1155__ERC20NotEnabled();
        }

        if (block.timestamp < drop.startTime) {
            revert BlueprintERC1155__DropNotStarted();
        }
        if (block.timestamp > drop.endTime && drop.endTime != 0) {
            revert BlueprintERC1155__DropEnded();
        }

        // Handle ERC20 fee distribution
        FeeConfig memory feeConfig = getFeeConfig(tokenId);
        if (feeConfig.blueprintRecipient == address(0)) {
            revert BlueprintERC1155__ZeroBlueprintRecipient();
        }
        if (feeConfig.creatorRecipient == address(0)) {
            revert BlueprintERC1155__ZeroCreatorRecipient();
        }

        // Determine payment amounts based on whether this is a free mint
        uint256 requiredPayment;
        uint256 platformFee;
        uint256 creatorFee;
        uint256 rewardPoolFee;
        uint256 treasuryAmount;

        if (erc20Price == 0) {
            // FREE MINT: Charge fixed protocol fee, 100% goes to Blueprint
            requiredPayment = protocolFee * amount;
            platformFee = requiredPayment;
            creatorFee = 0;
            rewardPoolFee = 0;
            treasuryAmount = 0;
        } else {
            // PAID MINT: Normal fee distribution
            requiredPayment = erc20Price * amount;
            platformFee =
                (requiredPayment * feeConfig.blueprintFeeBasisPoints) /
                BASIS_POINTS_DENOMINATOR;
            creatorFee =
                (requiredPayment * feeConfig.creatorBasisPoints) /
                BASIS_POINTS_DENOMINATOR;
            rewardPoolFee =
                (requiredPayment * feeConfig.rewardPoolBasisPoints) /
                BASIS_POINTS_DENOMINATOR;
            // Treasury gets remainder (rewardPoolFee goes to treasury if no recipient is set)
            treasuryAmount = requiredPayment - platformFee - creatorFee;
        }

        IERC20 erc20Token = IERC20(erc20TokenAddress);

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

        _totalSupply[tokenId] += amount;
        _globalTotalSupply += amount;

        if (allowFeeOnTransfer) {
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
            erc20TokenAddress,
            requiredPayment,
            block.timestamp
        );
        if (referrer != address(0)) {
            emit ReferredMint(
                msg.sender,
                referrer,
                to,
                tokenId,
                amount,
                erc20TokenAddress,
                requiredPayment,
                block.timestamp
            );
        }
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
     * @dev Get required ETH payment amount for a drop
     * @param tokenId Token ID to query
     * @param amount Number of tokens to mint
     * @return ethPrice ETH price in wei (includes protocol fee for free mints)
     * @notice ETH is always enabled. Returns protocol fee if price is 0.
     */
    function getETHPaymentInfo(
        uint256 tokenId,
        uint256 amount
    ) external view returns (uint256 ethPrice) {
        Drop memory drop = drops[tokenId];
        if (drop.price == 0) {
            return protocolFeeETH * amount;
        }
        return drop.price * amount;
    }

    /**
     * @dev Get required ERC20 payment amount for a specific token
     * @param tokenId Token ID to query
     * @param erc20Token ERC20 token address to check
     * @param amount Number of tokens to mint
     * @return erc20Price ERC20 price in token units (includes protocol fee for free mints, 0 if not accepted)
     */
    function getERC20PaymentInfo(
        uint256 tokenId,
        address erc20Token,
        uint256 amount
    ) external view returns (uint256 erc20Price) {
        uint256 price = erc20Prices[tokenId][erc20Token];
        if (price == 0) {
            // Check if protocol fee is configured for free mints
            uint256 protocolFee = protocolFeeERC20[erc20Token];
            if (protocolFee > 0) {
                return protocolFee * amount;
            }
            return 0; // ERC20 not enabled for this token
        }
        return price * amount;
    }

    /**
     * @dev Batch-friendly function to check if user can mint with current balances/allowances
     * @param user Address to check
     * @param tokenId Token ID to check
     * @param erc20Token ERC20 token address to check (address(0) to skip ERC20 check)
     * @param amount Amount to mint
     * @return canMintETH Whether user can mint with ETH
     * @return canMintERC20 Whether user can mint with specified ERC20
     * @return requiredETH Required ETH amount
     * @return requiredERC20 Required ERC20 amount
     * @return currentAllowance Current ERC20 allowance
     * @return currentBalance Current ERC20 balance
     */
    function checkMintEligibility(
        address user,
        uint256 tokenId,
        address erc20Token,
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

        // Calculate ETH requirement (includes protocol fee for free mints)
        if (drop.price == 0) {
            requiredETH = protocolFeeETH * amount;
        } else {
            requiredETH = drop.price * amount;
        }

        // Calculate ERC20 requirement (includes protocol fee for free mints)
        uint256 erc20Price = erc20Prices[tokenId][erc20Token];
        if (erc20Price == 0) {
            uint256 protocolFee = protocolFeeERC20[erc20Token];
            requiredERC20 = protocolFee * amount;
        } else {
            requiredERC20 = erc20Price * amount;
        }

        canMintETH =
            drop.active &&
            block.timestamp >= drop.startTime &&
            (drop.endTime == 0 || block.timestamp <= drop.endTime) &&
            user.balance >= requiredETH;

        if (erc20Token != address(0) && requiredERC20 > 0) {
            IERC20 token = IERC20(erc20Token);
            currentBalance = token.balanceOf(user);
            currentAllowance = token.allowance(user, address(this));

            canMintERC20 =
                drop.active &&
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
        // Validate critical addresses
        if (_blueprintRecipient == address(0)) {
            revert BlueprintERC1155__ZeroBlueprintRecipient();
        }
        if (_creatorRecipient == address(0)) {
            revert BlueprintERC1155__ZeroCreatorRecipient();
        }

        // Validate total basis points don't exceed 100%
        uint256 totalBasisPoints = _feeBasisPoints + _creatorBasisPoints + _rewardPoolBasisPoints;
        if (totalBasisPoints > BASIS_POINTS_DENOMINATOR) {
            revert BlueprintERC1155__InvalidBasisPoints(totalBasisPoints);
        }

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
        // Validate critical addresses
        if (_blueprintRecipient == address(0)) {
            revert BlueprintERC1155__ZeroBlueprintRecipient();
        }
        if (_creatorRecipient == address(0)) {
            revert BlueprintERC1155__ZeroCreatorRecipient();
        }

        // Validate total basis points don't exceed 100%
        uint256 totalBasisPoints = _feeBasisPoints + _creatorBasisPoints + _rewardPoolBasisPoints;
        if (totalBasisPoints > BASIS_POINTS_DENOMINATOR) {
            revert BlueprintERC1155__InvalidBasisPoints(totalBasisPoints);
        }

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
     * @dev Sets the protocol fee for free ETH mints - only callable by factory
     * @param _protocolFeeETH Protocol fee in wei (e.g., 111000000000000 = 0.000111 ETH)
     */
    function setProtocolFeeETH(
        uint256 _protocolFeeETH
    ) external onlyRole(FACTORY_ROLE) {
        protocolFeeETH = _protocolFeeETH;
        emit ProtocolFeeETHUpdated(_protocolFeeETH);
    }

    /**
     * @dev Sets the protocol fee for free ERC20 mints - only callable by factory
     * @param erc20Token ERC20 token address
     * @param _protocolFee Protocol fee in token units (e.g., USDC with 6 decimals: 300000 = $0.30)
     */
    function setProtocolFeeERC20(
        address erc20Token,
        uint256 _protocolFee
    ) external onlyRole(FACTORY_ROLE) {
        if (erc20Token == address(0)) {
            revert BlueprintERC1155__InvalidERC20Address();
        }
        protocolFeeERC20[erc20Token] = _protocolFee;
        emit ProtocolFeeERC20Updated(erc20Token, _protocolFee);
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

    // ===== PAUSE FUNCTIONALITY =====

    /**
     * @dev Pauses all minting operations - only callable by admin
     * @notice Use in case of emergency to stop all minting
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses all minting operations - only callable by admin
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ===== EMERGENCY RECOVERY =====

    /**
     * @dev Withdraws stuck ETH from the contract - only callable by admin
     * @notice Use only for recovering accidentally sent ETH
     * @param to Address to send the stuck ETH to
     */
    function withdrawStuckETH(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert BlueprintERC1155__NoStuckETH();
        }
        (bool success, ) = to.call{value: balance}("");
        if (!success) {
            revert BlueprintERC1155__WithdrawFailed();
        }
    }

    /**
     * @dev Withdraws stuck ERC20 tokens from the contract - only callable by admin
     * @notice Use only for recovering accidentally sent tokens
     * @param token Address of the ERC20 token to withdraw
     * @param to Address to send the stuck tokens to
     */
    function withdrawStuckERC20(address token, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20 erc20 = IERC20(token);
        uint256 balance = erc20.balanceOf(address(this));
        if (balance == 0) {
            revert BlueprintERC1155__NoStuckERC20();
        }
        erc20.safeTransfer(to, balance);
    }

    // ===== STORAGE GAP =====
    // Reserved storage space for future upgrades
    // This allows adding new state variables without breaking storage layout
    uint256[50] private __gap;
}
