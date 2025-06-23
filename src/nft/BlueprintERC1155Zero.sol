// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "@openzeppelin-contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin-contracts/access/AccessControl.sol";
import "@openzeppelin-contracts/utils/Strings.sol";
import "@openzeppelin-contracts/utils/ReentrancyGuard.sol";

/**
 * @title BlueprintERC1155Zero
 * @dev Simplified ERC1155 implementation for zkSync Era Zero deployment
 */
contract BlueprintERC1155Zero is ERC1155, AccessControl, ReentrancyGuard {
    using Strings for uint256;

    // ===== ERRORS =====
    error BlueprintERC1155__InvalidStartEndTime();
    error BlueprintERC1155__DropNotActive();
    error BlueprintERC1155__DropNotStarted();
    error BlueprintERC1155__DropEnded();
    error BlueprintERC1155__InsufficientPayment(uint256 required, uint256 provided);
    error BlueprintERC1155__BlueprintFeeTransferFailed();
    error BlueprintERC1155__CreatorFeeTransferFailed();
    error BlueprintERC1155__TreasuryTransferFailed();
    error BlueprintERC1155__RewardPoolFeeTransferFailed();
    error BlueprintERC1155__RefundFailed();
    error BlueprintERC1155__StartAfterEnd();
    error BlueprintERC1155__EndBeforeStart();
    error BlueprintERC1155__BatchLengthMismatch();
    error BlueprintERC1155__ZeroBlueprintRecipient();
    error BlueprintERC1155__ZeroCreatorRecipient();

    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");

    struct Drop {
        uint256 price;
        uint256 startTime;
        uint256 endTime;
        bool active;
    }

    struct FeeConfig {
        address blueprintRecipient;
        uint256 blueprintFeeBasisPoints;
        address creatorRecipient;
        uint256 creatorBasisPoints;
        address rewardPoolRecipient;
        uint256 rewardPoolBasisPoints;
        address treasury;
    }

    string private _name;
    string private _symbol;
    uint256 public nextTokenId;
    mapping(uint256 => uint256) private _totalSupply;
    uint256 private _globalTotalSupply;
    mapping(uint256 => string) private _tokenURIs;
    string private _collectionURI;
    mapping(uint256 => Drop) public drops;
    FeeConfig public defaultFeeConfig;
    mapping(uint256 => FeeConfig) public tokenFeeConfigs;
    mapping(uint256 => bool) public hasCustomFeeConfig;

    event DropCreated(uint256 indexed tokenId, uint256 price, uint256 startTime, uint256 endTime);
    event DropUpdated(uint256 indexed tokenId, uint256 price, uint256 startTime, uint256 endTime, bool active);
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

    constructor(
        string memory uri_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address blueprintRecipient_,
        uint256 feeBasisPoints_,
        address creatorRecipient_,
        uint256 creatorBasisPoints_,
        address rewardPoolRecipient_,
        uint256 rewardPoolBasisPoints_,
        address treasury_
    ) ERC1155(uri_) {
        _name = name_;
        _symbol = symbol_;
        _collectionURI = uri_;

        // Grant admin and factory roles to the admin (which will be the factory)
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(FACTORY_ROLE, admin_);

        // Grant creator role if specified
        if (creatorRecipient_ != address(0)) {
            _grantRole(CREATOR_ROLE, creatorRecipient_);
        }

        defaultFeeConfig = FeeConfig({
            blueprintRecipient: blueprintRecipient_,
            blueprintFeeBasisPoints: feeBasisPoints_,
            creatorRecipient: creatorRecipient_,
            creatorBasisPoints: creatorBasisPoints_,
            rewardPoolRecipient: rewardPoolRecipient_,
            rewardPoolBasisPoints: rewardPoolBasisPoints_,
            treasury: treasury_
        });
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function setName(string memory name_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _name = name_;
    }

    function setSymbol(string memory symbol_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _symbol = symbol_;
    }

    function setURI(string memory uri_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setURI(uri_);
        _collectionURI = uri_;
        emit CollectionURIUpdated(uri_);
    }

    function setTokenURI(uint256 tokenId, string memory uri_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _tokenURIs[tokenId] = uri_;
        emit TokenURIUpdated(tokenId, uri_);
    }

    function uri(uint256 tokenId) public view override returns (string memory) {
        string memory tokenURI = _tokenURIs[tokenId];
        if (bytes(tokenURI).length == 0) {
            return string(abi.encodePacked(_collectionURI, tokenId.toString()));
        }
        return tokenURI;
    }

    function collectionURI() public view returns (string memory) {
        return _collectionURI;
    }

    function createDrop(
        uint256 price,
        uint256 startTime,
        uint256 endTime,
        bool active
    ) external onlyRole(FACTORY_ROLE) returns (uint256) {
        if (startTime >= endTime && endTime != 0) {
            revert BlueprintERC1155__InvalidStartEndTime();
        }

        uint256 tokenId = nextTokenId;
        nextTokenId++;

        drops[tokenId] = Drop({
            price: price,
            startTime: startTime,
            endTime: endTime,
            active: active
        });

        emit DropCreated(tokenId, price, startTime, endTime);
        return tokenId;
    }

    function setDrop(
        uint256 tokenId,
        uint256 price,
        uint256 startTime,
        uint256 endTime,
        bool active
    ) external onlyRole(FACTORY_ROLE) {
        if (startTime >= endTime && endTime != 0) {
            revert BlueprintERC1155__StartAfterEnd();
        }

        // Update nextTokenId if necessary
        if (tokenId >= nextTokenId) {
            nextTokenId = tokenId + 1;
        }

        drops[tokenId] = Drop({
            price: price,
            startTime: startTime,
            endTime: endTime,
            active: active
        });

        emit DropUpdated(tokenId, price, startTime, endTime, active);
    }

    function updateDropTimes(uint256 tokenId, uint256 startTime, uint256 endTime)
        external
        onlyRole(CREATOR_ROLE)
    {
        if (startTime >= endTime) {
            revert BlueprintERC1155__StartAfterEnd();
        }

        Drop storage drop = drops[tokenId];
        if (!drop.active) {
            revert BlueprintERC1155__DropNotActive();
        }

        drop.startTime = startTime;
        drop.endTime = endTime;

        emit DropUpdated(tokenId, drop.price, startTime, endTime, drop.active);
    }

    function mint(
        address to,
        uint256 tokenId,
        uint256 amount
    ) external payable nonReentrant {
        Drop memory drop = drops[tokenId];
        if (!drop.active) {
            revert BlueprintERC1155__DropNotActive();
        }
        if (block.timestamp < drop.startTime) {
            revert BlueprintERC1155__DropNotStarted();
        }
        if (block.timestamp > drop.endTime) {
            revert BlueprintERC1155__DropEnded();
        }

        uint256 payment = drop.price * amount;
        if (msg.value < payment) {
            revert BlueprintERC1155__InsufficientPayment(payment, msg.value);
        }

        FeeConfig memory config = getFeeConfig(tokenId);
        if (config.blueprintRecipient == address(0)) {
            revert BlueprintERC1155__ZeroBlueprintRecipient();
        }
        if (config.creatorRecipient == address(0)) {
            revert BlueprintERC1155__ZeroCreatorRecipient();
        }

        uint256 platformFee = (payment * config.blueprintFeeBasisPoints) / 10000;
        uint256 creatorFee = (payment * config.creatorBasisPoints) / 10000;
        uint256 rewardPoolFee = (payment * config.rewardPoolBasisPoints) / 10000;
        uint256 treasuryAmount = payment - platformFee - creatorFee - rewardPoolFee;

        (bool feeSuccess,) = config.blueprintRecipient.call{value: platformFee}("");
        if (!feeSuccess) {
            revert BlueprintERC1155__BlueprintFeeTransferFailed();
        }

        (bool creatorSuccess,) = config.creatorRecipient.call{value: creatorFee}("");
        if (!creatorSuccess) {
            revert BlueprintERC1155__CreatorFeeTransferFailed();
        }

        if (config.rewardPoolRecipient != address(0)) {
            (bool rewardSuccess,) = config.rewardPoolRecipient.call{value: rewardPoolFee}("");
            if (!rewardSuccess) {
                revert BlueprintERC1155__RewardPoolFeeTransferFailed();
            }
        } else {
            treasuryAmount += rewardPoolFee;
        }

        if (treasuryAmount > 0) {
            (bool treasurySuccess,) = config.treasury.call{value: treasuryAmount}("");
            if (!treasurySuccess) {
                revert BlueprintERC1155__TreasuryTransferFailed();
            }
        }

        _mint(to, tokenId, amount, "");
        _totalSupply[tokenId] += amount;
        _globalTotalSupply += amount;

        emit TokensMinted(to, tokenId, amount);
    }

    function batchMint(address to, uint256[] memory tokenIds, uint256[] memory amounts)
        external
        payable
        nonReentrant
    {
        if (tokenIds.length != amounts.length) {
            revert BlueprintERC1155__BatchLengthMismatch();
        }

        uint256 requiredPayment = 0;

        // Calculate required payment and validate drops
        for (uint256 i = 0; i < tokenIds.length; i++) {
            Drop memory drop = drops[tokenIds[i]];
            if (!drop.active) {
                revert BlueprintERC1155__DropNotActive();
            }
            if (block.timestamp < drop.startTime) {
                revert BlueprintERC1155__DropNotStarted();
            }
            if (block.timestamp > drop.endTime && drop.endTime != 0) {
                revert BlueprintERC1155__DropEnded();
            }

            requiredPayment += drop.price * amounts[i];
        }

        if (msg.value < requiredPayment) {
            revert BlueprintERC1155__InsufficientPayment(requiredPayment, msg.value);
        }

        _mintBatch(to, tokenIds, amounts, "");

        // Update total supplies
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _totalSupply[tokenIds[i]] += amounts[i];
            totalAmount += amounts[i];
        }

        // Update global total supply
        _globalTotalSupply += totalAmount;

        // Process payments for each token
        uint256 totalProcessed = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            Drop memory drop = drops[tokenIds[i]];
            uint256 payment = drop.price * amounts[i];

            // Get fee config for this token
            FeeConfig memory config = getFeeConfig(tokenIds[i]);

            // Validate essential recipients
            if (config.blueprintRecipient == address(0)) {
                revert BlueprintERC1155__ZeroBlueprintRecipient();
            }
            if (config.creatorRecipient == address(0)) {
                revert BlueprintERC1155__ZeroCreatorRecipient();
            }

            // Calculate fees
            uint256 platformFee = (payment * config.blueprintFeeBasisPoints) / 10000;
            uint256 creatorFee = (payment * config.creatorBasisPoints) / 10000;
            uint256 rewardPoolFee = (payment * config.rewardPoolBasisPoints) / 10000;
            uint256 treasuryAmount = payment - platformFee - creatorFee;

            // Send platform fee
            (bool feeSuccess,) = config.blueprintRecipient.call{value: platformFee}("");
            if (!feeSuccess) {
                revert BlueprintERC1155__BlueprintFeeTransferFailed();
            }

            // Send creator fee
            (bool creatorSuccess,) = config.creatorRecipient.call{value: creatorFee}("");
            if (!creatorSuccess) {
                revert BlueprintERC1155__CreatorFeeTransferFailed();
            }

            // Send reward pool fee if recipient is set, otherwise it goes to treasury
            if (rewardPoolFee > 0 && config.rewardPoolRecipient != address(0)) {
                (bool rewardPoolSuccess,) = config.rewardPoolRecipient.call{value: rewardPoolFee}("");
                if (!rewardPoolSuccess) {
                    revert BlueprintERC1155__RewardPoolFeeTransferFailed();
                }
                // Subtract reward pool fee from treasury amount since it was sent
                treasuryAmount -= rewardPoolFee;
            }

            // Send treasury amount
            if (treasuryAmount > 0 && config.treasury != address(0)) {
                (bool treasurySuccess,) = config.treasury.call{value: treasuryAmount}("");
                if (!treasurySuccess) {
                    revert BlueprintERC1155__TreasuryTransferFailed();
                }
            }

            totalProcessed += payment;
        }

        // Refund excess payment if any
        if (msg.value > requiredPayment) {
            uint256 refund = msg.value - requiredPayment;
            (bool refundSuccess,) = msg.sender.call{value: refund}("");
            if (!refundSuccess) {
                revert BlueprintERC1155__RefundFailed();
            }
        }

        emit TokensBatchMinted(to, tokenIds, amounts);
    }

    function adminMint(address to, uint256 tokenId, uint256 amount)
        external
        onlyRole(FACTORY_ROLE)
    {
        _mint(to, tokenId, amount, "");

        // Update total supply for the token ID
        _totalSupply[tokenId] += amount;

        // Update global total supply
        _globalTotalSupply += amount;

        emit TokensMinted(to, tokenId, amount);
    }

    function adminBatchMint(address to, uint256[] memory tokenIds, uint256[] memory amounts)
        external
        onlyRole(FACTORY_ROLE)
    {
        if (tokenIds.length != amounts.length) {
            revert BlueprintERC1155__BatchLengthMismatch();
        }

        _mintBatch(to, tokenIds, amounts, "");

        // Update total supplies per token ID
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _totalSupply[tokenIds[i]] += amounts[i];
            totalAmount += amounts[i];
        }

        // Update global total supply
        _globalTotalSupply += totalAmount;

        emit TokensBatchMinted(to, tokenIds, amounts);
    }

    function getFeeConfig(uint256 tokenId) public view returns (FeeConfig memory) {
        if (hasCustomFeeConfig[tokenId]) {
            return tokenFeeConfigs[tokenId];
        }
        return defaultFeeConfig;
    }

    function totalSupply(uint256 tokenId) external view returns (uint256) {
        return _totalSupply[tokenId];
    }

    function totalSupply() external view returns (uint256) {
        return _globalTotalSupply;
    }

    function setFeeConfig(
        address _blueprintRecipient,
        uint256 _feeBasisPoints,
        address _creatorRecipient,
        uint256 _creatorBasisPoints,
        address _rewardPoolRecipient,
        uint256 _rewardPoolBasisPoints,
        address _treasury
    ) external onlyRole(FACTORY_ROLE) {
        defaultFeeConfig = FeeConfig({
            blueprintRecipient: _blueprintRecipient,
            blueprintFeeBasisPoints: _feeBasisPoints,
            creatorRecipient: _creatorRecipient,
            creatorBasisPoints: _creatorBasisPoints,
            rewardPoolRecipient: _rewardPoolRecipient,
            rewardPoolBasisPoints: _rewardPoolBasisPoints,
            treasury: _treasury
        });

        emit FeeConfigUpdated(
            _blueprintRecipient,
            _feeBasisPoints,
            _creatorRecipient,
            _creatorBasisPoints,
            _rewardPoolRecipient,
            _rewardPoolBasisPoints,
            _treasury
        );
    }

    function setTokenFeeConfig(
        uint256 tokenId,
        address _blueprintRecipient,
        uint256 _feeBasisPoints,
        address _creatorRecipient,
        uint256 _creatorBasisPoints,
        address _rewardPoolRecipient,
        uint256 _rewardPoolBasisPoints,
        address _treasury
    ) external onlyRole(FACTORY_ROLE) {
        tokenFeeConfigs[tokenId] = FeeConfig({
            blueprintRecipient: _blueprintRecipient,
            blueprintFeeBasisPoints: _feeBasisPoints,
            creatorRecipient: _creatorRecipient,
            creatorBasisPoints: _creatorBasisPoints,
            rewardPoolRecipient: _rewardPoolRecipient,
            rewardPoolBasisPoints: _rewardPoolBasisPoints,
            treasury: _treasury
        });

        hasCustomFeeConfig[tokenId] = true;

        emit TokenFeeConfigUpdated(
            tokenId,
            _blueprintRecipient,
            _feeBasisPoints,
            _creatorRecipient,
            _creatorBasisPoints,
            _rewardPoolRecipient,
            _rewardPoolBasisPoints,
            _treasury
        );
    }

    function removeTokenFeeConfig(uint256 tokenId) external onlyRole(FACTORY_ROLE) {
        delete tokenFeeConfigs[tokenId];
        hasCustomFeeConfig[tokenId] = false;

        emit TokenFeeConfigRemoved(tokenId);
    }

    function setDropPrice(uint256 tokenId, uint256 price) external onlyRole(FACTORY_ROLE) {
        drops[tokenId].price = price;

        emit DropUpdated(
            tokenId, price, drops[tokenId].startTime, drops[tokenId].endTime, drops[tokenId].active
        );
    }

    function setDropStartTime(uint256 tokenId, uint256 startTime) external onlyRole(FACTORY_ROLE) {
        if (startTime >= drops[tokenId].endTime && drops[tokenId].endTime != 0) {
            revert BlueprintERC1155__StartAfterEnd();
        }

        drops[tokenId].startTime = startTime;

        emit DropUpdated(
            tokenId, drops[tokenId].price, startTime, drops[tokenId].endTime, drops[tokenId].active
        );
    }

    function setDropEndTime(uint256 tokenId, uint256 endTime) external onlyRole(FACTORY_ROLE) {
        if (drops[tokenId].startTime >= endTime && endTime != 0) {
            revert BlueprintERC1155__EndBeforeStart();
        }

        drops[tokenId].endTime = endTime;

        emit DropUpdated(
            tokenId, drops[tokenId].price, drops[tokenId].startTime, endTime, drops[tokenId].active
        );
    }

    function setDropActive(uint256 tokenId, bool active) external onlyRole(FACTORY_ROLE) {
        drops[tokenId].active = active;

        emit DropUpdated(
            tokenId, drops[tokenId].price, drops[tokenId].startTime, drops[tokenId].endTime, active
        );
    }

    function setCreatorRecipient(address _creatorRecipient) external onlyRole(FACTORY_ROLE) {
        defaultFeeConfig.creatorRecipient = _creatorRecipient;

        emit FeeConfigUpdated(
            defaultFeeConfig.blueprintRecipient,
            defaultFeeConfig.blueprintFeeBasisPoints,
            _creatorRecipient,
            defaultFeeConfig.creatorBasisPoints,
            defaultFeeConfig.rewardPoolRecipient,
            defaultFeeConfig.rewardPoolBasisPoints,
            defaultFeeConfig.treasury
        );
    }

    function setRewardPoolRecipient(address _rewardPoolRecipient) external onlyRole(FACTORY_ROLE) {
        defaultFeeConfig.rewardPoolRecipient = _rewardPoolRecipient;

        emit FeeConfigUpdated(
            defaultFeeConfig.blueprintRecipient,
            defaultFeeConfig.blueprintFeeBasisPoints,
            defaultFeeConfig.creatorRecipient,
            defaultFeeConfig.creatorBasisPoints,
            _rewardPoolRecipient,
            defaultFeeConfig.rewardPoolBasisPoints,
            defaultFeeConfig.treasury
        );
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
} 