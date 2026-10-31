# FileTree: build the app bundle, run the tests, install.
#   make            build build.noindex/FileTree.app (release)
#   make run        build and open the app
#   make test       run the unit tests
#   make install    copy the app to /Applications (INSTALL_DIR=~/Applications to change)
#   make release    universal app (Apple silicon + Intel) packed into dist/ as a .dmg and a .pkg
#   make icon       redraw Resources/AppIcon.icns
#   make clean

SWIFT         ?= swift
CONFIG        ?= release
# Spotlight skips folders named *.noindex, so Spotlight and the Apps view show only the installed copy.
APP           := build.noindex/FileTree.app
INSTALL_DIR   ?= /Applications
VERSION       := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
BUNDLE_ID     := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)
TRIPLES       := arm64-apple-macosx14.0 x86_64-apple-macosx14.0
RELEASE_APP   := build.noindex/universal/FileTree.app
# The installation packages are kept in the repository, so they can be downloaded from GitHub.
DIST          := dist
RELEASE_DMG   := $(DIST)/FileTree-$(VERSION).dmg
RELEASE_PKG   := $(DIST)/FileTree-$(VERSION).pkg
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

# `strip -S` drops the debug symbols, which hold absolute paths of the build folder on this Mac.
app:
	$(SWIFT) build -c $(CONFIG) --product FileTree
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/FileTree" "$(APP)/Contents/MacOS/FileTree"
	strip -S "$(APP)/Contents/MacOS/FileTree"
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

# A universal build of the same bundle as `app`, packed as a disk image (drag the app to /Applications)
# and as an installer. The installer is not relocatable: otherwise it may update a copy found elsewhere.
# pkgbuild's archive names the build user as the owner of its parts, so it is repacked without owners.
release:
	for triple in $(TRIPLES); do $(SWIFT) build -c release --product FileTree --triple $$triple || exit 1; done
	rm -rf "$(RELEASE_APP)" build.noindex/dmg build.noindex/pkgroot
	mkdir -p "$(RELEASE_APP)/Contents/MacOS" "$(RELEASE_APP)/Contents/Resources"
	lipo -create -output "$(RELEASE_APP)/Contents/MacOS/FileTree" \
		$(foreach triple,$(TRIPLES),"$$($(SWIFT) build -c release --triple $(triple) --show-bin-path)/FileTree")
	strip -S "$(RELEASE_APP)/Contents/MacOS/FileTree"
	cp Resources/Info.plist "$(RELEASE_APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(RELEASE_APP)/Contents/Resources/AppIcon.icns"
	printf 'APPL????' > "$(RELEASE_APP)/Contents/PkgInfo"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(RELEASE_APP)"
	mkdir -p "$(DIST)" build.noindex/dmg build.noindex/pkgroot
	rm -f "$(RELEASE_DMG)" "$(RELEASE_PKG)"
	ditto --norsrc --noextattr "$(RELEASE_APP)" build.noindex/dmg/FileTree.app
	ln -s /Applications build.noindex/dmg/Applications
	hdiutil create -quiet -volname FileTree -srcfolder build.noindex/dmg -format UDZO "$(RELEASE_DMG)"
	ditto --norsrc --noextattr "$(RELEASE_APP)" build.noindex/pkgroot/FileTree.app
	pkgbuild --quiet --analyze --root build.noindex/pkgroot build.noindex/component.plist
	plutil -replace 0.BundleIsRelocatable -bool NO build.noindex/component.plist
	pkgbuild --quiet --root build.noindex/pkgroot --component-plist build.noindex/component.plist \
		--install-location /Applications --identifier "$(BUNDLE_ID)" --version "$(VERSION)" build.noindex/component.pkg
	rm -rf build.noindex/pkgparts && mkdir build.noindex/pkgparts
	xar -x -f build.noindex/component.pkg -C build.noindex/pkgparts
	cd build.noindex/pkgparts && xar -c -f "$(CURDIR)/$(RELEASE_PKG)" --no-compress '^Payload$$' \
		--prop-exclude=user --prop-exclude=group --prop-exclude=uid --prop-exclude=gid Bom Payload PackageInfo
	shasum -a 256 "$(RELEASE_DMG)" "$(RELEASE_PKG)"

icon:
	$(SWIFT) Scripts/make_icon.swift Resources/AppIcon.icns

clean:
	rm -rf .build build.noindex
