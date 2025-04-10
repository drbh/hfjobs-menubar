.PHONY: all build asset-catalog sign run clean

all: build asset-catalog sign

build:
	@mkdir -p HFJobs.app/Contents/MacOS
	@mkdir -p HFJobs.app/Contents/Resources
	@swiftc -o HFJobs.app/Contents/MacOS/HFJobs -parse-as-library \
		src/Models.swift \
		src/JobService.swift \
		src/NotificationService.swift \
		src/JobDetailView.swift \
		src/HFJobs.swift \
		src/main.swift
	@chmod +x HFJobs.app/Contents/MacOS/HFJobs
	@cp src/Info.plist HFJobs.app/Contents/
	@echo "✅ Built HFJobs.app"

asset-catalog:
	@xcrun actool --output-format human-readable-text \
		--notices --warnings \
		--platform macosx \
		--minimum-deployment-target 10.15 \
		--app-icon AppIcon \
		--compile HFJobs.app/Contents/Resources \
		--output-partial-info-plist HFJobs.app/Contents/Resources/asset-catalog-info.plist \
		src/Assets.xcassets
	@echo "🎨 Compiled asset catalog"

sign:
	@codesign --force --entitlements src/HFJobs.entitlements --sign "-" HFJobs.app
	@echo "🔑 Signed HFJobs.app"
	@echo "🚀 Run the app with 'open HFJobs.app'"

run: build asset-catalog sign
	open HFJobs.app

clean:
	rm -rf HFJobs.app
