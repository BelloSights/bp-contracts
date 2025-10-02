// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/nft/BlueprintERC1155Factory.sol";
import "../../src/nft/BlueprintERC1155.sol";
import "../../src/nft/BlueprintCrossBatchMinter.sol";
import "../mock/MockERC20.sol";
import {ERC1967Proxy} from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BlueprintCrossBatchMinterTest is Test {
    BlueprintERC1155Factory public factory;
    BlueprintERC1155 public implementation;
    BlueprintCrossBatchMinter public crossBatchMinter;
    MockERC20 public mockERC20;
    MockERC20 public mockERC20_2;

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

        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryLogic),
            factoryInitData
        );
        factory = BlueprintERC1155Factory(address(factoryProxy));

        // Deploy cross batch minter logic
        BlueprintCrossBatchMinter crossBatchMinterLogic = new BlueprintCrossBatchMinter();

        // Deploy cross batch minter proxy
        bytes memory crossBatchMinterInitData = abi.encodeWithSelector(
            BlueprintCrossBatchMinter.initialize.selector,
            address(factory),
            admin
        );

        ERC1967Proxy crossBatchMinterProxy = new ERC1967Proxy(
            address(crossBatchMinterLogic),
            crossBatchMinterInitData
        );
        crossBatchMinter = BlueprintCrossBatchMinter(
            address(crossBatchMinterProxy)
        );

        // Deploy mock ERC20s
        mockERC20 = new MockERC20();
        mockERC20_2 = new MockERC20();

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
        mockERC20.mint(user, 1000000 * 10 ** 18);
        mockERC20_2.mint(user, 1000000 * 10 ** 18);
    }

    function test_ShoppingCartScenario_ETH() public {
        vm.startPrank(admin);

        // Create drops in collection 1 (3 drops as per the example)
        uint256 tokenId1_1 = factory.createNewDrop(
            collection1,
            0.1 ether, // price
            block.timestamp, // start time
            block.timestamp + 1 hours, // end time
            true // active
        );

        uint256 tokenId1_2 = factory.createNewDrop(
            collection1,
            0.15 ether, // price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenId1_3 = factory.createNewDrop(
            collection1,
            0.2 ether, // price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        // Create drops in collection 2 (2 drops as per the example)
        uint256 tokenId2_1 = factory.createNewDrop(
            collection2,
            0.12 ether, // price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenId2_2 = factory.createNewDrop(
            collection2,
            0.18 ether, // price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        vm.stopPrank();

        // User wants to mint 2 of each drop (shopping cart scenario)
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](5);

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
        uint256 expectedTotal = (0.1 ether * 2) +
            (0.15 ether * 2) +
            (0.2 ether * 2) +
            (0.12 ether * 2) +
            (0.18 ether * 2);
        // = 0.2 + 0.3 + 0.4 + 0.24 + 0.36 = 1.5 ether

        // Get payment estimate
        (uint256 totalPayment, address paymentToken) = crossBatchMinter
            .getPaymentEstimate(items);

        assertEq(totalPayment, expectedTotal);
        assertEq(paymentToken, address(0)); // ETH

        // Check user eligibility
        (
            bool canMint,
            uint256 totalRequired,
            address requiredToken
        ) = crossBatchMinter.checkBatchMintEligibility(user, items);

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

        crossBatchMinter.batchMintAcrossCollections{value: expectedTotal}(
            user,
            items,
            address(0)
        );

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
        // Create ERC20-only drops (ETH disabled to force ERC20 payment in mixed function)
        uint256 tokenId1_1 = factory.createNewDropWithERC20(
            collection1,
            0, // No ETH price
            address(mockERC20),
            100 * 10 ** 18, // ERC20 price
            block.timestamp,
            block.timestamp + 1 hours,
            true, // active
            false // ETH disabled
        );

        uint256 tokenId1_2 = factory.createNewDropWithERC20(
            collection1,
            0, // No ETH price
            address(mockERC20),
            150 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true,
            false // ETH disabled
        );

        uint256 tokenId2_1 = factory.createNewDropWithERC20(
            collection2,
            0, // No ETH price
            address(mockERC20),
            120 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true,
            false // ETH disabled
        );

        vm.stopPrank();

        // Create shopping cart with 3 items
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](3);

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

        uint256 expectedTotal = (100 * 10 ** 18 * 2) +
            (150 * 10 ** 18 * 1) +
            (120 * 10 ** 18 * 3);
        // = 200 + 150 + 360 = 710 tokens

        // Approve the cross batch minter to spend ERC20 tokens
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), expectedTotal);

        // Get mixed payment estimate for ERC20 only
        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[]
                memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, false); // preferETH = false for ERC20 payment

        assertEq(ethRequired, 0); // No ETH required
        assertEq(erc20Requirements.length, 1);
        assertEq(erc20Requirements[0].token, address(mockERC20));
        assertEq(erc20Requirements[0].amount, expectedTotal);

        // Perform the cross-collection batch mint with ERC20 using mixed function
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        // Verify balances
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1_1), 2);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1_2), 1);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, tokenId2_1), 3);
    }

    function test_RevertWhen_InvalidCollection() public {
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: address(0x123), // Invalid collection
            tokenId: 0,
            amount: 1
        });

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintCrossBatchMinter
                    .BlueprintCrossBatchMinter__InvalidCollection
                    .selector,
                address(0x123)
            )
        );
        crossBatchMinter.batchMintAcrossCollections{value: 1 ether}(
            user,
            items,
            address(0)
        );
    }

    function test_MixedPaymentMethods_ETH_And_ERC20() public {
        vm.startPrank(admin);

        // Create one drop with ETH payment
        uint256 ethTokenId = factory.createNewDrop(
            collection1,
            0.1 ether, // ETH price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        // Create another drop with ERC20 payment
        uint256 erc20TokenId = factory.createNewDropWithERC20(
            collection2,
            0, // No ETH price
            address(mockERC20),
            100 * 10 ** 18, // ERC20 price
            block.timestamp,
            block.timestamp + 1 hours,
            true, // active
            false // ETH disabled
        );

        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: ethTokenId,
            amount: 1
        });

        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: erc20TokenId,
            amount: 1
        });

        // Approve ERC20 tokens for the cross batch minter
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 100 * 10 ** 18);

        uint256 userEthBefore = user.balance;
        uint256 userErc20Before = mockERC20.balanceOf(user);

        // Use the mixed payment method function
        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0.1 ether}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        // Verify balances
        assertEq(BlueprintERC1155(collection1).balanceOf(user, ethTokenId), 1);
        assertEq(
            BlueprintERC1155(collection2).balanceOf(user, erc20TokenId),
            1
        );

        // Verify payments were deducted
        assertEq(user.balance, userEthBefore - 0.1 ether);
        assertEq(mockERC20.balanceOf(user), userErc20Before - 100 * 10 ** 18);
    }

    function test_MixedPaymentMethods_Multiple_ERC20_Tokens() public {
        // Deploy second ERC20 token
        MockERC20 secondERC20 = new MockERC20();
        secondERC20.mint(user, 1000000 * 10 ** 18);

        vm.startPrank(admin);

        // Create drops with different ERC20 tokens
        uint256 erc20TokenId1 = factory.createNewDropWithERC20(
            collection1,
            0, // No ETH price
            address(mockERC20),
            100 * 10 ** 18, // ERC20 price
            block.timestamp,
            block.timestamp + 1 hours,
            true, // active
            false // ETH disabled
        );

        uint256 erc20TokenId2 = factory.createNewDropWithERC20(
            collection2,
            0, // No ETH price
            address(secondERC20),
            200 * 10 ** 18, // ERC20 price
            block.timestamp,
            block.timestamp + 1 hours,
            true, // active
            false // ETH disabled
        );

        vm.stopPrank();

        // Create shopping cart with multiple ERC20 tokens
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: erc20TokenId1,
            amount: 2 // 2 * 100 tokens = 200 tokens (mockERC20)
        });

        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: erc20TokenId2,
            amount: 1 // 1 * 200 tokens = 200 tokens (secondERC20)
        });

        // Approve both ERC20 tokens
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 200 * 10 ** 18);

        vm.prank(user);
        secondERC20.approve(address(crossBatchMinter), 200 * 10 ** 18);

        // Set up ERC20 tokens array
        address[] memory erc20Tokens = new address[](2);
        erc20Tokens[0] = address(mockERC20);
        erc20Tokens[1] = address(secondERC20);

        // Record balances before
        uint256 userErc20Before = mockERC20.balanceOf(user);
        uint256 userErc20_2Before = secondERC20.balanceOf(user);

        // Execute mixed ERC20 payment transaction (no ETH needed)
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        // Verify all NFTs were minted
        assertEq(
            BlueprintERC1155(collection1).balanceOf(user, erc20TokenId1),
            2
        );
        assertEq(
            BlueprintERC1155(collection2).balanceOf(user, erc20TokenId2),
            1
        );

        // Verify ERC20 payments were deducted correctly
        assertEq(mockERC20.balanceOf(user), userErc20Before - 200 * 10 ** 18);
        assertEq(
            secondERC20.balanceOf(user),
            userErc20_2Before - 200 * 10 ** 18
        );
    }

    function test_ERC20_Mode_Revert_When_ERC20_Not_Enabled() public {
        // Create ETH-only drop (no ERC20 enabled)
        vm.startPrank(admin);
        uint256 tid = factory.createNewDrop(
            collection1,
            0.1 ether,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tid,
            amount: 1
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        // Since the drop only accepts ETH and mixed function prefers ETH when available,
        // it will try to use ETH but fail because no ETH was sent (msg.value = 0)
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintCrossBatchMinter
                    .BlueprintCrossBatchMinter__InsufficientPayment
                    .selector,
                0.1 ether,
                0
            )
        );
        crossBatchMinter.batchMintAcrossCollectionsMixed(
            user,
            items,
            erc20Tokens,
            address(0)
        );
    }

    function test_Revert_FunctionNotSupported_When_No_PerItem_Either() public {
        // Use a second ERC20 token to mismatch approvals and force per-item failure after batch try
        vm.startPrank(admin);
        uint256 t = factory.createNewDropWithERC20(
            collection1,
            0,
            address(mockERC20_2),
            100 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true,
            false
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: t,
            amount: 1
        });

        // Provide wrong ERC20 token in the array (mockERC20 instead of mockERC20_2)
        // This will cause InvalidERC20Address error during payment analysis
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 100 * 10 ** 18);

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        vm.prank(user);
        vm.expectRevert(
            BlueprintCrossBatchMinter
                .BlueprintCrossBatchMinter__InvalidERC20Address
                .selector
        );
        crossBatchMinter.batchMintAcrossCollectionsMixed(
            user,
            items,
            erc20Tokens,
            address(0)
        );
    }

    function test_RevertWhen_InsufficientPayment() public {
        vm.startPrank(admin);

        uint256 tokenId = factory.createNewDrop(
            collection1,
            1 ether, // Expensive price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId,
            amount: 1
        });

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintCrossBatchMinter
                    .BlueprintCrossBatchMinter__InsufficientPayment
                    .selector,
                1 ether,
                0.5 ether
            )
        );
        crossBatchMinter.batchMintAcrossCollections{value: 0.5 ether}(
            user,
            items,
            address(0)
        );
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

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId,
            amount: 1
        });

        uint256 userBalanceBefore = user.balance;
        uint256 excessPayment = 1 ether; // Much more than needed

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollections{value: excessPayment}(
            user,
            items,
            address(0)
        );

        uint256 userBalanceAfter = user.balance;
        assertEq(userBalanceAfter, userBalanceBefore - 0.1 ether);
    }

    function test_EmptyItemsArray() public {
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](0);

        vm.prank(user);
        vm.expectRevert(
            BlueprintCrossBatchMinter
                .BlueprintCrossBatchMinter__InvalidArrayLength
                .selector
        );
        crossBatchMinter.batchMintAcrossCollections(user, items, address(0));
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

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);

        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId,
            amount: 0 // Zero amount should revert
        });

        vm.prank(user);
        vm.expectRevert(
            BlueprintCrossBatchMinter
                .BlueprintCrossBatchMinter__ZeroAmount
                .selector
        );
        crossBatchMinter.batchMintAcrossCollections{value: 1 ether}(
            user,
            items,
            address(0)
        );
    }

    function test_PaymentEstimateEdgeCases() public {
        // Test with empty array - should revert
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory emptyItems = new BlueprintCrossBatchMinter.BatchMintItem[](
                0
            );

        vm.expectRevert(
            BlueprintCrossBatchMinter
                .BlueprintCrossBatchMinter__InvalidArrayLength
                .selector
        );
        crossBatchMinter.getPaymentEstimate(emptyItems);
    }

    function test_UpdateFactory() public {
        address newFactory = address(0x456);

        vm.prank(admin);
        crossBatchMinter.setFactory(newFactory);

        assertEq(address(crossBatchMinter.factory()), newFactory);
    }

    function test_RevertWhen_InvalidFactoryUpdate() public {
        vm.prank(admin);
        vm.expectRevert(
            BlueprintCrossBatchMinter
                .BlueprintCrossBatchMinter__InvalidFactory
                .selector
        );
        crossBatchMinter.setFactory(address(0));
    }

    function test_UserChoosesPaymentMethod_DualPaymentDrop() public {
        // Create a drop that accepts BOTH ETH and ERC20
        vm.startPrank(admin);
        uint256 tokenId = factory.createNewDropWithERC20(
            collection1,
            0.1 ether, // ETH price
            address(mockERC20),
            100 * 10 ** 18, // ERC20 price
            block.timestamp,
            block.timestamp + 1 hours,
            true, // active
            true // ETH enabled
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId,
            amount: 1
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        // SCENARIO 1: User prefers ETH (sends msg.value > 0)
        {
            (
                uint256 ethRequired,
                BlueprintCrossBatchMinter.ERC20Requirement[]
                    memory erc20Requirements
            ) = crossBatchMinter.getMixedPaymentEstimate(
                    items,
                    erc20Tokens,
                    true
                ); // preferETH = true

            assertEq(
                ethRequired,
                0.1 ether,
                "Should require ETH when preferETH=true"
            );
            assertEq(
                erc20Requirements[0].amount,
                0,
                "Should not require ERC20 when preferETH=true"
            );

            // Execute the mint with ETH
            vm.prank(user);
            crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0.1 ether}(
                user,
                items,
                erc20Tokens,
                address(0)
            );

            assertEq(
                BlueprintERC1155(collection1).balanceOf(user, tokenId),
                1,
                "Should have minted with ETH"
            );
        }

        // SCENARIO 2: User prefers ERC20 (sends msg.value = 0)
        {
            (
                uint256 ethRequired,
                BlueprintCrossBatchMinter.ERC20Requirement[]
                    memory erc20Requirements
            ) = crossBatchMinter.getMixedPaymentEstimate(
                    items,
                    erc20Tokens,
                    false
                ); // preferETH = false

            assertEq(
                ethRequired,
                0,
                "Should not require ETH when preferETH=false"
            );
            assertEq(
                erc20Requirements[0].amount,
                100 * 10 ** 18,
                "Should require ERC20 when preferETH=false"
            );

            // Approve and execute the mint with ERC20
            vm.prank(user);
            mockERC20.approve(address(crossBatchMinter), 100 * 10 ** 18);

            vm.prank(user);
            crossBatchMinter.batchMintAcrossCollectionsMixed(
                user,
                items,
                erc20Tokens,
                address(0)
            ); // NO msg.value sent

            assertEq(
                BlueprintERC1155(collection1).balanceOf(user, tokenId),
                2,
                "Should have minted with ERC20"
            );
            assertEq(
                mockERC20.balanceOf(user),
                999900 * 10 ** 18,
                "User should have paid 100 ERC20 tokens (1M - 100)"
            );
        }
    }

    // ===== REFERRAL TESTS =====

    function test_Referral_ETH_Payment() public {
        // Setup
        vm.startPrank(admin);
        uint256 tokenId1 = factory.createNewDrop(
            collection1,
            0.1 ether,
            block.timestamp,
            block.timestamp + 1 days,
            true
        );
        uint256 tokenId2 = factory.createNewDrop(
            collection2,
            0.2 ether,
            block.timestamp,
            block.timestamp + 1 days,
            true
        );
        vm.stopPrank();

        vm.deal(user, 1 ether);

        // Setup referrer
        address referrer = makeAddr("referrer");

        // Create batch items
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId1,
            amount: 1
        });
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: tokenId2,
            amount: 1
        });

        // Expect referral events from each collection (check indexed params only)
        vm.expectEmit(true, true, true, false, address(collection1));
        emit BlueprintERC1155.ReferredBatchMint(
            address(crossBatchMinter),
            referrer,
            user,
            new uint256[](0),
            new uint256[](0),
            address(0),
            0,
            0
        );

        vm.expectEmit(true, true, true, false, address(collection2));
        emit BlueprintERC1155.ReferredBatchMint(
            address(crossBatchMinter),
            referrer,
            user,
            new uint256[](0),
            new uint256[](0),
            address(0),
            0,
            0
        );

        // Execute with referrer
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollections{value: 0.3 ether}(
            user,
            items,
            referrer
        );

        // Verify mints succeeded
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1), 1);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, tokenId2), 1);
    }

    function test_Referral_ERC20_Payment() public {
        // Setup
        vm.startPrank(admin);
        uint256 tokenId1 = factory.createNewDropWithERC20(
            collection1,
            0,
            address(mockERC20),
            100 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 days,
            true,
            false
        );
        uint256 tokenId2 = factory.createNewDropWithERC20(
            collection2,
            0,
            address(mockERC20),
            200 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 days,
            true,
            false
        );
        vm.stopPrank();

        // Setup user with ERC20 tokens
        vm.prank(user);
        mockERC20.mint(user, 1000 * 10 ** 18);
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 1000 * 10 ** 18);

        // Setup referrer
        address referrer = makeAddr("referrer");

        // Create batch items
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId1,
            amount: 1
        });
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: tokenId2,
            amount: 1
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        // Expect referral events from each collection (check indexed params only)
        vm.expectEmit(true, true, true, false, address(collection1));
        emit BlueprintERC1155.ReferredBatchMint(
            address(crossBatchMinter),
            referrer,
            user,
            new uint256[](0),
            new uint256[](0),
            address(0),
            0,
            0
        );

        vm.expectEmit(true, true, true, false, address(collection2));
        emit BlueprintERC1155.ReferredBatchMint(
            address(crossBatchMinter),
            referrer,
            user,
            new uint256[](0),
            new uint256[](0),
            address(0),
            0,
            0
        );

        // Execute with referrer
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed(
            user,
            items,
            erc20Tokens,
            referrer
        );

        // Verify mints succeeded
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1), 1);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, tokenId2), 1);
    }

    function test_Referral_MixedPayments() public {
        // Setup: One collection accepts ETH, another accepts ERC20
        vm.startPrank(admin);
        uint256 ethTokenId = factory.createNewDrop(
            collection1,
            0.1 ether,
            block.timestamp,
            block.timestamp + 1 days,
            true
        );
        uint256 erc20TokenId = factory.createNewDropWithERC20(
            collection2,
            0,
            address(mockERC20),
            100 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 days,
            true,
            false
        );
        vm.stopPrank();

        // Setup user
        vm.deal(user, 1 ether);
        vm.prank(user);
        mockERC20.mint(user, 1000 * 10 ** 18);
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 1000 * 10 ** 18);

        // Setup referrer
        address referrer = makeAddr("referrer");

        // Create batch items
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: ethTokenId,
            amount: 1
        });
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: erc20TokenId,
            amount: 1
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        // Expect referral event for ETH payment (check indexed params only)
        vm.expectEmit(true, true, true, false, address(collection1));
        emit BlueprintERC1155.ReferredBatchMint(
            address(crossBatchMinter),
            referrer,
            user,
            new uint256[](0),
            new uint256[](0),
            address(0),
            0,
            0
        );

        // Expect referral event for ERC20 payment (check indexed params only)
        vm.expectEmit(true, true, true, false, address(collection2));
        emit BlueprintERC1155.ReferredBatchMint(
            address(crossBatchMinter),
            referrer,
            user,
            new uint256[](0),
            new uint256[](0),
            address(0),
            0,
            0
        );

        // Execute with referrer
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0.1 ether}(
            user,
            items,
            erc20Tokens,
            referrer
        );

        // Verify mints succeeded
        assertEq(BlueprintERC1155(collection1).balanceOf(user, ethTokenId), 1);
        assertEq(
            BlueprintERC1155(collection2).balanceOf(user, erc20TokenId),
            1
        );
    }

    function test_NoReferral_WithZeroAddress() public {
        // Setup
        vm.startPrank(admin);
        uint256 tokenId1 = factory.createNewDrop(
            collection1,
            0.1 ether,
            block.timestamp,
            block.timestamp + 1 days,
            true
        );
        vm.stopPrank();

        vm.deal(user, 1 ether);

        // Create batch items
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId1,
            amount: 1
        });

        // Should emit TokensBatchMinted but NOT ReferredBatchMint (check indexed params only)
        vm.expectEmit(true, false, false, false, address(collection1));
        emit BlueprintERC1155.TokensBatchMinted(
            user,
            new uint256[](0),
            new uint256[](0)
        );

        // Execute with address(0) referrer - should NOT emit referral event
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollections{value: 0.1 ether}(
            user,
            items,
            address(0) // No referrer
        );

        // Verify mint succeeded
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1), 1);
    }

    function test_Referral_MultipleItemsSameCollection() public {
        // Setup
        vm.startPrank(admin);
        uint256 tokenId1 = factory.createNewDrop(
            collection1,
            0.1 ether,
            block.timestamp,
            block.timestamp + 1 days,
            true
        );
        uint256 tokenId2 = factory.createNewDrop(
            collection1,
            0.2 ether,
            block.timestamp,
            block.timestamp + 1 days,
            true
        );
        vm.stopPrank();

        vm.deal(user, 1 ether);

        // Setup referrer
        address referrer = makeAddr("referrer");

        // Create batch items from same collection
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId1,
            amount: 2
        });
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId2,
            amount: 1
        });

        // Expected arrays for the batch mint
        uint256[] memory expectedTokenIds = new uint256[](2);
        expectedTokenIds[0] = tokenId1;
        expectedTokenIds[1] = tokenId2;

        uint256[] memory expectedAmounts = new uint256[](2);
        expectedAmounts[0] = 2;
        expectedAmounts[1] = 1;

        uint256 expectedPayment = (0.1 ether * 2) + (0.2 ether * 1); // 0.4 ether

        // Expect single referral event for all items in the collection
        vm.expectEmit(true, true, true, true, address(collection1));
        emit BlueprintERC1155.ReferredBatchMint(
            address(crossBatchMinter),
            referrer,
            user,
            expectedTokenIds,
            expectedAmounts,
            address(0),
            expectedPayment,
            block.timestamp
        );

        // Execute with referrer
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollections{value: expectedPayment}(
            user,
            items,
            referrer
        );

        // Verify mints succeeded
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1), 2);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId2), 1);
    }

    function test_Referral_DualPaymentDrop_PreferETH() public {
        // Setup drop that accepts BOTH ETH and ERC20
        vm.startPrank(admin);
        uint256 tokenId = factory.createNewDropWithERC20(
            collection1,
            0.1 ether, // ETH price
            address(mockERC20),
            100 * 10 ** 18, // ERC20 price
            block.timestamp,
            block.timestamp + 1 days,
            true,
            true // ETH enabled
        );
        vm.stopPrank();

        vm.deal(user, 1 ether);

        // Setup referrer
        address referrer = makeAddr("referrer");

        // Create batch item
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: address(collection1),
            tokenId: tokenId,
            amount: 1
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        // User sends ETH, so should use ETH payment (check indexed params only)
        vm.expectEmit(true, true, true, false, address(collection1));
        emit BlueprintERC1155.ReferredBatchMint(
            address(crossBatchMinter),
            referrer,
            user,
            new uint256[](0),
            new uint256[](0),
            address(0),
            0,
            0
        );

        // Execute with ETH (preferETH = true)
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0.1 ether}(
            user,
            items,
            erc20Tokens,
            referrer
        );

        // Verify mint succeeded
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId), 1);
    }

    function test_Referral_DualPaymentDrop_PreferERC20() public {
        // Setup drop that accepts BOTH ETH and ERC20
        vm.startPrank(admin);
        uint256 tokenId = factory.createNewDropWithERC20(
            collection1,
            0.1 ether, // ETH price
            address(mockERC20),
            100 * 10 ** 18, // ERC20 price
            block.timestamp,
            block.timestamp + 1 days,
            true,
            true // ETH enabled
        );
        vm.stopPrank();

        // Setup user with ERC20 tokens (no ETH sent)
        vm.prank(user);
        mockERC20.mint(user, 1000 * 10 ** 18);
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 1000 * 10 ** 18);

        // Setup referrer
        address referrer = makeAddr("referrer");

        // Create batch item
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: address(collection1),
            tokenId: tokenId,
            amount: 1
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        // User sends NO ETH, so should use ERC20 payment (check indexed params only)
        vm.expectEmit(true, true, true, false, address(collection1));
        emit BlueprintERC1155.ReferredBatchMint(
            address(crossBatchMinter),
            referrer,
            user,
            new uint256[](0),
            new uint256[](0),
            address(0),
            0,
            0
        );

        // Execute with NO ETH (preferETH = false)
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed(
            user,
            items,
            erc20Tokens,
            referrer
        );

        // Verify mint succeeded
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId), 1);
    }
}
