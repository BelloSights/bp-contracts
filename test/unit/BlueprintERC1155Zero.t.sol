// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {BlueprintERC1155Zero} from "../../src/nft/BlueprintERC1155Zero.sol";
import {BlueprintERC1155FactoryZero} from "../../src/nft/BlueprintERC1155FactoryZero.sol";

contract BlueprintERC1155ZeroTest is Test {
    BlueprintERC1155Zero public implementation;
    BlueprintERC1155FactoryZero public factory;

    address public admin = address(this);
    address public blueprintRecipient = makeAddr("blueprintRecipient");
    address public creator = makeAddr("creator");
    address public treasury = makeAddr("treasury");
    address public rewardPoolRecipient = makeAddr("rewardPoolRecipient");
    address public minter = makeAddr("minter");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public newBlueprintRecipient = makeAddr("newBlueprintRecipient");
    address public newCreatorRecipient = makeAddr("newCreatorRecipient");
    address public newTreasury = makeAddr("newTreasury");
    address public tokenBlueprintRecipient = makeAddr("tokenBlueprintRecipient");
    address public tokenCreatorRecipient = makeAddr("tokenCreatorRecipient");
    address public tokenTreasury = makeAddr("tokenTreasury");
    address public newRewardPoolRecipient = makeAddr("newRewardPoolRecipient");
    address public tokenRewardPoolRecipient = makeAddr("tokenRewardPoolRecipient");

    uint256 public constant FEE_BASIS_POINTS = 4500; // 45%
    uint256 public constant CREATOR_BASIS_POINTS = 1000; // 10%
    uint256 public constant REWARD_POOL_BASIS_POINTS = 1000; // 10%
    uint256 public constant DEFAULT_MINT_FEE = 777000000000000; // 0.000777 ETH
    uint256 public constant MINT_PRICE = 1 ether;
    uint256 public constant TOKEN_BLUEPRINT_BASIS_POINTS = 250; // 2.5%
    uint256 public constant TOKEN_CREATOR_BASIS_POINTS = 750; // 7.5%
    uint256 public constant TOKEN_REWARD_POOL_BASIS_POINTS = 150; // 1.5%

    event CollectionCreated(address indexed creator, address indexed collection, string uri);
    event DropCreated(uint256 indexed tokenId, uint256 price, uint256 startTime, uint256 endTime);
    event TokensMinted(address indexed to, uint256 indexed tokenId, uint256 amount);
    event TokensBatchMinted(address indexed to, uint256[] tokenIds, uint256[] amounts);
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
    event DropUpdated(uint256 indexed tokenId, uint256 price, uint256 startTime, uint256 endTime, bool active);

    function setUp() public {
        // Deploy implementation contract
        implementation = new BlueprintERC1155Zero(
            "https://api.blueprint.xyz/v1/metadata/",
            "Blueprint",
            "BP",
            admin,
            blueprintRecipient,
            FEE_BASIS_POINTS,
            creator,
            CREATOR_BASIS_POINTS,
            rewardPoolRecipient,
            REWARD_POOL_BASIS_POINTS,
            treasury
        );

        // Deploy factory
        factory = new BlueprintERC1155FactoryZero(
            address(implementation),
            blueprintRecipient,
            FEE_BASIS_POINTS,
            DEFAULT_MINT_FEE,
            treasury,
            rewardPoolRecipient,
            REWARD_POOL_BASIS_POINTS,
            admin
        );

        // Grant DEFAULT_ADMIN_ROLE to test contract for factory operations
        vm.startPrank(admin);
        factory.grantRole(factory.DEFAULT_ADMIN_ROLE(), address(this));
        vm.stopPrank();
    }

    function test_FactoryDeployment() public view {
        assertEq(factory.implementation(), address(implementation));
        assertEq(factory.defaultBlueprintRecipient(), blueprintRecipient);
        assertEq(factory.defaultFeeBasisPoints(), FEE_BASIS_POINTS);
        assertEq(factory.defaultMintFee(), DEFAULT_MINT_FEE);
        assertEq(factory.defaultTreasury(), treasury);
        assertEq(factory.defaultRewardPoolRecipient(), rewardPoolRecipient);
        assertEq(factory.defaultRewardPoolBasisPoints(), REWARD_POOL_BASIS_POINTS);
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_CreateCollection() public {
        string memory uri = "https://api.test.xyz/metadata/";

        // Create collection and capture the address
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        assertTrue(factory.isDeployedCollection(collection));

        // Verify collection properties
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);
        assertEq(nft.name(), "Blueprint");
        assertEq(nft.symbol(), "BP");
        assertTrue(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertTrue(nft.hasRole(nft.FACTORY_ROLE(), address(factory)));
        assertTrue(nft.hasRole(nft.CREATOR_ROLE(), creator));
    }

    function test_CreateDrop() public {
        // Create a collection first
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        // Create a drop
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;

        vm.expectEmit(true, true, false, true);
        emit DropCreated(0, MINT_PRICE, startTime, endTime);

        uint256 tokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);
        assertEq(tokenId, 0);

        // Verify drop details
        (uint256 price, uint256 start, uint256 end, bool active) = nft.drops(tokenId);
        assertEq(price, MINT_PRICE);
        assertEq(start, startTime);
        assertEq(end, endTime);
        assertTrue(active);
        vm.stopPrank();
    }

    function test_Mint() public {
        // Create collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;
        
        uint256 tokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);
        vm.stopPrank();

        // Fast forward to within the drop period
        vm.warp(startTime + 1 hours);

        // Setup initial balances
        vm.deal(blueprintRecipient, 0);
        vm.deal(creator, 0);
        vm.deal(rewardPoolRecipient, 0);
        vm.deal(treasury, 0);

        // Mint token
        uint256 amount = 1;
        vm.deal(minter, MINT_PRICE);
        
        vm.expectEmit(true, true, false, true);
        emit TokensMinted(minter, tokenId, amount);

        vm.prank(minter);
        nft.mint{value: MINT_PRICE}(minter, tokenId, amount);

        // Verify balances
        assertEq(nft.balanceOf(minter, tokenId), amount);
        assertEq(nft.totalSupply(tokenId), amount);
        assertEq(nft.totalSupply(), amount);

        // Verify fee distribution
        uint256 platformFee = (MINT_PRICE * FEE_BASIS_POINTS) / 10000;
        uint256 creatorFee = (MINT_PRICE * CREATOR_BASIS_POINTS) / 10000;
        uint256 rewardPoolFee = (MINT_PRICE * REWARD_POOL_BASIS_POINTS) / 10000;
        uint256 treasuryAmount = MINT_PRICE - platformFee - creatorFee - rewardPoolFee;

        assertEq(blueprintRecipient.balance, platformFee);
        assertEq(creator.balance, creatorFee);
        assertEq(rewardPoolRecipient.balance, rewardPoolFee);
        assertEq(treasury.balance, treasuryAmount);
    }

    function test_RevertWhen_MintWithInsufficientPayment() public {
        // Create collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;
        
        uint256 tokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);
        vm.stopPrank();

        // Fast forward to within the drop period
        vm.warp(startTime + 1 hours);

        // Try to mint with insufficient payment
        uint256 amount = 1;
        uint256 insufficientPayment = MINT_PRICE - 1;
        vm.deal(minter, insufficientPayment);
        
        vm.expectRevert(abi.encodeWithSelector(
            BlueprintERC1155Zero.BlueprintERC1155__InsufficientPayment.selector,
            MINT_PRICE,
            insufficientPayment
        ));

        vm.prank(minter);
        nft.mint{value: insufficientPayment}(minter, tokenId, amount);
    }

    function test_RevertWhen_MintAfterDropEnded() public {
        // Create collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;
        
        uint256 tokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);
        vm.stopPrank();

        // Try to mint after drop ended
        vm.warp(endTime + 1);
        vm.deal(minter, MINT_PRICE);
        
        vm.expectRevert(BlueprintERC1155Zero.BlueprintERC1155__DropEnded.selector);

        vm.prank(minter);
        nft.mint{value: MINT_PRICE}(minter, tokenId, 1);
    }

    function test_UpdateDefaultFeeConfig() public {
        uint256 newFeeBasisPoints = 3000;
        uint256 newMintFee = 1 ether;
        uint256 newRewardPoolBasisPoints = 500;

        vm.prank(admin);
        factory.updateDefaultFeeConfig(
            newBlueprintRecipient,
            newFeeBasisPoints,
            newMintFee,
            newTreasury,
            newRewardPoolRecipient,
            newRewardPoolBasisPoints
        );

        assertEq(factory.defaultBlueprintRecipient(), newBlueprintRecipient);
        assertEq(factory.defaultFeeBasisPoints(), newFeeBasisPoints);
        assertEq(factory.defaultMintFee(), newMintFee);
        assertEq(factory.defaultTreasury(), newTreasury);
        assertEq(factory.defaultRewardPoolRecipient(), newRewardPoolRecipient);
        assertEq(factory.defaultRewardPoolBasisPoints(), newRewardPoolBasisPoints);
    }

    function test_InvalidFeeConfig() public {
        // First create a collection
        string memory uri = "https://api.test.xyz/metadata/";
        vm.prank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        // Set high basis points (more than 100% combined)
        // Note: The contract doesn't validate that basis points add up to at most 100%
        vm.prank(admin);
        factory.updateFeeConfig(
            collection,
            blueprintRecipient, // Non-zero address for blueprint recipient
            7000, // 70%
            creator, // Non-zero address for creator recipient
            7000, // 70%
            rewardPoolRecipient, // Non-zero address for reward pool recipient
            2000, // 20%
            treasury
        );

        // Verify the fee configuration was updated successfully
        (
            ,
            uint256 updatedBlueprintBasisPoints,
            ,
            uint256 updatedCreatorBasisPoints,
            ,
            uint256 updatedRewardPoolBasisPoints,
        ) = nft.defaultFeeConfig();

        // Verify values were set correctly
        assertEq(updatedBlueprintBasisPoints, 7000);
        assertEq(updatedCreatorBasisPoints, 7000);
        assertEq(updatedRewardPoolBasisPoints, 2000);
    }

    function test_MaxFeesEdgeCase() public {
        // Setup collection
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        // Set max fees (100%)
        factory.updateFeeConfig(
            collection,
            blueprintRecipient,
            3000, // 30%
            creator,
            5000, // 50%
            rewardPoolRecipient,
            2000, // 20%
            treasury
        );

        // Create a drop
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;

        uint256 tokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);
        vm.stopPrank();

        // Fast forward to after start time
        vm.warp(block.timestamp + 2 days);

        // Setup balances to check fee distribution
        vm.deal(blueprintRecipient, 0);
        vm.deal(creator, 0);
        vm.deal(rewardPoolRecipient, 0);
        vm.deal(treasury, 0);

        // Mint as user
        vm.startPrank(user1);
        vm.deal(user1, 1 ether);

        nft.mint{value: MINT_PRICE}(user1, tokenId, 1);

        // Verify fee distribution
        uint256 blueprintFee = (MINT_PRICE * 3000) / 10000; // 30%
        uint256 creatorFee = (MINT_PRICE * 5000) / 10000; // 50%
        uint256 rewardPoolFee = (MINT_PRICE * 2000) / 10000; // 20%

        assertEq(blueprintRecipient.balance, blueprintFee);
        assertEq(creator.balance, creatorFee);
        assertEq(rewardPoolRecipient.balance, rewardPoolFee);
        assertEq(treasury.balance, 0); // Nothing left for treasury

        vm.stopPrank();
    }

    function test_UpdateFeeConfig() public {
        // Setup collection
        string memory uri = "https://api.test.xyz/metadata/";
        vm.prank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        // Update fee config
        vm.prank(admin);
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
        (
            address updatedBlueprintRecipient,
            uint256 updatedBlueprintBasisPoints,
            address updatedCreatorRecipient,
            uint256 updatedCreatorBasisPoints,
            address updatedRewardPoolRecipient,
            uint256 updatedRewardPoolBasisPoints,
            address updatedTreasury
        ) = nft.defaultFeeConfig();

        assertEq(updatedBlueprintRecipient, newBlueprintRecipient);
        assertEq(updatedBlueprintBasisPoints, 300);
        assertEq(updatedCreatorRecipient, newCreatorRecipient);
        assertEq(updatedCreatorBasisPoints, 1500);
        assertEq(updatedRewardPoolRecipient, newRewardPoolRecipient);
        assertEq(updatedRewardPoolBasisPoints, 200);
        assertEq(updatedTreasury, newTreasury);
    }

    function test_UpdateFeeConfigSpecificValues() public {
        // Setup collection
        string memory uri = "https://api.test.xyz/metadata/";
        vm.prank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        // Update specific fee config values
        vm.prank(admin);
        factory.updateFeeConfig(
            collection,
            blueprintRecipient,
            FEE_BASIS_POINTS,
            newCreatorRecipient,
            2000, // 20%
            rewardPoolRecipient,
            REWARD_POOL_BASIS_POINTS,
            treasury
        );

        // Verify only requested values were updated
        (
            address updatedBlueprintRecipient,
            uint256 updatedBlueprintBasisPoints,
            address updatedCreatorRecipient,
            uint256 updatedCreatorBasisPoints,
            address updatedRewardPoolRecipient,
            uint256 updatedRewardPoolBasisPoints,
            address updatedTreasury
        ) = nft.defaultFeeConfig();

        assertEq(updatedBlueprintRecipient, blueprintRecipient);
        assertEq(updatedBlueprintBasisPoints, FEE_BASIS_POINTS);
        assertEq(updatedCreatorRecipient, newCreatorRecipient);
        assertEq(updatedCreatorBasisPoints, 2000);
        assertEq(updatedRewardPoolRecipient, rewardPoolRecipient);
        assertEq(updatedRewardPoolBasisPoints, REWARD_POOL_BASIS_POINTS);
        assertEq(updatedTreasury, treasury);
    }

    function test_UpdateCreatorRecipient() public {
        // Setup collection
        string memory uri = "https://api.test.xyz/metadata/";
        vm.prank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        vm.prank(admin);
        factory.updateCreatorRecipient(collection, newCreatorRecipient);

        // Verify only creator recipient was updated
        (
            address updatedBlueprintRecipient,
            uint256 updatedBlueprintBasisPoints,
            address updatedCreatorRecipient,
            uint256 updatedCreatorBasisPoints,
            address updatedRewardPoolRecipient,
            uint256 updatedRewardPoolBasisPoints,
            address updatedTreasury
        ) = nft.defaultFeeConfig();

        assertEq(updatedBlueprintRecipient, blueprintRecipient);
        assertEq(updatedBlueprintBasisPoints, FEE_BASIS_POINTS);
        assertEq(updatedCreatorRecipient, newCreatorRecipient);
        assertEq(updatedCreatorBasisPoints, CREATOR_BASIS_POINTS);
        assertEq(updatedRewardPoolRecipient, rewardPoolRecipient);
        assertEq(updatedRewardPoolBasisPoints, REWARD_POOL_BASIS_POINTS);
        assertEq(updatedTreasury, treasury);
    }

    function test_AdminMint() public {
        // Setup collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;
        
        uint256 tokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);

        // Admin mint
        factory.adminMint(collection, user1, tokenId, 5);

        // Verify user received tokens
        assertEq(nft.balanceOf(user1, tokenId), 5);
        vm.stopPrank();
    }

    function test_AdminBatchMint() public {
        // Setup collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;
        
        uint256 tokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);

        // Create another drop
        uint256 secondTokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);

        // Batch mint both drops
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId;
        tokenIds[1] = secondTokenId;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 3;
        amounts[1] = 7;

        factory.adminBatchMint(collection, user1, tokenIds, amounts);

        // Verify user received tokens
        assertEq(nft.balanceOf(user1, tokenId), 3);
        assertEq(nft.balanceOf(user1, secondTokenId), 7);
        vm.stopPrank();
    }

    function test_TokenMetadata() public {
        // Setup collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;
        
        uint256 tokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);

        // Update token URI
        factory.updateTokenURI(collection, tokenId, "ipfs://custom/0");

        // Verify URI was updated
        string memory tokenURI = nft.uri(tokenId);
        assertEq(tokenURI, "ipfs://custom/0");

        // Create a new drop that should use default URI
        uint256 secondTokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);

        // Check that second drop uses base URI with token ID
        string memory baseUri = nft.uri(secondTokenId);
        assertEq(baseUri, string(abi.encodePacked(uri, vm.toString(secondTokenId))));

        vm.stopPrank();
    }

    function test_UpdateRewardPoolRecipient() public {
        // Setup collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        vm.startPrank(admin);

        factory.updateRewardPoolRecipient(collection, newRewardPoolRecipient);

        // Verify updated config
        (,,,, address updatedRewardPoolRecipient,,) = nft.defaultFeeConfig();

        assertEq(updatedRewardPoolRecipient, newRewardPoolRecipient);

        vm.stopPrank();
    }

    function test_TokenFeeConfigWithRewardPool() public {
        // Setup collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;
        
        uint256 tokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);

        // Set token-specific fee config
        factory.updateTokenFeeConfig(
            collection,
            tokenId,
            tokenBlueprintRecipient,
            TOKEN_BLUEPRINT_BASIS_POINTS,
            tokenCreatorRecipient,
            TOKEN_CREATOR_BASIS_POINTS,
            tokenRewardPoolRecipient,
            TOKEN_REWARD_POOL_BASIS_POINTS,
            tokenTreasury
        );

        // Verify updated config
        assertTrue(nft.hasCustomFeeConfig(tokenId));

        // Get the token fee config
        (
            address updatedBlueprintRecipient,
            uint256 updatedBlueprintBasisPoints,
            address updatedCreatorRecipient,
            uint256 updatedCreatorBasisPoints,
            address updatedRewardPoolRecipient,
            uint256 updatedRewardPoolBasisPoints,
            address updatedTreasury
        ) = nft.tokenFeeConfigs(tokenId);

        assertEq(updatedBlueprintRecipient, tokenBlueprintRecipient);
        assertEq(updatedBlueprintBasisPoints, TOKEN_BLUEPRINT_BASIS_POINTS);
        assertEq(updatedCreatorRecipient, tokenCreatorRecipient);
        assertEq(updatedCreatorBasisPoints, TOKEN_CREATOR_BASIS_POINTS);
        assertEq(updatedRewardPoolRecipient, tokenRewardPoolRecipient);
        assertEq(updatedRewardPoolBasisPoints, TOKEN_REWARD_POOL_BASIS_POINTS);
        assertEq(updatedTreasury, tokenTreasury);

        vm.stopPrank();
    }

    function test_TokenFeeDistributionWithRewardPool() public {
        // Setup collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;
        
        uint256 tokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);

        // Set token-specific fee config
        factory.updateTokenFeeConfig(
            collection,
            tokenId,
            tokenBlueprintRecipient,
            TOKEN_BLUEPRINT_BASIS_POINTS,
            tokenCreatorRecipient,
            TOKEN_CREATOR_BASIS_POINTS,
            tokenRewardPoolRecipient,
            TOKEN_REWARD_POOL_BASIS_POINTS,
            tokenTreasury
        );
        vm.stopPrank();

        // Fast forward to within the drop period
        vm.warp(startTime + 1 hours);

        // Setup balances to check fee distribution
        vm.deal(tokenBlueprintRecipient, 0);
        vm.deal(tokenCreatorRecipient, 0);
        vm.deal(tokenRewardPoolRecipient, 0);
        vm.deal(tokenTreasury, 0);

        // Setup user
        vm.startPrank(user1);
        vm.deal(user1, 1 ether);

        // Mint tokens
        nft.mint{value: MINT_PRICE}(user1, tokenId, 1);

        // Calculate expected fees based on token-specific fee config
        uint256 blueprintFee = (MINT_PRICE * TOKEN_BLUEPRINT_BASIS_POINTS) / 10000;
        uint256 creatorFee = (MINT_PRICE * TOKEN_CREATOR_BASIS_POINTS) / 10000;
        uint256 rewardPoolFee = (MINT_PRICE * TOKEN_REWARD_POOL_BASIS_POINTS) / 10000;
        uint256 treasuryAmount = MINT_PRICE - blueprintFee - creatorFee - rewardPoolFee;

        // Verify fee distribution
        assertEq(tokenBlueprintRecipient.balance, blueprintFee);
        assertEq(tokenCreatorRecipient.balance, creatorFee);
        assertEq(tokenRewardPoolRecipient.balance, rewardPoolFee);
        assertEq(tokenTreasury.balance, treasuryAmount);

        vm.stopPrank();
    }

    function test_BatchMintWithRewardPoolFees() public {
        // Setup collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;
        
        uint256 tokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);

        // Create a second drop with custom fee config
        uint256 secondTokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);

        // Set custom fee config for second drop
        factory.updateTokenFeeConfig(
            collection,
            secondTokenId,
            tokenBlueprintRecipient,
            TOKEN_BLUEPRINT_BASIS_POINTS,
            tokenCreatorRecipient,
            TOKEN_CREATOR_BASIS_POINTS,
            tokenRewardPoolRecipient,
            TOKEN_REWARD_POOL_BASIS_POINTS,
            tokenTreasury
        );
        vm.stopPrank();

        // Fast forward to within the drop period
        vm.warp(startTime + 1 hours);

        // Setup balances to check fee distribution
        vm.deal(blueprintRecipient, 0);
        vm.deal(creator, 0);
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
        tokenIds[0] = tokenId; // Uses default fee config
        tokenIds[1] = secondTokenId; // Uses custom fee config

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 3;
        amounts[1] = 2;

        // Calculate total cost
        uint256 totalCost = MINT_PRICE * (amounts[0] + amounts[1]);

        nft.batchMint{value: totalCost}(user1, tokenIds, amounts);

        // Calculate expected fees for first drop (default config)
        uint256 drop1Cost = MINT_PRICE * amounts[0];
        uint256 drop1BlueprintFee = (drop1Cost * FEE_BASIS_POINTS) / 10000;
        uint256 drop1CreatorFee = (drop1Cost * CREATOR_BASIS_POINTS) / 10000;
        uint256 drop1RewardPoolFee = (drop1Cost * REWARD_POOL_BASIS_POINTS) / 10000;
        uint256 drop1TreasuryAmount = drop1Cost - drop1BlueprintFee - drop1CreatorFee - drop1RewardPoolFee;

        // Calculate expected fees for second drop (custom config)
        uint256 drop2Cost = MINT_PRICE * amounts[1];
        uint256 drop2BlueprintFee = (drop2Cost * TOKEN_BLUEPRINT_BASIS_POINTS) / 10000;
        uint256 drop2CreatorFee = (drop2Cost * TOKEN_CREATOR_BASIS_POINTS) / 10000;
        uint256 drop2RewardPoolFee = (drop2Cost * TOKEN_REWARD_POOL_BASIS_POINTS) / 10000;
        uint256 drop2TreasuryAmount = drop2Cost - drop2BlueprintFee - drop2CreatorFee - drop2RewardPoolFee;

        // Verify fee distribution for default config
        assertEq(blueprintRecipient.balance, drop1BlueprintFee);
        assertEq(creator.balance, drop1CreatorFee);
        assertEq(rewardPoolRecipient.balance, drop1RewardPoolFee);
        assertEq(treasury.balance, drop1TreasuryAmount);

        // Verify fee distribution for custom config
        assertEq(tokenBlueprintRecipient.balance, drop2BlueprintFee);
        assertEq(tokenCreatorRecipient.balance, drop2CreatorFee);
        assertEq(tokenRewardPoolRecipient.balance, drop2RewardPoolFee);
        assertEq(tokenTreasury.balance, drop2TreasuryAmount);

        // Verify token balances
        assertEq(nft.balanceOf(user1, tokenId), 3);
        assertEq(nft.balanceOf(user1, secondTokenId), 2);

        vm.stopPrank();
    }

    function test_GetFeeConfig() public {
        // Setup collection
        string memory uri = "https://api.test.xyz/metadata/";
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        // Get fee config
        (
            address blueprintRecipientAddr,
            uint256 blueprintBasisPoints,
            address creatorRecipientAddr,
            uint256 creatorBasisPoints,
            address rewardPoolRecipientAddr,
            uint256 rewardPoolBasisPoints,
            address treasuryAddr
        ) = nft.defaultFeeConfig();

        // Verify fee config matches initial values
        assertEq(blueprintRecipientAddr, blueprintRecipient);
        assertEq(blueprintBasisPoints, FEE_BASIS_POINTS);
        assertEq(creatorRecipientAddr, creator);
        assertEq(creatorBasisPoints, CREATOR_BASIS_POINTS);
        assertEq(rewardPoolRecipientAddr, rewardPoolRecipient);
        assertEq(rewardPoolBasisPoints, REWARD_POOL_BASIS_POINTS);
        assertEq(treasuryAddr, treasury);
    }

    function test_ZeroAddressRewardPoolRecipient() public {
        // Setup collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%
        BlueprintERC1155Zero nft = BlueprintERC1155Zero(collection);

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;
        
        uint256 tokenId = factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);

        // Update with zero address for reward pool
        factory.updateFeeConfig(
            collection,
            blueprintRecipient,
            FEE_BASIS_POINTS,
            creator,
            CREATOR_BASIS_POINTS,
            address(0),
            REWARD_POOL_BASIS_POINTS,
            treasury
        );
        vm.stopPrank();

        // Fast forward to within the drop period
        vm.warp(startTime + 1 hours);

        // Mint and ensure it still works without reward pool fee
        vm.startPrank(user1);
        vm.deal(user1, 1 ether);

        // Setup balances to check fee distribution
        vm.deal(blueprintRecipient, 0);
        vm.deal(creator, 0);
        vm.deal(treasury, 0);

        // Should still be able to mint
        nft.mint{value: MINT_PRICE}(user1, tokenId, 1);

        // Calculate expected fees
        uint256 blueprintFee = (MINT_PRICE * FEE_BASIS_POINTS) / 10000;
        uint256 creatorFee = (MINT_PRICE * CREATOR_BASIS_POINTS) / 10000;

        // When reward pool recipient is address(0), the reward pool fee should go to treasury
        uint256 treasuryAmount = MINT_PRICE - blueprintFee - creatorFee;

        // Verify fee distribution
        assertEq(blueprintRecipient.balance, blueprintFee);
        assertEq(creator.balance, creatorFee);
        assertEq(treasury.balance, treasuryAmount);

        vm.stopPrank();
    }

    function test_RevertOnZeroBlueprintRecipient() public {
        // Create collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;
        
        factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);

        // Update with zero address for blueprint recipient
        vm.expectRevert(
            BlueprintERC1155FactoryZero.BlueprintERC1155Factory__ZeroBlueprintRecipient.selector
        );
        factory.updateFeeConfig(
            collection,
            address(0), // zero address for blueprint recipient
            FEE_BASIS_POINTS,
            creator,
            CREATOR_BASIS_POINTS,
            rewardPoolRecipient,
            REWARD_POOL_BASIS_POINTS,
            treasury
        );
        vm.stopPrank();
    }

    function test_RevertOnZeroCreatorRecipient() public {
        // Create collection and drop
        string memory uri = "https://api.test.xyz/metadata/";
        vm.startPrank(admin);
        address collection = factory.createCollection(uri, creator, 1000); // 1000 basis points = 10%

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;
        
        factory.createNewDrop(collection, MINT_PRICE, startTime, endTime, true);

        // Update with zero address for creator recipient
        vm.expectRevert(
            BlueprintERC1155FactoryZero.BlueprintERC1155Factory__ZeroCreatorRecipient.selector
        );
        factory.updateFeeConfig(
            collection,
            blueprintRecipient,
            FEE_BASIS_POINTS,
            address(0), // zero address for creator recipient
            CREATOR_BASIS_POINTS,
            rewardPoolRecipient,
            REWARD_POOL_BASIS_POINTS,
            treasury
        );
        vm.stopPrank();
    }
} 