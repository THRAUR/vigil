# SwiftPM's default build engine can drop the swift-testing macro plugin, so pass it explicitly,
# from whichever toolchain xcode-select points at (Command Line Tools or Xcode).
TESTING_PLUGINS := $(abspath $(dir $(shell xcrun --find swift))../lib/swift/host/plugins/testing)
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

.PHONY: build test app icon release install uninstall clean

build:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

app:
	./scripts/build-app.sh

# Regenerates Resources/Vigil.icns from scripts/make-icon.swift.
icon:
	swiftc -O scripts/make-icon.swift -o .build/make-icon
	rm -rf .build/Vigil.iconset && .build/make-icon .build/Vigil.iconset
	iconutil -c icns .build/Vigil.iconset -o Resources/Vigil.icns

release:
	./scripts/release.sh

install: app
	./install.sh

uninstall:
	./uninstall.sh

clean:
	rm -rf .build build.noindex
