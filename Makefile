BIN := bin/so-aws-lab
GOBIN ?= $(shell go env GOBIN)
ifeq ($(strip $(GOBIN)),)
GOBIN := $(HOME)/.local/bin
endif

.PHONY: help build install run test fmt tidy third-party clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN{FS=":.*##"} {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Compile the so-aws-lab binary to bin/so-aws-lab
	go build -o $(BIN) ./cmd/so-aws-lab

install: ## Install so-aws-lab into GOBIN (default: ~/.local/bin)
	mkdir -p $(GOBIN)
	GOBIN=$(GOBIN) go install ./cmd/so-aws-lab

run: build ## Rebuild, then launch the TUI
	./$(BIN)

test: ## Run the test suite
	go test ./...

fmt: ## gofmt the tree
	go fmt ./...

tidy: ## go mod tidy
	go mod tidy

third-party: ## Regenerate THIRD_PARTY_NOTICES.md from linked dependencies
	sh scripts/gen-third-party.sh

clean: ## Remove the built binary
	rm -f $(BIN)

.DEFAULT_GOAL := help
