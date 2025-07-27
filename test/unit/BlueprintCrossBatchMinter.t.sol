// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/nft/BlueprintERC1155Factory.sol";
import "../../src/nft/BlueprintERC1155.sol";
import "../../src/nft/BlueprintCrossBatchMinter.sol";
import "../mock/MockERC20.sol";
import "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BlueprintCrossBatchMinterTest is Test {
    BlueprintERC1155Factory public factory;
    BlueprintERC1155 public implementation;
    BlueprintCrossBatchMinter public crossBatchMinter;
    MockERC20 public mockERC20;

    address public admin = address(1);
    address public blueprintRecipient = address(2);
    address public creatorRecipient1 = address(3);
    address public creatorRecipient2 = address(4);
    address public treasury = address(5);
    address public rewardPoolRecipient = address(6);
    address public user = address(7);
    
    address public collection1;
    address public collection2;

    uint256 public constant DEFAULT_FEE_BASIS_POINTS = 500; // 5%
    uint256 public constant DEFAULT_MINT_FEE = 0.001 ether;
    uint256 public constant CREATOR_BASIS_POINTS = 1000; // 10%
    uint256 public constant REWARD_POOL_BASIS_POINTS = 200; // 2%

    event CrossCollectionBatchMint(
        address indexed user,
        address indexed recipient,
        uint256 totalCollections,
        uint256 totalItems,
        address indexed paymentToken,
        uint256 totalPayment
    );

    function setUp() public {
        vm.startPrank(admin);

        // Deploy implementation
        implementation = new BlueprintERC1155();

        // Deploy factory logic
        BlueprintERC1155Factory factoryLogic = new BlueprintERC1155Factory();

        // Deploy factory proxy
        bytes memory factoryInitData = abi.encodeWithSelector(
            BlueprintERC1155Factory.initialize.selector,
            address(implementation),
            blueprintRecipient,
            DEFAULT_FEE_BASIS_POINTS,
            DEFAULT_MINT_FEE,
            treasury,
            rewardPoolRecipient,
            REWARD_POOL_BASIS_POINTS,
            admin
        );

        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryLogic), factoryInitData);
        factory = BlueprintERC1155Factory(address(factoryProxy));

        // Deploy cross batch minter logic
        BlueprintCrossBatchMinter crossBatchMinterLogic = new BlueprintCrossBatchMinter();

        // Deploy cross batch minter proxy
        bytes memory crossBatchMinterInitData = abi.encodeWithSelector(
            BlueprintCrossBatchMinter.initialize.selector,
            address(factory),
            admin
        );

        ERC1967Proxy crossBatchMinterProxy = new ERC1967Proxy(address(crossBatchMinterLogic), crossBatchMinterInitData);
        crossBatchMinter = BlueprintCrossBatchMinter(address(crossBatchMinterProxy));

        // Deploy mock ERC20
        mockERC20 = new MockERC20();

        // Create two collections
        collection1 = factory.createCollection(
            "Collection 1 URI",
            creatorRecipient1,
            CREATOR_BASIS_POINTS
        );

        collection2 = factory.createCollection(
            "Collection 2 URI", 
            creatorRecipient2,
            CREATOR_BASIS_POINTS
        );

        vm.stopPrank();

        // Setup user with ETH and ERC20 tokens
        vm.deal(user, 100 ether);
        mockERC20.mint(user, 1000000 * 10**18);
    }

    function test_ShoppingCartScenario_ETH() public {
        vm.startPrank(admin);

        // Create drops in collection 1 (3 drops as per the example)
        uint256 tokenId1_1 = factory.createNewDrop(
            collection1,
            0.1 ether,  // price
            block.timestamp, // start time
            block.timestamp + 1 hours, // end time
            true // active
        );

        uint256 tokenId1_2 = factory.createNewDrop(
            collection1,
            0.15 ether,  // price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenId1_3 = factory.createNewDrop(
            collection1,
            0.2 ether,   // price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        // Create drops in collection 2 (2 drops as per the example)
        uint256 tokenId2_1 = factory.createNewDrop(
            collection2,
            0.12 ether,  // price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenId2_2 = factory.createNewDrop(
            collection2,
            0.18 ether,  // price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        vm.stopPrank();

        // User wants to mint 2 of each drop (shopping cart scenario)
        BlueprintCrossBatchMinter.BatchMintItem[] memory items = 
            new BlueprintCrossBatchMinter.BatchMintItem[](5);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId1_1,
            amount: 2
        });

        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId1_2,
            amount: 2
        });

        items[2] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId1_3,
            amount: 2
        });

        items[3] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: tokenId2_1,
            amount: 2
        });

        items[4] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: tokenId2_2,
            amount: 2
        });

        // Calculate expected total payment
        uint256 expectedTotal = (0.1 ether * 2) + (0.15 ether * 2) + (0.2 ether * 2) + 
                               (0.12 ether * 2) + (0.18 ether * 2);
        // = 0.2 + 0.3 + 0.4 + 0.24 + 0.36 = 1.5 ether

        // Get payment estimate
        (uint256 totalPayment, address paymentToken, bool isValid) = 
            crossBatchMinter.getPaymentEstimate(items, true);

        assertEq(totalPayment, expectedTotal);
        assertEq(paymentToken, address(0)); // ETH
        assertTrue(isValid);

        // Check user eligibility
        (bool canMint, uint256 totalRequired, address requiredToken) = 
            crossBatchMinter.checkBatchMintEligibility(user, items, true);

        assertTrue(canMint);
        assertEq(totalRequired, expectedTotal);
        assertEq(requiredToken, address(0));

        // Perform the cross-collection batch mint
        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit CrossCollectionBatchMint(
            user,
            user,
            2, // 2 collections
            5, // 5 items
            address(0), // ETH
            expectedTotal
        );
        
        crossBatchMinter.batchMintAcrossCollections{value: expectedTotal}(user, items);

        // Verify balances
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1_1), 2);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1_2), 2);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1_3), 2);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, tokenId2_1), 2);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, tokenId2_2), 2);

        // Verify total supplies
        assertEq(BlueprintERC1155(collection1).totalSupply(tokenId1_1), 2);
        assertEq(BlueprintERC1155(collection1).totalSupply(tokenId1_2), 2);
        assertEq(BlueprintERC1155(collection1).totalSupply(tokenId1_3), 2);
        assertEq(BlueprintERC1155(collection2).totalSupply(tokenId2_1), 2);
        assertEq(BlueprintERC1155(collection2).totalSupply(tokenId2_2), 2);
    }

    function test_ShoppingCartScenario_ERC20() public {
        vm.startPrank(admin);

        // Create drops with ERC20 support
        uint256 tokenId1_1 = factory.createNewDropWithERC20(
            collection1,
            0.1 ether,  // ETH price
            100 * 10**18, // ERC20 price
            address(mockERC20),
            block.timestamp,
            block.timestamp + 1 hours,
            true, // active
            true, // ETH enabled
            true  // ERC20 enabled
        );

        uint256 tokenId1_2 = factory.createNewDropWithERC20(
            collection1,
            0.15 ether,
            150 * 10**18,
            address(mockERC20),
            block.timestamp,
            block.timestamp + 1 hours,
            true,
            true,
            true
        );

        uint256 tokenId2_1 = factory.createNewDropWithERC20(
            collection2,
            0.12 ether,
            120 * 10**18,
            address(mockERC20),
            block.timestamp,
            block.timestamp + 1 hours,
            true,
            true,
            true
        );

        vm.stopPrank();

        // Create shopping cart with 3 items
        BlueprintCrossBatchMinter.BatchMintItem[] memory items = 
            new BlueprintCrossBatchMinter.BatchMintItem[](3);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId1_1,
            amount: 2
        });

        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId1_2,
            amount: 1
        });

        items[2] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: tokenId2_1,
            amount: 3
        });

        uint256 expectedTotal = (100 * 10**18 * 2) + (150 * 10**18 * 1) + (120 * 10**18 * 3);
        // = 200 + 150 + 360 = 710 tokens

        // Approve the cross batch minter to spend ERC20 tokens
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), expectedTotal);

        // Get payment estimate for ERC20
        (uint256 totalPayment, address paymentToken, bool isValid) = 
            crossBatchMinter.getPaymentEstimate(items, false);

        assertEq(totalPayment, expectedTotal);
        assertEq(paymentToken, address(mockERC20));
        assertTrue(isValid);

        // Perform the cross-collection batch mint with ERC20
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsWithERC20(user, items, address(mockERC20));

        // Verify balances
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1_1), 2);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1_2), 1);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, tokenId2_1), 3);
    }

    function test_RevertWhen_InvalidCollection() public {
        BlueprintCrossBatchMinter.BatchMintItem[] memory items = 
            new BlueprintCrossBatchMinter.BatchMintItem[](1);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: address(0x123), // Invalid collection
            tokenId: 0,
            amount: 1
        });

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__InvalidCollection.selector,
                address(0x123)
            )
        );
        crossBatchMinter.batchMintAcrossCollections{value: 1 ether}(user, items);
    }

    function test_RevertWhen_MixedPaymentMethods() public {
        vm.startPrank(admin);

        // Create one drop with only ETH
        factory.setDropWithERC20(
            collection1,
            0,
            0.1 ether,  // ETH price
            0,          // No ERC20 price
            address(0), // No ERC20 token
            block.timestamp,
            block.timestamp + 1 hours,
            true,  // active
            true,  // ETH enabled
            false  // ERC20 disabled
        );

        // Create another drop with only ERC20
        factory.setDropWithERC20(
            collection2,
            0,
            0,               // No ETH price
            100 * 10**18,    // ERC20 price
            address(mockERC20),
            block.timestamp,
            block.timestamp + 1 hours,
            true,  // active
            false, // ETH disabled
            true   // ERC20 enabled
        );

        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[] memory items = 
            new BlueprintCrossBatchMinter.BatchMintItem[](2);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: 0,
            amount: 1
        });

        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: 0,
            amount: 1
        });

        vm.prank(user);
        vm.expectRevert(BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__MixedPaymentMethods.selector);
        crossBatchMinter.batchMintAcrossCollections{value: 1 ether}(user, items);
    }

    function test_RevertWhen_InsufficientPayment() public {
        vm.startPrank(admin);

        uint256 tokenId = factory.createNewDrop(
            collection1,
            1 ether,  // Expensive price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[] memory items = 
            new BlueprintCrossBatchMinter.BatchMintItem[](1);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId,
            amount: 1
        });

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__InsufficientPayment.selector,
                1 ether,
                0.5 ether
            )
        );
        crossBatchMinter.batchMintAcrossCollections{value: 0.5 ether}(user, items);
    }

    function test_RefundExcessPayment() public {
        vm.startPrank(admin);

        uint256 tokenId = factory.createNewDrop(
            collection1,
            0.1 ether,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[] memory items = 
            new BlueprintCrossBatchMinter.BatchMintItem[](1);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId,
            amount: 1
        });

        uint256 userBalanceBefore = user.balance;
        uint256 excessPayment = 1 ether; // Much more than needed
        uint256 expectedRefund = excessPayment - 0.1 ether;

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollections{value: excessPayment}(user, items);

        uint256 userBalanceAfter = user.balance;
        assertEq(userBalanceAfter, userBalanceBefore - 0.1 ether);
    }

    function test_EmptyItemsArray() public {
        BlueprintCrossBatchMinter.BatchMintItem[] memory items = 
            new BlueprintCrossBatchMinter.BatchMintItem[](0);

        vm.prank(user);
        vm.expectRevert(BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__InvalidArrayLength.selector);
        crossBatchMinter.batchMintAcrossCollections(user, items);
    }

    function test_ZeroAmount() public {
        vm.startPrank(admin);

        uint256 tokenId = factory.createNewDrop(
            collection1,
            0.1 ether,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[] memory items = 
            new BlueprintCrossBatchMinter.BatchMintItem[](1);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId,
            amount: 0 // Zero amount should revert
        });

        vm.prank(user);
        vm.expectRevert(BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__ZeroAmount.selector);
        crossBatchMinter.batchMintAcrossCollections{value: 1 ether}(user, items);
    }

    function test_PaymentEstimateEdgeCases() public {
        // Test with empty array
        BlueprintCrossBatchMinter.BatchMintItem[] memory emptyItems = 
            new BlueprintCrossBatchMinter.BatchMintItem[](0);

        (uint256 totalPayment, address paymentToken, bool isValid) = 
            crossBatchMinter.getPaymentEstimate(emptyItems, true);

        assertEq(totalPayment, 0);
        assertEq(paymentToken, address(0));
        assertFalse(isValid);
    }

    function test_UpdateFactory() public {
        address newFactory = address(0x456);
        
        vm.prank(admin);
        crossBatchMinter.setFactory(newFactory);
        
        assertEq(address(crossBatchMinter.factory()), newFactory);
    }

    function test_RevertWhen_InvalidFactoryUpdate() public {
        vm.prank(admin);
        vm.expectRevert(BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__InvalidFactory.selector);
        crossBatchMinter.setFactory(address(0));
    }
} 