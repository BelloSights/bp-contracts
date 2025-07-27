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

    // Constants
    uint256 public constant PROTOCOL_FEE_RATE = 100; // 1%

    function test_FactoryInitialization() public {
        // Deploy fresh factory implementation
        CreatorRewardPoolFactory factoryImplementation = new CreatorRewardPoolFactory();
        
        // Deploy fresh implementation for pools
        CreatorRewardPool poolImplementation = new CreatorRewardPool();
        
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
        
        CreatorRewardPoolFactory freshFactory = CreatorRewardPoolFactory(address(proxy));
        
        // Test the initialization
        assertEq(freshFactory.implementation(), address(poolImplementation));
        assertEq(freshFactory.protocolFeeRecipient(), protocolFeeRecipient);
        assertEq(freshFactory.defaultProtocolFeeRate(), PROTOCOL_FEE_RATE);
    }

    function test_CreateCreatorPool() public {
        // Deploy fresh factory implementation
        CreatorRewardPoolFactory factoryImplementation = new CreatorRewardPoolFactory();
        
        // Deploy fresh implementation for pools
        CreatorRewardPool poolImplementation = new CreatorRewardPool();
        
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
        
        CreatorRewardPoolFactory freshFactory = CreatorRewardPoolFactory(address(proxy));
        
        // Create a creator pool
        address newCreator = makeAddr("newCreator");
        vm.prank(admin);
        address poolAddress = freshFactory.createCreatorRewardPool(
            newCreator,
            "New Pool",
            "Description"
        );

        assertTrue(freshFactory.hasCreatorPool(newCreator));
        assertEq(freshFactory.getCreatorPoolAddress(newCreator), poolAddress);
    }

    function test_ProtocolFeeCollection() public {
        // Deploy fresh factory implementation
        CreatorRewardPoolFactory factoryImplementation = new CreatorRewardPoolFactory();
        
        // Deploy fresh implementation for pools
        CreatorRewardPool poolImplementation = new CreatorRewardPool();
        
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
        
        CreatorRewardPoolFactory freshFactory = CreatorRewardPoolFactory(address(proxy));
        
        // Create a creator pool
        address newCreator = makeAddr("newCreator");
        vm.prank(admin);
        address poolAddress = freshFactory.createCreatorRewardPool(
            newCreator,
            "New Pool",
            "Description"
        );
        
        CreatorRewardPool pool = CreatorRewardPool(payable(poolAddress));
        
        // Add user with allocation
        vm.prank(admin);
        freshFactory.addUser(newCreator, user1, 1000);
        
        // Fund the pool with 10 ETH
        vm.deal(address(pool), 10 ether);
        
        // Take snapshot
        vm.prank(admin);
        freshFactory.takeNativeSnapshot(newCreator);
        
        // Activate pool
        vm.prank(admin);
        freshFactory.activateCreatorPool(newCreator);
        
        // Check claim eligibility
        (bool canClaim, uint256 grossAmount, uint256 protocolFee) = 
            pool.checkClaimEligibility(user1, address(0), ICreatorRewardPool.TokenType.NATIVE);
        
        assertTrue(canClaim);
        assertEq(grossAmount, 10 ether); // User gets full amount since they have 100% allocation
        assertEq(protocolFee, (10 ether * PROTOCOL_FEE_RATE) / 10000); // 1% fee = 0.1 ETH
        
        // Record balances before claim
        uint256 userBalanceBefore = user1.balance;
        uint256 feeRecipientBalanceBefore = protocolFeeRecipient.balance;
        
        // Generate signature for claim
        ICreatorRewardPool.ClaimData memory claimData = ICreatorRewardPool.ClaimData({
            user: user1,
            nonce: 1,
            tokenAddress: address(0),
            tokenType: ICreatorRewardPool.TokenType.NATIVE
        });
        
        // Create a signer
        (address signer, uint256 signerPrivateKey) = makeAddrAndKey("signer");
        vm.prank(admin);
        freshFactory.grantSignerRole(newCreator, signer);
        
        // Generate signature
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("ClaimData(address user,uint256 nonce,address tokenAddress,uint8 tokenType)"),
                claimData.user,
                claimData.nonce,
                claimData.tokenAddress,
                claimData.tokenType
            )
        );
        
        bytes32 domainSeparator = pool.getDomainSeparator();
        bytes32 typedDataHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                structHash
            )
        );
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, typedDataHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // Claim reward
        vm.prank(user1);
        pool.claimReward(claimData, signature);
        
        // Verify transfers
        uint256 expectedNetAmount = grossAmount - protocolFee;
        assertEq(user1.balance, userBalanceBefore + expectedNetAmount);
        assertEq(protocolFeeRecipient.balance, feeRecipientBalanceBefore + protocolFee);
        
        // Verify claim tracking
        assertTrue(pool.hasClaimed(user1, address(0), ICreatorRewardPool.TokenType.NATIVE));
    }
} 