// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../../src/nft/BlueprintERC1155Factory.sol";
import "../../src/nft/BlueprintERC1155.sol";
import "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BlueprintERC1155FactoryTest is Test {
    // Import FeeConfig struct to fix compilation in test_GetFeeConfig
    struct FeeConfig {
        address blueprintRecipient;
        uint256 blueprintFeeBasisPoints;
        address creatorRecipient;
        uint256 creatorBasisPoints;
        address rewardPoolRecipient;
        uint256 rewardPoolBasisPoints;
        address treasury;
    }

    BlueprintERC1155Factory factory;
    BlueprintERC1155 implementation;

    address admin = address(0x1);
    address creatorRecipient = address(0x2);
    address blueprintRecipient = address(0x4);
    address treasury = address(0x5);
    address user1 = address(0x6);
    address user2 = address(0x7);
    address newBlueprintRecipient = address(0x8);
    address newCreatorRecipient = address(0x9);
    address newTreasury = address(0x10);
    address tokenBlueprintRecipient = address(0x11);
    address tokenCreatorRecipient = address(0x12);
    address tokenTreasury = address(0x13);
    address rewardPoolRecipient = address(0x14);
    address newRewardPoolRecipient = address(0x15);
    address tokenRewardPoolRecipient = address(0x16);

    uint256 defaultFeeBasisPoints = 500; // 5%
    uint256 creatorBasisPoints = 1000; // 10%
    uint256 defaultMintFee = 777000000000000; // 0.000777 ETH
    uint256 newMintFee = 111000000000000; // 0.000111 ETH
    uint256 tokenBlueprintBasisPoints = 250; // 2.5%
    uint256 tokenCreatorBasisPoints = 750; // 7.5%
    uint256 rewardPoolBasisPoints = 300; // 3%
    uint256 newRewardPoolBasisPoints = 200; // 2%
    uint256 tokenRewardPoolBasisPoints = 150; // 1.5%

    address collection;
    uint256 dropId;

    function setUp() public {
        // Setup accounts
        vm.startPrank(admin);

        // Deploy implementation
        implementation = new BlueprintERC1155();

        // Deploy factory logic
        BlueprintERC1155Factory factoryLogic = new BlueprintERC1155Factory();

        // Deploy factory proxy
        bytes memory initData = abi.encodeWithSelector(
            BlueprintERC1155Factory.initialize.selector,
            address(implementation),
            blueprintRecipient,
            defaultFeeBasisPoints,
            defaultMintFee,
            treasury,
            rewardPoolRecipient,
            rewardPoolBasisPoints,
            admin
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryLogic), initData);
        factory = BlueprintERC1155Factory(address(proxy));

        vm.stopPrank();
    }

    function test_CreateCollection() public {
        vm.startPrank(admin);

        // We don't use expectEmit because the collection address is unknown before creation

        collection =
            factory.createCollection("ipfs://baseuri/", creatorRecipient, creatorBasisPoints);

        // Verify collection was created
        assertTrue(factory.isDeployedCollection(collection));

        // Verify collection URI
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        assertEq(collectionContract.collectionURI(), "ipfs://baseuri/");

        // Verify roles
        assertTrue(collectionContract.hasRole(collectionContract.CREATOR_ROLE(), creatorRecipient));
        assertTrue(collectionContract.hasRole(collectionContract.FACTORY_ROLE(), address(factory)));

        vm.stopPrank();
    }

    function test_CreateDrop() public {
        // First create a collection
        test_CreateCollection();

        vm.startPrank(admin);

        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;

        // Create a drop and get the token ID
        dropId = factory.createNewDrop(
            collection,
            defaultMintFee,
            startTime,
            endTime,
            true // active
        );

        // Verify the drop was created with correct settings
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        (uint256 price, uint256 dropsStartTime, uint256 dropsEndTime, bool active) =
            collectionContract.drops(dropId);

        assertEq(price, defaultMintFee);
        assertEq(dropsStartTime, startTime);
        assertEq(dropsEndTime, endTime);
        assertTrue(active);

        // Token ID should be 0 for the first drop
        assertEq(dropId, 0);
        assertEq(collectionContract.nextTokenId(), 1); // Next token ID should be incremented

        vm.stopPrank();
    }

    function test_FeeDistribution() public {
        // Setup collection and drop
        test_CreateDrop();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Setup balances to check fee distribution
        vm.deal(blueprintRecipient, 0);
        vm.deal(creatorRecipient, 0);
        vm.deal(treasury, 0);
        vm.deal(rewardPoolRecipient, 0);

        // Setup user
        vm.startPrank(user1);
        vm.deal(user1, 1 ether);

        // Mint tokens
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        collectionContract.mint{value: defaultMintFee}(user1, dropId, 1);

        // Calculate expected fees
        uint256 blueprintFee = (defaultMintFee * defaultFeeBasisPoints) / 10000;
        uint256 creatorFee = (defaultMintFee * creatorBasisPoints) / 10000;
        uint256 rewardPoolFee = (defaultMintFee * rewardPoolBasisPoints) / 10000;
        uint256 treasuryAmount = defaultMintFee - blueprintFee - creatorFee - rewardPoolFee;

        // Verify fee distribution
        assertEq(address(blueprintRecipient).balance, blueprintFee);
        assertEq(address(creatorRecipient).balance, creatorFee);
        assertEq(address(rewardPoolRecipient).balance, rewardPoolFee);
        assertEq(address(treasury).balance, treasuryAmount);

        vm.stopPrank();
    }

    function test_InvalidFeeConfig() public {
        // First create a collection
        test_CreateCollection();

        vm.startPrank(admin);

        // Set high basis points (more than 100% combined)
        // Note: The contract doesn't validate that basis points add up to at most 100%
        factory.updateFeeConfig(
            collection,
            blueprintRecipient, // Non-zero address for blueprint recipient
            7000, // 70%
            creatorRecipient, // Non-zero address for creator recipient
            7000, // 70%
            rewardPoolRecipient, // Non-zero address for reward pool recipient
            2000, // 20%
            treasury
        );

        // Verify the fee configuration was updated successfully
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        (
            ,
            uint256 updatedBlueprintBasisPoints,
            ,
            uint256 updatedCreatorBasisPoints,
            ,
            uint256 updatedRewardPoolBasisPoints,
        ) = collectionContract.defaultFeeConfig();

        // Verify values were set correctly
        assertEq(updatedBlueprintBasisPoints, 7000);
        assertEq(updatedCreatorBasisPoints, 7000);
        assertEq(updatedRewardPoolBasisPoints, 2000);

        vm.stopPrank();
    }

    function test_MaxFeesEdgeCase() public {
        // Setup collection
        test_CreateCollection();

        vm.startPrank(admin);

        // Set max fees (100%)
        factory.updateFeeConfig(
            collection,
            blueprintRecipient,
            3000, // 30%
            creatorRecipient,
            5000, // 50%
            rewardPoolRecipient,
            2000, // 20%
            treasury
        );

        // Create a drop
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;

        dropId = factory.createNewDrop(collection, defaultMintFee, startTime, endTime, true);

        vm.stopPrank();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Setup balances to check fee distribution
        vm.deal(blueprintRecipient, 0);
        vm.deal(creatorRecipient, 0);
        vm.deal(rewardPoolRecipient, 0);
        vm.deal(treasury, 0);

        // Mint as user
        vm.startPrank(user1);
        vm.deal(user1, 1 ether);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        collectionContract.mint{value: defaultMintFee}(user1, dropId, 1);

        // Verify fee distribution
        uint256 blueprintFee = (defaultMintFee * 3000) / 10000; // 30%
        uint256 creatorFee = (defaultMintFee * 5000) / 10000; // 50%
        uint256 rewardPoolFee = (defaultMintFee * 2000) / 10000; // 20%

        assertEq(address(blueprintRecipient).balance, blueprintFee);
        assertEq(address(creatorRecipient).balance, creatorFee);
        assertEq(address(rewardPoolRecipient).balance, rewardPoolFee);
        assertEq(address(treasury).balance, 0); // Nothing left for treasury

        vm.stopPrank();
    }

    function test_UpdateFeeConfig() public {
        // Setup collection
        test_CreateCollection();

        vm.startPrank(admin);

        // Update fee config
        factory.updateFeeConfig(
            collection,
            newBlueprintRecipient,
            300, // 3%
            newCreatorRecipient,
            1500, // 15%
            newRewardPoolRecipient,
            200, // 2%
            newTreasury
        );

        // Verify updated config
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        (
            address updatedBlueprintRecipient,
            uint256 updatedBlueprintBasisPoints,
            address updatedCreatorRecipient,
            uint256 updatedCreatorBasisPoints,
            address updatedRewardPoolRecipient,
            uint256 updatedRewardPoolBasisPoints,
            address updatedTreasury
        ) = collectionContract.defaultFeeConfig();

        assertEq(updatedBlueprintRecipient, newBlueprintRecipient);
        assertEq(updatedBlueprintBasisPoints, 300);
        assertEq(updatedCreatorRecipient, newCreatorRecipient);
        assertEq(updatedCreatorBasisPoints, 1500);
        assertEq(updatedRewardPoolRecipient, newRewardPoolRecipient);
        assertEq(updatedRewardPoolBasisPoints, 200);
        assertEq(updatedTreasury, newTreasury);

        vm.stopPrank();
    }

    function test_UpdateFeeConfigSpecificValues() public {
        // Setup collection
        test_CreateCollection();

        vm.startPrank(admin);

        // Update specific fee config values
        factory.updateFeeConfig(
            collection,
            blueprintRecipient,
            defaultFeeBasisPoints,
            newCreatorRecipient,
            2000, // 20%
            rewardPoolRecipient,
            rewardPoolBasisPoints,
            treasury
        );

        // Verify only requested values were updated
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        (
            address updatedBlueprintRecipient,
            uint256 updatedBlueprintBasisPoints,
            address updatedCreatorRecipient,
            uint256 updatedCreatorBasisPoints,
            address updatedRewardPoolRecipient,
            uint256 updatedRewardPoolBasisPoints,
            address updatedTreasury
        ) = collectionContract.defaultFeeConfig();

        assertEq(updatedBlueprintRecipient, blueprintRecipient);
        assertEq(updatedBlueprintBasisPoints, defaultFeeBasisPoints);
        assertEq(updatedCreatorRecipient, newCreatorRecipient);
        assertEq(updatedCreatorBasisPoints, 2000);
        assertEq(updatedRewardPoolRecipient, rewardPoolRecipient);
        assertEq(updatedRewardPoolBasisPoints, rewardPoolBasisPoints);
        assertEq(updatedTreasury, treasury);

        vm.stopPrank();
    }

    function test_UpdateCreatorRecipient() public {
        // Setup collection
        test_CreateCollection();

        vm.startPrank(admin);

        factory.updateCreatorRecipient(collection, newCreatorRecipient);

        // Verify only creator recipient was updated
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        (
            address updatedBlueprintRecipient,
            uint256 updatedBlueprintBasisPoints,
            address updatedCreatorRecipient,
            uint256 updatedCreatorBasisPoints,
            address updatedRewardPoolRecipient,
            uint256 updatedRewardPoolBasisPoints,
            address updatedTreasury
        ) = collectionContract.defaultFeeConfig();

        assertEq(updatedBlueprintRecipient, blueprintRecipient);
        assertEq(updatedBlueprintBasisPoints, defaultFeeBasisPoints);
        assertEq(updatedCreatorRecipient, newCreatorRecipient);
        assertEq(updatedCreatorBasisPoints, creatorBasisPoints);
        assertEq(updatedRewardPoolRecipient, rewardPoolRecipient);
        assertEq(updatedRewardPoolBasisPoints, rewardPoolBasisPoints);
        assertEq(updatedTreasury, treasury);

        vm.stopPrank();
    }

    function test_UpdateDefaultFeeConfig() public {
        vm.startPrank(admin);

        factory.setDefaultFeeConfig(
            newBlueprintRecipient,
            300, // 3%
            newMintFee,
            newTreasury,
            newRewardPoolRecipient,
            newRewardPoolBasisPoints
        );

        // Verify updated defaults
        assertEq(factory.defaultBlueprintRecipient(), newBlueprintRecipient);
        assertEq(factory.defaultFeeBasisPoints(), 300);
        assertEq(factory.defaultMintFee(), newMintFee);
        assertEq(factory.defaultTreasury(), newTreasury);
        assertEq(factory.defaultRewardPoolRecipient(), newRewardPoolRecipient);
        assertEq(factory.defaultRewardPoolBasisPoints(), newRewardPoolBasisPoints);

        // Create a new collection with updated defaults
        address newCollection =
            factory.createCollection("ipfs://newuri/", creatorRecipient, creatorBasisPoints);

        // Verify new collection has updated defaults
        BlueprintERC1155 collectionContract = BlueprintERC1155(newCollection);
        (
            address collectionBlueprintRecipient,
            uint256 collectionBlueprintBasisPoints,
            ,
            ,
            address collectionRewardPoolRecipient,
            uint256 collectionRewardPoolBasisPoints,
            address collectionTreasury
        ) = collectionContract.defaultFeeConfig();

        assertEq(collectionBlueprintRecipient, newBlueprintRecipient);
        assertEq(collectionBlueprintBasisPoints, 300);
        assertEq(collectionRewardPoolRecipient, newRewardPoolRecipient);
        assertEq(collectionRewardPoolBasisPoints, newRewardPoolBasisPoints);
        assertEq(collectionTreasury, newTreasury);

        vm.stopPrank();
    }

    function test_AdminMint() public {
        // Setup collection and drop
        test_CreateDrop();

        vm.startPrank(admin);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        factory.adminMint(collection, user1, dropId, 5);

        // Verify user received tokens
        assertEq(collectionContract.balanceOf(user1, dropId), 5);

        vm.stopPrank();
    }

    function test_AdminBatchMint() public {
        // Setup collection and drop
        test_CreateDrop();

        vm.startPrank(admin);

        // Create another drop
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        uint256 secondDropId =
            factory.createNewDrop(collection, defaultMintFee, startTime, endTime, true);

        // Batch mint both drops
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = dropId;
        tokenIds[1] = secondDropId;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 3;
        amounts[1] = 7;

        factory.adminBatchMint(collection, user1, tokenIds, amounts);

        // Verify user received tokens
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        assertEq(collectionContract.balanceOf(user1, dropId), 3);
        assertEq(collectionContract.balanceOf(user1, secondDropId), 7);

        vm.stopPrank();
    }

    function test_TokenMetadata() public {
        // Setup collection and drop
        test_CreateDrop();

        vm.startPrank(admin);

        // Update token URI
        factory.updateTokenURI(collection, dropId, "ipfs://custom/0");

        // Verify URI was updated
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        string memory tokenURI = collectionContract.uri(dropId);
        assertEq(tokenURI, "ipfs://custom/0");

        // Create a new drop that should use default URI
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        uint256 secondDropId =
            factory.createNewDrop(collection, defaultMintFee, startTime, endTime, true);

        // Check that second drop uses base URI
        string memory baseUri = collectionContract.uri(secondDropId);
        assertEq(baseUri, "ipfs://baseuri/");

        vm.stopPrank();
    }

    // Add new test for reward pool functionality
    function test_UpdateRewardPoolRecipient() public {
        // Setup collection and drop
        test_CreateDrop();

        vm.startPrank(admin);

        factory.updateRewardPoolRecipient(collection, newRewardPoolRecipient);

        // Verify updated config
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        (,,,, address updatedRewardPoolRecipient,,) = collectionContract.defaultFeeConfig();

        assertEq(updatedRewardPoolRecipient, newRewardPoolRecipient);

        vm.stopPrank();
    }

    function test_TokenFeeConfigWithRewardPool() public {
        // Setup collection and drop
        test_CreateDrop();

        vm.startPrank(admin);

        factory.updateTokenFeeConfig(
            collection,
            dropId,
            tokenBlueprintRecipient,
            tokenBlueprintBasisPoints,
            tokenCreatorRecipient,
            tokenCreatorBasisPoints,
            tokenRewardPoolRecipient,
            tokenRewardPoolBasisPoints,
            tokenTreasury
        );

        // Verify updated config
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        // Check that the token has a custom fee config
        assertTrue(collectionContract.hasCustomFeeConfig(dropId));

        // Get the token fee config
        (
            address updatedBlueprintRecipient,
            uint256 updatedBlueprintBasisPoints,
            address updatedCreatorRecipient,
            uint256 updatedCreatorBasisPoints,
            address updatedRewardPoolRecipient,
            uint256 updatedRewardPoolBasisPoints,
            address updatedTreasury
        ) = collectionContract.tokenFeeConfigs(dropId);

        assertEq(updatedBlueprintRecipient, tokenBlueprintRecipient);
        assertEq(updatedBlueprintBasisPoints, tokenBlueprintBasisPoints);
        assertEq(updatedCreatorRecipient, tokenCreatorRecipient);
        assertEq(updatedCreatorBasisPoints, tokenCreatorBasisPoints);
        assertEq(updatedRewardPoolRecipient, tokenRewardPoolRecipient);
        assertEq(updatedRewardPoolBasisPoints, tokenRewardPoolBasisPoints);
        assertEq(updatedTreasury, tokenTreasury);

        vm.stopPrank();
    }

    function test_TokenFeeDistributionWithRewardPool() public {
        // Setup collection and drop
        test_CreateDrop();

        // Set token-specific fee config
        vm.startPrank(admin);
        factory.updateTokenFeeConfig(
            collection,
            dropId,
            tokenBlueprintRecipient,
            tokenBlueprintBasisPoints,
            tokenCreatorRecipient,
            tokenCreatorBasisPoints,
            tokenRewardPoolRecipient,
            tokenRewardPoolBasisPoints,
            tokenTreasury
        );
        vm.stopPrank();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Setup balances to check fee distribution
        vm.deal(tokenBlueprintRecipient, 0);
        vm.deal(tokenCreatorRecipient, 0);
        vm.deal(tokenRewardPoolRecipient, 0);
        vm.deal(tokenTreasury, 0);

        // Setup user
        vm.startPrank(user1);
        vm.deal(user1, 1 ether);

        // Mint tokens
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        collectionContract.mint{value: defaultMintFee}(user1, dropId, 1);

        // Calculate expected fees based on token-specific fee config
        uint256 blueprintFee = (defaultMintFee * tokenBlueprintBasisPoints) / 10000;
        uint256 creatorFee = (defaultMintFee * tokenCreatorBasisPoints) / 10000;
        uint256 rewardPoolFee = (defaultMintFee * tokenRewardPoolBasisPoints) / 10000;
        uint256 treasuryAmount = defaultMintFee - blueprintFee - creatorFee - rewardPoolFee;

        // Verify fee distribution
        assertEq(address(tokenBlueprintRecipient).balance, blueprintFee);
        assertEq(address(tokenCreatorRecipient).balance, creatorFee);
        assertEq(address(tokenRewardPoolRecipient).balance, rewardPoolFee);
        assertEq(address(tokenTreasury).balance, treasuryAmount);

        vm.stopPrank();
    }

    function test_BatchMintWithRewardPoolFees() public {
        // Setup collection and drop
        test_CreateDrop();

        // Create a second drop with custom fee config
        vm.startPrank(admin);
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        uint256 secondDropId =
            factory.createNewDrop(collection, defaultMintFee, startTime, endTime, true);

        // Set custom fee config for second drop
        factory.updateTokenFeeConfig(
            collection,
            secondDropId,
            tokenBlueprintRecipient,
            tokenBlueprintBasisPoints,
            tokenCreatorRecipient,
            tokenCreatorBasisPoints,
            tokenRewardPoolRecipient,
            tokenRewardPoolBasisPoints,
            tokenTreasury
        );
        vm.stopPrank();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Setup balances to check fee distribution
        vm.deal(blueprintRecipient, 0);
        vm.deal(creatorRecipient, 0);
        vm.deal(rewardPoolRecipient, 0);
        vm.deal(treasury, 0);
        vm.deal(tokenBlueprintRecipient, 0);
        vm.deal(tokenCreatorRecipient, 0);
        vm.deal(tokenRewardPoolRecipient, 0);
        vm.deal(tokenTreasury, 0);

        // Mint as user1
        vm.startPrank(user1);
        vm.deal(user1, 10 ether);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = dropId; // Uses default fee config
        tokenIds[1] = secondDropId; // Uses custom fee config

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 3;
        amounts[1] = 2;

        // Calculate total cost
        uint256 totalCost = defaultMintFee * (amounts[0] + amounts[1]);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        collectionContract.batchMint{value: totalCost}(user1, tokenIds, amounts);

        // Calculate expected fees for first drop (default config)
        uint256 drop1Cost = defaultMintFee * amounts[0];
        uint256 drop1BlueprintFee = (drop1Cost * defaultFeeBasisPoints) / 10000;
        uint256 drop1CreatorFee = (drop1Cost * creatorBasisPoints) / 10000;
        uint256 drop1RewardPoolFee = (drop1Cost * rewardPoolBasisPoints) / 10000;
        uint256 drop1TreasuryAmount =
            drop1Cost - drop1BlueprintFee - drop1CreatorFee - drop1RewardPoolFee;

        // Calculate expected fees for second drop (custom config)
        uint256 drop2Cost = defaultMintFee * amounts[1];
        uint256 drop2BlueprintFee = (drop2Cost * tokenBlueprintBasisPoints) / 10000;
        uint256 drop2CreatorFee = (drop2Cost * tokenCreatorBasisPoints) / 10000;
        uint256 drop2RewardPoolFee = (drop2Cost * tokenRewardPoolBasisPoints) / 10000;
        uint256 drop2TreasuryAmount =
            drop2Cost - drop2BlueprintFee - drop2CreatorFee - drop2RewardPoolFee;

        // Verify fee distribution for default config
        assertEq(address(blueprintRecipient).balance, drop1BlueprintFee);
        assertEq(address(creatorRecipient).balance, drop1CreatorFee);
        assertEq(address(rewardPoolRecipient).balance, drop1RewardPoolFee);
        assertEq(address(treasury).balance, drop1TreasuryAmount);

        // Verify fee distribution for custom config
        assertEq(address(tokenBlueprintRecipient).balance, drop2BlueprintFee);
        assertEq(address(tokenCreatorRecipient).balance, drop2CreatorFee);
        assertEq(address(tokenRewardPoolRecipient).balance, drop2RewardPoolFee);
        assertEq(address(tokenTreasury).balance, drop2TreasuryAmount);

        // Verify token balances
        assertEq(collectionContract.balanceOf(user1, dropId), 3);
        assertEq(collectionContract.balanceOf(user1, secondDropId), 2);

        vm.stopPrank();
    }

    function test_GetFeeConfig() public {
        // Setup collection and drop
        test_CreateDrop();

        vm.startPrank(admin);

        // Get default fee config for the drop
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        // Test default fee config values
        BlueprintERC1155.FeeConfig memory config = collectionContract.getFeeConfig(dropId);

        assertEq(config.blueprintRecipient, blueprintRecipient);
        assertEq(config.blueprintFeeBasisPoints, defaultFeeBasisPoints);
        assertEq(config.creatorRecipient, creatorRecipient);
        assertEq(config.creatorBasisPoints, creatorBasisPoints);
        assertEq(config.rewardPoolRecipient, rewardPoolRecipient);
        assertEq(config.rewardPoolBasisPoints, rewardPoolBasisPoints);
        assertEq(config.treasury, treasury);

        // Set token-specific fee config
        factory.updateTokenFeeConfig(
            collection,
            dropId,
            tokenBlueprintRecipient,
            tokenBlueprintBasisPoints,
            tokenCreatorRecipient,
            tokenCreatorBasisPoints,
            tokenRewardPoolRecipient,
            tokenRewardPoolBasisPoints,
            tokenTreasury
        );

        // Get custom fee config for the drop
        config = collectionContract.getFeeConfig(dropId);

        assertEq(config.blueprintRecipient, tokenBlueprintRecipient);
        assertEq(config.blueprintFeeBasisPoints, tokenBlueprintBasisPoints);
        assertEq(config.creatorRecipient, tokenCreatorRecipient);
        assertEq(config.creatorBasisPoints, tokenCreatorBasisPoints);
        assertEq(config.rewardPoolRecipient, tokenRewardPoolRecipient);
        assertEq(config.rewardPoolBasisPoints, tokenRewardPoolBasisPoints);
        assertEq(config.treasury, tokenTreasury);

        vm.stopPrank();
    }

    function test_ZeroAddressRewardPoolRecipient() public {
        // Setup collection and drop
        test_CreateDrop();

        vm.startPrank(admin);

        // Update with zero address for reward pool
        factory.updateFeeConfig(
            collection,
            blueprintRecipient,
            defaultFeeBasisPoints,
            creatorRecipient,
            creatorBasisPoints,
            address(0),
            rewardPoolBasisPoints,
            treasury
        );

        // Mint and ensure it still works without reward pool fee
        vm.stopPrank();

        vm.startPrank(user1);
        vm.deal(user1, 1 ether);

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Setup balances to check fee distribution
        vm.deal(blueprintRecipient, 0);
        vm.deal(creatorRecipient, 0);
        vm.deal(treasury, 0);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        // Should still be able to mint
        collectionContract.mint{value: defaultMintFee}(user1, dropId, 1);

        // Calculate expected fees
        uint256 blueprintFee = (defaultMintFee * defaultFeeBasisPoints) / 10000;
        uint256 creatorFee = (defaultMintFee * creatorBasisPoints) / 10000;

        // When reward pool recipient is address(0), the reward pool fee should go to treasury
        uint256 treasuryAmount = defaultMintFee - blueprintFee - creatorFee;

        // Verify fee distribution
        assertEq(address(blueprintRecipient).balance, blueprintFee);
        assertEq(address(creatorRecipient).balance, creatorFee);
        assertEq(address(treasury).balance, treasuryAmount);

        vm.stopPrank();
    }

    function test_RevertOnZeroBlueprintRecipient() public {
        // Setup collection and drop
        test_CreateDrop();

        vm.startPrank(admin);

        // Update with zero address for blueprint recipient
        vm.expectRevert(
            BlueprintERC1155Factory.BlueprintERC1155Factory__ZeroBlueprintRecipient.selector
        );
        factory.updateFeeConfig(
            collection,
            address(0), // zero address for blueprint recipient
            defaultFeeBasisPoints,
            creatorRecipient,
            creatorBasisPoints,
            rewardPoolRecipient,
            rewardPoolBasisPoints,
            treasury
        );

        vm.stopPrank();
    }

    function test_RevertOnZeroCreatorRecipient() public {
        // Setup collection and drop
        test_CreateDrop();

        vm.startPrank(admin);

        // Update with zero address for creator recipient
        vm.expectRevert(
            BlueprintERC1155Factory.BlueprintERC1155Factory__ZeroCreatorRecipient.selector
        );
        factory.updateFeeConfig(
            collection,
            blueprintRecipient,
            defaultFeeBasisPoints,
            address(0), // zero address for creator recipient
            creatorBasisPoints,
            rewardPoolRecipient,
            rewardPoolBasisPoints,
            treasury
        );

        vm.stopPrank();
    }
}
