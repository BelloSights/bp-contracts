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

import "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import "./BlueprintERC1155Factory.sol";
import "./BlueprintERC1155.sol";

/**
 * @title BlueprintCrossBatchMinter
 * @dev Enables batch minting across multiple BlueprintERC1155 collections in a single transaction.
 * Perfect for shopping cart experiences where users want to mint from multiple collections at once.
 *
 * @notice This contract provides the following minting functions:
 *
 * 1. batchMintAcrossCollections (ETH only)
 *    - Use when all items accept ETH payments
 *    - Simpler and more gas-efficient
 *    - Example: User wants to mint 3 NFTs from different collections, all priced in ETH
 *
 * 2. batchMintAcrossCollectionsMixed (Mixed payments - MOST FLEXIBLE)
 *    - Use for ANY payment scenario:
 *      • Pure ETH payments
 *      • Single ERC20 token (e.g., all collections accept USDC)
 *      • Multiple different ERC20 tokens (e.g., some accept USDC, others accept DAI)
 *      • Mix of ETH and ERC20 payments
 *    - Example: User wants to mint from 5 collections where:
 *      • Collections A & B accept ETH
 *      • Collection C accepts USDC
 *      • Collections D & E accept DAI
 *    - Requires users to approve each ERC20 token beforehand
 *
 * @notice PAYMENT METHOD SELECTION (for drops that accept BOTH ETH and ERC20):
 *    - User sends ETH (msg.value > 0) → Contract uses ETH for dual-payment drops
 *    - User sends NO ETH (msg.value == 0) → Contract uses ERC20 for dual-payment drops
 *    This gives users explicit control over their payment method!
 *
 * @custom:security Users must approve ERC20 tokens to this contract before calling mixed payment functions
 * @custom:oz-upgrades-from BlueprintCrossBatchMinter
 */
