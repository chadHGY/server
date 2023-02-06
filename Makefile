#!make
include .env

.PHONY: test
test: # test env
	@echo ${WANDB_BASE_URL}
	@echo "RM prefix:${WANDB_PREFIX}"

.PHONY: clearn-cache
clearn-cache: # clean wandb cache & configure
	@echo "🧹 Clean cache and config ..."
	@echo "RM cache: ~/.wandb" && sudo rm -rf ~/.wandb
	@echo "RM config:~/.config/wandb" && sudo rm -rf ~/.config/wandb/

.PHONY: clearn-all
clean-all: # clean all wandb related data
	@echo "🧹 Clean All ..." 
	@echo "RM prefix:${WANDB_PREFIX}" && sudo rm -rf ${WANDB_PREFIX}
	@echo "RM config:~/.config/wandb" && sudo rm -rf ~/.config/wandb/
	@echo "RM cache: ~/.wandb" && sudo rm -rf ~/.wandb
	@echo "RM netrc: ~/.netrc" && sudo rm ~/.netrc

.PHONY: deploy
deploy: # deploy latest wandb throuh docker compose
	@echo "🚀 Create bind mount directory at ${WANDB_PREFIX}"
	@sudo mkdir -p ${WANDB_PREFIX}
	@sudo chown 999:999 ${WANDB_PREFIX}
	@docker compose -f docker/docker-compose.yml up -d

