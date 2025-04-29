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
