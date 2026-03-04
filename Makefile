.PHONY: build rebuild web web-stop shell copilot gh claude help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the clide image
	docker compose build

rebuild: ## Rebuild the clide image (no cache)
	docker compose build --no-cache

web: ## Start web terminal at http://localhost:7681
	@docker compose up -d web
	@echo ""
	@echo "  Web terminal running at http://localhost:7681"
	@echo "  Stop with: make web-stop"
	@echo ""

web-stop: ## Stop the web terminal
	docker compose down

shell: ## Open interactive shell with all CLIs
	docker compose run --rm shell

copilot: ## Run GitHub Copilot CLI
	docker compose run --rm copilot

gh: ## Run GitHub CLI
	docker compose run --rm gh $(ARGS)

claude: ## Run Claude Code CLI
	CLAUDE_CODE_SIMPLE=1 docker compose run --rm claude

logs: ## Show web terminal logs
	docker compose logs -f web

status: ## Show running containers
	docker compose ps
