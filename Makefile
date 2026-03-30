FRAMEWORK_DIR := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
APP_NAME := Susurrus
APP_BUNDLE := build/$(APP_NAME).app
INSTALL_DIR := /Applications

.PHONY: test build clean perf release bundle install uninstall launch

build:
	swift build

release:
	swift build -c release

bundle: release
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp .build/release/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Info.plist $(APP_BUNDLE)/Contents/
	@if [ -f .env ]; then cp .env $(APP_BUNDLE)/Contents/Resources/; fi
	codesign --force --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

install: bundle
	@# Kill running instance if any
	-killall $(APP_NAME) 2>/dev/null || true
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -r $(APP_BUNDLE) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

launch:
	open $(INSTALL_DIR)/$(APP_NAME).app

uninstall:
	-killall $(APP_NAME) 2>/dev/null || true
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	@echo "Uninstalled $(APP_NAME)"

test:
	swift build --build-tests \
		-Xswiftc -F -Xswiftc $(FRAMEWORK_DIR) \
		-Xlinker -rpath -Xlinker $(FRAMEWORK_DIR)
	swift test --skip-build

perf:
	swift build --build-tests \
		-Xswiftc -F -Xswiftc $(FRAMEWORK_DIR) \
		-Xlinker -rpath -Xlinker $(FRAMEWORK_DIR)
	swift test --skip-build --filter TranscriptionPerfTests

clean:
	swift package clean
	rm -rf build
