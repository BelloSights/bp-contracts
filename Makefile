# Environment file selection
ENV_FILE := .env
ifeq ($(findstring --network local,$(ARGS)),--network local)
ENV_FILE := .env.test
endif

# Load environment variables
-include $(ENV_FILE)

.PHONY: deploy test coverage build fork_test deploy_nft_factory upgrade_nft_factory verify_base_sepolia verify_base install-foundry-zksync deploy_nft_factory_zero verify_erc1155_implementation verify_blueprint_factory_implementation test-reward-pool deploy_reward_pool upgrade_reward_pool deploy_creator_reward_pool

DEFAULT_ANVIL_PRIVATE_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

install:; forge install
build:; forge build

# Target to install foundry-zksync fork required for Zero Network
install-foundry-zksync:
	@echo "Installing foundryup-zksync - required for Zero Network deployments"
	@curl -L https://raw.githubusercontent.com/matter-labs/foundry-zksync/main/install-foundry-zksync | bash
	@echo "Installed foundryup-zksync. You now have forge and cast with ZKsync support."
	@echo "Note: This installation overrides any existing forge and cast binaries in ~/.foundry"
	@echo "You can use forge without the --zksync flag for standard EVM chains"
	@echo "To revert to a previous installation, follow instructions on Using foundryup on the official Foundry website"

test:
	@source .env.test && forge clean && forge test -vvvv --ffi

test-coverage:
	@source .env.test && forge coverage --ffi

test-reward-pool:
	@source .env.test && forge clean && forge test --match-contract RewardPoolTest -vvvv --ffi

coverage :; forge coverage --ffi --report debug > coverage-report.txt
snapshot :; forge snapshot --ffi

NETWORK_ARGS := --rpc-url http://localhost:8545 --private-key $(DEFAULT_ANVIL_PRIVATE_KEY) --broadcast

# Goerli
ifeq ($(findstring --network goerli,$(ARGS)),--network goerli)
	NETWORK_ARGS := --rpc-url $(GOERLI_RPC_ENDPOINT) --private-key $(PRIVATE_KEY) --verify --etherscan-api-key $(ETHERSCAN_API_KEY) --broadcast -vvvv
endif

# Base Mainnet
ifeq ($(findstring --network base,$(ARGS)),--network base)
	NETWORK_ARGS := --rpc-url $(BASE_MAINNET_RPC) --private-key $(PRIVATE_KEY) --broadcast -vvvv
endif

# Base Sepolia
ifeq ($(findstring --network base_sepolia,$(ARGS)),--network base_sepolia)
	NETWORK_ARGS := --rpc-url $(BASE_SEPOLIA_RPC) --private-key $(PRIVATE_KEY) --broadcast -vvvv
endif

# Cyber Testnet
ifeq ($(findstring --network cyber_testnet,$(ARGS)),--network cyber_testnet)
	NETWORK_ARGS := --rpc-url $(CYBER_TESTNET_RPC) --private-key $(PRIVATE_KEY) --broadcast -vvvv
endif

# Cyber Mainnet 
ifeq ($(findstring --network cyber,$(ARGS)),--network cyber)
	NETWORK_ARGS := --rpc-url $(CYBER_MAINNET_RPC) --private-key $(PRIVATE_KEY) --broadcast -vvvv
endif

# Zero Network
ifeq ($(findstring --network zero,$(ARGS)),--network zero)
	NETWORK_ARGS := --rpc-url https://rpc.zerion.io/v1/zero --private-key $(PRIVATE_KEY) --broadcast --chain 543210 --zksync -vvvv
endif

# Local network
ifeq ($(findstring --network local,$(ARGS)),--network local)
	NETWORK_ARGS := --rpc-url http://localhost:8545 --private-key $(PRIVATE_KEY) --broadcast -vvvv
endif

# Add to NETWORK_ARGS handling
ifeq ($(findstring --unsafe,$(ARGS)),--unsafe)
	NETWORK_ARGS += --unsafe
endif

deploy_nft_factory:
	@source $(ENV_FILE) && forge script script/DeployBlueprintNFT.s.sol:DeployBlueprintNFT $(NETWORK_ARGS) --ffi

