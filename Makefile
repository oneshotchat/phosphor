# Swift Testing ships outside the default search paths when only the Command Line Tools
# are installed; these flags are harmless with full Xcode.
TESTING_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TEST_FLAGS := --disable-xctest -Xswiftc -F -Xswiftc $(TESTING_FRAMEWORKS) -Xlinker -rpath -Xlinker $(TESTING_FRAMEWORKS)

.PHONY: build run test clean

build:
	swift build

run:
	swift run Phosphor

test:
	swift test $(TEST_FLAGS)

clean:
	swift package clean
