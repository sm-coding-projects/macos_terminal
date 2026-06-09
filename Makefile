# SecureSSH Terminal — build/test/run entry points.
#
# The test target passes explicit framework search paths because the Swift
# Testing framework ships with the Command Line Tools at a non-default
# location (no full Xcode required). With full Xcode installed, plain
# `swift test` works too.

TESTING_FWK := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TESTING_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS  := -Xswiftc -F -Xswiftc $(TESTING_FWK) \
               -Xlinker -F$(TESTING_FWK) \
               -Xlinker -rpath -Xlinker $(TESTING_FWK) \
               -Xlinker -rpath -Xlinker $(TESTING_LIB)

.PHONY: build release test run app dmg clean

build:
	swift build

release:
	swift build -c release

test:
	@if [ -d "$(TESTING_FWK)" ]; then \
		swift test $(TEST_FLAGS); \
	else \
		swift test; \
	fi

run: build
	swift run SecureSSHTerminal

# Wraps the release binary into SecureSSH Terminal.app (unsigned).
# See RELEASE_CHECKLIST.md for signing, sandbox and notarization.
app: release
	./Scripts/make-app.sh

# Universal (arm64 + x86_64) tester DMG, ad-hoc signed by default.
# Set SIGN_IDENTITY="Developer ID Application: ..." for a real signature.
dmg:
	./Scripts/make-dmg.sh

clean:
	swift package clean
	rm -rf build
