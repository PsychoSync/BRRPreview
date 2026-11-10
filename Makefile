APP_NAME := BRRPreview
APP_BUNDLE := build/$(APP_NAME).app
APP_EXECUTABLE := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
RELEASE_ZIP := build/$(APP_NAME)-macOS-universal.zip

.PHONY: app run release test clean

app:
	swift build -c release --arch arm64 --arch x86_64
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	cp ".build/apple/Products/Release/$(APP_NAME)" "$(APP_EXECUTABLE)"
	cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp Resources/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	codesign --force --sign - "$(APP_BUNDLE)"

run: app
	open "$(APP_BUNDLE)"

release: app
	rm -f "$(RELEASE_ZIP)"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(RELEASE_ZIP)"

test:
	swift test --arch x86_64

clean:
	rm -rf build .build
