FRAMEWORK_DIR := /Library/Developer/CommandLineTools/Library/Developer/Frameworks

.PHONY: test build clean

build:
	swift build

test:
	swift build --build-tests \
		-Xswiftc -F -Xswiftc $(FRAMEWORK_DIR) \
		-Xlinker -rpath -Xlinker $(FRAMEWORK_DIR)
	swift test --skip-build

clean:
	swift package clean
