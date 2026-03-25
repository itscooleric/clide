# Makefile — clide compose + deploy helpers
#
# Common targets:
#   make web          start web terminal (local dev)
#   make cli          interactive shell
#   make deploy       build + start with override (production)
#   make logs         tail logs

# ── Compose file sets ──────────────────────────────────────────────────────

DC      := docker compose -f docker-compose.yml
DC_FULL := docker compose -f docker-compose.yml -f docker-compose.override.yml

# Derive version: branch@shorthash (YYYY-MM-DD)
BUILD_VERSION := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "dev")@$(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown") ($(shell date -u +%Y-%m-%d))
export BUILD_VERSION

# ── Help ───────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help

# ── Build ──────────────────────────────────────────────────────────────────

.PHONY: build build-override rebuild

build: ## Build image (base compose)
	BUILD_VERSION="$(BUILD_VERSION)" $(DC) build

build-override: ## Build with override (production)
	BUILD_VERSION="$(BUILD_VERSION)" $(DC_FULL) build

rebuild: ## Rebuild image (no cache)
	BUILD_VERSION="$(BUILD_VERSION)" $(DC) build --no-cache

# ── Up / down ──────────────────────────────────────────────────────────────

.PHONY: up up-override deploy down restart

up: ## Start web terminal
	$(DC) up -d web

up-override: ## Start with override (production)
	$(DC_FULL) up -d web

deploy: ## Build + start with override (most common)
	BUILD_VERSION="$(BUILD_VERSION)" $(DC_FULL) up -d --build web

down: ## Stop services
	$(DC_FULL) down 2>/dev/null || $(DC) down

restart: ## Restart web terminal
	$(DC) restart web

# ── Clide-specific ─────────────────────────────────────────────────────────

.PHONY: web cli

web: up ## Start web terminal at http://localhost:7681
	@echo ""
	@echo "  Web terminal running at http://localhost:7681"
	@echo "  Stop with: make down"
	@echo ""

cli: ## Open interactive shell (all CLIs available)
	$(DC) run --rm cli

# ── Logs / status ──────────────────────────────────────────────────────────

.PHONY: logs health shell ps

logs: ## Tail logs (all services)
	$(DC) logs -f --tail=50

health: ## Health check
	@curl -sf http://localhost:$${TTYD_PORT:-7681}/ > /dev/null && echo "healthy" || echo "unhealthy"

shell: ## Shell into web container
	docker exec -it $$(docker compose ps -q web) bash

ps: ## Show running containers
	docker compose ps
