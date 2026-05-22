SHELL := $(shell command -v bash)
.ONESHELL:

# Local dev Makefile for scan-mcp only

.PHONY: install
install:
	npm install --no-audit --no-fund

.PHONY: typecheck
typecheck:
	npm run typecheck

.PHONY: lint
lint:
	npm run lint

.PHONY: lint-fix
lint-fix:
	npm run lint:fix

.PHONY: build
build:
	npm run build

.PHONY: pack-check
pack-check:
	npm run pack:check

.PHONY: test
test:
	npm test -- --run

.PHONY: test-swift
test-swift:
	@if [ "$$(uname)" = "Darwin" ]; then \
		npm run test:swift; \
	else \
		echo "skipping swift tests (non-darwin host)"; \
	fi

.PHONY: verify
verify:
	$(MAKE) install
	$(MAKE) typecheck
	$(MAKE) lint
	$(MAKE) build
	$(MAKE) pack-check
	$(MAKE) test
	$(MAKE) test-swift
