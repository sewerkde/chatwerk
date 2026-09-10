APP = Chatwerk

.PHONY: generate build app dmg clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Release -derivedDataPath build build

app: build
	rm -rf dist && mkdir -p dist
	cp -R build/Build/Products/Release/$(APP).app dist/
	@echo "→ dist/$(APP).app"

dmg: app
	hdiutil create -volname $(APP) -srcfolder dist/$(APP).app -ov -format UDZO dist/$(APP).dmg
	@echo "→ dist/$(APP).dmg"

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# Build products register with LaunchServices and otherwise linger as extra
# Chatwerk entries in the Apps list and Open With menus.
clean:
	@for app in build/Build/Products/*/$(APP).app dist/$(APP).app; do \
		[ -d "$$app" ] && $(LSREGISTER) -u "$$PWD/$$app" || true; \
	done
	rm -rf build dist

notarize:
	./scripts/notarize.sh
