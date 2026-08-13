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

clean:
	rm -rf build dist