deploy_nft_factory_zero:
	@echo "NOTE: This requires foundryup-zksync. Install with 'make install-foundry-zksync'"
	@if ! command -v forge > /dev/null; then \
		echo "ERROR: forge command not found. Please install foundryup-zksync first with 'make install-foundry-zksync'"; \
		exit 1; \
	fi
	@source $(ENV_FILE) && forge script script/DeployBlueprintNFTZero.s.sol:DeployBlueprintNFTZero \
		--rpc-url https://rpc.zerion.io/v1/zero \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--chain 543210 \
		--zksync \
		-vvvv \
		--ffi

deploy_reward_pool:
	@source $(ENV_FILE) && forge script script/DeployRewardPool.s.sol:DeployRewardPool $(NETWORK_ARGS) --ffi

upgrade_reward_pool:
	@source $(ENV_FILE) && \
	  if [ -z "$${ETHERSCAN_API_KEY}" ] && [ -z "$${BASESCAN_API_KEY}" ]; then \
	    echo "ERROR: No explorer API key found. Set BASESCAN_API_KEY (preferred for Base) or ETHERSCAN_API_KEY in $(ENV_FILE)."; \
	    exit 1; \
	  fi; \
	  export ETHERSCAN_API_KEY=$${ETHERSCAN_API_KEY:-$${BASESCAN_API_KEY}} && \
	  forge clean && forge build --build-info && \
	  forge script script/UpgradeRewardPool.s.sol:UpgradeRewardPool $(NETWORK_ARGS) --ffi

# Deploy CreatorRewardPool factory to selected network (Base mainnet with ARGS=--network base)
deploy_creator_reward_pool:
	@source $(ENV_FILE) && \
	  export ETHERSCAN_API_KEY=$${ETHERSCAN_API_KEY:-$${BASESCAN_API_KEY}} && \
	  forge script script/DeployCreatorRewardPool.s.sol:DeployCreatorRewardPool $(NETWORK_ARGS) --ffi

# Verify CreatorRewardPool (implementation)
verify_creator_reward_pool_impl:
	@if [ -z "$(ADDRESS)" ]; then \
		echo "Usage: make verify_creator_reward_pool_impl ADDRESS=0x..."; \
		exit 1; \
	fi; \
	forge verify-contract \
		$(ADDRESS) \
		"src/reward-pool/CreatorRewardPool.sol:CreatorRewardPool" \
		--chain-id 8453 \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		--rpc-url $(BASE_MAINNET_RPC)

# Verify CreatorRewardPoolFactory (implementation)
verify_creator_reward_pool_factory_impl:
	@if [ -z "$(ADDRESS)" ]; then \
		echo "Usage: make verify_creator_reward_pool_factory_impl ADDRESS=0x..."; \
		exit 1; \
	fi; \
	forge verify-contract \
		$(ADDRESS) \
		"src/reward-pool/CreatorRewardPoolFactory.sol:CreatorRewardPoolFactory" \
		--chain-id 8453 \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		--rpc-url $(BASE_MAINNET_RPC)

# Verify CreatorRewardPoolFactory (proxy)
verify_creator_reward_pool_factory_proxy:
	@if [ -z "$(PROXY)" ] || [ -z "$(IMPL)" ] || [ -z "$(DEPLOYER)" ] || [ -z "$(POOL_IMPL)" ]; then \
		echo "Usage: make verify_creator_reward_pool_factory_proxy PROXY=0x... IMPL=0x... DEPLOYER=0x... POOL_IMPL=0x..."; \
		echo "Where: IMPL is factory implementation, POOL_IMPL is CreatorRewardPool implementation"; \
		exit 1; \
	fi; \
	forge verify-contract \
		$(PROXY) \
		"lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy" \
		--chain-id 8453 \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		--rpc-url $(BASE_MAINNET_RPC) \
		--constructor-args $$(cast abi-encode "constructor(address,bytes)" $(IMPL) $$(cast calldata "initialize(address,address)" $(DEPLOYER) $(POOL_IMPL)))

upgrade_nft_factory:
	@source $(ENV_FILE) && forge script script/UpgradeBlueprintNFT.s.sol:UpgradeBlueprintNFT $(NETWORK_ARGS) \
		--ffi \
		--sig "run()"

