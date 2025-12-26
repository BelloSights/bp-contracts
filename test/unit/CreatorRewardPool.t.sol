// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CreatorRewardPool} from "../../src/reward-pool/CreatorRewardPool.sol";
import {CreatorRewardPoolFactory} from "../../src/reward-pool/CreatorRewardPoolFactory.sol";
import {ICreatorRewardPool} from "../../src/reward-pool/interfaces/ICreatorRewardPool.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract CreatorRewardPoolTest is Test {
    address public admin = makeAddr("admin");
    address public creator = makeAddr("creator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");
    address public signer = makeAddr("signer");
    uint256 public signerPrivateKey;
    address public attacker = makeAddr("attacker");

    // Constants
    uint256 public constant PROTOCOL_FEE_RATE = 100; // 1%
    uint256 public constant MAX_PROTOCOL_FEE_RATE = 1000; // 10%
    uint256 public constant FEE_PRECISION = 10000; // 0.01% precision

    // Test contracts
    CreatorRewardPoolFactory factory;
    CreatorRewardPool pool;
    CreatorRewardPool poolImplementation;
    MockERC20 mockToken;

    // Setup function to deploy fresh contracts for each test
    function setUp() public {
        // Deploy mock token
        mockToken = new MockERC20();

        // Deploy fresh factory implementation
        CreatorRewardPoolFactory factoryImplementation = new CreatorRewardPoolFactory();

        // Deploy fresh implementation for pools
        poolImplementation = new CreatorRewardPool();

        // Deploy factory as proxy
        bytes memory initData = abi.encodeWithSelector(
            CreatorRewardPoolFactory.initialize.selector,
            admin,
            address(poolImplementation),
            protocolFeeRecipient
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(factoryImplementation),
            initData
        );

        factory = CreatorRewardPoolFactory(address(proxy));

        // Create a creator pool
        vm.prank(admin);
        address poolAddress = factory.createCreatorRewardPool(
            creator,
            "Test Pool",
            "Test Description"
        );

        pool = CreatorRewardPool(payable(poolAddress));

        // Create a signer with a known private key
        (address signerAddr, uint256 signerKey) = makeAddrAndKey("signer");
        signer = signerAddr;
        signerPrivateKey = signerKey;

        // Grant signer role to the actual signer address
        vm.prank(admin);
        factory.grantSignerRole(creator, signer);
    }

    // ===== FACTORY TESTS =====

    function test_FactoryInitialization() public view {
        // Test that the factory is properly initialized
        assertEq(factory.protocolFeeRecipient(), protocolFeeRecipient);
        assertEq(factory.defaultProtocolFeeRate(), PROTOCOL_FEE_RATE);
        assertTrue(
            factory.implementation() != address(0),
            "Implementation should be set"
        );
    }

    function test_CreateCreatorPool() public {
        address newCreator = makeAddr("newCreator");
        vm.prank(admin);
        address poolAddress = factory.createCreatorRewardPool(
            newCreator,
            "New Pool",
            "Description"
        );

        assertTrue(factory.hasCreatorPool(newCreator));
        assertEq(factory.getCreatorPoolAddress(newCreator), poolAddress);

        // Test pool info
        CreatorRewardPoolFactory.CreatorPoolInfo memory poolInfo = factory
            .getCreatorPoolInfo(newCreator);
        assertEq(poolInfo.creator, newCreator);
        assertEq(poolInfo.pool, poolAddress);
        assertEq(poolInfo.name, "New Pool");
        assertEq(poolInfo.description, "Description");
        assertEq(poolInfo.protocolFeeRate, PROTOCOL_FEE_RATE);
        assertGt(poolInfo.createdAt, 0);
    }

    function test_RevertWhen_CreatePoolForExistingCreator() public {
        vm.prank(admin);
        vm.expectRevert();
        factory.createCreatorRewardPool(creator, "Another Pool", "Description");
    }

    function test_RevertWhen_NonAdminCreatesPool() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.createCreatorRewardPool(
            attacker,
            "Attacker Pool",
            "Description"
        );
    }

    // ===== USER MANAGEMENT TESTS =====

    function test_AddUser() public {
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        assertTrue(
            pool.isUserForToken(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            )
        );
        assertEq(
            pool.getUserAllocationForToken(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            10 ether
        );
        assertEq(
            pool.getTotalUsersForToken(
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            1
        );
        assertEq(
            pool.getUserAtIndexForToken(
                address(0),
                ICreatorRewardPool.TokenType.NATIVE,
                0
            ),
            user1
        );
    }

    function test_AddMultipleUsers() public {
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.prank(admin);
        factory.addUser(
            creator,
            user2,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            20 ether
        );

        vm.prank(admin);
        factory.addUser(
            creator,
            user3,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            3000
        );

        assertEq(
            pool.getTotalUsersForToken(
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            3
        );
        assertEq(
            pool.getUserAllocationForToken(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            10 ether
        );
        assertEq(
            pool.getUserAllocationForToken(
                user2,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            20 ether
        );
        assertEq(
            pool.getUserAllocationForToken(
                user3,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            3000
        );
        assertEq(
            pool.getTotalAllocationsForToken(
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            30 ether + 3000
        );
    }

    function test_AddUserWithZeroAllocationAllowed() public {
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            0
        );

        assertTrue(
            pool.isUserForToken(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            )
        );
        assertEq(
            pool.getUserAllocationForToken(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            0
        );
        assertEq(
            pool.getTotalAllocationsForToken(
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            0
        );
    }

    function test_RevertWhen_AddExistingUser() public {
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            1000
        );

        vm.prank(admin);
        vm.expectRevert();
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            2000
        );
    }

    function test_RevertWhen_AddUserToActivePool() public {
        // Add user and activate pool
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            1000
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Try to add another user
        vm.prank(admin);
        vm.expectRevert();
        factory.addUser(
            creator,
            user2,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            1000
        );
    }

    function test_UpdateUserAllocation() public {
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            1000
        );

        vm.prank(admin);
        factory.updateUserAllocation(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            2000
        );

        assertEq(
            pool.getUserAllocationForToken(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            2000
        );
        assertEq(
            pool.getTotalAllocationsForToken(
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            2000
        );
    }

    function test_UpdateUserAllocationToZero() public {
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            1000
        );

        vm.prank(admin);
        factory.updateUserAllocation(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            0
        );

        assertEq(
            pool.getUserAllocationForToken(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            0
        );
        assertFalse(
            pool.isUserForToken(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            )
        );
        assertEq(
            pool.getTotalAllocationsForToken(
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            0
        );
    }

    function test_RevertWhen_UpdateNonExistentUser() public {
        vm.prank(admin);
        vm.expectRevert();
        factory.updateUserAllocation(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            2000
        );
    }

    function test_RemoveUser() public {
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            1000
        );

        vm.prank(admin);
        factory.removeUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE
        );

        assertFalse(
            pool.isUserForToken(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            )
        );
        assertEq(
            pool.getUserAllocationForToken(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            0
        );
        assertEq(
            pool.getTotalAllocationsForToken(
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            0
        );
    }

    function test_RevertWhen_RemoveNonExistentUser() public {
        vm.prank(admin);
        vm.expectRevert();
        factory.removeUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE
        );
    }

    // ===== POOL ACTIVATION TESTS =====

    function test_ActivatePool() public {
        vm.prank(admin);
        factory.activateCreatorPool(creator);

        assertTrue(pool.s_active());
    }

    function test_DeactivatePool() public {
        vm.prank(admin);
        factory.activateCreatorPool(creator);

        vm.prank(admin);
        factory.deactivateCreatorPool(creator);

        assertFalse(pool.s_active());
    }

    function test_RevertWhen_NonFactoryActivatesPool() public {
        vm.prank(attacker);
        vm.expectRevert();
        pool.setActive(true);
    }

    // ===== CLAIM ELIGIBILITY TESTS =====

    function test_CheckClaimEligibility_Native() public {
        // Setup: add native allocation for user
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Check eligibility
        (bool canClaim, uint256 allocation, uint256 protocolFee) = pool
            .checkClaimEligibility(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            );

        assertTrue(canClaim);
        assertEq(allocation, 10 ether); // Absolute allocation
        assertEq(protocolFee, (10 ether * PROTOCOL_FEE_RATE) / FEE_PRECISION);
    }

    function test_CheckClaimEligibility_ERC20() public {
        // Setup (ERC20 allocation)
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(mockToken),
            ICreatorRewardPool.TokenType.ERC20,
            1000
        );

        mockToken.mint(address(pool), 1000);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Check eligibility
        (bool canClaim, uint256 allocation, uint256 protocolFee) = pool
            .checkClaimEligibility(
                user1,
                address(mockToken),
                ICreatorRewardPool.TokenType.ERC20
            );

        assertTrue(canClaim);
        assertEq(allocation, 1000);
        assertEq(protocolFee, (1000 * PROTOCOL_FEE_RATE) / FEE_PRECISION);
    }

    function test_CheckClaimEligibility_MultipleUsers() public {
        // Setup with multiple users
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.prank(admin);
        factory.addUser(
            creator,
            user2,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            20 ether
        );

        vm.deal(address(pool), 30 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Check user1 eligibility
        (bool canClaim1, uint256 allocation1, uint256 protocolFee1) = pool
            .checkClaimEligibility(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            );

        assertTrue(canClaim1);
        assertEq(allocation1, 10 ether);
        assertEq(protocolFee1, (10 ether * PROTOCOL_FEE_RATE) / FEE_PRECISION);

        // Check user2 eligibility
        (bool canClaim2, uint256 allocation2, uint256 protocolFee2) = pool
            .checkClaimEligibility(
                user2,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            );

        assertTrue(canClaim2);
        assertEq(allocation2, 20 ether);
        assertEq(protocolFee2, (20 ether * PROTOCOL_FEE_RATE) / FEE_PRECISION);
    }

    function test_CheckClaimEligibility_NotActive_NoSnapshotGate() public {
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        // Don't activate pool

        (bool canClaim, uint256 allocation, uint256 protocolFee) = pool
            .checkClaimEligibility(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            );

        assertFalse(canClaim);
        assertEq(allocation, 0);
        assertEq(protocolFee, 0);
    }

    function test_CheckClaimEligibility_NoSnapshot() public {
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Don't take snapshot

        (bool canClaim, uint256 allocation, uint256 protocolFee) = pool
            .checkClaimEligibility(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            );

        assertFalse(canClaim);
        assertEq(allocation, 0);
        assertEq(protocolFee, 0);
    }

    function test_CheckClaimEligibility_AlreadyClaimed() public {
        // Setup and claim
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            1000
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Claim first time
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        bytes memory signature = _generateSignature(claimData, signer);

        vm.prank(user1);
        pool.claimReward(claimData, signature);

        // Check eligibility again
        (bool canClaim, uint256 allocation, uint256 protocolFee) = pool
            .checkClaimEligibility(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            );

        assertFalse(canClaim);
        assertEq(allocation, 0);
        assertEq(protocolFee, 0);
    }

    // ===== CLAIM TESTS =====

    function test_ClaimReward_Native() public {
        // Setup
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Prepare claim data
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        bytes memory signature = _generateSignature(claimData, signer);

        // Record balances
        uint256 userBalanceBefore = user1.balance;
        uint256 feeRecipientBalanceBefore = protocolFeeRecipient.balance;

        // Claim
        vm.prank(user1);
        pool.claimReward(claimData, signature);

        // Verify transfers
        uint256 expectedNetAmount = 10 ether -
            ((10 ether * PROTOCOL_FEE_RATE) / FEE_PRECISION);
        assertEq(user1.balance, userBalanceBefore + expectedNetAmount);
        assertEq(
            protocolFeeRecipient.balance,
            feeRecipientBalanceBefore +
                ((10 ether * PROTOCOL_FEE_RATE) / FEE_PRECISION)
        );

        // Verify claim tracking
        assertTrue(
            pool.hasClaimed(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            )
        );
    }

    function test_ClaimReward_ERC20() public {
        // Setup
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(mockToken),
            ICreatorRewardPool.TokenType.ERC20,
            1000
        );

        mockToken.mint(address(pool), 1000);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Prepare claim data
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(mockToken),
                tokenType: ICreatorRewardPool.TokenType.ERC20
            });

        bytes memory signature = _generateSignature(claimData, signer);

        // Record balances
        uint256 userBalanceBefore = mockToken.balanceOf(user1);
        uint256 feeRecipientBalanceBefore = mockToken.balanceOf(
            protocolFeeRecipient
        );

        // Claim
        vm.prank(user1);
        pool.claimReward(claimData, signature);

        // Verify transfers
        uint256 expectedNetAmount = 1000 -
            ((1000 * PROTOCOL_FEE_RATE) / FEE_PRECISION);
        assertEq(
            mockToken.balanceOf(user1),
            userBalanceBefore + expectedNetAmount
        );
        assertEq(
            mockToken.balanceOf(protocolFeeRecipient),
            feeRecipientBalanceBefore +
                ((1000 * PROTOCOL_FEE_RATE) / FEE_PRECISION)
        );

        // Verify claim tracking
        assertTrue(
            pool.hasClaimed(
                user1,
                address(mockToken),
                ICreatorRewardPool.TokenType.ERC20
            )
        );
    }

    function test_ClaimRewardFor_Native() public {
        // Setup
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Prepare claim data
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        bytes memory signature = _generateSignature(claimData, signer);

        uint256 userBalanceBefore = user1.balance;
        uint256 feeRecipientBalanceBefore = protocolFeeRecipient.balance;

        // Factory claims on behalf of user (requires user be in pool for this ERC20)
        vm.prank(admin);
        factory.claimRewardFor(creator, claimData, signature);

        uint256 expectedNetAmount = 10 ether -
            ((10 ether * PROTOCOL_FEE_RATE) / FEE_PRECISION);
        assertEq(user1.balance, userBalanceBefore + expectedNetAmount);
        assertEq(
            protocolFeeRecipient.balance,
            feeRecipientBalanceBefore +
                ((10 ether * PROTOCOL_FEE_RATE) / FEE_PRECISION)
        );

        assertTrue(
            pool.hasClaimed(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            )
        );
    }

    function test_ClaimRewardFor_ERC20() public {
        // Setup: add ERC20 allocation
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(mockToken),
            ICreatorRewardPool.TokenType.ERC20,
            1000
        );

        mockToken.mint(address(pool), 1000);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(mockToken),
                tokenType: ICreatorRewardPool.TokenType.ERC20
            });

        bytes memory signature = _generateSignature(claimData, signer);

        uint256 userBalanceBefore = mockToken.balanceOf(user1);
        uint256 feeRecipientBalanceBefore = mockToken.balanceOf(
            protocolFeeRecipient
        );

        // Factory claims on behalf of user
        vm.prank(admin);
        factory.claimRewardFor(creator, claimData, signature);

        uint256 expectedNetAmount = 1000 -
            ((1000 * PROTOCOL_FEE_RATE) / FEE_PRECISION);
        assertEq(
            mockToken.balanceOf(user1),
            userBalanceBefore + expectedNetAmount
        );
        assertEq(
            mockToken.balanceOf(protocolFeeRecipient),
            feeRecipientBalanceBefore +
                ((1000 * PROTOCOL_FEE_RATE) / FEE_PRECISION)
        );

        assertTrue(
            pool.hasClaimed(
                user1,
                address(mockToken),
                ICreatorRewardPool.TokenType.ERC20
            )
        );
    }

    function test_RevertWhen_ClaimWithInvalidSignature() public {
        // Setup
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Prepare claim data with wrong signer
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        (, uint256 wrongKey) = makeAddrAndKey("wrongSigner");
        bytes memory signature = _generateSignatureWithKey(claimData, wrongKey);

        // Try to claim
        vm.prank(user1);
        vm.expectRevert();
        pool.claimReward(claimData, signature);
    }

    function test_RevertWhen_ClaimWithReusedNonce() public {
        // Setup
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Prepare claim data
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        bytes memory signature = _generateSignature(claimData, signer);

        // Claim first time
        vm.prank(user1);
        pool.claimReward(claimData, signature);

        // Try to claim again with same nonce
        vm.prank(user1);
        vm.expectRevert();
        pool.claimReward(claimData, signature);
    }

    function test_RevertWhen_ClaimWithWrongUser() public {
        // Setup
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Prepare claim data for user1 but try to claim as user2
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        bytes memory signature = _generateSignature(claimData, signer);

        // Try to claim as wrong user
        vm.prank(user2);
        vm.expectRevert();
        pool.claimReward(claimData, signature);
    }

    // ===== EMERGENCY WITHDRAW TESTS =====

    function test_EmergencyWithdraw_Native() public {
        vm.deal(address(pool), 10 ether);

        uint256 adminBalanceBefore = admin.balance;

        vm.prank(admin);
        factory.emergencyWithdraw(
            creator,
            address(0),
            admin,
            5 ether,
            ICreatorRewardPool.TokenType.NATIVE
        );

        assertEq(admin.balance, adminBalanceBefore + 5 ether);
        assertEq(address(pool).balance, 5 ether);
    }

    function test_EmergencyWithdraw_ERC20() public {
        mockToken.mint(address(pool), 1000);

        uint256 adminBalanceBefore = mockToken.balanceOf(admin);

        vm.prank(admin);
        factory.emergencyWithdraw(
            creator,
            address(mockToken),
            admin,
            500,
            ICreatorRewardPool.TokenType.ERC20
        );

        assertEq(mockToken.balanceOf(admin), adminBalanceBefore + 500);
        assertEq(mockToken.balanceOf(address(pool)), 500);
    }

    function test_RevertWhen_EmergencyWithdrawWhenActive() public {
        vm.prank(admin);
        factory.activateCreatorPool(creator);

        vm.prank(admin);
        vm.expectRevert();
        factory.emergencyWithdraw(
            creator,
            address(0),
            admin,
            1 ether,
            ICreatorRewardPool.TokenType.NATIVE
        );
    }

    function test_RevertWhen_NonAdminEmergencyWithdraw() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.emergencyWithdraw(
            creator,
            address(0),
            admin,
            1 ether,
            ICreatorRewardPool.TokenType.NATIVE
        );
    }

    // ===== VALIDATION TESTS =====

    function test_ValidateAllocations() public {
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        (
            bool isValid,
            uint256 totalAllocations,
            uint256 availableBalance
        ) = pool.validateAllocations(
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            );

        assertTrue(isValid);
        assertEq(totalAllocations, 10 ether);
        assertEq(availableBalance, 10 ether);
    }

    function test_ValidateAllocations_InvalidTokenType() public view {
        (
            bool isValid,
            uint256 totalAllocations,
            uint256 availableBalance
        ) = pool.validateAllocations(
                address(0),
                ICreatorRewardPool.TokenType.ERC20
            );

        assertFalse(isValid);
        assertEq(totalAllocations, 0);
        assertEq(availableBalance, 0);
    }

    // ===== PROTOCOL FEE TESTS =====

    function test_ProtocolFeeCollection() public {
        // Setup
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Check claim eligibility
        (bool canClaim, uint256 grossAmount, uint256 protocolFee) = pool
            .checkClaimEligibility(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            );

        assertTrue(canClaim);
        assertEq(grossAmount, 10 ether);
        assertEq(protocolFee, (10 ether * PROTOCOL_FEE_RATE) / FEE_PRECISION);

        // Record balances before claim
        uint256 userBalanceBefore = user1.balance;
        uint256 feeRecipientBalanceBefore = protocolFeeRecipient.balance;

        // Generate signature for claim
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        bytes memory signature = _generateSignature(claimData, signer);

        // Claim reward
        vm.prank(user1);
        pool.claimReward(claimData, signature);

        // Verify transfers
        uint256 expectedNetAmount = grossAmount - protocolFee;
        assertEq(user1.balance, userBalanceBefore + expectedNetAmount);
        assertEq(
            protocolFeeRecipient.balance,
            feeRecipientBalanceBefore + protocolFee
        );

        // Verify claim tracking
        assertTrue(
            pool.hasClaimed(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            )
        );
    }

    // ===== ADDITIONAL COMPREHENSIVE TESTS =====

    function test_BatchAddUsers() public {
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        uint256[] memory allocations = new uint256[](3);
        allocations[0] = 1000;
        allocations[1] = 2000;
        allocations[2] = 3000;

        vm.prank(admin);
        factory.batchAddUsers(
            creator,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            users,
            allocations
        );

        assertEq(
            pool.getTotalUsersForToken(
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            3
        );
        assertEq(
            pool.getUserAllocationForToken(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            1000
        );
        assertEq(
            pool.getUserAllocationForToken(
                user2,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            2000
        );
        assertEq(
            pool.getUserAllocationForToken(
                user3,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            3000
        );
        assertEq(
            pool.getTotalAllocationsForToken(
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            6000
        );
    }

    function test_RevertWhen_BatchAddUsersWithMismatchedArrays() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory allocations = new uint256[](3);
        allocations[0] = 1000;
        allocations[1] = 2000;
        allocations[2] = 3000;

        vm.prank(admin);
        vm.expectRevert();
        factory.batchAddUsers(
            creator,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            users,
            allocations
        );
    }

    function test_RevertWhen_BatchAddUsersWithEmptyArray() public {
        address[] memory users = new address[](0);
        uint256[] memory allocations = new uint256[](0);

        vm.prank(admin);
        vm.expectRevert();
        factory.batchAddUsers(
            creator,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            users,
            allocations
        );
    }

    function test_ClaimWithDifferentNonces() public {
        // Setup
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Claim with nonce 1
        ICreatorRewardPool.ClaimData memory claimData1 = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        bytes memory signature1 = _generateSignature(claimData1, signer);

        vm.prank(user1);
        pool.claimReward(claimData1, signature1);

        // Try to claim with nonce 2 (should fail since no more rewards)
        ICreatorRewardPool.ClaimData memory claimData2 = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 2,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        bytes memory signature2 = _generateSignature(claimData2, signer);

        vm.prank(user1);
        vm.expectRevert();
        pool.claimReward(claimData2, signature2);
    }

    function test_ClaimMultipleTokenTypes() public {
        // Setup: add ERC20 allocation so user can claim ERC20
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(mockToken),
            ICreatorRewardPool.TokenType.ERC20,
            1000
        );

        // Fund with ERC20 only for this test
        mockToken.mint(address(pool), 1000);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Claim ERC20 tokens
        ICreatorRewardPool.ClaimData memory erc20ClaimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(mockToken),
                tokenType: ICreatorRewardPool.TokenType.ERC20
            });

        bytes memory erc20Signature = _generateSignature(
            erc20ClaimData,
            signer
        );

        vm.prank(user1);
        pool.claimReward(erc20ClaimData, erc20Signature);

        // Verify claim was successful
        assertTrue(
            pool.hasClaimed(
                user1,
                address(mockToken),
                ICreatorRewardPool.TokenType.ERC20
            )
        );
    }

    function test_ProtocolFeeRateValidation() public {
        // Test that protocol fee rate cannot exceed maximum
        vm.prank(admin);
        vm.expectRevert();
        factory.createCreatorRewardPoolWithCustomFee(
            creator,
            "Test",
            "Test",
            MAX_PROTOCOL_FEE_RATE + 1
        );
    }

    // ===== ZERO PROTOCOL FEE TESTS =====

    function test_CreatePoolWithoutFee() public {
        address newCreator = makeAddr("newCreator");

        vm.prank(admin);
        address poolAddress = factory.createCreatorRewardPoolWithoutFee(
            newCreator,
            "No Fee Pool",
            "Pool with no protocol fees"
        );

        CreatorRewardPool noFeePool = CreatorRewardPool(payable(poolAddress));
        assertEq(noFeePool.getProtocolFeeRate(), 0);

        CreatorRewardPoolFactory.CreatorPoolInfo memory poolInfo = factory
            .getCreatorPoolInfo(newCreator);
        assertEq(poolInfo.protocolFeeRate, 0);
    }

    function test_CreatePoolWithZeroCustomFee() public {
        address newCreator = makeAddr("newCreator");

        vm.prank(admin);
        address poolAddress = factory.createCreatorRewardPoolWithCustomFee(
            newCreator,
            "Zero Fee Pool",
            "Pool with 0% protocol fee",
            0
        );

        CreatorRewardPool zeroFeePool = CreatorRewardPool(payable(poolAddress));
        assertEq(zeroFeePool.getProtocolFeeRate(), 0);
    }

    function test_ClaimRewardWithZeroProtocolFee_Native() public {
        // Create pool with 0% protocol fee
        address newCreator = makeAddr("newCreator");
        vm.prank(admin);
        address poolAddress = factory.createCreatorRewardPoolWithoutFee(
            newCreator,
            "No Fee Pool",
            "Pool with no protocol fees"
        );
        CreatorRewardPool noFeePool = CreatorRewardPool(payable(poolAddress));

        // Setup user
        vm.prank(admin);
        factory.addUser(
            newCreator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        // Fund pool and take snapshot
        vm.deal(address(noFeePool), 10 ether);

        // Activate pool
        vm.prank(admin);
        factory.activateCreatorPool(newCreator);

        // Grant signer role
        vm.prank(admin);
        factory.grantSignerRole(newCreator, signer);

        // Check eligibility - should have 0 protocol fee
        (bool canClaim, uint256 allocation, uint256 protocolFee) = noFeePool
            .checkClaimEligibility(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            );

        assertTrue(canClaim);
        assertEq(allocation, 10 ether); // Full amount
        assertEq(protocolFee, 0); // No protocol fee

        // Record balances
        uint256 userBalanceBefore = user1.balance;
        uint256 feeRecipientBalanceBefore = protocolFeeRecipient.balance;

        // Prepare claim data
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        bytes memory signature = _generateSignatureForPool(
            claimData,
            noFeePool
        );

        // Claim
        vm.prank(user1);
        noFeePool.claimReward(claimData, signature);

        // Verify user gets full amount (no fees deducted)
        assertEq(user1.balance, userBalanceBefore + 10 ether);

        // Verify no protocol fees were collected
        assertEq(protocolFeeRecipient.balance, feeRecipientBalanceBefore);

        // Verify protocol fees claimed is 0
        assertEq(
            noFeePool.getProtocolFeesClaimed(
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            ),
            0
        );
    }

    function test_ClaimRewardWithZeroProtocolFee_ERC20() public {
        // Create pool with 0% protocol fee
        address newCreator = makeAddr("newCreator");
        vm.prank(admin);
        address poolAddress = factory.createCreatorRewardPoolWithoutFee(
            newCreator,
            "No Fee Pool",
            "Pool with no protocol fees"
        );
        CreatorRewardPool noFeePool = CreatorRewardPool(payable(poolAddress));

        // Setup user
        vm.prank(admin);
        factory.addUser(
            newCreator,
            user1,
            address(mockToken),
            ICreatorRewardPool.TokenType.ERC20,
            1000
        );

        // Fund pool and take snapshot
        mockToken.mint(address(noFeePool), 1000);
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);

        // Activate pool
        vm.prank(admin);
        factory.activateCreatorPool(newCreator);

        // Grant signer role
        vm.prank(admin);
        factory.grantSignerRole(newCreator, signer);

        // Check eligibility - should have 0 protocol fee
        (bool canClaim, uint256 allocation, uint256 protocolFee) = noFeePool
            .checkClaimEligibility(
                user1,
                address(mockToken),
                ICreatorRewardPool.TokenType.ERC20
            );

        assertTrue(canClaim);
        assertEq(allocation, 1000); // Full amount
        assertEq(protocolFee, 0); // No protocol fee

        // Record balances
        uint256 userBalanceBefore = mockToken.balanceOf(user1);
        uint256 feeRecipientBalanceBefore = mockToken.balanceOf(
            protocolFeeRecipient
        );

        // Prepare claim data
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(mockToken),
                tokenType: ICreatorRewardPool.TokenType.ERC20
            });

        bytes memory signature = _generateSignatureForPool(
            claimData,
            noFeePool
        );

        // Claim
        vm.prank(user1);
        noFeePool.claimReward(claimData, signature);

        // Verify user gets full amount (no fees deducted)
        assertEq(mockToken.balanceOf(user1), userBalanceBefore + 1000);

        // Verify no protocol fees were collected
        assertEq(
            mockToken.balanceOf(protocolFeeRecipient),
            feeRecipientBalanceBefore
        );

        // Verify protocol fees claimed is 0
        assertEq(
            noFeePool.getProtocolFeesClaimed(
                address(mockToken),
                ICreatorRewardPool.TokenType.ERC20
            ),
            0
        );
    }

    function test_ComparePoolsWithAndWithoutFees() public {
        // Create two pools - one with fees, one without
        address creatorWithFee = makeAddr("creatorWithFee");
        address creatorNoFee = makeAddr("creatorNoFee");

        vm.prank(admin);
        address poolWithFeeAddress = factory.createCreatorRewardPool(
            creatorWithFee,
            "Fee Pool",
            "Pool with 1% protocol fee"
        );

        vm.prank(admin);
        address poolNoFeeAddress = factory.createCreatorRewardPoolWithoutFee(
            creatorNoFee,
            "No Fee Pool",
            "Pool with no protocol fees"
        );

        CreatorRewardPool poolWithFee = CreatorRewardPool(
            payable(poolWithFeeAddress)
        );
        CreatorRewardPool poolNoFee = CreatorRewardPool(
            payable(poolNoFeeAddress)
        );

        // Setup both pools identically
        vm.prank(admin);
        factory.addUser(
            creatorWithFee,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );
        vm.prank(admin);
        factory.addUser(
            creatorNoFee,
            user2,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        // Fund both pools with same amount
        vm.deal(address(poolWithFee), 10 ether);
        vm.deal(address(poolNoFee), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creatorWithFee);
        vm.prank(admin);
        factory.activateCreatorPool(creatorNoFee);

        vm.prank(admin);
        factory.grantSignerRole(creatorWithFee, signer);
        vm.prank(admin);
        factory.grantSignerRole(creatorNoFee, signer);

        // Check eligibility for both pools
        (
            bool canClaim1,
            uint256 allocation1,
            uint256 protocolFee1
        ) = poolWithFee.checkClaimEligibility(
                user1,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            );

        (bool canClaim2, uint256 allocation2, uint256 protocolFee2) = poolNoFee
            .checkClaimEligibility(
                user2,
                address(0),
                ICreatorRewardPool.TokenType.NATIVE
            );

        assertTrue(canClaim1);
        assertTrue(canClaim2);
        assertEq(allocation1, 10 ether);
        assertEq(allocation2, 10 ether);
        assertEq(protocolFee1, (10 ether * PROTOCOL_FEE_RATE) / FEE_PRECISION); // 1% fee
        assertEq(protocolFee2, 0); // No fee

        // Record balances
        uint256 user1BalanceBefore = user1.balance;
        uint256 user2BalanceBefore = user2.balance;
        uint256 feeRecipientBalanceBefore = protocolFeeRecipient.balance;

        // Claim from both pools
        ICreatorRewardPool.ClaimData memory claimData1 = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        ICreatorRewardPool.ClaimData memory claimData2 = ICreatorRewardPool
            .ClaimData({
                user: user2,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        bytes memory signature1 = _generateSignatureForPool(
            claimData1,
            poolWithFee
        );
        bytes memory signature2 = _generateSignatureForPool(
            claimData2,
            poolNoFee
        );

        vm.prank(user1);
        poolWithFee.claimReward(claimData1, signature1);

        vm.prank(user2);
        poolNoFee.claimReward(claimData2, signature2);

        // Verify results
        uint256 expectedNetWithFee = 10 ether - protocolFee1;
        assertEq(user1.balance, user1BalanceBefore + expectedNetWithFee);
        assertEq(user2.balance, user2BalanceBefore + 10 ether); // Full amount
        assertEq(
            protocolFeeRecipient.balance,
            feeRecipientBalanceBefore + protocolFee1
        );
    }

    function test_GetTotalClaimedAndProtocolFees() public {
        // Setup
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Claim
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        bytes memory signature = _generateSignature(claimData, signer);

        vm.prank(user1);
        pool.claimReward(claimData, signature);

        // Check totals
        uint256 totalClaimed = pool.getTotalClaimed(
            address(0),
            ICreatorRewardPool.TokenType.NATIVE
        );
        uint256 protocolFeesClaimed = pool.getProtocolFeesClaimed(
            address(0),
            ICreatorRewardPool.TokenType.NATIVE
        );

        assertEq(totalClaimed, 10 ether);
        assertEq(
            protocolFeesClaimed,
            (10 ether * PROTOCOL_FEE_RATE) / FEE_PRECISION
        );
    }

    function test_RevertWhen_ClaimWithInvalidTokenType() public {
        // Setup
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Try to claim with invalid token type (ERC20 but address(0))
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(0),
                tokenType: ICreatorRewardPool.TokenType.ERC20
            });

        bytes memory signature = _generateSignature(claimData, signer);

        vm.prank(user1);
        vm.expectRevert();
        pool.claimReward(claimData, signature);
    }

    function test_RevertWhen_ClaimWithInvalidTokenAddress() public {
        // Setup
        vm.prank(admin);
        factory.addUser(
            creator,
            user1,
            address(0),
            ICreatorRewardPool.TokenType.NATIVE,
            10 ether
        );

        vm.deal(address(pool), 10 ether);

        vm.prank(admin);
        factory.activateCreatorPool(creator);

        // Try to claim with invalid token address (NATIVE but non-zero address)
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool
            .ClaimData({
                user: user1,
                nonce: 1,
                tokenAddress: address(1),
                tokenType: ICreatorRewardPool.TokenType.NATIVE
            });

        bytes memory signature = _generateSignature(claimData, signer);

        vm.prank(user1);
        vm.expectRevert();
        pool.claimReward(claimData, signature);
    }

    function test_RevokeSignerRole() public {
        // Grant signer role
        vm.prank(admin);
        factory.grantSignerRole(creator, signer);

        // Verify signer has role
        assertTrue(pool.hasRole(pool.SIGNER_ROLE(), signer));

        // Revoke signer role
        vm.prank(admin);
        factory.revokeSignerRole(creator, signer);

        // Verify signer no longer has role
        assertFalse(pool.hasRole(pool.SIGNER_ROLE(), signer));
    }

    function test_UpdateProtocolFeeRecipient() public {
        vm.prank(admin);
        factory.updateProtocolFeeRecipientForAllPools();

        // The protocol fee recipient should be updated to the factory's recipient
        assertEq(pool.s_protocolFeeRecipient(), protocolFeeRecipient);
    }

    // ===== HELPER FUNCTIONS =====

    function _generateSignature(
        ICreatorRewardPool.ClaimData memory claimData,
        address /*signerAddress*/
    ) internal view returns (bytes memory) {
        // Manually construct the EIP-712 hash
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ClaimData(address user,uint256 nonce,address tokenAddress,uint8 tokenType)"
                ),
                claimData.user,
                claimData.nonce,
                claimData.tokenAddress,
                claimData.tokenType
            )
        );

        bytes32 domainSeparator = pool.getDomainSeparator();
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        // Use the actual private key for the signer
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _generateSignatureWithKey(
        ICreatorRewardPool.ClaimData memory claimData,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ClaimData(address user,uint256 nonce,address tokenAddress,uint8 tokenType)"
                ),
                claimData.user,
                claimData.nonce,
                claimData.tokenAddress,
                claimData.tokenType
            )
        );

        bytes32 domainSeparator = pool.getDomainSeparator();
        bytes32 typedDataHash = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, typedDataHash);
        return abi.encodePacked(r, s, v);
    }

    function _generateSignatureForPool(
        ICreatorRewardPool.ClaimData memory claimData,
        CreatorRewardPool targetPool
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ClaimData(address user,uint256 nonce,address tokenAddress,uint8 tokenType)"
                ),
                claimData.user,
                claimData.nonce,
                claimData.tokenAddress,
                claimData.tokenType
            )
        );

        bytes32 domainSeparator = targetPool.getDomainSeparator();
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
