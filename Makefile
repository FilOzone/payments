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
	./tools/deploy.sh 314159

.PHONY: deploy-devnet
deploy-devnet:
	./tools/deploy.sh 31415926

.PHONY: deploy-mainnet
deploy-mainnet:
	./tools/deploy.sh 314

# Upgrade targets
.PHONY: upgrade-calibnet
upgrade-calibnet:
	./tools/upgrade-contract.sh 314159

.PHONY: upgrade-devnet
upgrade-devnet:
	./tools/upgrade-contract.sh 31415926

.PHONY: upgrade-mainnet
upgrade-mainnet:
	./tools/upgrade-contract.sh 314

# Ownership management targets
.PHONY: transfer-owner
transfer-owner:
	./tools/transfer-owner.sh

.PHONY: get-owner
get-owner:
	./tools/get-owner.sh