fork_test:
	@forge test --rpc-url $(RPC_ENDPOINT) -vvv

verify_erc1155_implementation:
	@forge verify-contract \
		$(BASE_ERC1155_IMPLEMENTATION_ADDRESS) \
		"src/nft/BlueprintERC1155.sol:BlueprintERC1155" \
		--chain-id 8453 \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		--rpc-url $(BASE_MAINNET_RPC) \
		--watch

verify_blueprint_factory_implementation:
	@echo "Verifying BlueprintERC1155Factory implementation contract..."
	@forge verify-contract \
		$(BASE_ERC1155_FACTORY_IMPLEMENTATION_ADDRESS) \
		"src/nft/BlueprintERC1155Factory.sol:BlueprintERC1155Factory" \
		--chain-id 8453 \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		--rpc-url $(BASE_MAINNET_RPC) \
		--watch

verify_erc1155_implementation_base_sepolia:
	@forge verify-contract \
		$(BASE_SEPOLIA_ERC1155_IMPLEMENTATION_ADDRESS) \
		"src/nft/BlueprintERC1155.sol:BlueprintERC1155" \
		--chain-id 84532 \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		--rpc-url $(BASE_SEPOLIA_RPC) \
		--watch

verify_blueprint_factory_implementation_base_sepolia:
	@echo "Verifying BlueprintERC1155Factory implementation contract..."
	@forge verify-contract \
		$(BASE_SEPOLIA_ERC1155_FACTORY_IMPLEMENTATION_ADDRESS) \
		"src/nft/BlueprintERC1155Factory.sol:BlueprintERC1155Factory" \
		--chain-id 84532 \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		--rpc-url $(BASE_SEPOLIA_RPC) \
		--watch

# Unified verification commands that support both networks
verify_reward_pool:
	@if [ -z "$(NETWORK)" ]; then \
		echo "Usage: make verify_reward_pool NETWORK=base|base_sepolia"; \
		echo "Example: make verify_reward_pool NETWORK=base_sepolia"; \
		exit 1; \
	fi
	@if [ "$(NETWORK)" = "base" ]; then \
		echo "Verifying RewardPool contracts on Base Mainnet..."; \
		echo "Verifying RewardPool implementation..."; \
		forge verify-contract $(BASE_REWARD_POOL_IMPLEMENTATION_ADDRESS) "src/reward-pool/RewardPool.sol:RewardPool" --chain-id 8453 --etherscan-api-key $(BASESCAN_API_KEY) --rpc-url $(BASE_MAINNET_RPC); \
		echo "Waiting 10 seconds..."; \
		sleep 10; \
		echo "Verifying RewardPoolFactory implementation..."; \
		forge verify-contract $(BASE_REWARD_POOL_FACTORY_IMPLEMENTATION_ADDRESS) "src/reward-pool/RewardPoolFactory.sol:RewardPoolFactory" --chain-id 8453 --etherscan-api-key $(BASESCAN_API_KEY) --rpc-url $(BASE_MAINNET_RPC); \
		echo "Waiting 10 seconds..."; \
		sleep 10; \
		echo "Verifying RewardPoolFactory proxy..."; \
		forge verify-contract $(BASE_REWARD_POOL_FACTORY_PROXY_ADDRESS) "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy" --chain-id 8453 --etherscan-api-key $(BASESCAN_API_KEY) --rpc-url $(BASE_MAINNET_RPC) --constructor-args $(shell cast abi-encode "constructor(address,bytes)" $(BASE_REWARD_POOL_FACTORY_IMPLEMENTATION_ADDRESS) $(shell cast calldata "initialize(address,address)" $(DEPLOYER_ADDRESS) $(BASE_REWARD_POOL_IMPLEMENTATION_ADDRESS))); \
		echo "All RewardPool contracts verified on Base Mainnet!"; \
	elif [ "$(NETWORK)" = "base_sepolia" ]; then \
		echo "Verifying RewardPool contracts on Base Sepolia..."; \
		echo "Verifying RewardPool implementation..."; \
		forge verify-contract $(BASE_SEPOLIA_REWARD_POOL_IMPLEMENTATION_ADDRESS) "src/reward-pool/RewardPool.sol:RewardPool" --chain-id 84532 --etherscan-api-key $(BASESCAN_API_KEY) --rpc-url $(BASE_SEPOLIA_RPC); \
		echo "Waiting 10 seconds..."; \
		sleep 10; \
		echo "Verifying RewardPoolFactory implementation..."; \
		forge verify-contract $(BASE_SEPOLIA_REWARD_POOL_FACTORY_IMPLEMENTATION_ADDRESS) "src/reward-pool/RewardPoolFactory.sol:RewardPoolFactory" --chain-id 84532 --etherscan-api-key $(BASESCAN_API_KEY) --rpc-url $(BASE_SEPOLIA_RPC); \
		echo "Waiting 10 seconds..."; \
		sleep 10; \
		echo "Verifying RewardPoolFactory proxy..."; \
		forge verify-contract $(BASE_SEPOLIA_REWARD_POOL_FACTORY_PROXY_ADDRESS) "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy" --chain-id 84532 --etherscan-api-key $(BASESCAN_API_KEY) --rpc-url $(BASE_SEPOLIA_RPC) --constructor-args $(shell cast abi-encode "constructor(address,bytes)" $(BASE_SEPOLIA_REWARD_POOL_FACTORY_IMPLEMENTATION_ADDRESS) $(shell cast calldata "initialize(address,address)" $(DEPLOYER_ADDRESS) $(BASE_SEPOLIA_REWARD_POOL_IMPLEMENTATION_ADDRESS))); \
		echo "All RewardPool contracts verified on Base Sepolia!"; \
	else \
		echo "Error: Invalid network '$(NETWORK)'. Use 'base' or 'base_sepolia'"; \
		exit 1; \
	fi

