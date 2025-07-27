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
    error BlueprintCrossBatchMinter__InsufficientPayment(uint256 required, uint256 provided);
    error BlueprintCrossBatchMinter__MixedPaymentMethods();
    error BlueprintCrossBatchMinter__RefundFailed();
    error BlueprintCrossBatchMinter__InvalidFactory();
    error BlueprintCrossBatchMinter__InsufficientERC20Balance(uint256 required, uint256 balance);
    error BlueprintCrossBatchMinter__InsufficientERC20Allowance(uint256 required, uint256 allowance);
    error BlueprintCrossBatchMinter__DropNotActive();
    error BlueprintCrossBatchMinter__DropNotStarted();
    error BlueprintCrossBatchMinter__DropEnded();
    error BlueprintCrossBatchMinter__ETHNotEnabled();
    error BlueprintCrossBatchMinter__ERC20NotEnabled();
    error BlueprintCrossBatchMinter__InvalidERC20Address();

    // ===== ROLES =====
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ===== STRUCTS =====
    struct BatchMintItem {
        address collection;     // Address of the BlueprintERC1155 collection
        uint256 tokenId;       // Token ID to mint
        uint256 amount;        // Amount to mint
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
    function initialize(
        address _factory,
        address _admin
    ) public initializer {
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
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    /**
     * @dev Updates the factory address (admin only)
     * @param _factory New factory address
     */
    function setFactory(address _factory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_factory == address(0)) {
            revert BlueprintCrossBatchMinter__InvalidFactory();
        }
        factory = BlueprintERC1155Factory(_factory);
    }

    /**
     * @dev Batch mint across multiple collections using ETH payments
     * @param to Recipient address for all mints
     * @param items Array of mint items specifying collection, tokenId, and amount
     */
    function batchMintAcrossCollections(
        address to,
        BatchMintItem[] calldata items
    ) external payable nonReentrant {
        if (items.length == 0) {
            revert BlueprintCrossBatchMinter__InvalidArrayLength();
        }

        // Analyze payment requirements and validate all items
        PaymentInfo memory paymentInfo = _analyzePaymentRequirements(items, true); // ETH mode

        if (paymentInfo.mixedPaymentMethods) {
            revert BlueprintCrossBatchMinter__MixedPaymentMethods();
        }

        if (!paymentInfo.hasETHPayments) {
            revert BlueprintCrossBatchMinter__MixedPaymentMethods();
        }

        if (msg.value < paymentInfo.totalETHRequired) {
            revert BlueprintCrossBatchMinter__InsufficientPayment(
                paymentInfo.totalETHRequired,
                msg.value
            );
        }

        // Group items by collection for efficient batch processing
        CollectionMintData[] memory collectionData = _groupItemsByCollection(items, true);

        // Execute mints for each collection
        _executeBatchMints(to, collectionData, true, address(0));

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
     * @dev Batch mint across multiple collections using ERC20 payments
     * @param to Recipient address for all mints
     * @param items Array of mint items specifying collection, tokenId, and amount
     * @param erc20Token ERC20 token address for payment (must be consistent across all collections)
     */
    function batchMintAcrossCollectionsWithERC20(
        address to,
        BatchMintItem[] calldata items,
        address erc20Token
    ) external nonReentrant {
        if (items.length == 0) {
            revert BlueprintCrossBatchMinter__InvalidArrayLength();
        }

        // Analyze payment requirements and validate all items
        PaymentInfo memory paymentInfo = _analyzePaymentRequirements(items, false); // ERC20 mode

        if (paymentInfo.mixedPaymentMethods) {
            revert BlueprintCrossBatchMinter__MixedPaymentMethods();
        }

        if (!paymentInfo.hasERC20Payments) {
            revert BlueprintCrossBatchMinter__MixedPaymentMethods();
        }

        if (paymentInfo.erc20Token != erc20Token) {
            revert BlueprintCrossBatchMinter__MixedPaymentMethods();
        }

        IERC20 token = IERC20(erc20Token);

        // Check user balance and allowance
        uint256 userBalance = token.balanceOf(msg.sender);
        if (userBalance < paymentInfo.totalERC20Required) {
            revert BlueprintCrossBatchMinter__InsufficientERC20Balance(
                paymentInfo.totalERC20Required,
                userBalance
            );
        }

        uint256 allowance = token.allowance(msg.sender, address(this));
        if (allowance < paymentInfo.totalERC20Required) {
            revert BlueprintCrossBatchMinter__InsufficientERC20Allowance(
                paymentInfo.totalERC20Required,
                allowance
            );
        }

        // Group items by collection for efficient batch processing
        CollectionMintData[] memory collectionData = _groupItemsByCollection(items, false);

        // Execute mints for each collection
        _executeBatchMints(to, collectionData, false, erc20Token);

        emit CrossCollectionBatchMint(
            msg.sender,
            to,
            collectionData.length,
            items.length,
            erc20Token,
            paymentInfo.totalERC20Required
        );
    }

    /**
     * @dev Batch mint across multiple collections using MIXED payment methods (ETH + ERC20)
     * This enables true shopping cart experience where different drops can use different payment methods
     * @param to Recipient address for all mints
     * @param items Array of mint items specifying collection, tokenId, and amount
     * @param erc20Tokens Array of ERC20 token addresses that will be used (for approval checking)
     */
    function batchMintAcrossCollectionsMixed(
        address to,
        BatchMintItem[] calldata items,
        address[] calldata erc20Tokens
    ) external payable nonReentrant {
        if (items.length == 0) {
            revert BlueprintCrossBatchMinter__InvalidArrayLength();
        }

        // Analyze payment requirements for mixed mode
        MixedPaymentInfo memory paymentInfo = _analyzeMixedPaymentRequirements(items, erc20Tokens);

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
                    revert BlueprintCrossBatchMinter__InsufficientERC20Balance(req.amount, userBalance);
                }

                uint256 allowance = token.allowance(msg.sender, address(this));
                if (allowance < req.amount) {
                    revert BlueprintCrossBatchMinter__InsufficientERC20Allowance(req.amount, allowance);
                }
            }
        }

        // Group items by collection and payment method
        MixedCollectionData[] memory collectionData = _groupItemsByCollectionMixed(items);

        // Execute mints for each collection with appropriate payment method
        _executeMixedBatchMints(to, collectionData, paymentInfo);

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
     * @dev Get total payment required for a batch of items (useful for frontend estimation)
     * @param items Array of mint items
     * @param useETH Whether to calculate for ETH (true) or ERC20 (false)
     * @return totalPayment Total payment required
     * @return paymentToken Address of payment token (address(0) for ETH)
     * @return isValid Whether all items are valid for minting
     */
    function getPaymentEstimate(
        BatchMintItem[] calldata items,
        bool useETH
    ) external view returns (
        uint256 totalPayment,
        address paymentToken,
        bool isValid
    ) {
        if (items.length == 0) {
            return (0, address(0), false);
        }

        try this._analyzePaymentRequirementsView(items, useETH) returns (PaymentInfo memory info) {
            isValid = !info.mixedPaymentMethods;
            if (useETH) {
                totalPayment = info.totalETHRequired;
                paymentToken = address(0);
                isValid = isValid && info.hasETHPayments;
            } else {
                totalPayment = info.totalERC20Required;
                paymentToken = info.erc20Token;
                isValid = isValid && info.hasERC20Payments;
            }
        } catch {
            isValid = false;
        }
    }

    /**
     * @dev External view function for payment analysis (used by getPaymentEstimate)
     */
    function _analyzePaymentRequirementsView(
        BatchMintItem[] calldata items,
        bool useETH
    ) external view returns (PaymentInfo memory) {
        return _analyzePaymentRequirements(items, useETH);
    }

    /**
     * @dev Analyzes payment requirements for a batch of items
     * @param items Array of mint items
     * @param useETH Whether analyzing for ETH payments
     * @return PaymentInfo struct with payment analysis
     */
    function _analyzePaymentRequirements(
        BatchMintItem[] calldata items,
        bool useETH
    ) internal view returns (PaymentInfo memory) {
        PaymentInfo memory info;
        
        // First pass: validate basic requirements and collect payment method information
        bool hasETHOnlyDrops = false;
        bool hasERC20OnlyDrops = false;
        bool hasMixedDrops = false;
        
        for (uint256 i = 0; i < items.length; i++) {
            BatchMintItem calldata item = items[i];
            
            if (item.amount == 0) {
                revert BlueprintCrossBatchMinter__ZeroAmount();
            }

            // Validate collection is deployed by factory
            if (!factory.isDeployedCollection(item.collection)) {
                revert BlueprintCrossBatchMinter__InvalidCollection(item.collection);
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

            // Categorize payment methods
            bool supportsETH = ethEnabled;
            bool supportsERC20 = erc20Enabled && acceptedERC20 != address(0);
            
            if (supportsETH && supportsERC20) {
                hasMixedDrops = true;
            } else if (supportsETH && !supportsERC20) {
                hasETHOnlyDrops = true;
            } else if (!supportsETH && supportsERC20) {
                hasERC20OnlyDrops = true;
            }
            
            // Calculate payment amounts
            if (useETH) {
                info.totalETHRequired += ethPrice * item.amount;
                info.hasETHPayments = true;
            } else {
                // Ensure all ERC20 drops use the same token
                if (supportsERC20) {
                    if (info.erc20Token == address(0)) {
                        info.erc20Token = acceptedERC20;
                    } else if (info.erc20Token != acceptedERC20) {
                        info.mixedPaymentMethods = true;
                    }
                }
                
                info.totalERC20Required += erc20Price * item.amount;
                info.hasERC20Payments = true;
            }
        }
        
        // Determine if there are mixed payment methods
        if (useETH) {
            // For ETH mode, mixed methods occur only if we have drops that only support ERC20
            info.mixedPaymentMethods = hasERC20OnlyDrops;
        } else {
            // For ERC20 mode, mixed methods occur only if we have drops that only support ETH
            info.mixedPaymentMethods = hasETHOnlyDrops;
        }
        
        // Second pass: validate payment method compatibility if no mixed methods detected
        if (!info.mixedPaymentMethods) {
            for (uint256 i = 0; i < items.length; i++) {
                BatchMintItem calldata item = items[i];
                BlueprintERC1155 collection = BlueprintERC1155(item.collection);
                
                (
                    ,,,,,, // skip other fields
                    bool ethEnabled,
                    bool erc20Enabled
                ) = collection.drops(item.tokenId);

                if (useETH) {
                    if (!ethEnabled) {
                        revert BlueprintCrossBatchMinter__ETHNotEnabled();
                    }
                } else {
                    if (!erc20Enabled) {
                        revert BlueprintCrossBatchMinter__ERC20NotEnabled();
                    }
                }
            }
        }

        return info;
    }

    /**
     * @dev Groups items by collection for efficient batch processing
     * @param items Array of mint items
     * @param useETH Whether using ETH payments
     * @return Array of CollectionMintData for batch processing
     */
    function _groupItemsByCollection(
        BatchMintItem[] calldata items,
        bool useETH
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
        CollectionMintData[] memory collectionData = new CollectionMintData[](uniqueCount);
        
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
            
            // Fill arrays
            uint256 currentIndex = 0;
            for (uint256 j = 0; j < items.length; j++) {
                if (items[j].collection == collection) {
                    tokenIds[currentIndex] = items[j].tokenId;
                    amounts[currentIndex] = items[j].amount;
                    
                    // Calculate payment for this item
                    BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
                    (
                        uint256 ethPrice,
                        uint256 erc20Price,
                        ,,,,,
                    ) = collectionContract.drops(items[j].tokenId);
                    
                    if (useETH) {
                        ethPayment += ethPrice * items[j].amount;
                    } else {
                        erc20Payment += erc20Price * items[j].amount;
                    }
                    
                    currentIndex++;
                }
            }
            
            collectionData[i] = CollectionMintData({
                collection: collection,
                tokenIds: tokenIds,
                amounts: amounts,
                ethPayment: ethPayment,
                erc20Payment: erc20Payment
            });
        }
        
        return collectionData;
    }

    /**
     * @dev Executes batch mints for grouped collection data
     * @param to Recipient address
     * @param collectionData Array of collection mint data
     * @param useETH Whether using ETH payments
     * @param erc20Token ERC20 token address (ignored if useETH is true)
     */
    function _executeBatchMints(
        address to,
        CollectionMintData[] memory collectionData,
        bool useETH,
        address erc20Token
    ) internal {
        for (uint256 i = 0; i < collectionData.length; i++) {
            CollectionMintData memory data = collectionData[i];
            BlueprintERC1155 collection = BlueprintERC1155(data.collection);
            
            if (useETH) {
                // Use batchMint with ETH payment
                collection.batchMint{value: data.ethPayment}(
                    to,
                    data.tokenIds,
                    data.amounts
                );
            } else {
                // Transfer tokens from user to this contract for this collection
                IERC20 token = IERC20(erc20Token);
                token.safeTransferFrom(
                    msg.sender,
                    address(this),
                    data.erc20Payment
                );
                
                // Approve the collection to spend tokens
                token.forceApprove(data.collection, data.erc20Payment);
                
                // Use batchMintWithERC20
                collection.batchMintWithERC20(
                    to,
                    data.tokenIds,
                    data.amounts
                );
                
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
     * @dev Check if user can perform a cross-collection batch mint
     * @param user User address to check
     * @param items Array of mint items
     * @param useETH Whether checking for ETH payments
     * @return canMint Whether the user can perform the mint
     * @return totalRequired Total payment required
     * @return paymentToken Payment token address (address(0) for ETH)
     */
    function checkBatchMintEligibility(
        address user,
        BatchMintItem[] calldata items,
        bool useETH
    ) external view returns (
        bool canMint,
        uint256 totalRequired,
        address paymentToken
    ) {
        if (items.length == 0) {
            return (false, 0, address(0));
        }

        try this._analyzePaymentRequirementsView(items, useETH) returns (PaymentInfo memory info) {
            if (info.mixedPaymentMethods) {
                return (false, 0, address(0));
            }

            if (useETH) {
                if (!info.hasETHPayments) {
                    return (false, 0, address(0));
                }
                totalRequired = info.totalETHRequired;
                paymentToken = address(0);
                canMint = user.balance >= totalRequired;
            } else {
                if (!info.hasERC20Payments) {
                    return (false, 0, address(0));
                }
                totalRequired = info.totalERC20Required;
                paymentToken = info.erc20Token;
                
                IERC20 token = IERC20(paymentToken);
                uint256 userBalance = token.balanceOf(user);
                uint256 allowance = token.allowance(user, address(this));
                
                canMint = userBalance >= totalRequired && allowance >= totalRequired;
            }
        } catch {
            canMint = false;
        }
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

    // ===== MIXED PAYMENT HELPER FUNCTIONS =====

    /**
     * @dev Analyzes payment requirements for mixed payment batch
     * @param items Array of mint items
     * @param erc20Tokens Array of ERC20 tokens that might be used
     * @return MixedPaymentInfo with payment requirements
     */
    function _analyzeMixedPaymentRequirements(
        BatchMintItem[] calldata items,
        address[] calldata erc20Tokens
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
                revert BlueprintCrossBatchMinter__InvalidCollection(item.collection);
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
            bool useETH = ethEnabled && ethPrice > 0;
            bool useERC20 = erc20Enabled && acceptedERC20 != address(0) && erc20Price > 0;
            
            // Prefer ETH if both are available and ETH price exists
            if (useETH && (!useERC20 || ethPrice > 0)) {
                info.totalETHRequired += ethPrice * item.amount;
            } else if (useERC20) {
                // Find the ERC20 token in our requirements array
                bool found = false;
                for (uint256 j = 0; j < info.erc20Requirements.length; j++) {
                    if (info.erc20Requirements[j].token == acceptedERC20) {
                        info.erc20Requirements[j].amount += erc20Price * item.amount;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    revert BlueprintCrossBatchMinter__InvalidERC20Address();
                }
            } else {
                revert BlueprintCrossBatchMinter__DropNotActive();
            }
        }

        return info;
    }

    /**
     * @dev Groups items by collection for mixed payment processing
     * @param items Array of mint items
     * @return Array of MixedCollectionData
     */
    function _groupItemsByCollectionMixed(
        BatchMintItem[] calldata items
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
        MixedCollectionData[] memory collectionData = new MixedCollectionData[](uniqueCount);
        
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
                    BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
                    (
                        uint256 ethPrice,
                        uint256 erc20Price,
                        address acceptedERC20,
                        ,,,
                        bool ethEnabled,
                        bool erc20Enabled
                    ) = collectionContract.drops(items[j].tokenId);
                    
                    // Determine payment method (prefer ETH if available)
                    bool useETH = ethEnabled && ethPrice > 0;
                    bool useERC20 = erc20Enabled && acceptedERC20 != address(0) && erc20Price > 0;
                    
                    if (useETH && (!useERC20 || ethPrice > 0)) {
                        ethPayment += ethPrice * items[j].amount;
                    } else if (useERC20) {
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
     * @param paymentInfo Payment information
     */
    function _executeMixedBatchMints(
        address to,
        MixedCollectionData[] memory collectionData,
        MixedPaymentInfo memory paymentInfo
    ) internal {
        for (uint256 i = 0; i < collectionData.length; i++) {
            MixedCollectionData memory data = collectionData[i];
            BlueprintERC1155 collection = BlueprintERC1155(data.collection);
            
            if (data.ethPayment > 0) {
                // Use ETH payment
                collection.batchMint{value: data.ethPayment}(
                    to,
                    data.tokenIds,
                    data.amounts
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
                
                // Use batchMintWithERC20
                collection.batchMintWithERC20(
                    to,
                    data.tokenIds,
                    data.amounts
                );
                
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
     * @param items Array of mint items
     * @param erc20Tokens Array of potential ERC20 tokens
     * @return ethRequired Total ETH required
     * @return erc20Requirements Array of ERC20 requirements
     * @return isValid Whether the batch is valid
     */
    function getMixedPaymentEstimate(
        BatchMintItem[] calldata items,
        address[] calldata erc20Tokens
    ) external view returns (
        uint256 ethRequired,
        ERC20Requirement[] memory erc20Requirements,
        bool isValid
    ) {
        if (items.length == 0) {
            return (0, new ERC20Requirement[](0), false);
        }

        try this._analyzeMixedPaymentRequirementsView(items, erc20Tokens) returns (MixedPaymentInfo memory info) {
            return (info.totalETHRequired, info.erc20Requirements, true);
        } catch {
            return (0, new ERC20Requirement[](0), false);
        }
    }

    /**
     * @dev External view function for mixed payment analysis
     */
    function _analyzeMixedPaymentRequirementsView(
        BatchMintItem[] calldata items,
        address[] calldata erc20Tokens
    ) external view returns (MixedPaymentInfo memory) {
        return _analyzeMixedPaymentRequirements(items, erc20Tokens);
    }
} 