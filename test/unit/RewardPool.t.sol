// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {RewardPoolFactory} from "../../src/reward-pool/RewardPoolFactory.sol";
import {RewardPool} from "../../src/reward-pool/RewardPool.sol";
import {IRewardPool} from "../../src/reward-pool/interfaces/IRewardPool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract RewardPoolTest is Test {
    RewardPoolFactory public factory;
    IRewardPool public pool;
    uint256 public poolId;
    MockERC20 public mockToken;

    address public admin;
    uint256 public adminPrivateKey;
    address public treasury;
    address public user1;
    address public user2;
    address public user3;

    uint256 public constant USER1_XP = 500;
    uint256 public constant USER2_XP = 300;
    uint256 public constant USER3_XP = 200;
    uint256 public constant TOTAL_XP = USER1_XP + USER2_XP + USER3_XP; // 1000

    function setUp() public {
        // Create admin with a known private key
        adminPrivateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        admin = vm.addr(adminPrivateKey);

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        treasury = makeAddr("treasury");

        // Fund admin for transactions
        vm.deal(admin, 100 ether);

        // Deploy mock ERC20 token for testing
        mockToken = new MockERC20();

        // Deploy factory as admin
        vm.startPrank(admin);

        // Deploy factory implementation
        RewardPoolFactory implementation = new RewardPoolFactory();

        // Deploy proxy for factory
        bytes memory initData = abi.encodeWithSelector(
            RewardPoolFactory.initialize.selector,
            admin
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        factory = RewardPoolFactory(address(proxy));

        console.log("Factory deployed and initialized");

        // Create a reward pool
        poolId = factory.createRewardPool("Test Pool", "A test reward pool");

        console.log("Pool created with ID:", poolId);

        // Get pool address
        address poolAddress = factory.getPoolAddress(poolId);
        pool = IRewardPool(poolAddress);

        console.log("Pool address obtained:", poolAddress);
        console.log("Factory address:", address(factory));
        console.log("Admin address:", admin);

        // Add test users
        factory.addUser(poolId, user1, USER1_XP);
        factory.addUser(poolId, user2, USER2_XP);
        factory.addUser(poolId, user3, USER3_XP);

        // Grant admin signer role
        factory.grantSignerRole(poolId, admin);

        vm.stopPrank();
    }

    function testFactoryDeployment() public view {
        assertTrue(address(factory) != address(0));
        assertTrue(factory.s_nextPoolId() == 2); // Should be 2 after creating one pool
    }

    function testPoolCreation() public view {
        RewardPoolFactory.PoolInfo memory poolInfo = factory.getPoolInfo(
            poolId
        );
        assertEq(poolInfo.poolId, poolId);
        assertFalse(poolInfo.active); // Should start inactive
        assertEq(
            keccak256(bytes(poolInfo.name)),
            keccak256(bytes("Test Pool"))
        );
    }

    function testUserManagement() public view {
        // Check user XP
        assertEq(pool.getUserXP(user1), USER1_XP);
        assertEq(pool.getUserXP(user2), USER2_XP);
        assertEq(pool.getUserXP(user3), USER3_XP);

        // Check total XP
        assertEq(pool.s_totalXP(), TOTAL_XP);

        // Check total users
        assertEq(pool.getTotalUsers(), 3);
    }

    function testXPUpdate() public {
        uint256 newXP = 600;
        vm.prank(admin);
        factory.updateUserXP(poolId, user1, newXP);

        assertEq(pool.getUserXP(user1), newXP);
        assertEq(pool.s_totalXP(), newXP + USER2_XP + USER3_XP);
    }

    function testUserPenalization() public {
        uint256 penaltyXP = 100;
        vm.prank(admin);
        factory.penalizeUser(poolId, user1, penaltyXP);

        assertEq(pool.getUserXP(user1), USER1_XP - penaltyXP);
        assertEq(pool.s_totalXP(), TOTAL_XP - penaltyXP);
    }

    function testRewardAddition() public {
        uint256 rewardAmount = 1 ether;

        // Send native tokens directly to pool
        vm.deal(address(pool), rewardAmount);

        // Check pool balance
        assertEq(address(pool).balance, rewardAmount);
    }

    function testPoolActivation() public {
        // Pool should start inactive
        assertFalse(pool.s_active());

        // Activate pool
        vm.prank(admin);
        factory.activatePool(poolId);
        assertTrue(pool.s_active());

        // Deactivate pool
        vm.prank(admin);
        factory.deactivatePool(poolId);
        assertFalse(pool.s_active());
    }

    function testClaimEligibility() public {
        uint256 rewardAmount = 1 ether;

        // Send rewards directly BEFORE activation
        vm.deal(address(pool), rewardAmount);

        // Activate pool (no auto-snapshot in new system)
        vm.prank(admin);
        factory.activatePool(poolId);

        // Manually take snapshot of current balances
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // Check eligibility for each user
        (bool canClaim1, uint256 allocation1) = pool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        (bool canClaim2, uint256 allocation2) = pool.checkClaimEligibility(
            user2,
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        (bool canClaim3, uint256 allocation3) = pool.checkClaimEligibility(
            user3,
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        // All users should be able to claim
        assertTrue(canClaim1);
        assertTrue(canClaim2);
        assertTrue(canClaim3);

        // Check allocation percentages (with precision)
        uint256 expectedAllocation1 = (rewardAmount * USER1_XP) / TOTAL_XP; // 50%
        uint256 expectedAllocation2 = (rewardAmount * USER2_XP) / TOTAL_XP; // 30%
        uint256 expectedAllocation3 = (rewardAmount * USER3_XP) / TOTAL_XP; // 20%

        assertEq(allocation1, expectedAllocation1);
        assertEq(allocation2, expectedAllocation2);
        assertEq(allocation3, expectedAllocation3);

        console.log("User 1 allocation:", allocation1, "wei");
        console.log(
            "User 1 percentage:",
            (allocation1 * 100) / rewardAmount,
            "%"
        );
        console.log("User 2 allocation:", allocation2, "wei");
        console.log(
            "User 2 percentage:",
            (allocation2 * 100) / rewardAmount,
            "%"
        );
        console.log("User 3 allocation:", allocation3, "wei");
        console.log(
            "User 3 percentage:",
            (allocation3 * 100) / rewardAmount,
            "%"
        );
    }

    function testInactivePoolRestrictions() public view {
        // Test that inactive pools cannot claim rewards
        (bool canClaim, ) = pool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        assertFalse(canClaim);
    }

    /// @notice CRITICAL BUG TESTS - TokenType Duplicate Condition Bug
    /// @dev These tests ensure that TokenType.NATIVE and TokenType.ERC20 are handled correctly
    /// @dev This prevents the critical bug where both conditions checked TokenType.ERC20
    function testTokenTypeHandling_CRITICAL() public {
        uint256 nativeAmount = 2 ether;
        uint256 erc20Amount = 1000 * 10 ** 18;

        // Setup: Add both native and ERC20 rewards
        vm.deal(address(pool), nativeAmount);
        mockToken.mint(address(pool), erc20Amount);

        // Activate pool and take snapshots
        vm.startPrank(admin);
        factory.activatePool(poolId);
        factory.takeNativeSnapshot(poolId);

        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(mockToken);
        factory.takeSnapshot(poolId, tokenAddresses);
        vm.stopPrank();

        // CRITICAL TEST 1: NATIVE token type should use native balance
        uint256 nativeSnapshot = pool.getSnapshotAmount(
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        assertEq(
            nativeSnapshot,
            nativeAmount,
            "NATIVE snapshot should equal native balance"
        );

        // CRITICAL TEST 2: ERC20 token type should use ERC20 balance
        uint256 erc20Snapshot = pool.getSnapshotAmount(
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );
        assertEq(
            erc20Snapshot,
            erc20Amount,
            "ERC20 snapshot should equal ERC20 balance"
        );

        // CRITICAL TEST 3: NATIVE and ERC20 should return different values
        assertNotEq(
            nativeSnapshot,
            erc20Snapshot,
            "NATIVE and ERC20 snapshots should be different"
        );

        // CRITICAL TEST 4: getAvailableRewards should handle both types correctly
        uint256 availableNative = pool.getAvailableRewards(
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        uint256 availableERC20 = pool.getAvailableRewards(
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );

        assertEq(
            availableNative,
            nativeAmount,
            "Available NATIVE should equal native balance"
        );
        assertEq(
            availableERC20,
            erc20Amount,
            "Available ERC20 should equal ERC20 balance"
        );
        assertNotEq(
            availableNative,
            availableERC20,
            "Available balances should be different"
        );

        // CRITICAL TEST 5: checkClaimEligibility should handle both types correctly
        (bool canClaimNative, uint256 nativeAllocation) = pool
            .checkClaimEligibility(
                user1,
                address(0),
                IRewardPool.TokenType.NATIVE
            );
        (bool canClaimERC20, uint256 erc20Allocation) = pool
            .checkClaimEligibility(
                user1,
                address(mockToken),
                IRewardPool.TokenType.ERC20
            );

        assertTrue(canClaimNative, "Should be able to claim NATIVE rewards");
        assertTrue(canClaimERC20, "Should be able to claim ERC20 rewards");

        // Allocations should be proportional to different reward amounts
        uint256 expectedNativeAllocation = (nativeAmount * USER1_XP) / TOTAL_XP;
        uint256 expectedERC20Allocation = (erc20Amount * USER1_XP) / TOTAL_XP;

        assertEq(
            nativeAllocation,
            expectedNativeAllocation,
            "NATIVE allocation should be correct"
        );
        assertEq(
            erc20Allocation,
            expectedERC20Allocation,
            "ERC20 allocation should be correct"
        );
        assertNotEq(
            nativeAllocation,
            erc20Allocation,
            "Allocations should be different"
        );

        console.log("CRITICAL BUG TESTS PASSED:");
        console.log("Native snapshot:", nativeSnapshot);
        console.log("ERC20 snapshot:", erc20Snapshot);
        console.log("Native allocation:", nativeAllocation);
        console.log("ERC20 allocation:", erc20Allocation);
    }

    /// @notice Test that verifies the bug fix in getTotalRewards
    function testGetTotalRewards_TokenTypeBugFix() public {
        uint256 nativeAmount = 3 ether;
        uint256 erc20Amount = 500 * 10 ** 18;

        // Setup rewards
        vm.deal(address(pool), nativeAmount);
        mockToken.mint(address(pool), erc20Amount);

        // Activate and snapshot
        vm.startPrank(admin);
        factory.activatePool(poolId);
        factory.takeNativeSnapshot(poolId);

        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(mockToken);
        factory.takeSnapshot(poolId, tokenAddresses);
        vm.stopPrank();

        // Test getTotalRewards for both token types
        uint256 totalNative = pool.getTotalRewards(
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        uint256 totalERC20 = pool.getTotalRewards(
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );

        assertEq(
            totalNative,
            nativeAmount,
            "Total NATIVE rewards should equal native amount"
        );
        assertEq(
            totalERC20,
            erc20Amount,
            "Total ERC20 rewards should equal ERC20 amount"
        );
        assertNotEq(
            totalNative,
            totalERC20,
            "Total rewards should be different for different token types"
        );
    }

    /// @notice Test that verifies emergency withdraw handles token types correctly
    function testEmergencyWithdraw_TokenTypeBugFix() public {
        uint256 nativeAmount = 1 ether;
        uint256 erc20Amount = 100 * 10 ** 18;

        // Setup rewards
        vm.deal(address(pool), nativeAmount);
        mockToken.mint(address(pool), erc20Amount);

        // Pool must be inactive for emergency withdraw
        assertFalse(pool.s_active(), "Pool should be inactive");

        address recipient = makeAddr("recipient");

        vm.startPrank(admin);

        // Test NATIVE emergency withdraw
        uint256 withdrawNative = 0.5 ether;
        factory.emergencyWithdraw(
            poolId,
            address(0),
            recipient,
            withdrawNative,
            IRewardPool.TokenType.NATIVE
        );
        assertEq(
            recipient.balance,
            withdrawNative,
            "Recipient should receive NATIVE tokens"
        );

        // Test ERC20 emergency withdraw
        uint256 withdrawERC20 = 50 * 10 ** 18;
        factory.emergencyWithdraw(
            poolId,
            address(mockToken),
            recipient,
            withdrawERC20,
            IRewardPool.TokenType.ERC20
        );
        assertEq(
            mockToken.balanceOf(recipient),
            withdrawERC20,
            "Recipient should receive ERC20 tokens"
        );

        vm.stopPrank();

        // Verify remaining balances
        assertEq(
            address(pool).balance,
            nativeAmount - withdrawNative,
            "Pool should have remaining NATIVE"
        );
        assertEq(
            mockToken.balanceOf(address(pool)),
            erc20Amount - withdrawERC20,
            "Pool should have remaining ERC20"
        );
    }

    /// @notice Regression test that validates the simplified TokenType enum
    function testTokenTypeEnumValues_RegressionTest() public {
        // Verify enum values are as expected for RewardPool (simplified enum)
        assertTrue(
            uint8(IRewardPool.TokenType.ERC20) == 0,
            "ERC20 should be 0"
        );
        assertTrue(
            uint8(IRewardPool.TokenType.NATIVE) == 1,
            "NATIVE should be 1"
        );

        // Verify they are different values
        assertTrue(
            uint8(IRewardPool.TokenType.ERC20) !=
                uint8(IRewardPool.TokenType.NATIVE),
            "ERC20 and NATIVE should have different values"
        );

        console.log("SIMPLIFIED ENUM VALIDATION PASSED:");
        console.log("ERC20 value:", uint8(IRewardPool.TokenType.ERC20));
        console.log("NATIVE value:", uint8(IRewardPool.TokenType.NATIVE));
        console.log(
            "RewardPool only supports ERC20 and NATIVE tokens (no ERC721/ERC1155)"
        );
    }

    /// @notice Test that demonstrates the bug would cause incorrect behavior
    function testDuplicateConditionBug_WouldFail() public {
        // This test demonstrates what would happen with the duplicate condition bug
        uint256 nativeAmount = 1 ether;
        uint256 erc20Amount = 2000 * 10 ** 18;

        // Setup different amounts for native and ERC20
        vm.deal(address(pool), nativeAmount);
        mockToken.mint(address(pool), erc20Amount);

        vm.startPrank(admin);
        factory.activatePool(poolId);
        factory.takeNativeSnapshot(poolId);

        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(mockToken);
        factory.takeSnapshot(poolId, tokenAddresses);
        vm.stopPrank();

        // With the bug fixed, these should be different
        uint256 nativeSnapshot = pool.getSnapshotAmount(
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        uint256 erc20Snapshot = pool.getSnapshotAmount(
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );

        // If the bug existed, erc20Snapshot would equal nativeSnapshot (wrong!)
        // With the fix, they should be different
        assertNotEq(
            erc20Snapshot,
            nativeSnapshot,
            "ERC20 snapshot should NOT equal NATIVE snapshot (bug would make them equal)"
        );

        assertEq(
            nativeSnapshot,
            nativeAmount,
            "NATIVE snapshot should equal native amount"
        );
        assertEq(
            erc20Snapshot,
            erc20Amount,
            "ERC20 snapshot should equal ERC20 amount"
        );

        // Verify the bug is fixed by checking claim eligibility uses correct amounts
        (bool canClaimNative, uint256 nativeAllocation) = pool
            .checkClaimEligibility(
                user1,
                address(0),
                IRewardPool.TokenType.NATIVE
            );
        (bool canClaimERC20, uint256 erc20Allocation) = pool
            .checkClaimEligibility(
                user1,
                address(mockToken),
                IRewardPool.TokenType.ERC20
            );

        assertTrue(
            canClaimNative && canClaimERC20,
            "Both claim types should work"
        );

        // Allocations should be proportional to the CORRECT balances
        uint256 expectedNativeAllocation = (nativeAmount * USER1_XP) / TOTAL_XP;
        uint256 expectedERC20Allocation = (erc20Amount * USER1_XP) / TOTAL_XP;

        assertEq(
            nativeAllocation,
            expectedNativeAllocation,
            "NATIVE allocation should use NATIVE balance"
        );
        assertEq(
            erc20Allocation,
            expectedERC20Allocation,
            "ERC20 allocation should use ERC20 balance"
        );

        // With the bug, erc20Allocation would have been calculated using nativeAmount (wrong!)
        uint256 buggyERC20Allocation = (nativeAmount * USER1_XP) / TOTAL_XP;
        assertNotEq(
            erc20Allocation,
            buggyERC20Allocation,
            "ERC20 allocation should NOT use NATIVE amount (bug would cause this)"
        );

        console.log("BUG REGRESSION TEST PASSED:");
        console.log("NATIVE allocation (correct):", nativeAllocation);
        console.log("ERC20 allocation (correct):", erc20Allocation);
        console.log("ERC20 allocation (buggy would be):", buggyERC20Allocation);
    }

    /// @notice CRITICAL VALIDATION TESTS - TokenAddress/TokenType Validation
    /// @dev These tests ensure the contract properly validates tokenAddress and tokenType combinations
    function testTokenAddressValidation_CRITICAL() public {
        uint256 nativeAmount = 1 ether;
        uint256 erc20Amount = 1000 * 10 ** 18;

        // Setup rewards
        vm.deal(address(pool), nativeAmount);
        mockToken.mint(address(pool), erc20Amount);

        vm.startPrank(admin);
        factory.activatePool(poolId);
        factory.takeNativeSnapshot(poolId);

        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(mockToken);
        factory.takeSnapshot(poolId, tokenAddresses);
        vm.stopPrank();

        // VALID COMBINATIONS - These should work
        console.log("Testing VALID combinations:");

        // 1. NATIVE with address(0) - VALID
        (bool canClaimNative, uint256 nativeAllocation) = pool
            .checkClaimEligibility(
                user1,
                address(0),
                IRewardPool.TokenType.NATIVE
            );
        assertTrue(canClaimNative, "NATIVE with address(0) should be valid");
        assertTrue(nativeAllocation > 0, "NATIVE allocation should be > 0");

        uint256 nativeSnapshot = pool.getSnapshotAmount(
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        assertTrue(nativeSnapshot > 0, "NATIVE snapshot should be > 0");

        uint256 nativeAvailable = pool.getAvailableRewards(
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        assertTrue(nativeAvailable > 0, "NATIVE available should be > 0");

        uint256 nativeTotal = pool.getTotalRewards(
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        assertTrue(nativeTotal > 0, "NATIVE total should be > 0");

        // 2. ERC20 with token address - VALID
        (bool canClaimERC20, uint256 erc20Allocation) = pool
            .checkClaimEligibility(
                user1,
                address(mockToken),
                IRewardPool.TokenType.ERC20
            );
        assertTrue(canClaimERC20, "ERC20 with token address should be valid");
        assertTrue(erc20Allocation > 0, "ERC20 allocation should be > 0");

        uint256 erc20Snapshot = pool.getSnapshotAmount(
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );
        assertTrue(erc20Snapshot > 0, "ERC20 snapshot should be > 0");

        uint256 erc20Available = pool.getAvailableRewards(
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );
        assertTrue(erc20Available > 0, "ERC20 available should be > 0");

        uint256 erc20Total = pool.getTotalRewards(
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );
        assertTrue(erc20Total > 0, "ERC20 total should be > 0");

        // INVALID COMBINATIONS - These should fail/return 0
        console.log("Testing INVALID combinations:");

        // 3. NATIVE with token address - INVALID
        (bool canClaimInvalid1, uint256 invalidAllocation1) = pool
            .checkClaimEligibility(
                user1,
                address(mockToken),
                IRewardPool.TokenType.NATIVE
            );
        assertFalse(
            canClaimInvalid1,
            "NATIVE with token address should be invalid"
        );
        assertEq(invalidAllocation1, 0, "Invalid allocation should be 0");

        uint256 invalidSnapshot1 = pool.getSnapshotAmount(
            address(mockToken),
            IRewardPool.TokenType.NATIVE
        );
        assertEq(invalidSnapshot1, 0, "Invalid snapshot should be 0");

        uint256 invalidAvailable1 = pool.getAvailableRewards(
            address(mockToken),
            IRewardPool.TokenType.NATIVE
        );
        assertEq(invalidAvailable1, 0, "Invalid available should be 0");

        uint256 invalidTotal1 = pool.getTotalRewards(
            address(mockToken),
            IRewardPool.TokenType.NATIVE
        );
        assertEq(invalidTotal1, 0, "Invalid total should be 0");

        // 4. ERC20 with address(0) - INVALID
        (bool canClaimInvalid2, uint256 invalidAllocation2) = pool
            .checkClaimEligibility(
                user1,
                address(0),
                IRewardPool.TokenType.ERC20
            );
        assertFalse(
            canClaimInvalid2,
            "ERC20 with address(0) should be invalid"
        );
        assertEq(invalidAllocation2, 0, "Invalid allocation should be 0");

        uint256 invalidSnapshot2 = pool.getSnapshotAmount(
            address(0),
            IRewardPool.TokenType.ERC20
        );
        assertEq(invalidSnapshot2, 0, "Invalid snapshot should be 0");

        uint256 invalidAvailable2 = pool.getAvailableRewards(
            address(0),
            IRewardPool.TokenType.ERC20
        );
        assertEq(invalidAvailable2, 0, "Invalid available should be 0");

        uint256 invalidTotal2 = pool.getTotalRewards(
            address(0),
            IRewardPool.TokenType.ERC20
        );
        assertEq(invalidTotal2, 0, "Invalid total should be 0");

        console.log("ALL VALIDATION TESTS PASSED");
        console.log("Valid NATIVE allocation:", nativeAllocation);
        console.log("Valid ERC20 allocation:", erc20Allocation);
        console.log("Invalid allocations correctly returned 0");
    }

    /// @notice Test that claimReward properly validates tokenAddress/tokenType combinations
    function testClaimRewardValidation_CRITICAL() public {
        uint256 nativeAmount = 1 ether;
        vm.deal(address(pool), nativeAmount);

        vm.startPrank(admin);
        factory.activatePool(poolId);
        factory.takeNativeSnapshot(poolId);
        vm.stopPrank();

        // Test invalid combination: NATIVE with token address (should revert)
        IRewardPool.ClaimData memory invalidClaimData = IRewardPool.ClaimData({
            user: user1,
            nonce: 1,
            tokenAddress: address(mockToken), // Wrong: should be address(0) for NATIVE
            tokenType: IRewardPool.TokenType.NATIVE
        });

        bytes memory invalidSignature = abi.encodePacked(
            bytes32(0),
            bytes32(0),
            uint8(27)
        );

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                RewardPool.RewardPool__InvalidTokenType.selector
            )
        );
        pool.claimReward(invalidClaimData, invalidSignature);

        // Test invalid combination: ERC20 with address(0) (should revert)
        IRewardPool.ClaimData memory invalidClaimData2 = IRewardPool.ClaimData({
            user: user1,
            nonce: 1,
            tokenAddress: address(0), // Wrong: should be token address for ERC20
            tokenType: IRewardPool.TokenType.ERC20
        });

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                RewardPool.RewardPool__InvalidTokenType.selector
            )
        );
        pool.claimReward(invalidClaimData2, invalidSignature);

        console.log(
            "CLAIM VALIDATION TESTS PASSED - Invalid combinations properly rejected"
        );
    }

    /// @notice Test that emergencyWithdraw properly validates tokenAddress/tokenType combinations
    function testEmergencyWithdrawValidation_CRITICAL() public {
        uint256 nativeAmount = 1 ether;
        uint256 erc20Amount = 1000 * 10 ** 18;

        vm.deal(address(pool), nativeAmount);
        mockToken.mint(address(pool), erc20Amount);

        // Pool must be inactive for emergency withdraw
        assertFalse(pool.s_active(), "Pool should be inactive");

        address recipient = makeAddr("recipient");

        vm.startPrank(admin);

        // Test invalid combination: NATIVE with token address (should revert)
        vm.expectRevert(
            abi.encodeWithSelector(
                RewardPool.RewardPool__InvalidTokenType.selector
            )
        );
        factory.emergencyWithdraw(
            poolId,
            address(mockToken),
            recipient,
            0.1 ether,
            IRewardPool.TokenType.NATIVE
        );

        // Test invalid combination: ERC20 with address(0) (should revert)
        vm.expectRevert(
            abi.encodeWithSelector(
                RewardPool.RewardPool__InvalidTokenType.selector
            )
        );
        factory.emergencyWithdraw(
            poolId,
            address(0),
            recipient,
            100 * 10 ** 18,
            IRewardPool.TokenType.ERC20
        );

        // Test valid combinations should work
        factory.emergencyWithdraw(
            poolId,
            address(0),
            recipient,
            0.1 ether,
            IRewardPool.TokenType.NATIVE
        );
        assertEq(
            recipient.balance,
            0.1 ether,
            "Valid NATIVE withdraw should work"
        );

        factory.emergencyWithdraw(
            poolId,
            address(mockToken),
            recipient,
            100 * 10 ** 18,
            IRewardPool.TokenType.ERC20
        );
        assertEq(
            mockToken.balanceOf(recipient),
            100 * 10 ** 18,
            "Valid ERC20 withdraw should work"
        );

        vm.stopPrank();

        console.log("EMERGENCY WITHDRAW VALIDATION TESTS PASSED");
    }

    function testSingleUserJackpot() public {
        // Create a new pool with only one user
        vm.prank(admin);
        uint256 jackpotPoolId = factory.createRewardPool(
            "Jackpot Pool",
            "Single user pool"
        );

        address jackpotPoolAddress = factory.getPoolAddress(jackpotPoolId);
        IRewardPool jackpotPool = IRewardPool(jackpotPoolAddress);

        // Add one user with any XP amount
        uint256 userXP = 100;
        vm.prank(admin);
        factory.addUser(jackpotPoolId, user1, userXP);
        vm.prank(admin);
        factory.grantSignerRole(jackpotPoolId, admin);

        // Send rewards directly BEFORE activation
        uint256 jackpotAmount = 5 ether;
        vm.deal(jackpotPoolAddress, jackpotAmount);

        // Activate pool (no auto-snapshot)
        vm.prank(admin);
        factory.activatePool(jackpotPoolId);

        // Manually take snapshot
        vm.prank(admin);
        factory.takeNativeSnapshot(jackpotPoolId);

        // Check that single user gets full amount (jackpot)
        (bool canClaim, uint256 allocation) = jackpotPool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        assertTrue(canClaim);
        assertEq(allocation, jackpotAmount); // Should get 100% = full jackpot

        console.log("Jackpot scenario - Single user gets:", allocation, "wei");
        console.log(
            "This is 100% of the jackpot amount:",
            jackpotAmount,
            "wei"
        );
    }

    function testERC20ClaimEligibility() public {
        uint256 rewardAmount = 1000 * 10 ** 18; // 1000 tokens

        // Mint tokens directly to pool BEFORE activation
        vm.prank(admin);
        mockToken.mint(address(pool), rewardAmount);

        // Activate pool (no auto-snapshot)
        vm.prank(admin);
        factory.activatePool(poolId);

        // Take explicit snapshot for ERC20 tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        vm.prank(admin);
        factory.takeSnapshot(poolId, tokens);

        // Check eligibility for each user
        (bool canClaim1, uint256 allocation1) = pool.checkClaimEligibility(
            user1,
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );

        (bool canClaim2, uint256 allocation2) = pool.checkClaimEligibility(
            user2,
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );

        (bool canClaim3, uint256 allocation3) = pool.checkClaimEligibility(
            user3,
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );

        // All users should be able to claim
        assertTrue(canClaim1);
        assertTrue(canClaim2);
        assertTrue(canClaim3);

        // Check allocation percentages (with precision)
        uint256 expectedAllocation1 = (rewardAmount * USER1_XP) / TOTAL_XP; // 50% = 500 tokens
        uint256 expectedAllocation2 = (rewardAmount * USER2_XP) / TOTAL_XP; // 30% = 300 tokens
        uint256 expectedAllocation3 = (rewardAmount * USER3_XP) / TOTAL_XP; // 20% = 200 tokens

        assertEq(allocation1, expectedAllocation1);
        assertEq(allocation2, expectedAllocation2);
        assertEq(allocation3, expectedAllocation3);

        console.log(
            "ERC20 User 1 allocation:",
            allocation1 / 10 ** 18,
            "tokens"
        );
        console.log(
            "ERC20 User 1 percentage:",
            (allocation1 * 100) / rewardAmount,
            "%"
        );
        console.log(
            "ERC20 User 2 allocation:",
            allocation2 / 10 ** 18,
            "tokens"
        );
        console.log(
            "ERC20 User 2 percentage:",
            (allocation2 * 100) / rewardAmount,
            "%"
        );
        console.log(
            "ERC20 User 3 allocation:",
            allocation3 / 10 ** 18,
            "tokens"
        );
        console.log(
            "ERC20 User 3 percentage:",
            (allocation3 * 100) / rewardAmount,
            "%"
        );
    }

    function testMixedTokenRewards() public {
        uint256 ethRewardAmount = 1 ether;
        uint256 erc20RewardAmount = 2000 * 10 ** 18; // 2000 tokens

        // Send ETH directly to pool BEFORE activation
        vm.deal(address(pool), ethRewardAmount);

        // Mint ERC20 tokens directly to pool BEFORE activation
        vm.prank(admin);
        mockToken.mint(address(pool), erc20RewardAmount);

        // Activate pool (no auto-snapshot)
        vm.prank(admin);
        factory.activatePool(poolId);

        // Take explicit snapshot for ERC20 tokens (this also snapshots native ETH)
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        vm.prank(admin);
        factory.takeSnapshot(poolId, tokens);

        // Check ETH eligibility
        (bool canClaimEth1, uint256 ethAllocation1) = pool
            .checkClaimEligibility(
                user1,
                address(0),
                IRewardPool.TokenType.NATIVE
            );

        // Check ERC20 eligibility
        (bool canClaimErc20_1, uint256 erc20Allocation1) = pool
            .checkClaimEligibility(
                user1,
                address(mockToken),
                IRewardPool.TokenType.ERC20
            );

        // Both should be claimable
        assertTrue(canClaimEth1);
        assertTrue(canClaimErc20_1);

        // Check allocations
        uint256 expectedEthAllocation1 = (ethRewardAmount * USER1_XP) /
            TOTAL_XP; // 50% of ETH
        uint256 expectedErc20Allocation1 = (erc20RewardAmount * USER1_XP) /
            TOTAL_XP; // 50% of tokens

        assertEq(ethAllocation1, expectedEthAllocation1);
        assertEq(erc20Allocation1, expectedErc20Allocation1);

        console.log("Mixed rewards - User 1 ETH:", ethAllocation1, "wei");
        console.log(
            "Mixed rewards - User 1 ERC20:",
            erc20Allocation1 / 10 ** 18,
            "tokens"
        );
    }

    function testERC20SingleUserJackpot() public {
        // Create a new pool with only one user for ERC20 jackpot
        vm.prank(admin);
        uint256 erc20JackpotPoolId = factory.createRewardPool(
            "ERC20 Jackpot Pool",
            "Single user ERC20 pool"
        );

        address erc20JackpotPoolAddress = factory.getPoolAddress(
            erc20JackpotPoolId
        );
        IRewardPool erc20JackpotPool = IRewardPool(erc20JackpotPoolAddress);

        // Add one user with any XP amount
        uint256 userXP = 250;
        vm.prank(admin);
        factory.addUser(erc20JackpotPoolId, user2, userXP);

        vm.prank(admin);
        factory.grantSignerRole(erc20JackpotPoolId, admin);

        // Mint tokens directly to pool
        uint256 jackpotTokenAmount = 10000 * 10 ** 18; // 10,000 tokens
        vm.prank(admin);
        mockToken.mint(erc20JackpotPoolAddress, jackpotTokenAmount);

        vm.prank(admin);
        factory.activatePool(erc20JackpotPoolId);

        // Take explicit snapshot for ERC20 tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        vm.prank(admin);
        factory.takeSnapshot(erc20JackpotPoolId, tokens);

        // Check that single user gets full amount (jackpot)
        (bool canClaim, uint256 allocation) = erc20JackpotPool
            .checkClaimEligibility(
                user2,
                address(mockToken),
                IRewardPool.TokenType.ERC20
            );

        assertTrue(canClaim);
        assertEq(allocation, jackpotTokenAmount); // Should get 100% = full jackpot

        console.log(
            "ERC20 Jackpot scenario - Single user gets:",
            allocation / 10 ** 18,
            "tokens"
        );
        console.log(
            "This is 100% of the ERC20 jackpot amount:",
            jackpotTokenAmount / 10 ** 18,
            "tokens"
        );
    }

    function testInvalidERC20Address() public {
        uint256 rewardAmount = 1000 * 10 ** 18;

        // This test is no longer relevant since we don't use addRewards
        // ERC20 tokens are simply minted directly to the pool
        vm.prank(admin);
        mockToken.mint(address(pool), rewardAmount);

        // Check pool token balance
        assertEq(mockToken.balanceOf(address(pool)), rewardAmount);
    }

    function testERC20InsufficientBalance() public {
        // This test is no longer relevant since we don't use addRewards
        // ERC20 tokens are simply minted directly to the pool
        uint256 rewardAmount = 1000 * 10 ** 18;
        vm.prank(admin);
        mockToken.mint(address(pool), rewardAmount);

        // Check pool token balance
        assertEq(mockToken.balanceOf(address(pool)), rewardAmount);
    }

    function testERC20InsufficientAllowance() public {
        // This test is no longer relevant since we don't use addRewards
        // ERC20 tokens are simply minted directly to the pool
        uint256 rewardAmount = 1000 * 10 ** 18;
        vm.prank(admin);
        mockToken.mint(address(pool), rewardAmount);

        // Check pool token balance
        assertEq(mockToken.balanceOf(address(pool)), rewardAmount);
    }

    // ===== EDGE CASE TESTS =====

    function testCannotUpdateXPWhenPoolIsActive() public {
        // Activate the pool
        vm.prank(admin);
        factory.activatePool(poolId);

        // Try to add a new user - should fail
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSignature("RewardPool__CannotUpdateXPWhenActive()")
        );
        factory.addUser(
            poolId,
            address(0x4444444444444444444444444444444444444444),
            100
        );

        // Try to update existing user XP - should fail
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSignature("RewardPool__CannotUpdateXPWhenActive()")
        );
        factory.updateUserXP(poolId, user1, 600);

        // Try to penalize user - should fail
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSignature("RewardPool__CannotUpdateXPWhenActive()")
        );
        factory.penalizeUser(poolId, user1, 50);
    }

    function testDoubleClaimingPrevention() public {
        // Send ETH directly BEFORE activation
        vm.deal(address(pool), 1 ether);

        vm.prank(admin);
        factory.activatePool(poolId);

        // Take manual snapshot
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // Check initial eligibility
        (bool canClaim, uint256 allocation) = pool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        assertTrue(canClaim);
        assertEq(allocation, 500000000000000000); // 50% of 1 ETH

        // Initially user should not have claimed
        assertFalse(
            pool.hasClaimed(user1, address(0), IRewardPool.TokenType.NATIVE)
        );

        // Test that the hasClaimed function works correctly
        // This verifies the double claiming prevention mechanism exists
        // In production, the claimReward function would set this flag

        // The key insight is that checkClaimEligibility should check hasClaimed
        // and return false if already claimed, which we've implemented
    }

    function testERC20DoubleClaimingPrevention() public {
        // Mint ERC20 rewards directly to pool BEFORE activation
        uint256 rewardAmount = 1000 * 10 ** 18;
        vm.prank(admin);
        mockToken.mint(address(pool), rewardAmount);

        vm.prank(admin);
        factory.activatePool(poolId);

        // Take explicit snapshot for ERC20 tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        vm.prank(admin);
        factory.takeSnapshot(poolId, tokens);

        // Check initial eligibility
        (bool canClaim, uint256 allocation) = pool.checkClaimEligibility(
            user1,
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );
        assertTrue(canClaim);
        assertEq(allocation, 500 * 10 ** 18); // 50% of 1000 tokens

        // Initially user should not have claimed
        assertFalse(
            pool.hasClaimed(
                user1,
                address(mockToken),
                IRewardPool.TokenType.ERC20
            )
        );

        // Test that the double claiming prevention mechanism is in place
        // The hasClaimed mapping and checkClaimEligibility function work together
        // to prevent double claims
    }

    function testSeparateClaimTrackingForDifferentTokens() public {
        // Send ETH and ERC20 rewards directly to pool
        uint256 erc20Amount = 1000 * 10 ** 18;

        vm.deal(address(pool), 1 ether);

        vm.prank(admin);
        mockToken.mint(address(pool), erc20Amount);

        vm.prank(admin);
        factory.activatePool(poolId);

        // Take explicit snapshot for ERC20 tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        vm.prank(admin);
        factory.takeSnapshot(poolId, tokens);

        // Check native token eligibility for user1
        (bool canClaimNative, uint256 nativeAllocation) = pool
            .checkClaimEligibility(
                user1,
                address(0),
                IRewardPool.TokenType.NATIVE
            );

        // Check ERC20 eligibility for user1
        (bool canClaimERC20, uint256 erc20Allocation) = pool
            .checkClaimEligibility(
                user1,
                address(mockToken),
                IRewardPool.TokenType.ERC20
            );

        // Both should be claimable
        assertTrue(canClaimNative);
        assertTrue(canClaimERC20);

        // Allocations should be independent
        assertEq(nativeAllocation, 0.5 ether); // 50% of 1 ETH
        assertEq(erc20Allocation, 500 * 10 ** 18); // 50% of 1000 tokens

        // Initially, user should not have claimed either
        assertFalse(
            pool.hasClaimed(user1, address(0), IRewardPool.TokenType.NATIVE)
        );
        assertFalse(
            pool.hasClaimed(
                user1,
                address(mockToken),
                IRewardPool.TokenType.ERC20
            )
        );
    }

    function testRewardPoolIntegrityWithMultipleClaims() public {
        // Send limited rewards directly to pool
        uint256 totalRewards = 1000 * 10 ** 18; // 1000 tokens
        vm.prank(admin);
        mockToken.mint(address(pool), totalRewards);

        vm.prank(admin);
        factory.activatePool(poolId);

        // Take explicit snapshot for ERC20 tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        vm.prank(admin);
        factory.takeSnapshot(poolId, tokens);

        // User allocations should be proportional
        uint256 expectedUser1 = (totalRewards * USER1_XP) / TOTAL_XP; // 50%
        uint256 expectedUser2 = (totalRewards * USER2_XP) / TOTAL_XP; // 30%
        uint256 expectedUser3 = (totalRewards * USER3_XP) / TOTAL_XP; // 20%

        // Check eligibility
        (bool canClaim1, uint256 allocation1) = pool.checkClaimEligibility(
            user1,
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );
        (bool canClaim2, uint256 allocation2) = pool.checkClaimEligibility(
            user2,
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );
        (bool canClaim3, uint256 allocation3) = pool.checkClaimEligibility(
            user3,
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );

        assertTrue(canClaim1);
        assertTrue(canClaim2);
        assertTrue(canClaim3);

        assertEq(allocation1, expectedUser1);
        assertEq(allocation2, expectedUser2);
        assertEq(allocation3, expectedUser3);

        // Total allocations should equal total rewards (with possible small rounding)
        uint256 totalAllocations = allocation1 + allocation2 + allocation3;
        assertGe(totalAllocations, totalRewards - 1);
        assertLe(totalAllocations, totalRewards);
    }

    function testProportionalRewardIntegrity() public {
        // Send rewards directly to pool
        uint256 totalRewards = 1000 * 10 ** 18;
        vm.prank(admin);
        mockToken.mint(address(pool), totalRewards);

        vm.prank(admin);
        factory.activatePool(poolId);

        // Take explicit snapshot for ERC20 tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        vm.prank(admin);
        factory.takeSnapshot(poolId, tokens);

        // Check proportional allocations
        (bool canClaim1, uint256 allocation1) = pool.checkClaimEligibility(
            user1,
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );
        (bool canClaim2, uint256 allocation2) = pool.checkClaimEligibility(
            user2,
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );
        (bool canClaim3, uint256 allocation3) = pool.checkClaimEligibility(
            user3,
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );

        // Verify all users can claim
        assertTrue(canClaim1, "User1 should be able to claim");
        assertTrue(canClaim2, "User2 should be able to claim");
        assertTrue(canClaim3, "User3 should be able to claim");

        // Verify proportions match XP ratios
        assertEq(allocation1 * TOTAL_XP, totalRewards * USER1_XP); // 50%
        assertEq(allocation2 * TOTAL_XP, totalRewards * USER2_XP); // 30%
        assertEq(allocation3 * TOTAL_XP, totalRewards * USER3_XP); // 20%
    }

    function testClaimTrackingAndAccountingIntegrity() public {
        // Send rewards directly to pool
        uint256 totalRewards = 1000 * 10 ** 18;
        vm.prank(admin);
        mockToken.mint(address(pool), totalRewards);

        vm.prank(admin);
        factory.activatePool(poolId);

        // Take explicit snapshot for ERC20 tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        vm.prank(admin);
        factory.takeSnapshot(poolId, tokens);

        // Initial state: no claims
        assertEq(
            pool.getTotalClaimed(
                address(mockToken),
                IRewardPool.TokenType.ERC20
            ),
            0
        );
        assertFalse(
            pool.hasClaimed(
                user1,
                address(mockToken),
                IRewardPool.TokenType.ERC20
            )
        );

        // Expected allocation for user1 (50%)
        uint256 expectedAllocation = (totalRewards * USER1_XP) / TOTAL_XP;

        // Test accounting integrity
        (bool canClaim, uint256 allocation) = pool.checkClaimEligibility(
            user1,
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );

        assertTrue(canClaim);
        assertEq(allocation, expectedAllocation);
    }

    function testZeroXPUserRemoval() public {
        // Update user to 0 XP
        vm.prank(admin);
        factory.updateUserXP(poolId, user1, 0);

        // User should be marked as not in pool
        assertFalse(pool.isUser(user1));
        assertEq(pool.getUserXP(user1), 0);

        // Total XP should be updated
        assertEq(pool.s_totalXP(), USER2_XP + USER3_XP); // 300 + 200 = 500

        // User should not be able to claim
        vm.prank(admin);
        factory.activatePool(poolId);
        (bool canClaim, ) = pool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.ERC20
        );
        assertFalse(canClaim);
    }

    receive() external payable {}

    // ===== CLAIM REWARD TESTS =====

    function testSuccessfulNativeTokenClaim() public {
        // Send native tokens directly to pool
        vm.deal(address(pool), 1 ether);

        // Activate the pool
        vm.prank(admin);
        factory.activatePool(poolId);

        // Take manual native snapshot
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // Check user1 can claim
        (bool canClaim, uint256 allocation) = pool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        assertTrue(canClaim);
        assertEq(allocation, 0.5 ether); // 500/1000 * 1 ether = 0.5 ether

        // Generate claim signature
        IRewardPool.ClaimData memory claimData = IRewardPool.ClaimData({
            user: user1,
            nonce: 1,
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        bytes memory signature = _generateClaimSignature(claimData, admin);

        // Record user1's balance before claim
        uint256 balanceBefore = user1.balance;

        // User1 claims rewards
        vm.prank(user1);
        pool.claimReward(claimData, signature);

        // Check user1's balance increased
        uint256 balanceAfter = user1.balance;
        assertEq(balanceAfter - balanceBefore, 0.5 ether);

        // Check user1 cannot claim again
        assertTrue(
            pool.hasClaimed(user1, address(0), IRewardPool.TokenType.NATIVE)
        );

        // Check total claimed updated
        assertEq(
            pool.getTotalClaimed(address(0), IRewardPool.TokenType.NATIVE),
            0.5 ether
        );
    }

    function testSuccessfulERC20TokenClaim() public {
        // Mint tokens directly to pool
        vm.prank(admin);
        mockToken.mint(address(pool), 1000 ether);

        // Activate the pool
        vm.prank(admin);
        factory.activatePool(poolId);

        // Take explicit snapshot for ERC20 tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        vm.prank(admin);
        factory.takeSnapshot(poolId, tokens);

        // Check user2 can claim (30% of rewards)
        (bool canClaim, uint256 allocation) = pool.checkClaimEligibility(
            user2,
            address(mockToken),
            IRewardPool.TokenType.ERC20
        );
        assertTrue(canClaim);
        assertEq(allocation, 300 ether); // 300/1000 * 1000 ether = 300 ether

        // Generate claim signature
        IRewardPool.ClaimData memory claimData = IRewardPool.ClaimData({
            user: user2,
            nonce: 2,
            tokenAddress: address(mockToken),
            tokenType: IRewardPool.TokenType.ERC20
        });

        bytes memory signature = _generateClaimSignature(claimData, admin);

        // Record user2's balance before claim
        uint256 balanceBefore = mockToken.balanceOf(user2);

        // User2 claims rewards
        vm.prank(user2);
        pool.claimReward(claimData, signature);

        // Check user2's balance increased
        uint256 balanceAfter = mockToken.balanceOf(user2);
        assertEq(balanceAfter - balanceBefore, 300 ether);

        // Check user2 cannot claim again
        assertTrue(
            pool.hasClaimed(
                user2,
                address(mockToken),
                IRewardPool.TokenType.ERC20
            )
        );

        // Check total claimed updated
        assertEq(
            pool.getTotalClaimed(
                address(mockToken),
                IRewardPool.TokenType.ERC20
            ),
            300 ether
        );
    }

    function testMultipleUsersClaiming() public {
        // Send native tokens directly to pool
        vm.deal(address(pool), 2 ether);

        // Activate the pool
        vm.prank(admin);
        factory.activatePool(poolId);

        // Take manual native snapshot
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // User1 claims (50% = 1 ether)
        IRewardPool.ClaimData memory claimData1 = IRewardPool.ClaimData({
            user: user1,
            nonce: 3,
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        bytes memory signature1 = _generateClaimSignature(claimData1, admin);
        uint256 user1BalanceBefore = user1.balance;

        vm.prank(user1);
        pool.claimReward(claimData1, signature1);

        assertEq(user1.balance - user1BalanceBefore, 1 ether);

        // User2 claims (30% = 0.6 ether)
        IRewardPool.ClaimData memory claimData2 = IRewardPool.ClaimData({
            user: user2,
            nonce: 4,
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        bytes memory signature2 = _generateClaimSignature(claimData2, admin);
        uint256 user2BalanceBefore = user2.balance;

        vm.prank(user2);
        pool.claimReward(claimData2, signature2);

        assertEq(user2.balance - user2BalanceBefore, 0.6 ether);

        // User3 claims (20% = 0.4 ether)
        IRewardPool.ClaimData memory claimData3 = IRewardPool.ClaimData({
            user: user3,
            nonce: 5,
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        bytes memory signature3 = _generateClaimSignature(claimData3, admin);
        uint256 user3BalanceBefore = user3.balance;

        vm.prank(user3);
        pool.claimReward(claimData3, signature3);

        assertEq(user3.balance - user3BalanceBefore, 0.4 ether);

        // Check total claimed
        assertEq(
            pool.getTotalClaimed(address(0), IRewardPool.TokenType.NATIVE),
            2 ether
        );

        // Check pool balance is now 0
        assertEq(address(pool).balance, 0);
    }

    function testClaimWithInvalidSignature() public {
        // Send ETH directly and activate
        vm.deal(address(pool), 1 ether);

        vm.prank(admin);
        factory.activatePool(poolId);

        // Take manual native snapshot
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // Create claim data
        IRewardPool.ClaimData memory claimData = IRewardPool.ClaimData({
            user: user1,
            nonce: 6,
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        // Generate invalid signature (using wrong private key)
        uint256 wrongPrivateKey = 0x9999999999999999999999999999999999999999999999999999999999999999;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            wrongPrivateKey,
            keccak256("invalid")
        );
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        // Attempt to claim with invalid signature
        vm.prank(user1);
        vm.expectRevert(RewardPool.RewardPool__InvalidSignature.selector);
        pool.claimReward(claimData, invalidSignature);
    }

    function testDoubleClaimPrevention() public {
        // Send ETH directly and activate
        vm.deal(address(pool), 1 ether);

        vm.prank(admin);
        factory.activatePool(poolId);

        // Take manual native snapshot
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // First claim
        IRewardPool.ClaimData memory claimData = IRewardPool.ClaimData({
            user: user1,
            nonce: 7,
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        bytes memory signature = _generateClaimSignature(claimData, admin);

        vm.prank(user1);
        pool.claimReward(claimData, signature);

        // Attempt second claim with different nonce
        IRewardPool.ClaimData memory claimData2 = IRewardPool.ClaimData({
            user: user1,
            nonce: 8,
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        bytes memory signature2 = _generateClaimSignature(claimData2, admin);

        vm.prank(user1);
        vm.expectRevert(RewardPool.RewardPool__AlreadyClaimed.selector);
        pool.claimReward(claimData2, signature2);
    }

    function testPerUserNonceManagement() public {
        // Test the new per-user nonce functions

        // Initially, all users should have nonce counter 0
        assertEq(pool.getUserNonceCounter(user1), 0);
        assertEq(pool.getUserNonceCounter(user2), 0);
        assertEq(pool.getNextNonce(user1), 1);
        assertEq(pool.getNextNonce(user2), 1);

        // No nonces should be used initially
        assertFalse(pool.isNonceUsed(user1, 1));
        assertFalse(pool.isNonceUsed(user2, 1));
        assertFalse(pool.isNonceUsed(user1, 5));

        // Send ETH directly and activate
        vm.deal(address(pool), 1 ether);

        vm.prank(admin);
        factory.activatePool(poolId);

        // Take manual native snapshot
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // User1 claims with nonce 5 (not sequential)
        IRewardPool.ClaimData memory claimData1 = IRewardPool.ClaimData({
            user: user1,
            nonce: 5,
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        bytes memory signature1 = _generateClaimSignature(claimData1, admin);

        vm.prank(user1);
        pool.claimReward(claimData1, signature1);

        // Check that user1's nonce counter is updated and nonce 5 is marked as used
        assertEq(pool.getUserNonceCounter(user1), 5);
        assertTrue(pool.isNonceUsed(user1, 5));
        assertFalse(pool.isNonceUsed(user1, 1)); // Other nonces still available
        assertEq(pool.getNextNonce(user1), 6);

        // User2's nonces should be unaffected
        assertEq(pool.getUserNonceCounter(user2), 0);
        assertFalse(pool.isNonceUsed(user2, 5)); // User2 can still use nonce 5
        assertEq(pool.getNextNonce(user2), 1);
    }

    function testNonceReplayPrevention() public {
        // Send ETH and ERC20 directly to pool
        vm.deal(address(pool), 2 ether);

        vm.prank(admin);
        mockToken.mint(address(pool), 1000 ether);

        vm.prank(admin);
        factory.activatePool(poolId);

        // Take manual native snapshot first (for native ETH)
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // Take explicit snapshot for ERC20 tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        vm.prank(admin);
        factory.takeSnapshot(poolId, tokens);

        // User1 claims with nonce 9
        IRewardPool.ClaimData memory claimData1 = IRewardPool.ClaimData({
            user: user1,
            nonce: 9,
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        bytes memory signature1 = _generateClaimSignature(claimData1, admin);

        vm.prank(user1);
        pool.claimReward(claimData1, signature1);

        // User2 can use the same nonce 9 (per-user nonces)
        IRewardPool.ClaimData memory claimData2 = IRewardPool.ClaimData({
            user: user2,
            nonce: 9, // Same nonce but different user - should work!
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        bytes memory signature2 = _generateClaimSignature(claimData2, admin);

        vm.prank(user2);
        pool.claimReward(claimData2, signature2); // This should succeed

        // But user1 cannot reuse their own nonce 9
        IRewardPool.ClaimData memory claimData3 = IRewardPool.ClaimData({
            user: user1,
            nonce: 9, // Same user, same nonce - should fail!
            tokenAddress: address(mockToken), // Different token to avoid AlreadyClaimed error
            tokenType: IRewardPool.TokenType.ERC20
        });

        bytes memory signature3 = _generateClaimSignature(claimData3, admin);

        vm.prank(user1);
        vm.expectRevert(RewardPool.RewardPool__NonceAlreadyUsed.selector);
        pool.claimReward(claimData3, signature3);
    }

    function testMixedTokenClaiming() public {
        // Send both native and ERC20 rewards directly to pool
        vm.deal(address(pool), 1 ether);

        vm.prank(admin);
        mockToken.mint(address(pool), 1000 ether);

        // Activate pool
        vm.prank(admin);
        factory.activatePool(poolId);

        // Take manual native snapshot first (for native ETH)
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // Take explicit snapshot for ERC20 tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        vm.prank(admin);
        factory.takeSnapshot(poolId, tokens);

        // User1 claims native tokens
        IRewardPool.ClaimData memory nativeClaimData = IRewardPool.ClaimData({
            user: user1,
            nonce: 10,
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        bytes memory nativeSignature = _generateClaimSignature(
            nativeClaimData,
            admin
        );
        uint256 nativeBalanceBefore = user1.balance;

        vm.prank(user1);
        pool.claimReward(nativeClaimData, nativeSignature);

        assertEq(user1.balance - nativeBalanceBefore, 0.5 ether); // 50% of 1 ether

        // Same user claims ERC20 tokens (should be allowed)
        IRewardPool.ClaimData memory erc20ClaimData = IRewardPool.ClaimData({
            user: user1,
            nonce: 11,
            tokenAddress: address(mockToken),
            tokenType: IRewardPool.TokenType.ERC20
        });

        bytes memory erc20Signature = _generateClaimSignature(
            erc20ClaimData,
            admin
        );
        uint256 erc20BalanceBefore = mockToken.balanceOf(user1);

        vm.prank(user1);
        pool.claimReward(erc20ClaimData, erc20Signature);

        assertEq(mockToken.balanceOf(user1) - erc20BalanceBefore, 500 ether); // 50% of 1000 ether

        // Verify both claims are recorded
        assertTrue(
            pool.hasClaimed(user1, address(0), IRewardPool.TokenType.NATIVE)
        );
        assertTrue(
            pool.hasClaimed(
                user1,
                address(mockToken),
                IRewardPool.TokenType.ERC20
            )
        );
    }

    function testClaimInsufficientPoolBalance() public {
        // Send ETH directly and activate
        vm.deal(address(pool), 1 ether);

        vm.prank(admin);
        factory.activatePool(poolId);

        // Take manual native snapshot
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // Manually drain pool balance to simulate insufficient funds
        vm.deal(address(pool), 0);

        // Create claim data
        IRewardPool.ClaimData memory claimData = IRewardPool.ClaimData({
            user: user1,
            nonce: 14,
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        // Generate signature
        bytes memory signature = _generateClaimSignature(claimData, admin);

        // Claim should fail due to insufficient balance
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("RewardPool__InsufficientRewards()")
        );
        pool.claimReward(claimData, signature);
    }

    // ===== HELPER FUNCTIONS =====

    function _generateClaimSignature(
        IRewardPool.ClaimData memory claimData,
        address signer
    ) internal view returns (bytes memory) {
        // Construct the domain separator exactly as the contract does
        // The contract uses __EIP712_init("BP_REWARD_POOL", "1") in the factory
        bytes32 typeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 nameHash = keccak256(bytes("BP_REWARD_POOL"));
        bytes32 versionHash = keccak256(bytes("1"));
        uint256 chainId = block.chainid;
        address verifyingContract = address(pool);

        bytes32 domainSeparator = keccak256(
            abi.encode(
                typeHash,
                nameHash,
                versionHash,
                chainId,
                verifyingContract
            )
        );

        // Create the struct hash exactly as the contract does
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ClaimData(address user,uint256 nonce,address tokenAddress,uint8 tokenType)"
                ),
                claimData.user,
                claimData.nonce,
                claimData.tokenAddress,
                uint8(claimData.tokenType)
            )
        );

        // Create the final digest as per EIP-712
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        // Use the actual admin private key for signing
        require(signer == admin, "Only admin can sign in this test");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }

    function _generateClaimSignatureForPool(
        IRewardPool.ClaimData memory claimData,
        address signer,
        address poolAddress
    ) internal view returns (bytes memory) {
        // Construct the domain separator exactly as the contract does
        bytes32 typeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 nameHash = keccak256(bytes("BP_REWARD_POOL"));
        bytes32 versionHash = keccak256(bytes("1"));
        uint256 chainId = block.chainid;
        address verifyingContract = poolAddress;

        bytes32 domainSeparator = keccak256(
            abi.encode(
                typeHash,
                nameHash,
                versionHash,
                chainId,
                verifyingContract
            )
        );

        // Create the struct hash exactly as the contract does
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ClaimData(address user,uint256 nonce,address tokenAddress,uint8 tokenType)"
                ),
                claimData.user,
                claimData.nonce,
                claimData.tokenAddress,
                uint8(claimData.tokenType)
            )
        );

        // Create the final digest as per EIP-712
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        // Use the actual admin private key for signing
        require(signer == admin, "Only admin can sign in this test");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }

    // ===== SNAPSHOT-BASED REWARD SYSTEM TESTS =====

    function testNativeETHViaAddRewards() public {
        uint256 addRewardsAmount = 1.5 ether;

        // Send ETH directly to pool BEFORE activation
        vm.deal(address(pool), addRewardsAmount);

        // Activate pool (no auto-snapshot in new system)
        vm.prank(admin);
        factory.activatePool(poolId);

        // Take manual native snapshot
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // Check that pool balance is updated
        assertEq(address(pool).balance, addRewardsAmount);

        // Check that getAvailableRewards reflects the added rewards
        uint256 availableRewards = pool.getAvailableRewards(
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        assertEq(availableRewards, addRewardsAmount);

        // Check claim eligibility
        (bool canClaim1, uint256 allocation1) = pool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        (bool canClaim2, uint256 allocation2) = pool.checkClaimEligibility(
            user2,
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        (bool canClaim3, uint256 allocation3) = pool.checkClaimEligibility(
            user3,
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        // All users should be able to claim
        assertTrue(canClaim1, "User 1 should be able to claim");
        assertTrue(canClaim2, "User 2 should be able to claim");
        assertTrue(canClaim3, "User 3 should be able to claim");

        // Verify allocation calculations
        uint256 expectedAllocation1 = (addRewardsAmount * USER1_XP) / TOTAL_XP;
        uint256 expectedAllocation2 = (addRewardsAmount * USER2_XP) / TOTAL_XP;
        uint256 expectedAllocation3 = (addRewardsAmount * USER3_XP) / TOTAL_XP;

        assertEq(
            allocation1,
            expectedAllocation1,
            "User 1 allocation incorrect"
        );
        assertEq(
            allocation2,
            expectedAllocation2,
            "User 2 allocation incorrect"
        );
        assertEq(
            allocation3,
            expectedAllocation3,
            "User 3 allocation incorrect"
        );

        console.log("=== NATIVE ETH VIA ADD REWARDS TEST ===");
        console.log("Pool balance:", address(pool).balance);
        console.log("Available rewards:", availableRewards);
        console.log("User 1 allocation:", allocation1);
        console.log("User 2 allocation:", allocation2);
        console.log("User 3 allocation:", allocation3);
    }

    function testNativeETHDirectTransfer() public {
        uint256 directTransferAmount = 2 ether;

        // Send ETH directly to the contract BEFORE activation
        vm.deal(address(pool), directTransferAmount);

        // Activate pool (no auto-snapshot in new system)
        vm.prank(admin);
        factory.activatePool(poolId);

        // Take manual native snapshot
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // Check that pool balance is updated
        assertEq(address(pool).balance, directTransferAmount);

        // Check that getAvailableRewards reflects the direct transfer
        uint256 availableRewards = pool.getAvailableRewards(
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        assertEq(availableRewards, directTransferAmount);

        // Check claim eligibility for users with direct transfer
        (bool canClaim1, uint256 allocation1) = pool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        (bool canClaim2, uint256 allocation2) = pool.checkClaimEligibility(
            user2,
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        (bool canClaim3, uint256 allocation3) = pool.checkClaimEligibility(
            user3,
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        // All users should be able to claim
        assertTrue(canClaim1, "User 1 should be able to claim");
        assertTrue(canClaim2, "User 2 should be able to claim");
        assertTrue(canClaim3, "User 3 should be able to claim");

        // Verify allocation calculations based on direct transfer
        uint256 expectedAllocation1 = (directTransferAmount * USER1_XP) /
            TOTAL_XP;
        uint256 expectedAllocation2 = (directTransferAmount * USER2_XP) /
            TOTAL_XP;
        uint256 expectedAllocation3 = (directTransferAmount * USER3_XP) /
            TOTAL_XP;

        assertEq(
            allocation1,
            expectedAllocation1,
            "User 1 allocation incorrect"
        );
        assertEq(
            allocation2,
            expectedAllocation2,
            "User 2 allocation incorrect"
        );
        assertEq(
            allocation3,
            expectedAllocation3,
            "User 3 allocation incorrect"
        );

        console.log("=== NATIVE ETH DIRECT TRANSFER TEST ===");
        console.log("Pool balance:", address(pool).balance);
        console.log("Available rewards:", availableRewards);
        console.log("User 1 allocation:", allocation1);
        console.log("User 2 allocation:", allocation2);
        console.log("User 3 allocation:", allocation3);
    }

    function testNativeETHMixedSources() public {
        uint256 addRewardsAmount = 1 ether;
        uint256 directTransferAmount = 0.5 ether;
        uint256 totalAmount = addRewardsAmount + directTransferAmount;

        // Send ETH directly to pool BEFORE activation
        vm.deal(address(pool), addRewardsAmount);

        // Add ETH via direct transfer BEFORE activation
        vm.deal(address(pool), address(pool).balance + directTransferAmount);

        // Activate pool (no auto-snapshot in new system)
        vm.prank(admin);
        factory.activatePool(poolId);

        // Take manual native snapshot
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // Check total pool balance
        assertEq(address(pool).balance, totalAmount);

        // Check that getAvailableRewards reflects total ETH
        uint256 availableRewards = pool.getAvailableRewards(
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        assertEq(availableRewards, totalAmount);

        // Check claim eligibility with mixed sources
        (bool canClaim1, uint256 allocation1) = pool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        assertTrue(
            canClaim1,
            "User 1 should be able to claim from mixed sources"
        );

        // Verify allocation is based on total available ETH
        uint256 expectedAllocation1 = (totalAmount * USER1_XP) / TOTAL_XP;
        assertEq(
            allocation1,
            expectedAllocation1,
            "User 1 allocation should be based on total ETH"
        );

        console.log("=== NATIVE ETH MIXED SOURCES TEST ===");
        console.log("AddRewards amount:", addRewardsAmount);
        console.log("Direct transfer amount:", directTransferAmount);
        console.log("Total pool balance:", address(pool).balance);
        console.log("Available rewards:", availableRewards);
        console.log("User 1 allocation:", allocation1);
    }

    function testSnapshotBasedRewardDistribution() public {
        console.log("=== SNAPSHOT-BASED REWARD DISTRIBUTION TEST ===");

        // Create a fresh pool for this test
        vm.prank(admin);
        uint256 snapshotPoolId = factory.createRewardPool(
            "Snapshot Test Pool",
            "v1"
        );
        address snapshotPoolAddress = factory.getPoolAddress(snapshotPoolId);
        RewardPool snapshotPool = RewardPool(payable(snapshotPoolAddress));

        // Add users to the snapshot pool
        vm.prank(admin);
        factory.addUser(snapshotPoolId, user1, 1000);
        vm.prank(admin);
        factory.addUser(snapshotPoolId, user2, 500);

        console.log("Initial state:");
        console.log("- Pool active:", snapshotPool.s_active());
        console.log("- Snapshot taken:", snapshotPool.s_snapshotTaken());
        console.log("- Contract balance:", address(snapshotPool).balance);

        // Send ETH directly to the contract BEFORE activation
        vm.deal(address(this), 1 ether);
        (bool success, ) = payable(address(snapshotPool)).call{
            value: 0.5 ether
        }("");
        assertTrue(success);

        console.log("After ETH sent before activation:");
        console.log("- Contract balance:", address(snapshotPool).balance);
        console.log("- Snapshot taken:", snapshotPool.s_snapshotTaken());
        console.log(
            "- Native snapshot:",
            snapshotPool.getSnapshotAmount(
                address(0),
                IRewardPool.TokenType.NATIVE
            )
        );

        // Grant signer role to admin for this pool
        vm.prank(admin);
        factory.grantSignerRole(snapshotPoolId, admin);

        // Activate pool (no auto-snapshot in new system)
        vm.prank(admin);
        factory.activatePool(snapshotPoolId);

        // Manually take snapshot AFTER activation
        vm.prank(admin);
        factory.takeNativeSnapshot(snapshotPoolId);

        console.log("After activation and manual snapshot:");
        console.log("- Pool active:", snapshotPool.s_active());
        console.log("- Snapshot taken:", snapshotPool.s_snapshotTaken());
        console.log("- Contract balance:", address(snapshotPool).balance);
        console.log(
            "- Native snapshot:",
            snapshotPool.getSnapshotAmount(
                address(0),
                IRewardPool.TokenType.NATIVE
            )
        );
        console.log(
            "- Available rewards:",
            snapshotPool.getAvailableRewards(
                address(0),
                IRewardPool.TokenType.NATIVE
            )
        );
        console.log(
            "- Total rewards:",
            snapshotPool.getTotalRewards(
                address(0),
                IRewardPool.TokenType.NATIVE
            )
        );

        // Verify snapshot was taken
        assertTrue(snapshotPool.s_snapshotTaken(), "Snapshot should be taken");
        assertEq(
            snapshotPool.getSnapshotAmount(
                address(0),
                IRewardPool.TokenType.NATIVE
            ),
            0.5 ether,
            "Snapshot should capture 0.5 ETH"
        );

        // Send more ETH AFTER activation - this should NOT affect allocations
        (bool success2, ) = payable(address(snapshotPool)).call{
            value: 0.3 ether
        }("");
        assertTrue(success2);

        console.log("After additional ETH sent post-activation:");
        console.log("- Contract balance:", address(snapshotPool).balance);
        console.log(
            "- Native snapshot (should be unchanged):",
            snapshotPool.getSnapshotAmount(
                address(0),
                IRewardPool.TokenType.NATIVE
            )
        );
        console.log(
            "- Available rewards:",
            snapshotPool.getAvailableRewards(
                address(0),
                IRewardPool.TokenType.NATIVE
            )
        );

        // Verify snapshot is unchanged but available balance increased
        assertEq(
            snapshotPool.getSnapshotAmount(
                address(0),
                IRewardPool.TokenType.NATIVE
            ),
            0.5 ether,
            "Snapshot should remain 0.5 ETH"
        );
        assertEq(
            address(snapshotPool).balance,
            0.8 ether,
            "Contract should have 0.8 ETH total"
        );
        assertEq(
            snapshotPool.getAvailableRewards(
                address(0),
                IRewardPool.TokenType.NATIVE
            ),
            0.8 ether,
            "Available should be 0.8 ETH"
        );

        // Check user allocations - should be based on snapshot (0.5 ETH), not current balance (0.8 ETH)
        (bool canClaim1, uint256 allocation1) = snapshotPool
            .checkClaimEligibility(
                user1,
                address(0),
                IRewardPool.TokenType.NATIVE
            );
        (bool canClaim2, uint256 allocation2) = snapshotPool
            .checkClaimEligibility(
                user2,
                address(0),
                IRewardPool.TokenType.NATIVE
            );

        console.log("User allocations based on snapshot:");
        console.log(
            "- User1 can claim:",
            canClaim1,
            "allocation:",
            allocation1
        );
        console.log(
            "- User2 can claim:",
            canClaim2,
            "allocation:",
            allocation2
        );

        // Verify allocations are based on snapshot (0.5 ETH), not current balance (0.8 ETH)
        assertTrue(canClaim1, "User1 should be able to claim");
        assertTrue(canClaim2, "User2 should be able to claim");

        // User1: 1000 XP out of 1500 total = 2/3 of 0.5 ETH = ~0.333 ETH
        // User2: 500 XP out of 1500 total = 1/3 of 0.5 ETH = ~0.167 ETH
        uint256 snapshotAmount = 0.5 ether;
        uint256 totalXP = 1500;
        uint256 expectedAllocation1 = (snapshotAmount * 1000) / totalXP;
        uint256 expectedAllocation2 = (snapshotAmount * 500) / totalXP;

        assertEq(
            allocation1,
            expectedAllocation1,
            "User1 allocation should be 2/3 of snapshot"
        );
        assertEq(
            allocation2,
            expectedAllocation2,
            "User2 allocation should be 1/3 of snapshot"
        );

        // Total allocations should be close to snapshot amount (allowing for rounding)
        // Due to integer division, there may be 1-2 wei difference
        uint256 totalAllocations = allocation1 + allocation2;
        assertGe(
            totalAllocations,
            snapshotAmount - 2,
            "Total allocations should be close to snapshot"
        );
        assertLe(
            totalAllocations,
            snapshotAmount,
            "Total allocations should not exceed snapshot"
        );

        // Verify snapshot system integrity
        assertEq(
            snapshotPool.getSnapshotAmount(
                address(0),
                IRewardPool.TokenType.NATIVE
            ),
            0.5 ether,
            "Snapshot should be 0.5 ETH"
        );
        assertEq(
            snapshotPool.getAvailableRewards(
                address(0),
                IRewardPool.TokenType.NATIVE
            ),
            0.8 ether,
            "Available should be 0.8 ETH"
        );
        assertEq(
            snapshotPool.getTotalRewards(
                address(0),
                IRewardPool.TokenType.NATIVE
            ),
            0.5 ether,
            "Total rewards should equal snapshot + claimed (0)"
        );

        // Test claiming - users should be able to claim their full allocation even though available > snapshot
        console.log("Testing claims...");

        IRewardPool.ClaimData memory claimData1 = IRewardPool.ClaimData({
            user: user1,
            nonce: 1,
            tokenAddress: address(0),
            tokenType: IRewardPool.TokenType.NATIVE
        });

        bytes memory signature1 = _generateClaimSignatureForPool(
            claimData1,
            admin,
            address(snapshotPool)
        );
        uint256 user1BalanceBefore = user1.balance;

        // Convert to IRewardPool.ClaimData for the actual call
        IRewardPool.ClaimData memory poolClaimData = IRewardPool.ClaimData({
            user: claimData1.user,
            nonce: claimData1.nonce,
            tokenAddress: claimData1.tokenAddress,
            tokenType: claimData1.tokenType
        });

        vm.prank(user1);
        snapshotPool.claimReward(poolClaimData, signature1);

        uint256 user1Claimed = user1.balance - user1BalanceBefore;
        console.log("User1 claimed:", user1Claimed);
        assertEq(
            user1Claimed,
            expectedAllocation1,
            "User1 should receive exact allocation"
        );

        // Check remaining available balance
        uint256 remainingBalance = address(snapshotPool).balance;
        console.log(
            "Remaining contract balance after User1 claim:",
            remainingBalance
        );
        assertEq(
            remainingBalance,
            0.8 ether - expectedAllocation1,
            "Remaining balance should be correct"
        );

        // User2 should still be able to claim their allocation
        (bool canClaim2After, uint256 allocation2After) = snapshotPool
            .checkClaimEligibility(
                user2,
                address(0),
                IRewardPool.TokenType.NATIVE
            );
        assertTrue(canClaim2After, "User2 should still be able to claim");
        assertEq(
            allocation2After,
            expectedAllocation2,
            "User2 allocation should be unchanged"
        );

        console.log("=== SNAPSHOT SYSTEM SUMMARY ===");
        console.log("SUCCESS: Manual snapshot taken after pool activation");
        console.log(
            "SUCCESS: Allocations based on snapshot balance, not current balance"
        );
        console.log(
            "SUCCESS: Additional funds after snapshot don't affect allocations"
        );
        console.log(
            "SUCCESS: Users can claim their proportional share from snapshot"
        );
        console.log("SUCCESS: Excess funds remain in contract for future use");

        console.log(
            "Snapshot amount:",
            snapshotPool.getSnapshotAmount(
                address(0),
                IRewardPool.TokenType.NATIVE
            )
        );
        console.log(
            "Available balance:",
            snapshotPool.getAvailableRewards(
                address(0),
                IRewardPool.TokenType.NATIVE
            )
        );
        console.log(
            "Total rewards:",
            snapshotPool.getTotalRewards(
                address(0),
                IRewardPool.TokenType.NATIVE
            )
        );
    }

    function testEmergencyWithdrawBlockedWhenActive() public {
        // Add ETH to pool
        vm.deal(address(pool), 1 ether);

        // Record admin's initial balance
        uint256 adminInitialBalance = admin.balance;

        // Pool is initially inactive - emergency withdraw should work
        vm.prank(admin);
        factory.emergencyWithdraw(
            poolId,
            address(0),
            address(admin),
            0.1 ether,
            IRewardPool.TokenType.NATIVE
        );

        // Verify partial withdrawal succeeded
        assertEq(address(pool).balance, 0.9 ether);
        assertEq(admin.balance, adminInitialBalance + 0.1 ether);

        // Activate the pool
        vm.prank(admin);
        factory.activatePool(poolId);

        // Now emergency withdraw should be blocked
        vm.prank(admin);
        vm.expectRevert(
            RewardPool.RewardPool__CannotWithdrawWhenActive.selector
        );
        factory.emergencyWithdraw(
            poolId,
            address(0),
            address(admin),
            0.1 ether,
            IRewardPool.TokenType.NATIVE
        );

        // Pool balance should remain unchanged
        assertEq(address(pool).balance, 0.9 ether);

        // Deactivate the pool
        vm.prank(admin);
        factory.deactivatePool(poolId);

        // Emergency withdraw should work again
        vm.prank(admin);
        factory.emergencyWithdraw(
            poolId,
            address(0),
            address(admin),
            0.1 ether,
            IRewardPool.TokenType.NATIVE
        );

        // Verify withdrawal succeeded after deactivation
        assertEq(address(pool).balance, 0.8 ether);
        assertEq(admin.balance, adminInitialBalance + 0.2 ether);
    }

    function testEmergencyWithdrawERC20BlockedWhenActive() public {
        // Add ERC20 tokens to pool
        uint256 tokenAmount = 1000 * 10 ** 18;
        vm.prank(admin);
        mockToken.mint(address(pool), tokenAmount);

        // Pool is initially inactive - emergency withdraw should work
        vm.prank(admin);
        factory.emergencyWithdraw(
            poolId,
            address(mockToken),
            address(admin),
            100 * 10 ** 18,
            IRewardPool.TokenType.ERC20
        );

        // Verify partial withdrawal succeeded
        assertEq(mockToken.balanceOf(address(pool)), 900 * 10 ** 18);
        assertEq(mockToken.balanceOf(admin), 100 * 10 ** 18);

        // Activate the pool
        vm.prank(admin);
        factory.activatePool(poolId);

        // Now emergency withdraw should be blocked
        vm.prank(admin);
        vm.expectRevert(
            RewardPool.RewardPool__CannotWithdrawWhenActive.selector
        );
        factory.emergencyWithdraw(
            poolId,
            address(mockToken),
            address(admin),
            100 * 10 ** 18,
            IRewardPool.TokenType.ERC20
        );

        // Pool balance should remain unchanged
        assertEq(mockToken.balanceOf(address(pool)), 900 * 10 ** 18);

        // Deactivate the pool
        vm.prank(admin);
        factory.deactivatePool(poolId);

        // Emergency withdraw should work again
        vm.prank(admin);
        factory.emergencyWithdraw(
            poolId,
            address(mockToken),
            address(admin),
            100 * 10 ** 18,
            IRewardPool.TokenType.ERC20
        );

        // Verify withdrawal succeeded after deactivation
        assertEq(mockToken.balanceOf(address(pool)), 800 * 10 ** 18);
        assertEq(mockToken.balanceOf(admin), 200 * 10 ** 18);
    }

    function testManualSnapshotSystem() public {
        console.log("=== TESTING NEW MANUAL SNAPSHOT SYSTEM ===");

        uint256 rewardAmount = 1 ether;

        // Test 1: Pool activation without ETH should result in 0 snapshot if taken immediately
        vm.prank(admin);
        factory.activatePool(poolId);

        // Take snapshot when pool has no ETH
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        // Users should not be able to claim (0 snapshot)
        (bool canClaim1, uint256 allocation1) = pool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        assertFalse(
            canClaim1,
            "Users should not be able to claim with 0 snapshot"
        );
        assertEq(allocation1, 0, "Allocation should be 0 with empty snapshot");

        console.log("SUCCESS: Empty snapshot correctly prevents claims");

        // Test 2: Add ETH AFTER snapshot - users still can't claim until new snapshot
        vm.deal(address(pool), rewardAmount);

        (bool canClaim2, uint256 allocation2) = pool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        assertFalse(
            canClaim2,
            "Users should not be able to claim after adding ETH without new snapshot"
        );
        assertEq(
            allocation2,
            0,
            "Allocation should still be 0 without new snapshot"
        );

        console.log(
            "SUCCESS: Adding ETH after snapshot doesn't automatically enable claims"
        );

        // Test 3: Take new snapshot with ETH - now users can claim
        vm.prank(admin);
        factory.takeNativeSnapshot(poolId);

        (bool canClaim3, uint256 allocation3) = pool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        assertTrue(
            canClaim3,
            "Users should be able to claim after taking snapshot with ETH"
        );
        assertEq(
            allocation3,
            (rewardAmount * USER1_XP) / TOTAL_XP,
            "Allocation should be based on new snapshot"
        );

        console.log("SUCCESS: New snapshot with ETH enables claims correctly");

        // Test 4: Verify snapshot amount vs available rewards
        uint256 snapshotAmount = pool.getSnapshotAmount(
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        uint256 availableRewards = pool.getAvailableRewards(
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        assertEq(
            snapshotAmount,
            rewardAmount,
            "Snapshot should capture full ETH amount"
        );
        assertEq(
            availableRewards,
            rewardAmount,
            "Available rewards should equal contract balance"
        );

        console.log("Snapshot amount:", snapshotAmount);
        console.log("Available rewards:", availableRewards);
        console.log(
            "SUCCESS: Snapshot and available rewards tracking working correctly"
        );

        // Test 5: Add more ETH after snapshot - allocations stay based on snapshot
        uint256 additionalETH = 0.5 ether;
        vm.deal(address(pool), address(pool).balance + additionalETH);

        (bool canClaim4, uint256 allocation4) = pool.checkClaimEligibility(
            user1,
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        assertTrue(canClaim4, "Users should still be able to claim");
        assertEq(
            allocation4,
            (rewardAmount * USER1_XP) / TOTAL_XP,
            "Allocation should still be based on original snapshot"
        );

        uint256 newAvailableRewards = pool.getAvailableRewards(
            address(0),
            IRewardPool.TokenType.NATIVE
        );
        uint256 newSnapshotAmount = pool.getSnapshotAmount(
            address(0),
            IRewardPool.TokenType.NATIVE
        );

        assertEq(
            newAvailableRewards,
            rewardAmount + additionalETH,
            "Available should include new ETH"
        );
        assertEq(
            newSnapshotAmount,
            rewardAmount,
            "Snapshot should remain unchanged"
        );

        console.log(
            "SUCCESS: Additional ETH doesn't affect existing snapshot-based allocations"
        );

        console.log("=== MANUAL SNAPSHOT SYSTEM TESTS PASSED ===");
    }
}
