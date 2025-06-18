# Makefile for Payment Contracts

# Default target
.PHONY: default
default: build test

# All target including installation
.PHONY: all
all: install build test

# Install dependencies
.PHONY: install
install:
	forge install

# Build target
.PHONY: build
build:
	forge build

# Test target
.PHONY: test
test:
	forge test -vv

# Deployment targets
.PHONY: deploy-calibnet
deploy-calibnet:
	./tools/deploy-calibnet.sh

.PHONY: deploy-devnet
deploy-devnet:
	./tools/deploy-devnet.sh

.PHONY: deploy-mainnet
deploy-mainnet:
	./tools/deploy-mainnet.sh

# Upgrade targets
.PHONY: upgrade-calibnet
upgrade-calibnet:
	./tools/upgrade-contract-calibnet.sh

.PHONY: upgrade-mainnet
upgrade-mainnet:
	./tools/upgrade-contract-mainnet.sh

# Ownership management targets
.PHONY: transfer-owner
transfer-owner:
	./tools/transfer-owner.sh

.PHONY: get-owner
get-owner:
	./tools/get-owner.sh

