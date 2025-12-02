.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

SCRIPT := n8n-git.sh
INSTALL_SCRIPT := install.sh
INSTALL_NAME ?= n8n-git
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
SHAREDIR ?= $(PREFIX)/share/n8n-git
LIB_DEST := $(SHAREDIR)/lib
DIST_DIR ?= dist
DIST_STAGE := $(DIST_DIR)/$(INSTALL_NAME)

.PHONY: help install lint syntax shellcheck regression push-test pull-test reset-test test package clean-package clean distclean

help:
	@echo "Available targets:"
	@echo "  make install           # Install $(SCRIPT) into $(BINDIR) (override with PREFIX=…)"
	@echo "                         # Libraries copied to $(LIB_DEST) (override with SHAREDIR=…)"
	@echo "  make lint              # Run shell syntax validation and ShellCheck"
	@echo "  make test              # Run the full regression suite (push and pull flows)"
	@echo "  make package           # Stage scripts and docs under $(DIST_STAGE) for release packaging"
	@echo "  make distclean         # Remove dist/ staging artifacts"

install: $(SCRIPT)
	@chmod +x $(SCRIPT)
	@echo "Installing $(SCRIPT) to $(BINDIR)/$(INSTALL_NAME)"
	@if install -d "$(BINDIR)"; then \
		if install -m 755 "$(SCRIPT)" "$(BINDIR)/$(INSTALL_NAME)"; then \
			echo "Installed $(INSTALL_NAME) successfully"; \
		else \
			echo "Failed to write $(BINDIR)/$(INSTALL_NAME). Try 'sudo make install' or set PREFIX=\$$HOME/.local"; \
			exit 1; \
		fi; \
	else \
		echo "Failed to create $(BINDIR). Try 'sudo make install' or set PREFIX=\$$HOME/.local"; \
		exit 1; \
	fi
	@echo "Syncing libraries to $(LIB_DEST)"
	@if install -d "$(SHAREDIR)"; then \
		rm -rf "$(LIB_DEST)"; \
		if mkdir -p "$(LIB_DEST)" && cp -R lib/. "$(LIB_DEST)/"; then \
			echo "Libraries installed to $(LIB_DEST)"; \
		else \
			echo "Failed to copy libraries into $(LIB_DEST). Verify permissions or SHAREDIR override."; \
			exit 1; \
		fi; \
	else \
		echo "Failed to create $(SHAREDIR). Try 'sudo make install' or adjust SHAREDIR."; \
		exit 1; \
	fi

syntax:
	@tests/test-syntax.sh

shellcheck:
	@tests/test-shellcheck.sh

lint: syntax shellcheck

push-test:
	@tests/test-push.sh

pull-test:
	@tests/test-pull.sh

reset-test:
	@tests/test-reset.sh

regression: syntax shellcheck push-test pull-test reset-test

test: regression

package: clean-package
	@echo "Staging release assets under $(DIST_STAGE)"
	@mkdir -p "$(DIST_STAGE)"
	@cp "$(SCRIPT)" "$(DIST_STAGE)/$(INSTALL_NAME).sh"
	@cp "$(INSTALL_SCRIPT)" "$(DIST_STAGE)/install.sh"
	@cp readme.md "$(DIST_STAGE)/README.md"
	@mkdir -p "$(DIST_STAGE)/lib"
	@cp -R lib/. "$(DIST_STAGE)/lib/"
	@chmod +x "$(DIST_STAGE)/$(INSTALL_NAME).sh"

clean-package:
	@rm -rf "$(DIST_STAGE)"

clean: clean-package

distclean:
	@rm -rf "$(DIST_DIR)"
