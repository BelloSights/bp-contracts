# BlueprintCrossBatchMinter Usage Guide

The `BlueprintCrossBatchMinter` contract enables users to mint tokens from multiple ERC1155 collections in a single transaction, perfect for shopping cart experiences.

## Overview

This contract allows users to:
- Mint tokens from different collections in one transaction
- Pay with either ETH or ERC20 tokens
- Get cost estimates before executing transactions
- Check eligibility before attempting to mint

## Contract Deployment

### Prerequisites
- Deployed `BlueprintERC1155Factory` contract
- Admin account with necessary permissions

### Deployment Script
```javascript
// Using ethers.js
const factory = new ethers.Contract(factoryAddress, factoryABI, signer);
const crossBatchMinter = await deployContract("BlueprintCrossBatchMinter");

// Initialize the contract
await crossBatchMinter.initialize(
    factory.address,  // factory address
    adminAddress     // admin address
);
```

## Frontend Integration Examples

### 1. Shopping Cart Scenario Setup

```javascript
// Example shopping cart data structure
const shoppingCart = [
    {
        collection: "0x1234...", // Collection A address
        tokenId: 0,
        amount: 2,
        name: "Cool NFT #1",
        price: "0.1" // ETH price
    },
    {
        collection: "0x1234...", // Collection A address  
        tokenId: 1,
        amount: 1,
        name: "Cool NFT #2",
        price: "0.15"
    },
    {
        collection: "0x5678...", // Collection B address
        tokenId: 0,
        amount: 3,
        name: "Awesome NFT #1", 
        price: "0.12"
    }
];

// Convert to contract format
const batchMintItems = shoppingCart.map(item => ({
    collection: item.collection,
    tokenId: item.tokenId,
    amount: item.amount
}));
```

### 2. Get Payment Estimate

```javascript
async function getPaymentEstimate(crossBatchMinter, items, useETH = true) {
    try {
        const [totalPayment, paymentToken, isValid] = await crossBatchMinter.getPaymentEstimate(
            items,
            useETH
        );
        
        return {
            total: ethers.utils.formatEther(totalPayment),
            token: paymentToken,
            valid: isValid
        };
    } catch (error) {
        console.error("Error getting payment estimate:", error);
        return { total: "0", token: ethers.constants.AddressZero, valid: false };
    }
}

// Usage
const estimate = await getPaymentEstimate(crossBatchMinter, batchMintItems, true);
console.log(`Total cost: ${estimate.total} ETH`);
```

### 3. Check User Eligibility

```javascript
async function checkEligibility(crossBatchMinter, userAddress, items, useETH = true) {
    try {
        const [canMint, totalRequired, paymentToken] = await crossBatchMinter.checkBatchMintEligibility(
            userAddress,
            items,
            useETH
        );
        
        return {
            eligible: canMint,
            required: ethers.utils.formatEther(totalRequired),
            token: paymentToken
        };
    } catch (error) {
        console.error("Error checking eligibility:", error);
        return { eligible: false, required: "0", token: ethers.constants.AddressZero };
    }
}

// Usage
const eligibility = await checkEligibility(crossBatchMinter, userAddress, batchMintItems);
if (!eligibility.eligible) {
    alert(`Insufficient funds. Required: ${eligibility.required} ETH`);
}
```

### 4. Execute Cross-Collection Batch Mint (ETH)

```javascript
async function batchMintWithETH(crossBatchMinter, recipient, items) {
    try {
        // Get payment estimate first
        const estimate = await getPaymentEstimate(crossBatchMinter, items, true);
        
        if (!estimate.valid) {
            throw new Error("Invalid items for batch minting");
        }
        
        // Execute the transaction
        const tx = await crossBatchMinter.batchMintAcrossCollections(
            recipient,
            items,
            {
                value: ethers.utils.parseEther(estimate.total),
                gasLimit: 500000 // Adjust based on number of items
            }
        );
        
        console.log("Transaction submitted:", tx.hash);
        
        // Wait for confirmation
        const receipt = await tx.wait();
        console.log("Batch mint successful! Gas used:", receipt.gasUsed.toString());
        
        return receipt;
        
    } catch (error) {
        console.error("Batch mint failed:", error);
        throw error;
    }
}

// Usage
await batchMintWithETH(crossBatchMinter, userAddress, batchMintItems);
```

### 5. Execute Cross-Collection Batch Mint (ERC20)

```javascript
async function batchMintWithERC20(crossBatchMinter, recipient, items, erc20TokenAddress) {
    try {
        // Get payment estimate
        const estimate = await getPaymentEstimate(crossBatchMinter, items, false);
        
        if (!estimate.valid) {
            throw new Error("Invalid items for ERC20 batch minting");
        }
        
        // Check and approve ERC20 spending if needed
        const erc20Contract = new ethers.Contract(erc20TokenAddress, erc20ABI, signer);
        const requiredAmount = ethers.utils.parseUnits(estimate.total, 18);
        
        const currentAllowance = await erc20Contract.allowance(
            userAddress, 
            crossBatchMinter.address
        );
        
        if (currentAllowance.lt(requiredAmount)) {
            console.log("Approving ERC20 spending...");
            const approveTx = await erc20Contract.approve(
                crossBatchMinter.address,
                requiredAmount
            );
            await approveTx.wait();
        }
        
        // Execute the batch mint
        const tx = await crossBatchMinter.batchMintAcrossCollectionsWithERC20(
            recipient,
            items,
            erc20TokenAddress,
            { gasLimit: 500000 }
        );
        
        console.log("ERC20 batch mint transaction submitted:", tx.hash);
        const receipt = await tx.wait();
        
        return receipt;
        
    } catch (error) {
        console.error("ERC20 batch mint failed:", error);
        throw error;
    }
}
```