contract BlueprintCrossBatchMinter is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ===== ERRORS =====
    error BlueprintCrossBatchMinter__InvalidArrayLength();
    error BlueprintCrossBatchMinter__InvalidCollection(address collection);
    error BlueprintCrossBatchMinter__ZeroAmount();
    error BlueprintCrossBatchMinter__InsufficientPayment(
        uint256 required,
        uint256 provided
    );
    error BlueprintCrossBatchMinter__MixedPaymentMethods();
    error BlueprintCrossBatchMinter__RefundFailed();
    error BlueprintCrossBatchMinter__InvalidFactory();
    error BlueprintCrossBatchMinter__InsufficientERC20Balance(
        uint256 required,
        uint256 balance
    );
    error BlueprintCrossBatchMinter__InsufficientERC20Allowance(
        uint256 required,
        uint256 allowance
    );
    error BlueprintCrossBatchMinter__DropNotActive();
    error BlueprintCrossBatchMinter__DropNotStarted();
    error BlueprintCrossBatchMinter__DropEnded();
    error BlueprintCrossBatchMinter__ETHNotEnabled();
    error BlueprintCrossBatchMinter__ERC20NotEnabled();
    error BlueprintCrossBatchMinter__InvalidERC20Address();
    error BlueprintCrossBatchMinter__FunctionNotSupported(bytes4 selector);

    // ===== ROLES =====
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ===== STRUCTS =====
    struct BatchMintItem {
        address collection; // Address of the BlueprintERC1155 collection
        uint256 tokenId; // Token ID to mint
        uint256 amount; // Amount to mint
    }

    struct PaymentInfo {
        uint256 totalETHRequired;
        uint256 totalERC20Required;
        address erc20Token;
        bool hasETHPayments;
        bool hasERC20Payments;
        bool mixedPaymentMethods;
    }

    struct CollectionMintData {
        address collection;
        uint256[] tokenIds;
        uint256[] amounts;
        uint256 ethPayment;
        uint256 erc20Payment;
    }

    struct ERC20Requirement {
        address token;
        uint256 amount;
    }

    struct MixedPaymentInfo {
        uint256 totalETHRequired;
        ERC20Requirement[] erc20Requirements;
    }

    struct MixedCollectionData {
        address collection;
        uint256[] tokenIds;
        uint256[] amounts;
        uint256 ethPayment;
        address erc20Token;
        uint256 erc20Payment;
    }

    // ===== STATE VARIABLES =====
    BlueprintERC1155Factory public factory;

    // ===== EVENTS =====
    event CrossCollectionBatchMint(
        address indexed user,
        address indexed recipient,
        uint256 totalCollections,
        uint256 totalItems,
        address indexed paymentToken,
        uint256 totalPayment
    );

    event BatchMintItemProcessed(
        address indexed collection,
        uint256 indexed tokenId,
        uint256 amount,
        address indexed recipient
    );

    event CrossCollectionMixedBatchMint(
        address indexed user,
        address indexed recipient,
        uint256 totalCollections,
        uint256 totalItems,
        uint256 totalETHPaid,
        ERC20Requirement[] erc20Payments
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the cross batch minter
     * @param _factory Address of the BlueprintERC1155Factory
     * @param _admin Admin address with full control
     */
    function initialize(address _factory, address _admin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (_factory == address(0)) {
            revert BlueprintCrossBatchMinter__InvalidFactory();
        }

        factory = BlueprintERC1155Factory(_factory);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    /**
     * @dev Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    /**
     * @dev Updates the factory address (admin only)
     * @param _factory New factory address
     */
    function setFactory(
        address _factory
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_factory == address(0)) {
            revert BlueprintCrossBatchMinter__InvalidFactory();
        }
        factory = BlueprintERC1155Factory(_factory);
    }

    /**
     * @dev Batch mint across multiple collections using ETH payments only
     * @notice Use this function when all items will be paid with ETH
     * @notice For mixed payment methods (ETH + ERC20) or multiple ERC20 tokens, use batchMintAcrossCollectionsMixed
     * @param to Recipient address for all mints
     * @param items Array of mint items specifying collection, tokenId, and amount
     * @param referrer Optional referrer address for tracking (set to address(0) if none)
     */
    function batchMintAcrossCollections(
        address to,
        BatchMintItem[] calldata items,
        address referrer
    ) external payable nonReentrant {
        if (items.length == 0) {
            revert BlueprintCrossBatchMinter__InvalidArrayLength();
        }

        // Analyze payment requirements and validate all items
        PaymentInfo memory paymentInfo = _analyzePaymentRequirements(items);

        if (msg.value < paymentInfo.totalETHRequired) {
            revert BlueprintCrossBatchMinter__InsufficientPayment(
                paymentInfo.totalETHRequired,
                msg.value
            );
        }

        // Group items by collection for efficient batch processing
        CollectionMintData[] memory collectionData = _groupItemsByCollection(
            items
        );

        // Execute mints for each collection
        _executeBatchMints(to, collectionData, referrer);

        // Refund excess payment
        if (msg.value > paymentInfo.totalETHRequired) {
            uint256 refund = msg.value - paymentInfo.totalETHRequired;
            (bool success, ) = msg.sender.call{value: refund}("");
            if (!success) {
                revert BlueprintCrossBatchMinter__RefundFailed();
            }
        }

        emit CrossCollectionBatchMint(
            msg.sender,
            to,
            collectionData.length,
            items.length,
            address(0), // ETH
            paymentInfo.totalETHRequired
        );
    }

    /**
     * @dev Batch mint across multiple collections using MIXED payment methods (ETH + multiple ERC20 tokens)
     * @notice This is the MOST FLEXIBLE option - supports multiple payment methods in a single transaction:
     *         - Pure ETH payments
     *         - Pure ERC20 payments (single token like USDC)
     *         - Multiple different ERC20 tokens (USDC + DAI + USDT)
     *         - Mix of ETH and ERC20 payments
     * @notice Perfect for shopping cart experiences where different creators accept different payment methods
     * @notice Users must approve each ERC20 token separately before calling this function
     *
     * @notice PAYMENT METHOD SELECTION (for drops that accept both ETH and ERC20):
     *         - Send ETH (msg.value > 0): Prefer ETH payment for dual-payment drops
     *         - Send NO ETH (msg.value == 0): Prefer ERC20 payment for dual-payment drops
     *         This gives users explicit control over which payment method to use!
     *
     * @param to Recipient address for all mints
     * @param items Array of mint items specifying collection, tokenId, and amount
     * @param erc20Tokens Array of ERC20 token addresses that will be used (must include all tokens accepted by items)
     * @param referrer Optional referrer address for tracking (set to address(0) if none)
     *
     * @custom:example Pay with USDC only (even if drops accept ETH):
     *   batchMintAcrossCollectionsMixed(recipient, items, [USDC_ADDRESS], address(0))  // msg.value = 0
     *
     * @custom:example Pay with ETH (for drops that accept both ETH and USDC):
     *   batchMintAcrossCollectionsMixed{value: ethAmount}(recipient, items, [USDC_ADDRESS], address(0))
     *
     * @custom:example Multiple ERC20 tokens (some items accept USDC, others accept DAI):
     *   batchMintAcrossCollectionsMixed(recipient, items, [USDC_ADDRESS, DAI_ADDRESS], referrerAddress)
     */
    function batchMintAcrossCollectionsMixed(
        address to,
        BatchMintItem[] calldata items,
        address[] calldata erc20Tokens,
        address referrer
    ) external payable nonReentrant {
        if (items.length == 0) {
            revert BlueprintCrossBatchMinter__InvalidArrayLength();
        }

        // Determine user's payment preference based on msg.value
        // If user sends ETH, they prefer ETH for dual-payment drops
        // If user sends no ETH, they prefer ERC20 for dual-payment drops
        bool preferETH = msg.value > 0;

        // Analyze payment requirements for mixed mode
        MixedPaymentInfo memory paymentInfo = _analyzeMixedPaymentRequirements(
            items,
            erc20Tokens,
            preferETH
        );

        // Validate ETH payment
        if (msg.value < paymentInfo.totalETHRequired) {
            revert BlueprintCrossBatchMinter__InsufficientPayment(
                paymentInfo.totalETHRequired,
                msg.value
            );
        }

        // Validate ERC20 balances and allowances
        for (uint256 i = 0; i < paymentInfo.erc20Requirements.length; i++) {
            ERC20Requirement memory req = paymentInfo.erc20Requirements[i];
            if (req.amount > 0) {
                IERC20 token = IERC20(req.token);

                uint256 userBalance = token.balanceOf(msg.sender);
                if (userBalance < req.amount) {
                    revert BlueprintCrossBatchMinter__InsufficientERC20Balance(
                        req.amount,
                        userBalance
                    );
                }

                uint256 allowance = token.allowance(msg.sender, address(this));
                if (allowance < req.amount) {
                    revert BlueprintCrossBatchMinter__InsufficientERC20Allowance(
                        req.amount,
                        allowance
                    );
                }
            }
        }

        // Group items by collection and payment method
        MixedCollectionData[]
            memory collectionData = _groupItemsByCollectionMixed(
                items,
                preferETH
            );

        // Execute mints for each collection with appropriate payment method
        _executeMixedBatchMints(to, collectionData, referrer);

        // Refund excess ETH payment
        if (msg.value > paymentInfo.totalETHRequired) {
            uint256 refund = msg.value - paymentInfo.totalETHRequired;
            (bool success, ) = msg.sender.call{value: refund}("");
            if (!success) {
                revert BlueprintCrossBatchMinter__RefundFailed();
            }
        }

        emit CrossCollectionMixedBatchMint(
            msg.sender,
            to,
            collectionData.length,
            items.length,
            paymentInfo.totalETHRequired,
            paymentInfo.erc20Requirements
        );
    }

    /**
     * @dev Get total ETH payment required for a batch of items (useful for frontend estimation)
     * @notice For mixed payment estimates, use getMixedPaymentEstimate instead
     * @notice This function will revert with specific errors if items are invalid (provides better error context than isValid flag)
     * @param items Array of mint items
     * @return totalPayment Total ETH payment required
     * @return paymentToken Address of payment token (always address(0) for ETH)
     */
    function getPaymentEstimate(
        BatchMintItem[] calldata items
    ) external view returns (uint256 totalPayment, address paymentToken) {
        if (items.length == 0) {
            revert BlueprintCrossBatchMinter__InvalidArrayLength();
        }

        PaymentInfo memory info = _analyzePaymentRequirements(items);

        if (info.mixedPaymentMethods || !info.hasETHPayments) {
            revert BlueprintCrossBatchMinter__MixedPaymentMethods();
        }

        totalPayment = info.totalETHRequired;
        paymentToken = address(0);
    }

    /**
     * @dev Analyzes ETH payment requirements for a batch of items
     * @param items Array of mint items
     * @return PaymentInfo struct with payment analysis
     */
    function _analyzePaymentRequirements(
        BatchMintItem[] calldata items
    ) internal view returns (PaymentInfo memory) {
        PaymentInfo memory info;
        bool hasERC20OnlyDrops = false;

        for (uint256 i = 0; i < items.length; i++) {
            BatchMintItem calldata item = items[i];

            if (item.amount == 0) {
                revert BlueprintCrossBatchMinter__ZeroAmount();
            }

            // Validate collection is deployed by factory
            if (!factory.isDeployedCollection(item.collection)) {
                revert BlueprintCrossBatchMinter__InvalidCollection(
                    item.collection
                );
            }

            BlueprintERC1155 collection = BlueprintERC1155(item.collection);

            // Get drop information
            (
                uint256 ethPrice,
                ,
                address acceptedERC20,
                uint256 startTime,
                uint256 endTime,
                bool active,
                bool ethEnabled,
                bool erc20Enabled
            ) = collection.drops(item.tokenId);

            // Validate drop is active and within time bounds
            if (!active) {
                revert BlueprintCrossBatchMinter__DropNotActive();
            }
            if (block.timestamp < startTime) {
                revert BlueprintCrossBatchMinter__DropNotStarted();
            }
            if (block.timestamp > endTime && endTime != 0) {
                revert BlueprintCrossBatchMinter__DropEnded();
            }

            // Check if drop only supports ERC20
            bool supportsETH = ethEnabled;
            bool supportsERC20 = erc20Enabled && acceptedERC20 != address(0);

            if (!supportsETH && supportsERC20) {
                hasERC20OnlyDrops = true;
            }

            // Validate ETH is enabled
            if (!ethEnabled) {
                revert BlueprintCrossBatchMinter__ETHNotEnabled();
            }

            // Calculate ETH payment
            info.totalETHRequired += ethPrice * item.amount;
            info.hasETHPayments = true;
        }

        // For ETH mode, mixed methods occur if we have drops that only support ERC20
        info.mixedPaymentMethods = hasERC20OnlyDrops;

        return info;
    }

    /**
     * @dev Groups items by collection for efficient batch processing (ETH payments only)
     * @param items Array of mint items
     * @return Array of CollectionMintData for batch processing
     */
    function _groupItemsByCollection(
        BatchMintItem[] calldata items
    ) internal view returns (CollectionMintData[] memory) {
        // Count unique collections
        address[] memory uniqueCollections = new address[](items.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < items.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniqueCollections[j] == items[i].collection) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                uniqueCollections[uniqueCount] = items[i].collection;
                uniqueCount++;
            }
        }

        // Create collection data array
        CollectionMintData[] memory collectionData = new CollectionMintData[](
            uniqueCount
        );

        // Group items by collection
        for (uint256 i = 0; i < uniqueCount; i++) {
            address collection = uniqueCollections[i];

            // Count items for this collection
            uint256 itemCount = 0;
            for (uint256 j = 0; j < items.length; j++) {
                if (items[j].collection == collection) {
                    itemCount++;
                }
            }

            // Create arrays for this collection
            uint256[] memory tokenIds = new uint256[](itemCount);
            uint256[] memory amounts = new uint256[](itemCount);
            uint256 ethPayment = 0;

            // Fill arrays
            uint256 currentIndex = 0;
            for (uint256 j = 0; j < items.length; j++) {
                if (items[j].collection == collection) {
                    tokenIds[currentIndex] = items[j].tokenId;
                    amounts[currentIndex] = items[j].amount;

                    // Calculate ETH payment for this item
                    BlueprintERC1155 collectionContract = BlueprintERC1155(
                        collection
                    );
                    (uint256 ethPrice, , , , , , , ) = collectionContract.drops(
                        items[j].tokenId
                    );

                    ethPayment += ethPrice * items[j].amount;

                    currentIndex++;
                }
            }

            collectionData[i] = CollectionMintData({
                collection: collection,
                tokenIds: tokenIds,
                amounts: amounts,
                ethPayment: ethPayment,
                erc20Payment: 0
            });
        }

        return collectionData;
    }

    /**
     * @dev Executes batch mints for grouped collection data (ETH payments only)
     * @param to Recipient address
     * @param collectionData Array of collection mint data
     * @param referrer Optional referrer address for tracking
     */
    function _executeBatchMints(
        address to,
        CollectionMintData[] memory collectionData,
        address referrer
    ) internal {
        for (uint256 i = 0; i < collectionData.length; i++) {
            CollectionMintData memory data = collectionData[i];
            BlueprintERC1155 collection = BlueprintERC1155(data.collection);

            // Use batchMint with ETH payment and referrer
            collection.batchMint{value: data.ethPayment}(
                to,
                data.tokenIds,
                data.amounts,
                referrer
            );

            // Emit events for each item processed
            for (uint256 j = 0; j < data.tokenIds.length; j++) {
                emit BatchMintItemProcessed(
                    data.collection,
                    data.tokenIds[j],
                    data.amounts[j],
                    to
                );
            }
        }
    }

    /**
     * @dev Check if user can perform a cross-collection batch mint with ETH
     * @notice For mixed payment eligibility checks, check balances/allowances for each token separately
     * @notice This function will revert with specific errors if items are invalid
     * @param user User address to check
     * @param items Array of mint items
     * @return canMint Whether the user can perform the mint
     * @return totalRequired Total ETH payment required
     * @return paymentToken Payment token address (always address(0) for ETH)
     */
    function checkBatchMintEligibility(
        address user,
        BatchMintItem[] calldata items
    )
        external
        view
        returns (bool canMint, uint256 totalRequired, address paymentToken)
    {
        if (items.length == 0) {
            revert BlueprintCrossBatchMinter__InvalidArrayLength();
        }

        PaymentInfo memory info = _analyzePaymentRequirements(items);

        if (info.mixedPaymentMethods || !info.hasETHPayments) {
            revert BlueprintCrossBatchMinter__MixedPaymentMethods();
        }

        totalRequired = info.totalETHRequired;
        paymentToken = address(0);
        canMint = user.balance >= totalRequired;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ===== MIXED PAYMENT HELPER FUNCTIONS =====

    /**
     * @dev Analyzes payment requirements for mixed payment batch
     * @param items Array of mint items
     * @param erc20Tokens Array of ERC20 tokens that might be used
     * @param preferETH If true, prefer ETH for drops that accept both; if false, prefer ERC20
     * @return MixedPaymentInfo with payment requirements
     */
    function _analyzeMixedPaymentRequirements(
        BatchMintItem[] calldata items,
        address[] calldata erc20Tokens,
        bool preferETH
    ) internal view returns (MixedPaymentInfo memory) {
        MixedPaymentInfo memory info;
        info.erc20Requirements = new ERC20Requirement[](erc20Tokens.length);

        // Initialize ERC20 requirements
        for (uint256 i = 0; i < erc20Tokens.length; i++) {
            info.erc20Requirements[i] = ERC20Requirement({
                token: erc20Tokens[i],
                amount: 0
            });
        }

        for (uint256 i = 0; i < items.length; i++) {
            BatchMintItem calldata item = items[i];

            if (item.amount == 0) {
                revert BlueprintCrossBatchMinter__ZeroAmount();
            }

            // Validate collection is deployed by factory
            if (!factory.isDeployedCollection(item.collection)) {
                revert BlueprintCrossBatchMinter__InvalidCollection(
                    item.collection
                );
            }

            BlueprintERC1155 collection = BlueprintERC1155(item.collection);

            // Get drop information
            (
                uint256 ethPrice,
                uint256 erc20Price,
                address acceptedERC20,
                uint256 startTime,
                uint256 endTime,
                bool active,
                bool ethEnabled,
                bool erc20Enabled
            ) = collection.drops(item.tokenId);

            // Validate drop is active and within time bounds
            if (!active) {
                revert BlueprintCrossBatchMinter__DropNotActive();
            }
            if (block.timestamp < startTime) {
                revert BlueprintCrossBatchMinter__DropNotStarted();
            }
            if (block.timestamp > endTime && endTime != 0) {
                revert BlueprintCrossBatchMinter__DropEnded();
            }

            // Determine payment method for this drop
            bool canUseETH = ethEnabled && ethPrice > 0;
            bool canUseERC20 = erc20Enabled &&
                acceptedERC20 != address(0) &&
                erc20Price > 0;

            // Respect user's payment preference
            bool shouldUseETH;
            if (canUseETH && canUseERC20) {
                // Both available - use user's preference
                shouldUseETH = preferETH;
            } else if (canUseETH) {
                // Only ETH available
                shouldUseETH = true;
            } else if (canUseERC20) {
                // Only ERC20 available
                shouldUseETH = false;
            } else {
                // Neither available - invalid drop
                revert BlueprintCrossBatchMinter__DropNotActive();
            }

            if (shouldUseETH) {
                info.totalETHRequired += ethPrice * item.amount;
            } else {
                // Find the ERC20 token in our requirements array
                bool found = false;
                for (uint256 j = 0; j < info.erc20Requirements.length; j++) {
                    if (info.erc20Requirements[j].token == acceptedERC20) {
                        info.erc20Requirements[j].amount +=
                            erc20Price *
                            item.amount;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    revert BlueprintCrossBatchMinter__InvalidERC20Address();
                }
            }
        }

        return info;
    }

    /**
     * @dev Groups items by collection for mixed payment processing
     * @param items Array of mint items
     * @param preferETH If true, prefer ETH for drops that accept both; if false, prefer ERC20
     * @return Array of MixedCollectionData
     */
    function _groupItemsByCollectionMixed(
        BatchMintItem[] calldata items,
        bool preferETH
    ) internal view returns (MixedCollectionData[] memory) {
        // Count unique collections
        address[] memory uniqueCollections = new address[](items.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < items.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniqueCollections[j] == items[i].collection) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                uniqueCollections[uniqueCount] = items[i].collection;
                uniqueCount++;
            }
        }

        // Create collection data array
        MixedCollectionData[] memory collectionData = new MixedCollectionData[](
            uniqueCount
        );

        // Group items by collection
        for (uint256 i = 0; i < uniqueCount; i++) {
            address collection = uniqueCollections[i];

            // Count items for this collection
            uint256 itemCount = 0;
            for (uint256 j = 0; j < items.length; j++) {
                if (items[j].collection == collection) {
                    itemCount++;
                }
            }

            // Create arrays for this collection
            uint256[] memory tokenIds = new uint256[](itemCount);
            uint256[] memory amounts = new uint256[](itemCount);
            uint256 ethPayment = 0;
            uint256 erc20Payment = 0;
            address erc20Token = address(0);

            // Fill arrays and determine payment method
            uint256 currentIndex = 0;
            for (uint256 j = 0; j < items.length; j++) {
                if (items[j].collection == collection) {
                    tokenIds[currentIndex] = items[j].tokenId;
                    amounts[currentIndex] = items[j].amount;

                    // Get payment info for this item
                    BlueprintERC1155 collectionContract = BlueprintERC1155(
                        collection
                    );
                    (
                        uint256 ethPrice,
                        uint256 erc20Price,
                        address acceptedERC20,
                        ,
                        ,
                        ,
                        bool ethEnabled,
                        bool erc20Enabled
                    ) = collectionContract.drops(items[j].tokenId);

                    // Determine payment method based on user preference
                    bool canUseETH = ethEnabled && ethPrice > 0;
                    bool canUseERC20 = erc20Enabled &&
                        acceptedERC20 != address(0) &&
                        erc20Price > 0;

                    // Respect user's payment preference
                    bool shouldUseETH;
                    if (canUseETH && canUseERC20) {
                        // Both available - use user's preference
                        shouldUseETH = preferETH;
                    } else if (canUseETH) {
                        // Only ETH available
                        shouldUseETH = true;
                    } else {
                        // Only ERC20 available (or neither, but that's caught in validation)
                        shouldUseETH = false;
                    }

                    if (shouldUseETH) {
                        ethPayment += ethPrice * items[j].amount;
                    } else {
                        erc20Payment += erc20Price * items[j].amount;
                        erc20Token = acceptedERC20;
                    }

                    currentIndex++;
                }
            }

            collectionData[i] = MixedCollectionData({
                collection: collection,
                tokenIds: tokenIds,
                amounts: amounts,
                ethPayment: ethPayment,
                erc20Token: erc20Token,
                erc20Payment: erc20Payment
            });
        }

        return collectionData;
    }

    /**
     * @dev Executes mixed batch mints with both ETH and ERC20 payments
     * @param to Recipient address
     * @param collectionData Array of collection mint data
     * @param referrer Optional referrer address for tracking
     */
    function _executeMixedBatchMints(
        address to,
        MixedCollectionData[] memory collectionData,
        address referrer
    ) internal {
        for (uint256 i = 0; i < collectionData.length; i++) {
            MixedCollectionData memory data = collectionData[i];
            BlueprintERC1155 collection = BlueprintERC1155(data.collection);

            if (data.ethPayment > 0) {
                // Use ETH payment with referrer
                collection.batchMint{value: data.ethPayment}(
                    to,
                    data.tokenIds,
                    data.amounts,
                    referrer
                );
            } else if (data.erc20Payment > 0 && data.erc20Token != address(0)) {
                // Use ERC20 payment
                IERC20 token = IERC20(data.erc20Token);
                token.safeTransferFrom(
                    msg.sender,
                    address(this),
                    data.erc20Payment
                );

                // Approve the collection to spend tokens
                token.forceApprove(data.collection, data.erc20Payment);

                // Try batch ERC20 mint with referrer (new signature for v2+ collections)
                try
                    collection.batchMintWithERC20(
                        to,
                        data.tokenIds,
                        data.amounts,
                        referrer
                    )
                {
                    // success with referrer
                } catch {
                    // Fall back to old signature (v1 collections without referrer support)
                    try
                        collection.batchMintWithERC20(
                            to,
                            data.tokenIds,
                            data.amounts
                        )
                    {
                        // success without referrer
                    } catch {
                        // Both attempts failed - reset approval and revert
                        token.forceApprove(data.collection, 0);
                        revert BlueprintCrossBatchMinter__FunctionNotSupported(
                            bytes4(
                                keccak256(
                                    "batchMintWithERC20(address,uint256[],uint256[])"
                                )
                            )
                        );
                    }
                }

                // Reset approval for security
                token.forceApprove(data.collection, 0);
            }

            // Emit events for each item processed
            for (uint256 j = 0; j < data.tokenIds.length; j++) {
                emit BatchMintItemProcessed(
                    data.collection,
                    data.tokenIds[j],
                    data.amounts[j],
                    to
                );
            }
        }
    }

    /**
     * @dev Get payment estimate for mixed batch minting
     * @notice This function will revert with specific errors if items are invalid (provides better error context than isValid flag)
     * @param items Array of mint items
     * @param erc20Tokens Array of potential ERC20 tokens
     * @param preferETH If true, prefer ETH for drops that accept both; if false, prefer ERC20
     * @return ethRequired Total ETH required
     * @return erc20Requirements Array of ERC20 requirements
     */
    function getMixedPaymentEstimate(
        BatchMintItem[] calldata items,
        address[] calldata erc20Tokens,
        bool preferETH
    )
        external
        view
        returns (
            uint256 ethRequired,
            ERC20Requirement[] memory erc20Requirements
        )
    {
        if (items.length == 0) {
            revert BlueprintCrossBatchMinter__InvalidArrayLength();
        }

        MixedPaymentInfo memory info = _analyzeMixedPaymentRequirements(
            items,
            erc20Tokens,
            preferETH
        );

        return (info.totalETHRequired, info.erc20Requirements);
    }
}
