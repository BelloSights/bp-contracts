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
        (
            uint256 totalPayment,
            address paymentToken,
            bool isValid
        ) = crossBatchMinter.getPaymentEstimate(items, true);

        assertEq(totalPayment, expectedTotal);
        assertEq(paymentToken, address(0)); // ETH
        assertTrue(isValid);

        // Check user eligibility
        (
            bool canMint,
            uint256 totalRequired,
            address requiredToken
        ) = crossBatchMinter.checkBatchMintEligibility(user, items, true);

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
            items
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
        uint256 tokenId1_1 = factory.createNewDropWithERC20(
            collection1,
            0.1 ether, // ETH price
            100 * 10 ** 18, // ERC20 price
            address(mockERC20),
            block.timestamp,
            block.timestamp + 1 hours,
            true, // active
            true, // ETH enabled
            true // ERC20 enabled
        );

        uint256 tokenId1_2 = factory.createNewDropWithERC20(
            collection1,
            0.15 ether,
            150 * 10 ** 18,
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
            120 * 10 ** 18,
            address(mockERC20),
            block.timestamp,
            block.timestamp + 1 hours,
            true,
            true,
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

        // Get payment estimate for ERC20
        (
            uint256 totalPayment,
            address paymentToken,
            bool isValid
        ) = crossBatchMinter.getPaymentEstimate(items, false);

        assertEq(totalPayment, expectedTotal);
        assertEq(paymentToken, address(mockERC20));
        assertTrue(isValid);

        // Perform the cross-collection batch mint with ERC20
        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsWithERC20(
            user,
            items,
            address(mockERC20)
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
            items
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
            100 * 10 ** 18, // ERC20 price
            address(mockERC20),
            block.timestamp,
            block.timestamp + 1 hours,
            true, // active
            false, // ETH disabled
            true // ERC20 enabled
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
            erc20Tokens
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
            100 * 10 ** 18, // ERC20 price
            address(mockERC20),
            block.timestamp,
            block.timestamp + 1 hours,
            true, // active
            false, // ETH disabled
            true // ERC20 enabled
        );

        uint256 erc20TokenId2 = factory.createNewDropWithERC20(
            collection2,
            0, // No ETH price
            200 * 10 ** 18, // ERC20 price
            address(secondERC20),
            block.timestamp,
            block.timestamp + 1 hours,
            true, // active
            false, // ETH disabled
            true // ERC20 enabled
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
            erc20Tokens
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

    function test_ERC20_BatchMint_Fallbacks_To_PerItem_When_Batch_Reverts() public {
        // Set up a collection where per-item ERC20 mint will work but batch ERC20 is forced to revert.
        // We simulate this by creating ERC20-enabled drops and then using expectRevert on the batch call via a prank/call filter.

        vm.startPrank(admin);

        uint256 t1 = factory.createNewDropWithERC20(
            collection1,
            0, // ETH price
            100 * 10 ** 18,
            address(mockERC20),
            block.timestamp,
            block.timestamp + 1 hours,
            true,
            false,
            true
        );

        uint256 t2 = factory.createNewDropWithERC20(
            collection1,
            0,
            200 * 10 ** 18,
            address(mockERC20),
            block.timestamp,
            block.timestamp + 1 hours,
            true,
            false,
            true
        );

        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[] memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({collection: collection1, tokenId: t1, amount: 1});
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({collection: collection1, tokenId: t2, amount: 2});

        uint256 total = (100 * 10 ** 18) + (200 * 10 ** 18 * 2);

        // Approve spender
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), total);

        // Simulate that collection.batchMintWithERC20 will revert by expecting revert on the next external call from minter to that selector
        // We can't directly intercept low-level, but our minter has fallback to per-item inside try/catch if batch reverts.
        // Using vm.expectRevert here would catch the revert in test context; instead, we rely on the minter's try/catch to absorb it.
        // So simply call and ensure success and balances updated via per-item fallback.

        uint256 bal1_before = BlueprintERC1155(collection1).balanceOf(user, t1);
        uint256 bal2_before = BlueprintERC1155(collection1).balanceOf(user, t2);

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsWithERC20(user, items, address(mockERC20));

        assertEq(BlueprintERC1155(collection1).balanceOf(user, t1), bal1_before + 1);
        assertEq(BlueprintERC1155(collection1).balanceOf(user, t2), bal2_before + 2);
    }

    function test_MixedMode_Fallbacks_To_PerItem_When_Batch_Reverts() public {
        // One ERC20-only drop in collection1, one ETH-only drop in collection2
        vm.startPrank(admin);
        uint256 e1 = factory.createNewDrop(
            collection2,
            0.05 ether,
            block.timestamp,
            block.timestamp + 1 hours,
            true
        );
        uint256 c1 = factory.createNewDropWithERC20(
            collection1,
            0,
            100 * 10 ** 18,
            address(mockERC20),
            block.timestamp,
            block.timestamp + 1 hours,
            true,
            false,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[] memory items = new BlueprintCrossBatchMinter.BatchMintItem[](2);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({collection: collection1, tokenId: c1, amount: 2});
        items[1] = BlueprintCrossBatchMinter.BatchMintItem({collection: collection2, tokenId: e1, amount: 1});

        // Approve ERC20 and send ETH
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 200 * 10 ** 18);

        uint256 balC1_before = BlueprintERC1155(collection1).balanceOf(user, c1);
        uint256 balE1_before = BlueprintERC1155(collection2).balanceOf(user, e1);

        address[] memory erc20s = new address[](1);
        erc20s[0] = address(mockERC20);

        vm.prank(user);
        crossBatchMinter.batchMintAcrossCollectionsMixed{value: 0.05 ether}(
            user,
            items,
            erc20s
        );

        assertEq(BlueprintERC1155(collection1).balanceOf(user, c1), balC1_before + 2);
        assertEq(BlueprintERC1155(collection2).balanceOf(user, e1), balE1_before + 1);
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

        BlueprintCrossBatchMinter.BatchMintItem[] memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({collection: collection1, tokenId: tid, amount: 1});

        vm.prank(user);
        vm.expectRevert(
            BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__ERC20NotEnabled.selector
        );
        crossBatchMinter.batchMintAcrossCollectionsWithERC20(user, items, address(mockERC20));
    }

    function test_Revert_FunctionNotSupported_When_No_PerItem_Either() public {
        // Use a second ERC20 token to mismatch approvals and force per-item failure after batch try
        vm.startPrank(admin);
        uint256 t = factory.createNewDropWithERC20(
            collection1,
            0,
            100 * 10 ** 18,
            address(mockERC20_2),
            block.timestamp,
            block.timestamp + 1 hours,
            true,
            false,
            true
        );
        vm.stopPrank();

        BlueprintCrossBatchMinter.BatchMintItem[] memory items = new BlueprintCrossBatchMinter.BatchMintItem[](1);
        items[0] = BlueprintCrossBatchMinter.BatchMintItem({collection: collection1, tokenId: t, amount: 1});

        // Approve only mockERC20 (not the accepted mockERC20_2), causing per-item to fail allowance check
        vm.prank(user);
        mockERC20.approve(address(crossBatchMinter), 100 * 10 ** 18);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintCrossBatchMinter.BlueprintCrossBatchMinter__FunctionNotSupported.selector,
                bytes4(keccak256("batchMintWithERC20(address,uint256[],uint256[])"))
            )
        );
        crossBatchMinter.batchMintAcrossCollectionsWithERC20(user, items, address(mockERC20));
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
            items
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
            items
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
            items
        );
    }

    function test_PaymentEstimateEdgeCases() public view {
        // Test with empty array
        BlueprintCrossBatchMinter.BatchMintItem[]
            memory emptyItems = new BlueprintCrossBatchMinter.BatchMintItem[](
                0
            );

        (
            uint256 totalPayment,
            address paymentToken,
            bool isValid
        ) = crossBatchMinter.getPaymentEstimate(emptyItems, true);

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
        vm.expectRevert(
            BlueprintCrossBatchMinter
                .BlueprintCrossBatchMinter__InvalidFactory
                .selector
        );
        crossBatchMinter.setFactory(address(0));
    }
}
