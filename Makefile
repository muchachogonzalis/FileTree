# FileTree: build the app bundle, run the tests, install.
#   make            build build.noindex/FileTree.app (release)
#   make run        build and open the app
#   make test       run the unit tests
#   make install    copy the app to /Applications (INSTALL_DIR=~/Applications to change)
#   make release    universal app (Apple silicon + Intel) zipped in build.noindex/ for a GitHub release
#   make icon       redraw Resources/AppIcon.icns
#   make clean

SWIFT         ?= swift
CONFIG        ?= release
# Spotlight skips folders named *.noindex, so Spotlight and the Apps view show only the installed copy.
APP           := build.noindex/FileTree.app
INSTALL_DIR   ?= /Applications
VERSION       := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
TRIPLES       := arm64-apple-macosx14.0 x86_64-apple-macosx14.0
RELEASE_APP   := build.noindex/universal/FileTree.app
RELEASE_ZIP   := build.noindex/FileTree-$(VERSION).zip
# "-" signs ad hoc. Set to a "Developer ID Application: …" or "Apple Development: …" identity
# so that macOS keeps privacy permissions (Full Disk Access) across rebuilds.
SIGN_IDENTITY ?= -

# Command Line Tools keep the Swift Testing framework outside the default search paths.
DEVELOPER_DIR := $(shell xcode-select -p 2>/dev/null)
ifneq (,$(findstring CommandLineTools,$(DEVELOPER_DIR)))
FRAMEWORKS := $(DEVELOPER_DIR)/Library/Developer/Frameworks
TEST_FLAGS := -Xswiftc -F -Xswiftc $(FRAMEWORKS) -Xlinker -F -Xlinker $(FRAMEWORKS) \
              -Xlinker -rpath -Xlinker $(FRAMEWORKS) -Xlinker -rpath -Xlinker $(DEVELOPER_DIR)/Library/Developer/usr/lib
endif

.PHONY: all app run test install release icon clean

all: app

app:
	$(SWIFT) build -c $(CONFIG) --product FileTree
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/FileTree" "$(APP)/Contents/MacOS/FileTree"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"
	@echo "Built $(APP)"

run: app
	open "$(APP)"

test:
	$(SWIFT) test $(TEST_FLAGS)

install: app
	rm -rf "$(INSTALL_DIR)/FileTree.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/FileTree.app"
	@echo "Installed $(INSTALL_DIR)/FileTree.app"

# A universal build of the same bundle as `app`, zipped for a GitHub release.
release:
	for triple in $(TRIPLES); do $(SWIFT) build -c release --product FileTree --triple $$triple || exit 1; done
	rm -rf "$(RELEASE_APP)" "$(RELEASE_ZIP)"
	mkdir -p "$(RELEASE_APP)/Contents/MacOS" "$(RELEASE_APP)/Contents/Resources"
	lipo -create -output "$(RELEASE_APP)/Contents/MacOS/FileTree" \
		$(foreach triple,$(TRIPLES),"$$($(SWIFT) build -c release --triple $(triple) --show-bin-path)/FileTree")
	cp Resources/Info.plist "$(RELEASE_APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(RELEASE_APP)/Contents/Resources/AppIcon.icns"
	printf 'APPL????' > "$(RELEASE_APP)/Contents/PkgInfo"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(RELEASE_APP)"
	ditto -c -k --norsrc --noextattr --keepParent "$(RELEASE_APP)" "$(RELEASE_ZIP)"
	shasum -a 256 "$(RELEASE_ZIP)"

icon:
	$(SWIFT) Scripts/make_icon.swift Resources/AppIcon.icns

clean:
	rm -rf .build build.noindex
