PROFILE := default
NETWORK := local
PACKAGE_DIR := .
MODULE_NAME := hashlock

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

test:
	aptos move test --package-dir $(PACKAGE_DIR)

clean:
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
	@command -v rustup >/dev/null 2>&1 || { echo "$(RED)Error: rustup not found. Run 'make install-rust'$(NC)"; exit 1; }
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

test:
	@echo "$(YELLOW)Running tests...$(NC)"
	@cargo test --workspace
	@echo "$(GREEN)✓ Tests passed$(NC)"

clean:
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	@cargo clean
	@rm -rf $(TARGET_DIR)/
	@echo "$(GREEN)✓ Clean complete$(NC)"

.PHONY: start restart start-simple restart-simple kill-ports deploy version compile test clean init fund