### 6. Complete Shopping Cart Component (React Example)

```jsx
import React, { useState, useEffect } from 'react';
import { ethers } from 'ethers';

const ShoppingCartComponent = ({ crossBatchMinter, userAddress, signer }) => {
    const [cartItems, setCartItems] = useState([]);
    const [paymentEstimate, setPaymentEstimate] = useState(null);
    const [isProcessing, setIsProcessing] = useState(false);
    const [useETH, setUseETH] = useState(true);

    // Update payment estimate when cart changes
    useEffect(() => {
        if (cartItems.length > 0) {
            updatePaymentEstimate();
        }
    }, [cartItems, useETH]);

    const updatePaymentEstimate = async () => {
        const batchItems = cartItems.map(item => ({
            collection: item.collection,
            tokenId: item.tokenId,
            amount: item.amount
        }));

        const estimate = await getPaymentEstimate(crossBatchMinter, batchItems, useETH);
        setPaymentEstimate(estimate);
    };

    const handleCheckout = async () => {
        setIsProcessing(true);
        try {
            const batchItems = cartItems.map(item => ({
                collection: item.collection,
                tokenId: item.tokenId,
                amount: item.amount
            }));

            let receipt;
            if (useETH) {
                receipt = await batchMintWithETH(crossBatchMinter, userAddress, batchItems);
            } else {
                // Assuming USDC for this example
                const usdcAddress = "0xA0b86a33E6441c33c7e2a45acba8d32BB5A18e6e";
                receipt = await batchMintWithERC20(
                    crossBatchMinter, 
                    userAddress, 
                    batchItems, 
                    usdcAddress
                );
            }

            alert("Batch mint successful!");
            setCartItems([]); // Clear cart
            
        } catch (error) {
            alert("Batch mint failed: " + error.message);
        } finally {
            setIsProcessing(false);
        }
    };

    return (
        <div className="shopping-cart">
            <h2>Shopping Cart</h2>
            
            <div className="payment-method">
                <label>
                    <input 
                        type="radio" 
                        checked={useETH} 
                        onChange={() => setUseETH(true)} 
                    />
                    Pay with ETH
                </label>
                <label>
                    <input 
                        type="radio" 
                        checked={!useETH} 
                        onChange={() => setUseETH(false)} 
                    />
                    Pay with ERC20
                </label>
            </div>

            <div className="cart-items">
                {cartItems.map((item, index) => (
                    <div key={index} className="cart-item">
                        <span>{item.name}</span>
                        <span>Qty: {item.amount}</span>
                        <span>{item.price} {useETH ? 'ETH' : 'tokens'}</span>
                    </div>
                ))}
            </div>

            {paymentEstimate && (
                <div className="payment-summary">
                    <h3>Payment Summary</h3>
                    <p>Total: {paymentEstimate.total} {useETH ? 'ETH' : 'tokens'}</p>
                    <p>Collections: {new Set(cartItems.map(item => item.collection)).size}</p>
                    <p>Total Items: {cartItems.reduce((sum, item) => sum + item.amount, 0)}</p>
                </div>
            )}

            <button 
                onClick={handleCheckout}
                disabled={isProcessing || cartItems.length === 0}
                className="checkout-button"
            >
                {isProcessing ? 'Processing...' : 'Checkout All Items'}
            </button>
        </div>
    );
};

export default ShoppingCartComponent;
```

## Gas Optimization Tips

1. **Group by Collection**: The contract automatically groups items by collection to minimize gas costs
2. **Batch Size**: While there's no hard limit, batches of 10-20 items typically provide the best gas efficiency
3. **Payment Method**: ERC20 payments require additional approval transactions but can be cheaper for large batches

## Error Handling

Common errors and solutions:

```javascript
// Handle common errors
const handleBatchMintError = (error) => {
    if (error.message.includes("InvalidCollection")) {
        return "One or more collections are invalid";
    } else if (error.message.includes("MixedPaymentMethods")) {
        return "Cannot mix ETH and ERC20 payments in a single batch";
    } else if (error.message.includes("InsufficientPayment")) {
        return "Insufficient payment amount";
    } else if (error.message.includes("DropNotActive")) {
        return "One or more drops are not currently active";
    } else {
        return "Transaction failed: " + error.message;
    }
};
```

## Events Monitoring

```javascript
// Listen for batch mint events
crossBatchMinter.on("CrossCollectionBatchMint", (user, recipient, totalCollections, totalItems, paymentToken, totalPayment) => {
    console.log("Batch mint completed:", {
        user,
        recipient,
        collections: totalCollections.toString(),
        items: totalItems.toString(),
        token: paymentToken,
        amount: ethers.utils.formatEther(totalPayment)
    });
});

// Listen for individual item processing
crossBatchMinter.on("BatchMintItemProcessed", (collection, tokenId, amount, recipient) => {
    console.log("Item processed:", {
        collection,
        tokenId: tokenId.toString(),
        amount: amount.toString(),
        recipient
    });
});
```

This contract provides a seamless shopping cart experience for users wanting to mint from multiple collections in a single transaction, significantly improving UX and reducing gas costs compared to individual transactions. 