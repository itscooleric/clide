.PHONY: build rebuild web web-stop cli logs status help

# Derive version: branch@shorthash (YYYY-MM-DD)
BUILD_VERSION := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "dev")@$(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown") ($(shell date -u +%Y-%m-%d))
export BUILD_VERSION

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the clide image
	BUILD_VERSION="$(BUILD_VERSION)" docker compose build

rebuild: ## Rebuild the clide image (no cache)
	BUILD_VERSION="$(BUILD_VERSION)" docker compose build --no-cache

web: ## Start web terminal at http://localhost:7681
	@docker compose up -d web
	@echo ""
	@echo "  Web terminal running at http://localhost:7681"
	@echo "  Stop with: make web-stop"
	@echo ""

web-stop: ## Stop the web terminal
	docker compose down

cli: ## Open interactive shell (all CLIs available)
	docker compose run --rm cli

logs: ## Show web terminal logs
	docker compose logs -f web

status: ## Show running containers
	docker compose ps
