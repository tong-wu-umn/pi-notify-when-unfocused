# PiMenuBar — build, test, install.
#
# Command Line Tools are enough: no Xcode project, no XCTest (see `make test`).

SHELL := /bin/bash
CONFIG ?= release
APP_NAME := PiMenuBar
BUNDLE_ID := dev.tongwu.PiMenuBar
VERSION := 0.1.0

BUILD_DIR := .build/$(CONFIG)
APP_BUNDLE := .build/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
EXTENSION_SRC := extension
PI_EXTENSION_DIR := $(HOME)/.pi/agent/extensions/pi-menubar
LAUNCH_AGENT := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
GUI_DOMAIN := gui/$(shell id -u)

.DEFAULT_GOAL := help
.PHONY: help build test probe run app icon install install-app install-extension install-agent uninstall clean dist

help:
	@echo "PiMenuBar $(VERSION)"
	@echo ""
	@echo "  make build              compile (swift build -c $(CONFIG))"
	@echo "  make test               run both suites (Swift core + extension; no XCTest)"
	@echo "  make probe              print what the menu bar would show right now"
	@echo "  make probe-json         same, as JSON (good for scripts)"
	@echo "  make app                assemble .build/PiMenuBar.app"
	@echo "  make icon               regenerate Resources/PiMenuBar.icns"
	@echo "  make run                build the bundle and launch it"
	@echo "  make install            app + extension + LaunchAgent (login item)"
	@echo "  make install-extension  only the pi extension (symlink, for development)"
	@echo "  make uninstall          remove app, extension and LaunchAgent"
	@echo "  make dist               zip the app + extension with a sha256"
	@echo ""

# Only the app product: the test target uses `@testable import`, which SwiftPM enables
# for debug builds only, so it is intentionally not part of a release build.
build:
	swift build -c $(CONFIG) --product $(APP_NAME)

test:
	swift run PiMenuBarTests
	node --test extension/

probe:
	swift run PiMenuBar --probe

probe-json:
	swift run PiMenuBar --probe --json

app: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/PiMenuBar.icns "$(APP_BUNDLE)/Contents/Resources/PiMenuBar.icns"
	@sed -e 's/<string>0\.1\.0<\/string>/<string>$(VERSION)<\/string>/' Resources/Info.plist > "$(APP_BUNDLE)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP_BUNDLE)/Contents/PkgInfo"
	@codesign --force --sign - "$(APP_BUNDLE)" 2>/dev/null || echo "note: ad-hoc codesign skipped"
	@echo "built $(APP_BUNDLE)"

# Only needed when the mark changes: the generated .icns is committed.
icon:
	@swift dev/make-icon.swift Resources/PiMenuBar.icns

run: app
	@open "$(APP_BUNDLE)"
	@echo "launched. Look for π in the menu bar; 'make uninstall' removes it."

install-app: app
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALLED_APP)"
	@cp -R "$(APP_BUNDLE)" "$(INSTALLED_APP)"
	@echo "installed $(INSTALLED_APP)"

# Symlinked on purpose: editing menubar/extension/*.ts takes effect on pi /reload.
install-extension:
	@mkdir -p "$(dir $(PI_EXTENSION_DIR))"
	@rm -rf "$(PI_EXTENSION_DIR)"
	@ln -s "$(CURDIR)/$(EXTENSION_SRC)" "$(PI_EXTENSION_DIR)"
	@echo "linked $(PI_EXTENSION_DIR) -> $(CURDIR)/$(EXTENSION_SRC)"
	@echo "run /reload in each pi session to load it"

install-agent: install-app
	@mkdir -p "$(dir $(LAUNCH_AGENT))"
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>Label</key><string>$(BUNDLE_ID)</string>' \
	  '  <key>ProgramArguments</key><array>' \
	  '    <string>$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)</string>' \
	  '  </array>' \
	  '  <key>RunAtLoad</key><true/>' \
	  '  <key>KeepAlive</key><false/>' \
	  '  <key>ProcessType</key><string>Interactive</string>' \
	  '</dict></plist>' > "$(LAUNCH_AGENT)"
	@chmod 600 "$(LAUNCH_AGENT)"
	@launchctl bootout $(GUI_DOMAIN) "$(LAUNCH_AGENT)" 2>/dev/null || true
	@launchctl bootstrap $(GUI_DOMAIN) "$(LAUNCH_AGENT)"
	@echo "launch agent installed: $(LAUNCH_AGENT)"

install: install-app install-extension install-agent
	@echo ""
	@echo "PiMenuBar installed. Notes:"
	@echo "  • the app is a login item now; quit it from its menu to stop it"
	@echo "  • pi sessions must /reload once to publish registry data"
	@echo ""
	@echo "Native notifications are off until you opt in (they would double up with"
	@echo "the notify-when-unfocused extension otherwise):"
	@echo "  1. set \"notifications\": { \"enabled\": true } in ~/.pi/agent/menubar.json"
	@echo "  2. disable the root extension (\"enabled\": false in"
	@echo "     ~/.pi/agent/notify-when-unfocused.json, then /reload)"
	@echo "  3. menu bar → Send test notification"

uninstall:
	@-launchctl bootout $(GUI_DOMAIN) "$(LAUNCH_AGENT)" 2>/dev/null
	@rm -f "$(LAUNCH_AGENT)"
	@rm -rf "$(INSTALLED_APP)"
	@rm -rf "$(PI_EXTENSION_DIR)"
	@echo "removed app, extension and launch agent"
	@echo "(registry files and ~/.pi/agent/menubar.json are left in place)"

clean:
	@rm -rf .build
	@echo "cleaned"

dist: app
	@rm -rf .build/dist && mkdir -p .build/dist
	@cp -R "$(APP_BUNDLE)" .build/dist/
	@cp -R "$(EXTENSION_SRC)" .build/dist/extension
	@cp README.md .build/dist/README.md 2>/dev/null || true
	@cd .build/dist && zip -qry "../$(APP_NAME)-$(VERSION).zip" . && cd - >/dev/null
	@shasum -a 256 ".build/$(APP_NAME)-$(VERSION).zip" | tee ".build/$(APP_NAME)-$(VERSION).zip.sha256"
	@echo "dist: .build/$(APP_NAME)-$(VERSION).zip"