# Individual unified commands
verify_reward_pool_impl:
	@if [ -z "$(NETWORK)" ]; then \
		echo "Usage: make verify_reward_pool_impl NETWORK=base|base_sepolia"; \
		exit 1; \
	fi
	@if [ "$(NETWORK)" = "base" ]; then \
		echo "Verifying RewardPool implementation on Base Mainnet..."; \
		forge verify-contract $(BASE_REWARD_POOL_IMPLEMENTATION_ADDRESS) "src/reward-pool/RewardPool.sol:RewardPool" --chain-id 8453 --etherscan-api-key $(BASESCAN_API_KEY) --rpc-url $(BASE_MAINNET_RPC); \
		echo "Verification submitted. Check status on Basescan."; \
	elif [ "$(NETWORK)" = "base_sepolia" ]; then \
		echo "Verifying RewardPool implementation on Base Sepolia..."; \
		forge verify-contract $(BASE_SEPOLIA_REWARD_POOL_IMPLEMENTATION_ADDRESS) "src/reward-pool/RewardPool.sol:RewardPool" --chain-id 84532 --etherscan-api-key $(BASESCAN_API_KEY) --rpc-url $(BASE_SEPOLIA_RPC); \
		echo "Verification submitted. Check status on Basescan."; \
	else \
		echo "Error: Invalid network '$(NETWORK)'. Use 'base' or 'base_sepolia'"; \
		exit 1; \
	fi

verify_reward_pool_factory_impl:
	@if [ -z "$(NETWORK)" ]; then \
		echo "Usage: make verify_reward_pool_factory_impl NETWORK=base|base_sepolia"; \
		exit 1; \
	fi
	@if [ "$(NETWORK)" = "base" ]; then \
		echo "Verifying RewardPoolFactory implementation on Base Mainnet..."; \
		forge verify-contract $(BASE_REWARD_POOL_FACTORY_IMPLEMENTATION_ADDRESS) "src/reward-pool/RewardPoolFactory.sol:RewardPoolFactory" --chain-id 8453 --etherscan-api-key $(BASESCAN_API_KEY) --rpc-url $(BASE_MAINNET_RPC); \
		echo "Verification submitted. Check status on Basescan."; \
	elif [ "$(NETWORK)" = "base_sepolia" ]; then \
		echo "Verifying RewardPoolFactory implementation on Base Sepolia..."; \
		forge verify-contract $(BASE_SEPOLIA_REWARD_POOL_FACTORY_IMPLEMENTATION_ADDRESS) "src/reward-pool/RewardPoolFactory.sol:RewardPoolFactory" --chain-id 84532 --etherscan-api-key $(BASESCAN_API_KEY) --rpc-url $(BASE_SEPOLIA_RPC); \
		echo "Verification submitted. Check status on Basescan."; \
	else \
		echo "Error: Invalid network '$(NETWORK)'. Use 'base' or 'base_sepolia'"; \
		exit 1; \
	fi

