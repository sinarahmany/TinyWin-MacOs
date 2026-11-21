.PHONY: all build app test clean

BUILD_DIR := .build/release
APP_BUNDLE := dist/TinyWin.app

all: app

test:
	swift test

build:
	swift build -c release

app: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BUILD_DIR)/TinyWinApp" "$(APP_BUNDLE)/Contents/MacOS/TinyWin"
	@cp "$(BUILD_DIR)/tinywin" "$(APP_BUNDLE)/Contents/MacOS/tinywin-cli"
	@chmod +x "$(APP_BUNDLE)/Contents/MacOS/TinyWin" "$(APP_BUNDLE)/Contents/MacOS/tinywin-cli"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'  <key>CFBundleDevelopmentRegion</key><string>en</string>' \
		'  <key>CFBundleExecutable</key><string>TinyWin</string>' \
		'  <key>CFBundleIdentifier</key><string>dev.tinywin.manager</string>' \
		'  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>' \
		'  <key>CFBundleName</key><string>TinyWin</string>' \
		'  <key>CFBundleDisplayName</key><string>TinyWin</string>' \
		'  <key>CFBundlePackageType</key><string>APPL</string>' \
		'  <key>CFBundleShortVersionString</key><string>1.0.0</string>' \
		'  <key>CFBundleVersion</key><string>1</string>' \
		'  <key>LSMinimumSystemVersion</key><string>14.0</string>' \
		'  <key>NSHighResolutionCapable</key><true/>' \
		'</dict>' \
		'</plist>' > "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign --force --deep --sign - "$(APP_BUNDLE)" >/dev/null 2>&1 || true
	@echo "Built native macOS app: $(APP_BUNDLE) ($$(du -sh "$(APP_BUNDLE)" | cut -f1))"

clean:
	swift package clean
	rm -rf dist
