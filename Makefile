PROFILE := default
NETWORK := local
PACKAGE_DIR := .
MODULE_NAME := hashlock
RUST_TOOLCHAIN := nightly-2025-01-30
RUST_EDITION := 2024
TARGET_DIR := target

YELLOW := \033[1;33m
GREEN := \033[1;32m
RED := \033[1;31m
NC := \033[0m

start:
	@echo "Starting with indexer API (requires Docker)..."
	@docker info >/dev/null 2>&1 || (echo "ERROR: Docker not running. Start Docker or use 'make start-simple'" && exit 1)
	aptos node run-local-testnet --with-indexer-api

restart:
	@docker info >/dev/null 2>&1 || (echo "ERROR: Docker not running. Start Docker or use 'make restart-simple'" && exit 1)
	aptos node run-local-testnet --with-indexer-api --force-restart --assume-yes

start-simple:
	@echo "Starting without indexer API (no Docker required)..."
	aptos node run-local-testnet

restart-simple:
	aptos node run-local-testnet --force-restart --assume-yes

kill-ports:
ifeq ($(OS),Windows_NT)
	@for /f "tokens=5" %a in ('netstat -ano ^| findstr :8080') do taskkill /PID %a /F 2>nul || echo Port 8080 not in use
	@for /f "tokens=5" %a in ('netstat -ano ^| findstr :9102') do taskkill /PID %a /F 2>nul || echo Port 9102 not in use
	@for /f "tokens=5" %a in ('netstat -ano ^| findstr :5433') do taskkill /PID %a /F 2>nul || echo Port 5433 not in use
else
	@lsof -ti:8080 | xargs kill -9 2>/dev/null || echo "Port 8080 not in use"
	@lsof -ti:9102 | xargs kill -9 2>/dev/null || echo "Port 9102 not in use"
	@lsof -ti:5433 | xargs kill -9 2>/dev/null || echo "Port 5433 not in use"
endif

deploy:
	aptos move publish --profile $(PROFILE) --package-dir $(PACKAGE_DIR)

version:
	aptos move run --profile $(PROFILE) --function-id $(shell aptos account lookup-address --profile $(PROFILE))::$(MODULE_NAME)::version

compile:
	aptos move compile --package-dir $(PACKAGE_DIR)

test-move:
	aptos move test --package-dir $(PACKAGE_DIR)

clean-move:
	rm -rf build/

init:
	aptos init --profile $(PROFILE) --network $(NETWORK)

fund:
	aptos account fund-with-faucet --profile $(PROFILE)

install-taplo:
	@echo "$(YELLOW)Installing TAPLO...$(NC)"
	@if ! command -v taplo >/dev/null 2>&1; then \
		cargo install taplo-cli --locked; \
	fi
	@echo "$(GREEN)✓ TAPLO installed$(NC)"

install-sp1:
	@echo "$(YELLOW)Installing SP1...$(NC)"
	@if ! command -v cargo-prove >/dev/null 2>&1; then \
		curl -L https://sp1.succinct.xyz | bash && ~/.sp1/bin/sp1up; \
	fi
	@echo "$(GREEN)✓ SP1 installed$(NC)"

setup-submodules:
	@echo "$(YELLOW)Setting up submodules...$(NC)"
	@if [ -d "contracts" ]; then \
		cd contracts && git submodule update --init --recursive; \
	else \
		git submodule update --init --recursive; \
	fi
	@echo "$(GREEN)✓ Submodules initialized$(NC)"

install-dependencies:
	@echo "$(YELLOW)Fetching dependencies...$(NC)"
	@cargo fetch
	@echo "$(GREEN)✓ Dependencies fetched$(NC)"

check-tools:
	@echo "$(YELLOW)Checking required tools...$(NC)"
	@command -v rustup >/dev/null 2>&1 || { echo "$(RED)Error: rustup not found. Install Rust first$(NC)"; exit 1; }
	@command -v taplo >/dev/null 2>&1 || { echo "$(RED)Error: taplo not found. Run 'make install-taplo'$(NC)"; exit 1; }
	@echo "$(GREEN)✓ All tools available$(NC)"

check-sp1:
	@echo "$(YELLOW)Checking SP1 installation...$(NC)"
	@command -v cargo-prove >/dev/null 2>&1 || { echo "$(RED)Error: cargo-prove not found. Run 'make install-sp1'$(NC)"; exit 1; }
	@echo "$(GREEN)✓ SP1 tools available$(NC)"

fmt: check-tools
	@echo "$(YELLOW)Formatting code...$(NC)"
	@find lib -name "*.rs" -exec rustup run $(RUST_TOOLCHAIN) rustfmt {} --edition $(RUST_EDITION) \; 2>/dev/null || true
	@taplo fmt
	@echo "$(GREEN)✓ Code formatted$(NC)"

lint: check-tools
	@echo "$(YELLOW)Checking code formatting...$(NC)"
	@find lib -name "*.rs" -exec rustup run $(RUST_TOOLCHAIN) rustfmt --check {} --edition $(RUST_EDITION) \; 2>/dev/null || { echo "$(RED)Code formatting check failed$(NC)"; exit 1; }
	@taplo fmt --check || { echo "$(RED)TOML formatting check failed$(NC)"; exit 1; }
	@echo "$(GREEN)✓ Code formatting OK$(NC)"

clippy: check-tools
	@echo "$(YELLOW)Running Clippy...$(NC)"
	@cargo clippy --all-targets --all-features --locked --workspace --quiet -- -D warnings
	@echo "$(GREEN)✓ Clippy checks passed$(NC)"

test-rust:
	@echo "$(YELLOW)Running Rust tests...$(NC)"
	@cargo test --workspace
	@echo "$(GREEN)✓ Rust tests passed$(NC)"

test: test-move test-rust
	@echo "$(GREEN)✓ All tests passed$(NC)"

clean-rust:
	@echo "$(YELLOW)Cleaning Rust build artifacts...$(NC)"
	@cargo clean
	@rm -rf $(TARGET_DIR)/
	@echo "$(GREEN)✓ Rust clean complete$(NC)"

clean: clean-move clean-rust
	@echo "$(GREEN)✓ All clean tasks complete$(NC)"

setup: setup-submodules install-dependencies install-taplo
	@echo "$(GREEN)✓ Setup complete$(NC)"

check: check-tools lint clippy test
	@echo "$(GREEN)✓ All checks passed$(NC)"

help:
	@echo "Available targets:"
	@echo "  Node Management:"
	@echo "    start         - Start Aptos node with indexer API (requires Docker)"
	@echo "    start-simple  - Start Aptos node without indexer API"
	@echo "    restart       - Restart node with indexer API"
	@echo "    restart-simple- Restart node without indexer API"
	@echo "    kill-ports    - Kill processes using ports 8080, 9102, 5433"
	@echo ""
	@echo "  Aptos Development:"
	@echo "    deploy        - Deploy Move package"
	@echo "    version       - Get deployed contract version"
	@echo "    compile       - Compile Move package"
	@echo "    test-move     - Run Move tests"
	@echo "    clean-move    - Clean Move build artifacts"
	@echo "    init          - Initialize Aptos profile"
	@echo "    fund          - Fund account from faucet"
	@echo ""
	@echo "  Rust Development:"
	@echo "    test-rust     - Run Rust tests"
	@echo "    clean-rust    - Clean Rust build artifacts"
	@echo "    fmt           - Format code"
	@echo "    lint          - Check code formatting"
	@echo "    clippy        - Run Clippy linter"
	@echo ""
	@echo "  Combined:"
	@echo "    test          - Run both Move and Rust tests"
	@echo "    clean         - Clean both Move and Rust artifacts"
	@echo "    setup         - Complete project setup"
	@echo "    check         - Run all code quality checks"

.PHONY: start restart start-simple restart-simple kill-ports deploy version compile test-move clean-move init fund \
        install-taplo install-sp1 setup-submodules install-dependencies check-tools check-sp1 \
        fmt lint clippy test-rust clean-rust test clean setup check help