verify_reward_pool_proxy:
	@if [ -z "$(NETWORK)" ]; then \
		echo "Usage: make verify_reward_pool_proxy NETWORK=base|base_sepolia"; \
		exit 1; \
	fi
	@if [ "$(NETWORK)" = "base" ]; then \
		echo "Verifying RewardPoolFactory proxy on Base Mainnet..."; \
		forge verify-contract $(BASE_REWARD_POOL_FACTORY_PROXY_ADDRESS) "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy" --chain-id 8453 --etherscan-api-key $(BASESCAN_API_KEY) --rpc-url $(BASE_MAINNET_RPC) --constructor-args $(shell cast abi-encode "constructor(address,bytes)" $(BASE_REWARD_POOL_FACTORY_IMPLEMENTATION_ADDRESS) $(shell cast calldata "initialize(address,address)" $(DEPLOYER_ADDRESS) $(BASE_REWARD_POOL_IMPLEMENTATION_ADDRESS))); \
		echo "Verification submitted. Check status on Basescan."; \
	elif [ "$(NETWORK)" = "base_sepolia" ]; then \
		echo "Verifying RewardPoolFactory proxy on Base Sepolia..."; \
		forge verify-contract $(BASE_SEPOLIA_REWARD_POOL_FACTORY_PROXY_ADDRESS) "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy" --chain-id 84532 --etherscan-api-key $(BASESCAN_API_KEY) --rpc-url $(BASE_SEPOLIA_RPC) --constructor-args $(shell cast abi-encode "constructor(address,bytes)" $(BASE_SEPOLIA_REWARD_POOL_FACTORY_IMPLEMENTATION_ADDRESS) $(shell cast calldata "initialize(address,address)" $(DEPLOYER_ADDRESS) $(BASE_SEPOLIA_REWARD_POOL_IMPLEMENTATION_ADDRESS))); \
		echo "Verification submitted. Check status on Basescan."; \
	else \
		echo "Error: Invalid network '$(NETWORK)'. Use 'base' or 'base_sepolia'"; \
		exit 1; \
	fi

verify_base_sepolia:
	@if [ -z "${ADDRESS}" ] || [ -z "${CONTRACT}" ]; then \
		echo "Usage: make verify_base_sepolia ADDRESS=0x... CONTRACT=path:Name"; \
		echo "Example targets:"; \
		echo "  BlueprintERC1155:        src/nft/BlueprintERC1155.sol:BlueprintERC1155"; \
		echo "  BlueprintERC1155Factory: src/nft/BlueprintERC1155Factory.sol:BlueprintERC1155Factory"; \
		exit 1; \
	fi
	forge verify-contract \
		${ADDRESS} \
		"${CONTRACT}" \
		--chain-id 84532 \
		--verifier etherscan \
		--etherscan-api-key ${BASESCAN_API_KEY}

verify_base:
	@if [ -z "${ADDRESS}" ] || [ -z "${CONTRACT}" ]; then \
		echo "Usage: make verify_base ADDRESS=0x... CONTRACT=path:Name"; \
		echo "Example targets:"; \
		echo "  BlueprintERC1155:        src/nft/BlueprintERC1155.sol:BlueprintERC1155"; \
		echo "  BlueprintERC1155Factory: src/nft/BlueprintERC1155Factory.sol:BlueprintERC1155Factory"; \
		exit 1; \
	fi
	forge verify-contract \
		${ADDRESS} \
		"${CONTRACT}" \
		--chain-id 8453 \
		--verifier etherscan \
		--etherscan-api-key ${BASESCAN_API_KEY}