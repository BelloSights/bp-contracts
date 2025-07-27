// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/nft/BlueprintERC1155Factory.sol";
import "../../src/nft/BlueprintERC1155.sol";
import "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../test/mock/MockERC20.sol";

// Mock batch executor contract to simulate EIP-5792
contract MockBatchExecutor {
    function executeBatch(
        address[] calldata targets,
        bytes[] calldata datas
    ) external {
        require(targets.length == datas.length, "Length mismatch");
        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, ) = targets[i].call(datas[i]);
            require(success, "Batch call failed");
        }
    }

    // Alternative: execute batch with specific caller context
    function executeBatchAs(
        address /* caller */,
        address[] calldata targets,
        bytes[] calldata datas
    ) external {
        require(targets.length == datas.length, "Length mismatch");
        for (uint256 i = 0; i < targets.length; i++) {
            // This simulates the caller being the msg.sender for each call
            (bool success, ) = targets[i].call(datas[i]);
            require(success, "Batch call failed");
        }
    }
}

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
    MockERC20 mockERC20;
    MockBatchExecutor batchExecutor;

    address admin = address(0x1);
    address creatorRecipient = address(0x2);
    address blueprintRecipient = address(0x4);
    address treasury = address(0x5);
    address user1 = address(0x6);
    address user2 = address(0x7);
    address newBlueprintRecipient = address(0x8);
    address newCreatorRecipient = address(0x9);
    address newTreasury = address(0x10);
    address tokenBlueprintRecipient = address(0x1111);
    address tokenCreatorRecipient = address(0x1112);
    address tokenTreasury = address(0x1113);
    address rewardPoolRecipient = address(0x1114);
    address newRewardPoolRecipient = address(0x1115);
    address tokenRewardPoolRecipient = address(0x1116);

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

        // Deploy mock ERC20 token
        mockERC20 = new MockERC20();

        // Deploy mock batch executor
        batchExecutor = new MockBatchExecutor();

        vm.stopPrank();
    }

    function test_CreateCollection() public {
        vm.startPrank(admin);

        // We don't use expectEmit because the collection address is unknown before creation

        collection = factory.createCollection(
            "ipfs://baseuri/",
            creatorRecipient,
            creatorBasisPoints
        );

        // Verify collection was created
        assertTrue(factory.isDeployedCollection(collection));

        // Verify collection URI
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        assertEq(collectionContract.collectionURI(), "ipfs://baseuri/");

        // Verify roles
        assertTrue(
            collectionContract.hasRole(
                collectionContract.CREATOR_ROLE(),
                creatorRecipient
            )
        );
        assertTrue(
            collectionContract.hasRole(
                collectionContract.FACTORY_ROLE(),
                address(factory)
            )
        );

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
        (
            uint256 price,
            uint256 erc20Price,
            address acceptedERC20,
            uint256 dropsStartTime,
            uint256 dropsEndTime,
            bool active,
            bool ethEnabled,
            bool erc20Enabled
        ) = collectionContract.drops(dropId);

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
        uint256 rewardPoolFee = (defaultMintFee * rewardPoolBasisPoints) /
            10000;
        uint256 treasuryAmount = defaultMintFee -
            blueprintFee -
            creatorFee -
            rewardPoolFee;

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

        dropId = factory.createNewDrop(
            collection,
            defaultMintFee,
            startTime,
            endTime,
            true
        );

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
        assertEq(
            factory.defaultRewardPoolBasisPoints(),
            newRewardPoolBasisPoints
        );

        // Create a new collection with updated defaults
        address newCollection = factory.createCollection(
            "ipfs://newuri/",
            creatorRecipient,
            creatorBasisPoints
        );

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
        uint256 secondDropId = factory.createNewDrop(
            collection,
            defaultMintFee,
            startTime,
            endTime,
            true
        );

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
        uint256 secondDropId = factory.createNewDrop(
            collection,
            defaultMintFee,
            startTime,
            endTime,
            true
        );

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
        (, , , , address updatedRewardPoolRecipient, , ) = collectionContract
            .defaultFeeConfig();

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
        uint256 blueprintFee = (defaultMintFee * tokenBlueprintBasisPoints) /
            10000;
        uint256 creatorFee = (defaultMintFee * tokenCreatorBasisPoints) / 10000;
        uint256 rewardPoolFee = (defaultMintFee * tokenRewardPoolBasisPoints) /
            10000;
        uint256 treasuryAmount = defaultMintFee -
            blueprintFee -
            creatorFee -
            rewardPoolFee;

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
        uint256 secondDropId = factory.createNewDrop(
            collection,
            defaultMintFee,
            startTime,
            endTime,
            true
        );

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
        collectionContract.batchMint{value: totalCost}(
            user1,
            tokenIds,
            amounts
        );

        // Calculate expected fees for first drop (default config)
        uint256 drop1Cost = defaultMintFee * amounts[0];
        uint256 drop1BlueprintFee = (drop1Cost * defaultFeeBasisPoints) / 10000;
        uint256 drop1CreatorFee = (drop1Cost * creatorBasisPoints) / 10000;
        uint256 drop1RewardPoolFee = (drop1Cost * rewardPoolBasisPoints) /
            10000;
        uint256 drop1TreasuryAmount = drop1Cost -
            drop1BlueprintFee -
            drop1CreatorFee -
            drop1RewardPoolFee;

        // Calculate expected fees for second drop (custom config)
        uint256 drop2Cost = defaultMintFee * amounts[1];
        uint256 drop2BlueprintFee = (drop2Cost * tokenBlueprintBasisPoints) /
            10000;
        uint256 drop2CreatorFee = (drop2Cost * tokenCreatorBasisPoints) / 10000;
        uint256 drop2RewardPoolFee = (drop2Cost * tokenRewardPoolBasisPoints) /
            10000;
        uint256 drop2TreasuryAmount = drop2Cost -
            drop2BlueprintFee -
            drop2CreatorFee -
            drop2RewardPoolFee;

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
        BlueprintERC1155.FeeConfig memory config = collectionContract
            .getFeeConfig(dropId);

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
            BlueprintERC1155Factory
                .BlueprintERC1155Factory__ZeroBlueprintRecipient
                .selector
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
            BlueprintERC1155Factory
                .BlueprintERC1155Factory__ZeroCreatorRecipient
                .selector
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

    // ===== ERC20 MINTING TESTS =====

    function test_CreateDropWithERC20() public {
        test_CreateCollection();

        vm.startPrank(admin);

        uint256 ethPrice = 1 ether;
        uint256 erc20Price = 100 * 10 ** 18; // 100 tokens
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;

        uint256 tokenId = factory.createNewDropWithERC20(
            collection,
            ethPrice,
            erc20Price,
            address(mockERC20),
            startTime,
            endTime,
            true, // active
            true, // eth enabled
            true // erc20 enabled
        );

        // Verify drop details
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        (
            uint256 price,
            uint256 erc20PriceReturned,
            address acceptedERC20,
            uint256 start,
            uint256 end,
            bool active,
            bool ethEnabled,
            bool erc20Enabled
        ) = collectionContract.drops(tokenId);

        assertEq(price, ethPrice);
        assertEq(erc20PriceReturned, erc20Price);
        assertEq(acceptedERC20, address(mockERC20));
        assertEq(start, startTime);
        assertEq(end, endTime);
        assertTrue(active);
        assertTrue(ethEnabled);
        assertTrue(erc20Enabled);

        vm.stopPrank();
    }

    function test_MintWithERC20() public {
        test_CreateDropWithERC20();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Setup balances to check fee distribution
        vm.deal(blueprintRecipient, 0);
        vm.deal(creatorRecipient, 0);
        vm.deal(treasury, 0);
        vm.deal(rewardPoolRecipient, 0);

        // Mint tokens to user
        uint256 mintAmount = 1000 * 10 ** 18; // 1000 tokens
        mockERC20.mint(user1, mintAmount);

        // Setup user and approve tokens
        vm.startPrank(user1);

        uint256 erc20Price = 100 * 10 ** 18; // 100 tokens per NFT
        uint256 nftAmount = 2;
        uint256 totalCost = erc20Price * nftAmount;

        mockERC20.approve(collection, totalCost);

        // Get initial balances
        uint256 initialBlueprint = mockERC20.balanceOf(blueprintRecipient);
        uint256 initialCreator = mockERC20.balanceOf(creatorRecipient);
        uint256 initialRewardPool = mockERC20.balanceOf(rewardPoolRecipient);
        uint256 initialTreasury = mockERC20.balanceOf(treasury);

        // Mint with ERC20
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        collectionContract.mintWithERC20(user1, 0, nftAmount);

        // Verify user received NFTs
        assertEq(collectionContract.balanceOf(user1, 0), nftAmount);

        // Calculate expected fees
        uint256 blueprintFee = (totalCost * defaultFeeBasisPoints) / 10000;
        uint256 creatorFee = (totalCost * creatorBasisPoints) / 10000;
        uint256 rewardPoolFee = (totalCost * rewardPoolBasisPoints) / 10000;
        uint256 treasuryAmount = totalCost -
            blueprintFee -
            creatorFee -
            rewardPoolFee;

        // Verify fee distribution
        assertEq(
            mockERC20.balanceOf(blueprintRecipient),
            initialBlueprint + blueprintFee
        );
        assertEq(
            mockERC20.balanceOf(creatorRecipient),
            initialCreator + creatorFee
        );
        assertEq(
            mockERC20.balanceOf(rewardPoolRecipient),
            initialRewardPool + rewardPoolFee
        );
        assertEq(
            mockERC20.balanceOf(treasury),
            initialTreasury + treasuryAmount
        );

        vm.stopPrank();
    }

    function test_BatchMintWithERC20() public {
        test_CreateDropWithERC20();

        // Create another drop
        vm.startPrank(admin);
        uint256 secondTokenId = factory.createNewDropWithERC20(
            collection,
            1 ether,
            150 * 10 ** 18, // 150 tokens
            address(mockERC20),
            block.timestamp + 1 days,
            block.timestamp + 30 days,
            true, // active
            true, // eth enabled
            true // erc20 enabled
        );
        vm.stopPrank();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Mint tokens to user
        uint256 mintAmount = 2000 * 10 ** 18; // 2000 tokens
        mockERC20.mint(user1, mintAmount);

        // Setup user and approve tokens
        vm.startPrank(user1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = secondTokenId;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 2;

        uint256 totalCost = 100 * 10 ** 18 + 150 * 10 ** 18 * 2; // 100 + 300 = 400 tokens

        mockERC20.approve(collection, totalCost);

        // Batch mint with ERC20
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        collectionContract.batchMintWithERC20(user1, tokenIds, amounts);

        // Verify user received NFTs
        assertEq(collectionContract.balanceOf(user1, 0), 1);
        assertEq(collectionContract.balanceOf(user1, secondTokenId), 2);

        vm.stopPrank();
    }

    function test_RevertWhen_ERC20NotEnabled() public {
        test_CreateCollection();

        // Create drop with ERC20 disabled
        vm.startPrank(admin);
        uint256 tokenId = factory.createNewDropWithERC20(
            collection,
            1 ether,
            100 * 10 ** 18,
            address(mockERC20),
            block.timestamp + 1 days,
            block.timestamp + 30 days,
            true, // active
            true, // eth enabled
            false // erc20 disabled
        );
        vm.stopPrank();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Try to mint with ERC20
        vm.startPrank(user1);
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintERC1155.BlueprintERC1155__ERC20NotEnabled.selector
            )
        );
        collectionContract.mintWithERC20(user1, tokenId, 1);

        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientERC20Allowance() public {
        test_CreateDropWithERC20();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Mint tokens to user but don't approve enough
        uint256 mintAmount = 1000 * 10 ** 18;
        mockERC20.mint(user1, mintAmount);

        vm.startPrank(user1);
        uint256 erc20Price = 100 * 10 ** 18;
        mockERC20.approve(collection, erc20Price / 2); // Only approve half

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintERC1155
                    .BlueprintERC1155__InsufficientERC20Allowance
                    .selector,
                erc20Price,
                erc20Price / 2
            )
        );
        collectionContract.mintWithERC20(user1, 0, 1);

        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientERC20Balance() public {
        test_CreateDropWithERC20();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        vm.startPrank(user1);
        uint256 erc20Price = 100 * 10 ** 18;
        uint256 insufficientBalance = erc20Price / 2;

        // Mint insufficient tokens
        mockERC20.mint(user1, insufficientBalance);
        mockERC20.approve(collection, erc20Price);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        vm.expectRevert(
            abi.encodeWithSelector(
                BlueprintERC1155
                    .BlueprintERC1155__InsufficientERC20Balance
                    .selector,
                erc20Price,
                insufficientBalance
            )
        );
        collectionContract.mintWithERC20(user1, 0, 1);

        vm.stopPrank();
    }

    function test_UpdateDropERC20Price() public {
        test_CreateDropWithERC20();

        vm.startPrank(admin);

        uint256 newERC20Price = 200 * 10 ** 18; // 200 tokens
        factory.updateDropERC20Price(collection, 0, newERC20Price);

        // Verify price was updated
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        (, uint256 erc20Price, , , , , , ) = collectionContract.drops(0);
        assertEq(erc20Price, newERC20Price);

        vm.stopPrank();
    }

    function test_SetDropERC20Enabled() public {
        test_CreateDropWithERC20();

        vm.startPrank(admin);

        // Disable ERC20
        factory.setDropERC20Enabled(collection, 0, false);

        // Verify ERC20 was disabled
        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        (, , , , , , , bool erc20Enabled) = collectionContract.drops(0);
        assertFalse(erc20Enabled);

        // Re-enable ERC20
        factory.setDropERC20Enabled(collection, 0, true);

        // Verify ERC20 was re-enabled
        (, , , , , , , erc20Enabled) = collectionContract.drops(0);
        assertTrue(erc20Enabled);

        vm.stopPrank();
    }

    function test_MixedPaymentMethods() public {
        test_CreateDropWithERC20();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Test ETH minting
        vm.startPrank(user1);
        vm.deal(user1, 2 ether);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);
        collectionContract.mint{value: 1 ether}(user1, 0, 1);

        assertEq(collectionContract.balanceOf(user1, 0), 1);
        vm.stopPrank();

        // Test ERC20 minting from a different user
        vm.startPrank(user2);
        mockERC20.mint(user2, 1000 * 10 ** 18);
        mockERC20.approve(collection, 100 * 10 ** 18);

        collectionContract.mintWithERC20(user2, 0, 1);

        assertEq(collectionContract.balanceOf(user2, 0), 1);
        vm.stopPrank();
    }

    // ===== EIP-5792 BATCH TRANSACTION TESTS =====

    function test_EIP5792BatchTransaction_ApproveAndMint() public {
        test_CreateDropWithERC20();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Mint tokens directly to the batch executor (simulating wallet that already has tokens)
        uint256 mintAmount = 1000 * 10 ** 18;
        mockERC20.mint(address(batchExecutor), mintAmount);

        vm.startPrank(user1);

        uint256 erc20Price = 100 * 10 ** 18;
        uint256 nftAmount = 1;

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        // Create batch transaction data for EIP-5792 simulation
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);

        // 1. Approve tokens from batch executor
        targets[0] = address(mockERC20);
        datas[0] = abi.encodeWithSelector(
            mockERC20.approve.selector,
            address(collectionContract),
            erc20Price
        );

        // 2. Mint NFTs using batch-safe function
        targets[1] = address(collectionContract);
        datas[1] = abi.encodeWithSelector(
            collectionContract.mintWithERC20BatchSafe.selector,
            user1,
            0,
            nftAmount,
            false // strict mode
        );

        // Execute batch transaction using MockBatchExecutor
        batchExecutor.executeBatch(targets, datas);

        // Verify the batch transaction succeeded
        assertEq(collectionContract.balanceOf(user1, 0), nftAmount);
        assertEq(
            mockERC20.balanceOf(address(batchExecutor)),
            mintAmount - erc20Price
        ); // Should be consumed

        vm.stopPrank();
    }

    function test_EIP5792BatchTransaction_MultipleMints() public {
        test_CreateDropWithERC20();

        // Create second drop
        vm.startPrank(admin);
        uint256 secondDropId = factory.createNewDropWithERC20(
            collection,
            1 ether,
            150 * 10 ** 18,
            address(mockERC20),
            block.timestamp + 1 days,
            block.timestamp + 30 days,
            true,
            true,
            true
        );
        vm.stopPrank();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Mint tokens directly to the batch executor (simulating wallet that already has tokens)
        uint256 mintAmount = 2000 * 10 ** 18;
        mockERC20.mint(address(batchExecutor), mintAmount);

        vm.startPrank(user1);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        // Create batch transaction data for EIP-5792 simulation with multiple operations
        address[] memory targets = new address[](3);
        bytes[] memory datas = new bytes[](3);

        uint256 totalCost = 100 * 10 ** 18 + 150 * 10 ** 18; // 100 + 150 tokens

        // 1. Approve tokens for both mints
        targets[0] = address(mockERC20);
        datas[0] = abi.encodeWithSelector(
            mockERC20.approve.selector,
            address(collectionContract),
            totalCost
        );

        // 2. Mint first drop
        targets[1] = address(collectionContract);
        datas[1] = abi.encodeWithSelector(
            collectionContract.mintWithERC20BatchSafe.selector,
            user1,
            0,
            1,
            false
        );

        // 3. Mint second drop
        targets[2] = address(collectionContract);
        datas[2] = abi.encodeWithSelector(
            collectionContract.mintWithERC20BatchSafe.selector,
            user1,
            secondDropId,
            1,
            false
        );

        // Execute batch transaction using MockBatchExecutor
        batchExecutor.executeBatch(targets, datas);

        // Verify the batch transaction succeeded
        assertEq(collectionContract.balanceOf(user1, 0), 1);
        assertEq(collectionContract.balanceOf(user1, secondDropId), 1);

        vm.stopPrank();
    }

    function test_EIP5792BatchTransaction_RevertsOnFailure() public {
        test_CreateDropWithERC20();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Mint tokens to user
        uint256 mintAmount = 1000 * 10 ** 18;
        mockERC20.mint(user1, mintAmount);

        vm.startPrank(user1);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        // Create batch transaction data that should fail
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);

        uint256 erc20Price = 100 * 10 ** 18;

        // 1. Approve tokens
        targets[0] = address(mockERC20);
        datas[0] = abi.encodeWithSelector(
            mockERC20.approve.selector,
            address(collectionContract),
            erc20Price
        );

        // 2. Try to mint without approval (this should fail)
        targets[1] = address(collectionContract);
        datas[1] = abi.encodeWithSelector(
            collectionContract.mintWithERC20BatchSafe.selector,
            user1,
            0,
            2, // Try to mint 2 but only approved for 1
            false
        );

        // Execute batch transaction - should revert
        vm.expectRevert("Batch call failed");
        batchExecutor.executeBatch(targets, datas);

        // Verify nothing was minted (atomic rollback)
        assertEq(collectionContract.balanceOf(user1, 0), 0);

        vm.stopPrank();
    }

    function test_EIP5792BatchTransaction_MultipleERC20Operations() public {
        test_CreateDropWithERC20();

        // Create second drop with different ERC20 price
        vm.startPrank(admin);
        uint256 secondDropId = factory.createNewDropWithERC20(
            collection,
            1 ether,
            200 * 10 ** 18, // Different price
            address(mockERC20),
            block.timestamp + 1 days,
            block.timestamp + 30 days,
            true,
            true,
            true
        );
        vm.stopPrank();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Mint ERC20 tokens to batch executor
        uint256 mintAmount = 1000 * 10 ** 18;
        mockERC20.mint(address(batchExecutor), mintAmount);

        vm.startPrank(user1);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        // Create batch transaction data for multiple ERC20 operations
        address[] memory targets = new address[](6);
        bytes[] memory datas = new bytes[](6);

        // 1. Approve tokens for first two mints
        targets[0] = address(mockERC20);
        datas[0] = abi.encodeWithSelector(
            mockERC20.approve.selector,
            address(collectionContract),
            300 * 10 ** 18 // 100 + 200 tokens
        );

        // 2. Mint first drop (100 tokens)
        targets[1] = address(collectionContract);
        datas[1] = abi.encodeWithSelector(
            collectionContract.mintWithERC20BatchSafe.selector,
            user1,
            0,
            1,
            false
        );

        // 3. Mint second drop (200 tokens)
        targets[2] = address(collectionContract);
        datas[2] = abi.encodeWithSelector(
            collectionContract.mintWithERC20BatchSafe.selector,
            user1,
            secondDropId,
            1,
            false
        );

        // 4. Approve additional tokens for the third mint
        targets[3] = address(mockERC20);
        datas[3] = abi.encodeWithSelector(
            mockERC20.approve.selector,
            address(collectionContract),
            100 * 10 ** 18
        );

        // 5. Mint first drop again (100 tokens)
        targets[4] = address(collectionContract);
        datas[4] = abi.encodeWithSelector(
            collectionContract.mintWithERC20BatchSafe.selector,
            user1,
            0,
            1,
            false
        );

        // Execute batch transaction using MockBatchExecutor
        batchExecutor.executeBatch(targets, datas);

        // Verify the batch transaction succeeded
        assertEq(collectionContract.balanceOf(user1, 0), 2); // 2 mints from first drop
        assertEq(collectionContract.balanceOf(user1, secondDropId), 1); // 1 mint from second drop

        vm.stopPrank();
    }

    function test_MintWithERC20BatchSafe_SingleCall() public {
        test_CreateDropWithERC20();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Mint tokens to user
        uint256 mintAmount = 1000 * 10 ** 18;
        mockERC20.mint(user1, mintAmount);

        vm.startPrank(user1);

        uint256 erc20Price = 100 * 10 ** 18;
        uint256 nftAmount = 1;
        uint256 totalCost = erc20Price * nftAmount;

        // Test the batch-safe function with approval and minting
        mockERC20.approve(collection, totalCost);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        // Expect enhanced tracking event
        vm.expectEmit(true, true, true, true);
        emit TokensMintedWithPayment(
            user1,
            0,
            nftAmount,
            address(mockERC20),
            totalCost,
            block.timestamp
        );

        collectionContract.mintWithERC20BatchSafe(user1, 0, nftAmount, false); // Strict mode - no fee-on-transfer

        // Verify user received NFTs
        assertEq(collectionContract.balanceOf(user1, 0), nftAmount);

        vm.stopPrank();
    }

    function test_GetPaymentInfo() public {
        test_CreateDropWithERC20();

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        (
            address paymentToken,
            uint256 paymentAmount,
            bool ethEnabled,
            bool erc20Enabled
        ) = collectionContract.getPaymentInfo(0, 2);

        assertEq(paymentToken, address(mockERC20));
        assertEq(paymentAmount, 200 * 10 ** 18); // 100 * 2
        assertTrue(ethEnabled);
        assertTrue(erc20Enabled);
    }

    function test_CheckMintEligibility() public {
        test_CreateDropWithERC20();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Give user ETH and ERC20 tokens
        vm.deal(user1, 2 ether);
        mockERC20.mint(user1, 1000 * 10 ** 18);

        vm.startPrank(user1);
        mockERC20.approve(collection, 200 * 10 ** 18);
        vm.stopPrank();

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        (
            bool canMintETH,
            bool canMintERC20,
            uint256 requiredETH,
            uint256 requiredERC20,
            uint256 currentAllowance,
            uint256 currentBalance
        ) = collectionContract.checkMintEligibility(user1, 0, 2);

        assertTrue(canMintETH);
        assertTrue(canMintERC20);
        assertEq(requiredETH, 2 ether);
        assertEq(requiredERC20, 200 * 10 ** 18);
        assertEq(currentAllowance, 200 * 10 ** 18);
        assertEq(currentBalance, 1000 * 10 ** 18);
    }

    function test_EnhancedEventsETH() public {
        test_CreateCollection();

        vm.startPrank(admin);
        dropId = factory.createNewDrop(
            collection,
            defaultMintFee,
            block.timestamp + 1 days,
            block.timestamp + 30 days,
            true
        );
        vm.stopPrank();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        vm.startPrank(user1);
        vm.deal(user1, 1 ether);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        // Expect enhanced tracking event for ETH payment
        vm.expectEmit(true, true, true, true);
        emit TokensMintedWithPayment(
            user1,
            dropId,
            1,
            address(0),
            defaultMintFee,
            block.timestamp
        );

        collectionContract.mint{value: defaultMintFee}(user1, dropId, 1);

        vm.stopPrank();
    }

    function test_EnhancedEventsERC20() public {
        test_CreateDropWithERC20();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        mockERC20.mint(user1, 1000 * 10 ** 18);

        vm.startPrank(user1);
        uint256 erc20Price = 100 * 10 ** 18;
        mockERC20.approve(collection, erc20Price);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        // Expect enhanced tracking event for ERC20 payment
        vm.expectEmit(true, true, true, true);
        emit TokensMintedWithPayment(
            user1,
            0,
            1,
            address(mockERC20),
            erc20Price,
            block.timestamp
        );

        collectionContract.mintWithERC20(user1, 0, 1);

        vm.stopPrank();
    }

    function test_BatchEnhancedEventsETH() public {
        test_CreateCollection();

        vm.startPrank(admin);
        uint256 firstDrop = factory.createNewDrop(
            collection,
            defaultMintFee,
            block.timestamp + 1 days,
            block.timestamp + 30 days,
            true
        );
        uint256 secondDrop = factory.createNewDrop(
            collection,
            defaultMintFee,
            block.timestamp + 1 days,
            block.timestamp + 30 days,
            true
        );
        vm.stopPrank();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        vm.startPrank(user1);
        vm.deal(user1, 2 ether);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = firstDrop;
        tokenIds[1] = secondDrop;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;

        uint256 totalCost = defaultMintFee * 2;

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        // Expect enhanced tracking event for ETH batch payment
        vm.expectEmit(true, true, true, true);
        emit TokensBatchMintedWithPayment(
            user1,
            tokenIds,
            amounts,
            address(0),
            totalCost,
            block.timestamp
        );

        collectionContract.batchMint{value: totalCost}(
            user1,
            tokenIds,
            amounts
        );

        vm.stopPrank();
    }

    function test_FeeOnTransferModes() public {
        test_CreateDropWithERC20();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        mockERC20.mint(user1, 1000 * 10 ** 18);

        vm.startPrank(user1);
        uint256 erc20Price = 100 * 10 ** 18;
        mockERC20.approve(collection, erc20Price * 2);

        BlueprintERC1155 collectionContract = BlueprintERC1155(collection);

        // Test strict mode (should work with normal tokens)
        collectionContract.mintWithERC20BatchSafe(user1, 0, 1, false); // Strict mode
        assertEq(collectionContract.balanceOf(user1, 0), 1);

        // Test permissive mode (allows fee-on-transfer tokens)
        collectionContract.mintWithERC20BatchSafe(user1, 0, 1, true); // Allow fee-on-transfer
        assertEq(collectionContract.balanceOf(user1, 0), 2);

        vm.stopPrank();
    }

    // Custom event declarations for testing
    event TokensMintedWithPayment(
        address indexed to,
        uint256 indexed tokenId,
        uint256 amount,
        address indexed paymentToken,
        uint256 amountPaidWei,
        uint256 timestamp
    );

    event TokensBatchMintedWithPayment(
        address indexed to,
        uint256[] tokenIds,
        uint256[] amounts,
        address indexed paymentToken,
        uint256 totalAmountPaidWei,
        uint256 timestamp
    );
}
