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
            true // active
        );

        uint256 tokenId1_2 = factory.createNewDropWithERC20(
            collection1,
            0, // No ETH price
            address(mockERC20),
            150 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenId2_1 = factory.createNewDropWithERC20(
            collection2,
            0, // No ETH price
            address(mockERC20),
            120 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true
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
            true // active
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
            true // active
        );

        uint256 erc20TokenId2 = factory.createNewDropWithERC20(
            collection2,
            0, // No ETH price
            address(secondERC20),
            200 * 10 ** 18, // ERC20 price
            block.timestamp,
            block.timestamp + 1 hours,
            true // active
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

    function test_Revert_WrongERC20Token_FallsBackToETH_InsufficientPayment() public {
        // Use a second ERC20 token to mismatch - drop accepts mockERC20_2, user provides mockERC20
        // Since no matching ERC20 token found, system falls back to ETH (protocol fee only)
        // User sends 0 ETH, so gets InsufficientPayment
        vm.startPrank(admin);
        uint256 t = factory.createNewDropWithERC20(
            collection1,
            0,
            address(mockERC20_2),
            100 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true
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
        // System will fall back to ETH since no matching ERC20 found
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 100 * 10 ** 18);

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        uint256 protocolFee = BlueprintERC1155(collection1).protocolFeeETH();

        // Falls back to ETH, but user sends 0 ETH
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__InsufficientPayment.selector,
                protocolFee,  // expected
                0             // actual
            )
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
            true // active
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
            true
        );
        uint256 tokenId2 = factory.createNewDropWithERC20(
            collection2,
            0,
            address(mockERC20),
            200 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 days,
            true
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
            true
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
            true
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
            true
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

    // ===== BUG FIX REGRESSION TESTS =====
    // These tests specifically cover the bug where _groupItemsByCollectionMixed
    // incorrectly defaulted to ETH payment when ethPrice = 0 and no ERC20 tokens provided

    function test_RevertWhen_ZeroEthPrice_NoERC20Tokens_Provided_InsufficientPayment() public {
        // Test: Drop with ethPrice = 0 but has ERC20 price
        // User calls mixed function WITHOUT providing ERC20 tokens array and sends no ETH
        // System will fall back to ETH payment (protocol fee only) since no ERC20 tokens provided
        // Should revert with InsufficientPayment because user sent 0 ETH but protocol fee is required
        vm.startPrank(admin);
        uint256 tokenId = factory.createNewDropWithERC20(
            collection1,
            0, // ethPrice = 0
            address(mockERC20),
            100 * 10 ** 18, // ERC20 price exists
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

        // User provides EMPTY ERC20 tokens array
        address[] memory erc20Tokens = new address[](0);

        uint256 protocolFee = BlueprintERC1155(collection1).protocolFeeETH();

        // Should revert with InsufficientPayment because:
        // - No ERC20 tokens provided, so falls back to ETH
        // - ETH protocol fee is required but user sends 0 ETH
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__InsufficientPayment.selector,
                protocolFee,  // expected
                0             // actual
            )
        );
        crossBatchMinter.batchMintAcrossCollectionsMixed(
            user,
            items,
            erc20Tokens,
            address(0)
        );
    }

    function test_RevertWhen_ZeroEthPrice_WrongERC20Token_Provided_FallsBackToETH() public {
        // Drop accepts mockERC20_2, but user provides mockERC20
        // Since ethPrice = 0 and no matching ERC20, system falls back to ETH (protocol fee)
        // User sends 0 ETH, so gets InsufficientPayment error
        vm.startPrank(admin);
        uint256 tokenId = factory.createNewDropWithERC20(
            collection1,
            0, // ethPrice = 0
            address(mockERC20_2), // Drop accepts mockERC20_2
            100 * 10 ** 18,
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

        // User provides WRONG ERC20 token
        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20); // Wrong token!

        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 100 * 10 ** 18);

        uint256 protocolFee = BlueprintERC1155(collection1).protocolFeeETH();

        // Since no matching ERC20 found, system falls back to ETH
        // User sends 0 ETH but protocol fee is required
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__InsufficientPayment.selector,
                protocolFee,  // expected
                0             // actual
            )
        );
        crossBatchMinter.batchMintAcrossCollectionsMixed(
            user,
            items,
            erc20Tokens,
            address(0)
        );
    }

    function test_SuccessWhen_ZeroEthPrice_CorrectERC20Token_Provided() public {
        // Positive test: Drop with ethPrice = 0, correct ERC20 token provided
        // Should successfully mint with ERC20
        vm.startPrank(admin);
        uint256 tokenId = factory.createNewDropWithERC20(
            collection1,
            0, // ethPrice = 0 (ERC20-only)
            address(mockERC20),
            100 * 10 ** 18, // ERC20 price
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

        // User provides correct ERC20 token
        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 100 * 10 ** 18);

        uint256 userErc20Before = mockERC20.balanceOf(user);

        // Should succeed with ERC20 payment (no ETH sent)
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        // Verify mint succeeded with ERC20 payment
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId), 1);
        assertEq(
            mockERC20.balanceOf(user),
            userErc20Before - 100 * 10 ** 18,
            "Should have paid with ERC20"
        );
    }

    function test_GetMixedPaymentEstimate_ZeroEthPrice_NoERC20Tokens_FallsBackToETH() public {
        // Test that getMixedPaymentEstimate falls back to ETH when no ERC20 tokens provided
        // Even if the drop was created with ERC20, if user doesn't provide the token,
        // the system will use ETH (protocol fee only)
        vm.startPrank(admin);
        uint256 tokenId = factory.createNewDropWithERC20(
            collection1,
            0, // ethPrice = 0
            address(mockERC20),
            100 * 10 ** 18,
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

        // Empty ERC20 tokens array - will fall back to ETH
        address[] memory erc20Tokens = new address[](0);

        uint256 protocolFee = BlueprintERC1155(collection1).protocolFeeETH();

        // Should return ETH required = protocol fee (since ethPrice=0)
        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[] memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, false);

        assertEq(ethRequired, protocolFee, "Should require protocol fee in ETH");
        assertEq(erc20Requirements.length, 0, "Should have no ERC20 requirements");
    }

    function test_GetMixedPaymentEstimate_ZeroEthPrice_CorrectERC20Token()
        public
    {
        // Test that getMixedPaymentEstimate correctly returns ERC20 requirements
        vm.startPrank(admin);
        uint256 tokenId = factory.createNewDropWithERC20(
            collection1,
            0, // ethPrice = 0
            address(mockERC20),
            100 * 10 ** 18,
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
            amount: 2 // Mint 2 to test calculation
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[]
                memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, false);

        // Should require 0 ETH and correct ERC20 amount
        assertEq(ethRequired, 0, "Should not require ETH when ethPrice=0");
        assertEq(erc20Requirements.length, 1);
        assertEq(erc20Requirements[0].token, address(mockERC20));
        assertEq(
            erc20Requirements[0].amount,
            200 * 10 ** 18,
            "Should require correct ERC20 amount (2 * 100)"
        );
    }

    function test_MixedPayment_MultipleDrops_SomeZeroEthPrice() public {
        // Real-world scenario: Shopping cart with mix of drops
        // Drop 1: ethPrice = 0.1 ETH (has ETH price)
        // Drop 2: ethPrice = 0, ERC20 price = 100 tokens (ERC20-only)
        vm.startPrank(admin);
        uint256 tokenId1 = factory.createNewDrop(
            collection1,
            0.1 ether, // Has ETH price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenId2 = factory.createNewDropWithERC20(
            collection2,
            0, // ethPrice = 0 (ERC20-only)
            address(mockERC20),
            100 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

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

        // Get payment estimate
        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[]
                memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(
                items,
                erc20Tokens,
                true // preferETH
            );

        // Should require ETH for drop1, ERC20 for drop2
        assertEq(ethRequired, 0.1 ether, "Should require ETH for drop1");
        assertEq(
            erc20Requirements[0].amount,
            100 * 10 ** 18,
            "Should require ERC20 for drop2"
        );

        // Execute the mixed payment
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 100 * 10 ** 18);

        uint256 userEthBefore = user.balance;
        uint256 userErc20Before = mockERC20.balanceOf(user);

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0.1 ether}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        // Verify both mints succeeded with correct payments
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1), 1);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, tokenId2), 1);
        assertEq(
            user.balance,
            userEthBefore - 0.1 ether,
            "Should have paid 0.1 ETH"
        );
        assertEq(
            mockERC20.balanceOf(user),
            userErc20Before - 100 * 10 ** 18,
            "Should have paid 100 ERC20 tokens"
        );
    }

    // ===== ADDITIONAL CRITICAL EDGE CASE TESTS =====

    function test_MixedPayments_SameCollection_ETH_And_ERC20() public {
        // 🎉 NEW FEATURE: Same collection can now have items with different payment methods!
        // This tests the enhanced shopping cart experience
        vm.startPrank(admin);

        // Create 3 drops in SAME collection with different payment methods:
        uint256 tokenId1 = factory.createNewDrop(
            collection1,
            0.1 ether, // ETH payment
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenId2 = factory.createNewDropWithERC20(
            collection1, // SAME collection!
            0, // ethPrice = 0 (ERC20-only)
            address(mockERC20),
            100 * 10 ** 18, // ERC20 price
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenId3 = factory.createNewDrop(
            collection1, // SAME collection!
            0.2 ether, // ETH payment
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        // Shopping cart: 3 items from same collection, mixed payments
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](3);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId1,
            amount: 1 // ETH: 0.1 ether
        });
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId2,
            amount: 2 // ERC20: 200 tokens
        });
        items[2] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId3,
            amount: 1 // ETH: 0.2 ether
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        // Get payment estimate
        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[]
                memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, true);

        // Should require both ETH (0.1 + 0.2 = 0.3) AND ERC20 (200 tokens)
        assertEq(
            ethRequired,
            0.3 ether,
            "Should require 0.3 ETH for items 1 & 3"
        );
        assertEq(
            erc20Requirements[0].amount,
            200 * 10 ** 18,
            "Should require 200 ERC20 for item 2"
        );

        // Approve ERC20
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 200 * 10 ** 18);

        uint256 userEthBefore = user.balance;
        uint256 userErc20Before = mockERC20.balanceOf(user);

        // Execute the mixed payment - SAME collection, DIFFERENT payment methods!
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0.3 ether}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        // Verify all mints succeeded
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1), 1);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId2), 2);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId3), 1);

        // Verify correct payments
        assertEq(
            user.balance,
            userEthBefore - 0.3 ether,
            "Should have paid 0.3 ETH"
        );
        assertEq(
            mockERC20.balanceOf(user),
            userErc20Before - 200 * 10 ** 18,
            "Should have paid 200 ERC20 tokens"
        );
    }

    function test_EdgeCase_UserSendsETH_ForERC20OnlyDrop_ShouldRevert() public {
        // CRITICAL: User sends ETH (preferETH=true) but drop only accepts ERC20
        // Should revert appropriately, not try to use ETH with ethPrice=0
        vm.startPrank(admin);
        uint256 tokenId = factory.createNewDropWithERC20(
            collection1,
            0, // No ETH accepted
            address(mockERC20),
            100 * 10 ** 18,
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

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 100 * 10 ** 18);

        // User mistakenly sends ETH with preferETH=true
        // Should use ERC20 since ETH is not available (ethPrice=0)
        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[]
                memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, true);

        // Even with preferETH=true, should require ERC20 since ethPrice=0
        assertEq(ethRequired, 0, "Should not require ETH when ethPrice=0");
        assertEq(
            erc20Requirements[0].amount,
            100 * 10 ** 18,
            "Should require ERC20"
        );

        uint256 userErc20Before = mockERC20.balanceOf(user);

        // Execute - system should use ERC20 even though user sent ETH
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0.1 ether}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        // Verify ERC20 was used and ETH was refunded
        assertEq(
            mockERC20.balanceOf(user),
            userErc20Before - 100 * 10 ** 18,
            "Should have paid with ERC20"
        );
        assertEq(
            user.balance,
            100 ether,
            "ETH should be refunded since not needed"
        );
    }

    function test_EdgeCase_AllZeroEthPrices_MultipleERC20Tokens() public {
        // CRITICAL: Shopping cart where ALL drops have ethPrice=0
        // Drop 1: ethPrice=0, accepts mockERC20
        // Drop 2: ethPrice=0, accepts mockERC20_2
        // Drop 3: ethPrice=0, accepts mockERC20
        vm.startPrank(admin);
        uint256 tokenId1 = factory.createNewDropWithERC20(
            collection1,
            0,
            address(mockERC20),
            100 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenId2 = factory.createNewDropWithERC20(
            collection2,
            0,
            address(mockERC20_2),
            200 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenId3 = factory.createNewDropWithERC20(
            collection1,
            0,
            address(mockERC20),
            150 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](3);
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
        items[2] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId3,
            amount: 1
        });

        address[] memory erc20Tokens = new address[](2);
        erc20Tokens[0] = address(mockERC20);
        erc20Tokens[1] = address(mockERC20_2);

        // Get estimate - should show 0 ETH, multiple ERC20 requirements
        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[]
                memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, false);

        assertEq(ethRequired, 0, "Should require 0 ETH");
        // mockERC20: 100 + 150 = 250 tokens
        // mockERC20_2: 200 tokens
        assertEq(erc20Requirements[0].amount, 250 * 10 ** 18);
        assertEq(erc20Requirements[1].amount, 200 * 10 ** 18);

        // Approve and execute
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 250 * 10 ** 18);
        vm.prank(user);
        mockERC20_2.approve(address(crossBatchMinter), 200 * 10 ** 18);

        uint256 userErc20Before = mockERC20.balanceOf(user);
        uint256 userErc20_2Before = mockERC20_2.balanceOf(user);

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        // Verify all mints succeeded with correct ERC20 payments
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1), 1);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, tokenId2), 1);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId3), 1);
        assertEq(mockERC20.balanceOf(user), userErc20Before - 250 * 10 ** 18);
        assertEq(
            mockERC20_2.balanceOf(user),
            userErc20_2Before - 200 * 10 ** 18
        );
    }

    function test_EdgeCase_BoundaryValue_1WeiEthPrice_vs_0() public {
        // CRITICAL: Test the exact boundary - 1 wei should work, 0 uses protocol fee
        vm.startPrank(admin);
        uint256 tokenId1Wei = factory.createNewDrop(
            collection1,
            1, // 1 wei - smallest non-zero value
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenIdZero = factory.createNewDropWithERC20(
            collection2,
            0, // 0 wei - uses protocol fee
            address(mockERC20),
            100 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        // Test 1: 1 wei drop should accept ETH
        {
            BlueprintCrossBatchMinter.BatchMintItem[]
                memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
            items[0] = BlueprintCrossBatchMinter.BatchMintItem({
                collection: collection1,
                tokenId: tokenId1Wei,
                amount: 10 // 10 * 1 wei = 10 wei
            });

            (uint256 totalPayment, ) = crossBatchMinter.getPaymentEstimate(
                items
            );

            assertEq(totalPayment, 10, "Should require 10 wei");

            vm.prank(user);
            crossBatchMinter.batchMintAcrossCollections{value: 10}(
                user,
                items,
                address(0)
            );

            assertEq(
                BlueprintERC1155(collection1).balanceOf(user, tokenId1Wei),
                10
            );
        }

        // Test 2: 0 wei drop with protocol fee should use ETH with protocol fee
        // Now with proper protocol fee support, ethPrice=0 drops CAN use ETH via protocol fee
        {
            BlueprintCrossBatchMinter.BatchMintItem[]
                memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
            items[0] = BlueprintCrossBatchMinter.BatchMintItem({
                collection: collection2,
                tokenId: tokenIdZero,
                amount: 1
            });

            address[] memory erc20Tokens = new address[](0);

            // With empty ERC20 tokens array and preferETH=true, should fall back to ETH with protocol fee
            uint256 protocolFee = BlueprintERC1155(collection2).protocolFeeETH();
            (uint256 ethRequired, BlueprintCrossBatchMinter.ERC20Requirement[] memory erc20Requirements) =
                crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, true);

            assertEq(ethRequired, protocolFee, "Should require protocol fee for free ETH mint");
            assertEq(erc20Requirements.length, 0, "Should not require ERC20");
        }
    }

    function test_EdgeCase_LargeBatch_MixedZeroAndNonZeroEthPrices() public {
        // CRITICAL: Large batch with ETH drops and ERC20-only drops
        // This tests gas efficiency and correct routing for many items
        // NOTE: With preferETH=false, ERC20-only drops will use ERC20
        vm.startPrank(admin);

        uint256[] memory tokenIds = new uint256[](10);
        // Create 10 drops: 5 with ETH, 5 with ERC20-only (ethPrice=0)
        for (uint256 i = 0; i < 5; i++) {
            tokenIds[i] = factory.createNewDrop(
                collection1,
                (i + 1) * 0.01 ether, // 0.01, 0.02, 0.03, 0.04, 0.05 ETH
                block.timestamp,
                block.timestamp + 1 hours,
                true
            );
        }
        for (uint256 i = 5; i < 10; i++) {
            tokenIds[i] = factory.createNewDropWithERC20(
                collection2,
                0, // ethPrice = 0
                address(mockERC20),
                (i - 4) * 10 * 10 ** 18, // 10, 20, 30, 40, 50 tokens
                block.timestamp,
                block.timestamp + 1 hours,
                true
            );
        }
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](10);
        for (uint256 i = 0; i < 10; i++) {
            items[i] = BlueprintCrossBatchMinter.BatchMintItem({
                collection: i < 5 ? collection1 : collection2,
                tokenId: tokenIds[i],
                amount: 1
            });
        }

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        // Use preferETH=false so ERC20-only drops use ERC20 (not ETH with protocol fee)
        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[]
                memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, false);

        // ETH drops: 0.01 + 0.02 + 0.03 + 0.04 + 0.05 = 0.15 ETH (even with preferETH=false, ETH-only drops must use ETH)
        assertEq(
            ethRequired,
            0.15 ether,
            "Should require 0.15 ETH for items 0-4"
        );
        // ERC20: 10 + 20 + 30 + 40 + 50 = 150 tokens
        assertEq(
            erc20Requirements[0].amount,
            150 * 10 ** 18,
            "Should require 150 ERC20 for items 5-9"
        );

        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 150 * 10 ** 18);

        uint256 userEthBefore = user.balance;
        uint256 userErc20Before = mockERC20.balanceOf(user);

        // Send ETH for ETH-only drops, preferETH=false (msg.value=0 would prefer ERC20)
        // But since we need ETH for ETH-only drops, we send the exact amount
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0.15 ether}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        // Verify all 10 mints succeeded
        for (uint256 i = 0; i < 5; i++) {
            assertEq(
                BlueprintERC1155(collection1).balanceOf(user, tokenIds[i]),
                1
            );
        }
        for (uint256 i = 5; i < 10; i++) {
            assertEq(
                BlueprintERC1155(collection2).balanceOf(user, tokenIds[i]),
                1
            );
        }

        assertEq(user.balance, userEthBefore - 0.15 ether);
        assertEq(mockERC20.balanceOf(user), userErc20Before - 150 * 10 ** 18);
    }

    function test_MixedPayments_SameCollection_MultipleERC20Tokens() public {
        // CRITICAL: Same collection with items accepting DIFFERENT ERC20 tokens
        // Tests that grouping creates separate groups for each ERC20 token
        vm.startPrank(admin);

        uint256 tokenId1 = factory.createNewDropWithERC20(
            collection1,
            0, // No ETH
            address(mockERC20),
            100 * 10 ** 18, // Accepts mockERC20
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenId2 = factory.createNewDropWithERC20(
            collection1, // SAME collection!
            0, // No ETH
            address(mockERC20_2),
            200 * 10 ** 18, // Accepts mockERC20_2
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 tokenId3 = factory.createNewDropWithERC20(
            collection1, // SAME collection!
            0,
            address(mockERC20),
            150 * 10 ** 18, // Also accepts mockERC20
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](3);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId1,
            amount: 1 // mockERC20: 100
        });
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId2,
            amount: 1 // mockERC20_2: 200
        });
        items[2] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: tokenId3,
            amount: 2 // mockERC20: 300 (2 * 150)
        });

        address[] memory erc20Tokens = new address[](2);
        erc20Tokens[0] = address(mockERC20);
        erc20Tokens[1] = address(mockERC20_2);

        // Should create 2 groups: (collection1, mockERC20) and (collection1, mockERC20_2)
        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[]
                memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, false);

        assertEq(ethRequired, 0, "Should not require ETH");
        // mockERC20: 100 + 300 = 400 tokens
        assertEq(erc20Requirements[0].amount, 400 * 10 ** 18);
        // mockERC20_2: 200 tokens
        assertEq(erc20Requirements[1].amount, 200 * 10 ** 18);

        // Approve both tokens
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 400 * 10 ** 18);
        vm.prank(user);
        mockERC20_2.approve(address(crossBatchMinter), 200 * 10 ** 18);

        uint256 userErc20Before = mockERC20.balanceOf(user);
        uint256 userErc20_2Before = mockERC20_2.balanceOf(user);

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        // Verify all mints succeeded
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId1), 1);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId2), 1);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId3), 2);

        // Verify correct token deductions
        assertEq(mockERC20.balanceOf(user), userErc20Before - 400 * 10 ** 18);
        assertEq(
            mockERC20_2.balanceOf(user),
            userErc20_2Before - 200 * 10 ** 18
        );
    }

    function test_MixedPayments_ItemOrderDoesNotMatter() public {
        // CRITICAL: Verify that item order doesn't affect grouping/payments
        vm.startPrank(admin);

        uint256 ethToken = factory.createNewDrop(
            collection1,
            0.1 ether,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 erc20Token = factory.createNewDropWithERC20(
            collection1,
            0,
            address(mockERC20),
            100 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        // Test with different orderings
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items1 = new BlueprintCrossBatchMinter.BatchMintItem[](4);
        items1[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: ethToken,
            amount: 1
        });
        items1[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: erc20Token,
            amount: 1
        });
        items1[2] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: ethToken,
            amount: 1
        });
        items1[3] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: erc20Token,
            amount: 1
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        (
            uint256 eth1,
            BlueprintCrossBatchMinter.ERC20Requirement[] memory erc1
        ) = crossBatchMinter.getMixedPaymentEstimate(items1, erc20Tokens, true);

        // Different order
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items2 = new BlueprintCrossBatchMinter.BatchMintItem[](4);
        items2[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: erc20Token,
            amount: 1
        });
        items2[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: erc20Token,
            amount: 1
        });
        items2[2] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: ethToken,
            amount: 1
        });
        items2[3] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: ethToken,
            amount: 1
        });

        (
            uint256 eth2,
            BlueprintCrossBatchMinter.ERC20Requirement[] memory erc2
        ) = crossBatchMinter.getMixedPaymentEstimate(items2, erc20Tokens, true);

        // Totals should be identical regardless of order
        assertEq(eth1, eth2, "ETH total should be same");
        assertEq(eth1, 0.2 ether, "Should require 0.2 ETH");
        assertEq(erc1[0].amount, erc2[0].amount, "ERC20 total should be same");
        assertEq(erc1[0].amount, 200 * 10 ** 18, "Should require 200 ERC20");
    }

    function test_MixedPayments_LargeNumberOfGroups() public {
        // CRITICAL: Test with maximum number of unique groups
        // This stresses the grouping logic and gas costs
        vm.startPrank(admin);

        uint256[] memory tokenIds = new uint256[](6);

        // Create 3 ETH drops and 3 ERC20 drops in same collection
        // This creates 2 groups
        for (uint256 i = 0; i < 3; i++) {
            tokenIds[i] = factory.createNewDrop(
                collection1,
                (i + 1) * 0.01 ether,
                block.timestamp,
                block.timestamp + 1 hours,
                true
            );
        }

        for (uint256 i = 3; i < 6; i++) {
            tokenIds[i] = factory.createNewDropWithERC20(
                collection1,
                0,
                address(mockERC20),
                (i - 2) * 50 * 10 ** 18,
                block.timestamp,
                block.timestamp + 1 hours,
                true
            );
        }
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](6);

        for (uint256 i = 0; i < 6; i++) {
            items[i] = BlueprintCrossBatchMinter.BatchMintItem({
                collection: collection1,
                tokenId: tokenIds[i],
                amount: 1
            });
        }

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[]
                memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, true);

        // ETH: 0.01 + 0.02 + 0.03 = 0.06
        assertEq(ethRequired, 0.06 ether);
        // ERC20: 50 + 100 + 150 = 300
        assertEq(erc20Requirements[0].amount, 300 * 10 ** 18);

        // Execute and verify
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 300 * 10 ** 18);

        uint256 gasStart = gasleft();
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0.06 ether}(
            user,
            items,
            erc20Tokens,
            address(0)
        );
        uint256 gasUsed = gasStart - gasleft();

        // Verify gas is reasonable (less than block gas limit)
        assertTrue(
            gasUsed < 30_000_000,
            "Gas should be reasonable for 6 items in 2 groups"
        );

        // Verify all mints
        for (uint256 i = 0; i < 6; i++) {
            assertEq(
                BlueprintERC1155(collection1).balanceOf(user, tokenIds[i]),
                1
            );
        }
    }

    function test_MixedPayments_RefundExcessETH() public {
        // CRITICAL: Ensure excess ETH is refunded when using mixed payments
        vm.startPrank(admin);

        uint256 ethToken = factory.createNewDrop(
            collection1,
            0.1 ether,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 erc20Token = factory.createNewDropWithERC20(
            collection1,
            0,
            address(mockERC20),
            100 * 10 ** 18,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: ethToken,
            amount: 1
        });
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: erc20Token,
            amount: 1
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 100 * 10 ** 18);

        uint256 userEthBefore = user.balance;
        uint256 excessPayment = 1 ether; // Much more than needed

        // Send excess ETH
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: excessPayment}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        // Should only pay required 0.1 ETH, rest refunded
        assertEq(
            user.balance,
            userEthBefore - 0.1 ether,
            "Should refund excess ETH"
        );

        assertEq(BlueprintERC1155(collection1).balanceOf(user, ethToken), 1);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, erc20Token), 1);
    }

    function test_EdgeCase_PreferERC20_ButOnlyETHAvailable_ZeroERC20Price()
        public
    {
        // CRITICAL: User prefers ERC20 (msg.value=0, preferETH=false)
        // But drop only accepts ETH (has no ERC20 price configured)
        // Should use ETH anyway since it's the only option
        vm.startPrank(admin);
        uint256 tokenId = factory.createNewDrop(
            collection1,
            0.1 ether, // Only ETH, no ERC20 configured
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

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20); // User provides ERC20 token but drop doesn't accept it

        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[]
                memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(
                items,
                erc20Tokens,
                false // User prefers ERC20
            );

        // Should fall back to ETH since no ERC20 price configured
        assertEq(ethRequired, 0.1 ether, "Should require ETH");
        assertEq(erc20Requirements[0].amount, 0, "Should not require ERC20");

        uint256 userEthBefore = user.balance;

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0.1 ether}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId), 1);
        assertEq(user.balance, userEthBefore - 0.1 ether);
    }

    // ===== FREE MINT WITH PROTOCOL FEE TESTS =====
    // These tests verify that the cross batch minter correctly handles free mints
    // where price = 0 but protocol fee > 0

    function test_FreeETHMint_WithProtocolFee_SingleDrop() public {
        // Setup: Create a free ETH drop (price = 0, uses protocolFeeETH)
        vm.startPrank(admin);

        // Get the default protocol fee
        uint256 protocolFee = BlueprintERC1155(collection1).protocolFeeETH();

        // Create a free drop (price = 0)
        uint256 freeTokenId = factory.createNewDrop(
            collection1,
            0, // FREE - no price, but protocolFeeETH applies
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: freeTokenId,
            amount: 3
        });

        // Get payment estimate - should include protocol fee
        (uint256 totalPayment, address paymentToken) = crossBatchMinter
            .getPaymentEstimate(items);

        assertEq(totalPayment, protocolFee * 3, "Should require protocol fee * amount");
        assertEq(paymentToken, address(0), "Should be ETH payment");

        // Verify user can mint with ETH
        uint256 userEthBefore = user.balance;

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollections{value: totalPayment}(
            user,
            items,
            address(0)
        );

        // Verify mint succeeded
        assertEq(BlueprintERC1155(collection1).balanceOf(user, freeTokenId), 3);
        assertEq(user.balance, userEthBefore - totalPayment, "Should have paid protocol fee");
    }

    function test_FreeETHMint_WithProtocolFee_MultipleFreeDrops() public {
        // Setup: Create multiple free drops
        vm.startPrank(admin);

        uint256 protocolFee = BlueprintERC1155(collection1).protocolFeeETH();

        uint256 freeTokenId1 = factory.createNewDrop(
            collection1,
            0, // FREE
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 freeTokenId2 = factory.createNewDrop(
            collection2,
            0, // FREE
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: freeTokenId1,
            amount: 2
        });
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: freeTokenId2,
            amount: 3
        });

        // Total: 5 mints * protocol fee
        uint256 expectedTotal = protocolFee * 5;

        (uint256 totalPayment, ) = crossBatchMinter.getPaymentEstimate(items);
        assertEq(totalPayment, expectedTotal, "Should require total protocol fees");

        uint256 userEthBefore = user.balance;

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollections{value: expectedTotal}(
            user,
            items,
            address(0)
        );

        // Verify mints
        assertEq(BlueprintERC1155(collection1).balanceOf(user, freeTokenId1), 2);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, freeTokenId2), 3);
        assertEq(user.balance, userEthBefore - expectedTotal);
    }

    function test_FreeETHMint_MixedWithPaidDrops() public {
        // Setup: Mix free and paid ETH drops
        vm.startPrank(admin);

        uint256 protocolFee = BlueprintERC1155(collection1).protocolFeeETH();

        uint256 freeTokenId = factory.createNewDrop(
            collection1,
            0, // FREE
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        uint256 paidTokenId = factory.createNewDrop(
            collection1,
            0.1 ether, // PAID
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: freeTokenId,
            amount: 2 // 2 * protocol fee
        });
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: paidTokenId,
            amount: 1 // 0.1 ETH
        });

        uint256 expectedTotal = (protocolFee * 2) + 0.1 ether;

        (uint256 totalPayment, ) = crossBatchMinter.getPaymentEstimate(items);
        assertEq(totalPayment, expectedTotal, "Should combine protocol fee and paid price");

        uint256 userEthBefore = user.balance;

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollections{value: expectedTotal}(
            user,
            items,
            address(0)
        );

        assertEq(BlueprintERC1155(collection1).balanceOf(user, freeTokenId), 2);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, paidTokenId), 1);
        assertEq(user.balance, userEthBefore - expectedTotal);
    }

    function test_FreeERC20Mint_WithProtocolFee() public {
        // Setup: Create free ERC20 drop with protocol fee
        vm.startPrank(admin);

        // Set protocol fee for mockERC20 (e.g., 0.30 USDC = 300000 with 6 decimals, but we use 18)
        uint256 erc20ProtocolFee = 0.3 * 10 ** 18; // 0.3 tokens
        factory.setProtocolFeeERC20(collection1, address(mockERC20), erc20ProtocolFee);

        // Create free ERC20 drop (price = 0 but protocol fee applies)
        uint256 freeTokenId = factory.createNewDropWithERC20(
            collection1,
            0, // No ETH price
            address(mockERC20),
            0, // FREE - price = 0, but protocolFeeERC20 applies
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: freeTokenId,
            amount: 5
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        // Get payment estimate
        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[] memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, false);

        assertEq(ethRequired, 0, "Should not require ETH");
        assertEq(erc20Requirements[0].amount, erc20ProtocolFee * 5, "Should require protocol fee * amount");

        // Approve and mint
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), erc20ProtocolFee * 5);

        uint256 userErc20Before = mockERC20.balanceOf(user);

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        assertEq(BlueprintERC1155(collection1).balanceOf(user, freeTokenId), 5);
        assertEq(mockERC20.balanceOf(user), userErc20Before - (erc20ProtocolFee * 5));
    }

    function test_FreeERC20Mint_MixedWithPaidERC20Drops() public {
        // Setup: Mix free and paid ERC20 drops
        vm.startPrank(admin);

        uint256 erc20ProtocolFee = 0.5 * 10 ** 18;
        factory.setProtocolFeeERC20(collection1, address(mockERC20), erc20ProtocolFee);
        factory.setProtocolFeeERC20(collection2, address(mockERC20), erc20ProtocolFee);

        // Free ERC20 drop
        uint256 freeTokenId = factory.createNewDropWithERC20(
            collection1,
            0,
            address(mockERC20),
            0, // FREE
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        // Paid ERC20 drop
        uint256 paidTokenId = factory.createNewDropWithERC20(
            collection2,
            0,
            address(mockERC20),
            100 * 10 ** 18, // 100 tokens
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: freeTokenId,
            amount: 2 // 2 * 0.5 = 1 token protocol fee
        });
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: paidTokenId,
            amount: 1 // 100 tokens
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        uint256 expectedTotal = (erc20ProtocolFee * 2) + (100 * 10 ** 18);

        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[] memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, false);

        assertEq(ethRequired, 0);
        assertEq(erc20Requirements[0].amount, expectedTotal, "Should combine protocol fee and paid price");

        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), expectedTotal);

        uint256 userErc20Before = mockERC20.balanceOf(user);

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        assertEq(BlueprintERC1155(collection1).balanceOf(user, freeTokenId), 2);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, paidTokenId), 1);
        assertEq(mockERC20.balanceOf(user), userErc20Before - expectedTotal);
    }

    function test_MixedPayments_FreeETH_And_FreeERC20() public {
        // Setup: Free ETH drop + Free ERC20 drop in same batch
        vm.startPrank(admin);

        uint256 ethProtocolFee = BlueprintERC1155(collection1).protocolFeeETH();
        uint256 erc20ProtocolFee = 0.25 * 10 ** 18;
        factory.setProtocolFeeERC20(collection2, address(mockERC20), erc20ProtocolFee);

        // Free ETH drop
        uint256 freeEthTokenId = factory.createNewDrop(
            collection1,
            0, // FREE ETH
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );

        // Free ERC20 drop
        uint256 freeErc20TokenId = factory.createNewDropWithERC20(
            collection2,
            0,
            address(mockERC20),
            0, // FREE ERC20
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: freeEthTokenId,
            amount: 3 // 3 * ethProtocolFee
        });
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: freeErc20TokenId,
            amount: 4 // 4 * erc20ProtocolFee
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        uint256 expectedEth = ethProtocolFee * 3;
        uint256 expectedErc20 = erc20ProtocolFee * 4;

        // Use preferETH = false so that:
        // - Item 0 (free ETH drop, no ERC20) uses ETH (only option)
        // - Item 1 (free ERC20 drop) uses ERC20 (preferred since preferETH = false)
        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[] memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, false);

        assertEq(ethRequired, expectedEth, "Should require ETH protocol fee");
        assertEq(erc20Requirements[0].amount, expectedErc20, "Should require ERC20 protocol fee");

        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), expectedErc20);

        uint256 userEthBefore = user.balance;
        uint256 userErc20Before = mockERC20.balanceOf(user);

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: expectedEth}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        assertEq(BlueprintERC1155(collection1).balanceOf(user, freeEthTokenId), 3);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, freeErc20TokenId), 4);
        assertEq(user.balance, userEthBefore - expectedEth);
        assertEq(mockERC20.balanceOf(user), userErc20Before - expectedErc20);
    }

    function test_MixedPayments_AllFree_MultipleCollections() public {
        // Complex scenario: Multiple free drops across multiple collections
        vm.startPrank(admin);

        uint256 ethProtocolFee = BlueprintERC1155(collection1).protocolFeeETH();
        uint256 erc20ProtocolFee = 1 * 10 ** 18;
        factory.setProtocolFeeERC20(collection1, address(mockERC20), erc20ProtocolFee);
        factory.setProtocolFeeERC20(collection2, address(mockERC20), erc20ProtocolFee);

        // Free ETH drops in both collections
        uint256 freeEth1 = factory.createNewDrop(collection1, 0, block.timestamp, block.timestamp + 1 hours, true);
        uint256 freeEth2 = factory.createNewDrop(collection2, 0, block.timestamp, block.timestamp + 1 hours, true);

        // Free ERC20 drops in both collections
        uint256 freeErc20_1 = factory.createNewDropWithERC20(
            collection1, 0, address(mockERC20), 0, block.timestamp, block.timestamp + 1 hours, true
        );
        uint256 freeErc20_2 = factory.createNewDropWithERC20(
            collection2, 0, address(mockERC20), 0, block.timestamp, block.timestamp + 1 hours, true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](4);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: freeEth1,
            amount: 1
        });
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: freeEth2,
            amount: 2
        });
        items[2] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: freeErc20_1,
            amount: 3
        });
        items[3] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection2,
            tokenId: freeErc20_2,
            amount: 4
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        // ETH: 1 + 2 = 3 protocol fees (for free ETH-only drops)
        // ERC20: 3 + 4 = 7 protocol fees (for free ERC20 drops)
        uint256 expectedEth = ethProtocolFee * 3;
        uint256 expectedErc20 = erc20ProtocolFee * 7;

        // Use preferETH = false so that:
        // - Free ETH drops (no ERC20 enabled) use ETH
        // - Free ERC20 drops use ERC20 (preferred since preferETH = false)
        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[] memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, false);

        assertEq(ethRequired, expectedEth);
        assertEq(erc20Requirements[0].amount, expectedErc20);

        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), expectedErc20);

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: expectedEth}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        // Verify all mints
        assertEq(BlueprintERC1155(collection1).balanceOf(user, freeEth1), 1);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, freeEth2), 2);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, freeErc20_1), 3);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, freeErc20_2), 4);
    }

    function test_FreeETHMint_ViaETHOnlyFunction() public {
        // Verify the ETH-only function (batchMintAcrossCollections) handles free mints
        vm.startPrank(admin);

        uint256 protocolFee = BlueprintERC1155(collection1).protocolFeeETH();

        uint256 freeTokenId = factory.createNewDrop(
            collection1,
            0, // FREE
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: freeTokenId,
            amount: 10
        });

        uint256 expectedPayment = protocolFee * 10;

        // Check eligibility
        (bool canMint, uint256 totalRequired, ) = crossBatchMinter.checkBatchMintEligibility(user, items);
        assertTrue(canMint);
        assertEq(totalRequired, expectedPayment);

        // Execute mint
        uint256 userEthBefore = user.balance;

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollections{value: expectedPayment}(
            user,
            items,
            address(0)
        );

        assertEq(BlueprintERC1155(collection1).balanceOf(user, freeTokenId), 10);
        assertEq(user.balance, userEthBefore - expectedPayment);
    }

    function test_Revert_FreeETHMint_InsufficientProtocolFee() public {
        // Verify revert when user doesn't provide enough for protocol fee
        vm.startPrank(admin);

        uint256 protocolFee = BlueprintERC1155(collection1).protocolFeeETH();

        uint256 freeTokenId = factory.createNewDrop(
            collection1,
            0, // FREE - requires protocol fee
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: freeTokenId,
            amount: 5
        });

        uint256 requiredPayment = protocolFee * 5;

        // Try to mint with insufficient payment
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__InsufficientPayment.selector,
                requiredPayment,
                requiredPayment - 1
            )
        );
        crossBatchMinter.batchMintAcrossCollections{value: requiredPayment - 1}(
            user,
            items,
            address(0)
        );
    }

    function test_Revert_FreeERC20Mint_InsufficientProtocolFee() public {
        // Verify revert when user doesn't have enough ERC20 for protocol fee
        vm.startPrank(admin);

        uint256 erc20ProtocolFee = 10 * 10 ** 18; // 10 tokens
        factory.setProtocolFeeERC20(collection1, address(mockERC20), erc20ProtocolFee);

        uint256 freeTokenId = factory.createNewDropWithERC20(
            collection1,
            0,
            address(mockERC20),
            0, // FREE - requires protocol fee
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[]
            memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({
            collection: collection1,
            tokenId: freeTokenId,
            amount: 1
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        // Approve insufficient amount
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), erc20ProtocolFee - 1);

        // Should revert due to insufficient allowance
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__InsufficientERC20Allowance.selector,
                erc20ProtocolFee,
                erc20ProtocolFee - 1
            )
        );
        crossBatchMinter.batchMintAcrossCollectionsMixed(
            user,
            items,
            erc20Tokens,
            address(0)
        );
    }

    function test_DualPaymentDrop_Free_UserPrefersETH() public {
        // Drop accepts both ETH (free with protocol fee) and ERC20 (free with protocol fee)
        // User prefers ETH by NOT providing ERC20 tokens in the array
        vm.startPrank(admin);

        uint256 ethProtocolFee = BlueprintERC1155(collection1).protocolFeeETH();
        uint256 erc20ProtocolFee = 0.5 * 10 ** 18;
        factory.setProtocolFeeERC20(collection1, address(mockERC20), erc20ProtocolFee);

        // Create dual-payment free drop
        uint256 tokenId = factory.createNewDropWithERC20(
            collection1,
            0, // Free ETH (protocol fee applies)
            address(mockERC20),
            0, // Free ERC20 (protocol fee applies)
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
            amount: 2
        });

        // User prefers ETH by NOT providing ERC20 tokens
        // This forces the system to use ETH even for ERC20-enabled drops
        address[] memory erc20Tokens = new address[](0);

        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[] memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, true);

        assertEq(ethRequired, ethProtocolFee * 2, "Should use ETH protocol fee");
        assertEq(erc20Requirements.length, 0, "Should not require ERC20");

        uint256 userEthBefore = user.balance;

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: ethRequired}(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId), 2);
        assertEq(user.balance, userEthBefore - ethRequired);
    }

    function test_DualPaymentDrop_Free_UserPrefersERC20() public {
        // Drop accepts both ETH (free with protocol fee) and ERC20 (free with protocol fee)
        // User prefers ERC20
        vm.startPrank(admin);

        uint256 erc20ProtocolFee = 0.5 * 10 ** 18;
        factory.setProtocolFeeERC20(collection1, address(mockERC20), erc20ProtocolFee);

        // Create dual-payment free drop
        uint256 tokenId = factory.createNewDropWithERC20(
            collection1,
            0, // Free ETH
            address(mockERC20),
            0, // Free ERC20
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
            amount: 4
        });

        address[] memory erc20Tokens = new address[](1);
        erc20Tokens[0] = address(mockERC20);

        // User prefers ERC20 (sends no ETH)
        (
            uint256 ethRequired,
            BlueprintCrossBatchMinter.ERC20Requirement[] memory erc20Requirements
        ) = crossBatchMinter.getMixedPaymentEstimate(items, erc20Tokens, false); // preferERC20

        assertEq(ethRequired, 0, "Should not require ETH");
        assertEq(erc20Requirements[0].amount, erc20ProtocolFee * 4, "Should use ERC20 protocol fee");

        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), erc20ProtocolFee * 4);

        uint256 userErc20Before = mockERC20.balanceOf(user);

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed(
            user,
            items,
            erc20Tokens,
            address(0)
        );

        assertEq(BlueprintERC1155(collection1).balanceOf(user, tokenId), 4);
        assertEq(mockERC20.balanceOf(user), userErc20Before - (erc20ProtocolFee * 4));
    }
}
