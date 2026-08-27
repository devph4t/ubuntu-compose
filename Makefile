# Makefile — shortcuts for commands you run over and over.
#
# Needs GNU make + the `docker` CLI on whatever shell you run it from
# (Git Bash or WSL bash on Windows — PowerShell's `make`, if you have one,
# won't understand the inline VAR=val syntax used below).
#
# Usage:
#   make help                       list every target with a description
#   make build-tag TAG=mytag        build + run under a new image tag
#   make save TAG=mytag             save that tag to an auto-named .tar
#   make push APP_TAG=myapp:dev     push an app image to the kind registry
#
# TAG (default: 26.04) is which my_wsl_ubuntu tag a command acts on — it's
# the same TAG that flows into docker-compose.yml's IMAGE_TAG substitution.

SHELL      := /bin/bash
IMAGE      := my_wsl_ubuntu
DEFAULT_TAG:= 26.04
TAG        ?= $(DEFAULT_TAG)
IMAGE_TAG  ?= $(IMAGE):$(TAG)
TIMESTAMP  := $(shell date +%Y%m%d_%H%M%S)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this list
	@grep -E '^[a-zA-Z0-9_-]+:.*##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# ---- Container lifecycle (default tag, $(DEFAULT_TAG)) --------------------

.PHONY: build
build: ## Build the image at the default tag
	docker compose build --no-cache

.PHONY: up
up: ## Start the VM
	docker compose up -d

.PHONY: down
down: ## Stop the VM (kube-config volume persists)
	docker compose down

.PHONY: restart
restart: down up ## Stop then start the VM

.PHONY: sh
sh: ## Open a shell inside the running VM
	docker compose exec ubuntu-dev bash

# ---- Build/tag/run under a new tag -----------------------------------------
# docker-compose.yml's `image:` reads IMAGE_TAG (default 26.04), so setting
# it on the command line builds/runs a different tag without editing that
# file — same container name (my-ubuntu-vm), just backed by a different image.

.PHONY: tag
tag: ## Tag the already-built default image as $(IMAGE):$(TAG) (no rebuild)
	docker tag $(IMAGE):$(DEFAULT_TAG) $(IMAGE):$(TAG)
	@echo "Tagged $(IMAGE):$(DEFAULT_TAG) -> $(IMAGE):$(TAG)"

.PHONY: build-tag
build-tag: ## Build + run under a new tag: make build-tag TAG=mytag (default: timestamp)
	IMAGE_TAG=$(TAG) docker compose build --no-cache
	IMAGE_TAG=$(TAG) docker compose up -d
	@echo "Running $(IMAGE):$(TAG)"

.PHONY: run-tag
run-tag: ## Switch the running VM to an already-built tag: make run-tag TAG=mytag
	IMAGE_TAG=$(TAG) docker compose up -d --force-recreate
	@echo "Running $(IMAGE):$(TAG)"

# ---- Save / load ------------------------------------------------------------
# Auto-names the file so you never have to type a timestamp by hand.

.PHONY: save
save: ## Save $(IMAGE):$(TAG) to an auto-named .tar (TAG defaults to $(DEFAULT_TAG))
	docker save $(IMAGE):$(TAG) -o $(IMAGE)_$(TAG)_$(TIMESTAMP).tar
	@echo "Saved $(IMAGE)_$(TAG)_$(TIMESTAMP).tar"

.PHONY: save-gz
save-gz: ## Same as save, but gzip-compressed
	docker save $(IMAGE):$(TAG) | gzip > $(IMAGE)_$(TAG)_$(TIMESTAMP).tar.gz
	@echo "Saved $(IMAGE)_$(TAG)_$(TIMESTAMP).tar.gz"

.PHONY: save-full
save-full: ## Save any name:tag to an auto-named .tar: make save-full IMAGE_TAG=my_wsl_ubuntu:26.04-v001
	@image_tag="$(IMAGE_TAG)"; \
	image_name="$${image_tag%%:*}"; \
	tag="$${image_tag##*:}"; \
	file="$${image_name}_$${tag}_$(TIMESTAMP).tar"; \
	docker save -o "$$file" "$$image_tag"; \
	echo "Saved: $$file"

.PHONY: load
load: ## Load an image from a .tar: make load FILE=path.tar
	docker load -i $(FILE)

# ---- kind / cluster ----------------------------------------------------------

.PHONY: cluster
cluster: ## Create the kind cluster, wired to the local registry
	docker compose exec ubuntu-dev kind create cluster --config /root/config/kind-config.yaml

.PHONY: connect
connect: ## Wire kubectl + the local registry into the cluster (connect-kind + connect-registry)
	docker compose exec ubuntu-dev connect-kind
	docker compose exec ubuntu-dev connect-registry

.PHONY: prereqs
prereqs: ## Run the one-shot cluster prereqs + accelerator upgrade (fix-and-run.sh)
	docker compose exec ubuntu-dev bash /root/config/fix-and-run.sh

.PHONY: push
push: ## Tag + push an app image to the local registry: make push APP_TAG=myapp:dev
	docker compose exec ubuntu-dev kind-push $(APP_TAG)
