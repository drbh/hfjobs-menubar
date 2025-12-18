.PHONY: all build build-universal build-intel build-arm asset-catalog sign run dev clean store-credentials notarize staple package

# Default target that builds for current architecture
all: build asset-catalog sign

# Application configuration
APP_NAME         := HFJobs
BUNDLE_ID        := drbh.hfjobsmenubar

# Use environment variables for sensitive data
TEAM_ID          := $(TEAM_ID)
SIGN_IDENTITY    := $(SIGN_IDENTITY)
APPLE_ID         := $(APPLE_ID)
NOTARY_PASSWORD  := $(NOTARY_PASSWORD)
NOTARY_PROFILE   := $(NOTARY_PROFILE)

# Define architectures
ARCH_INTEL       := x86_64
ARCH_ARM         := arm64
ARCH             := $(shell uname -m)

# Target-specific variables
build-intel: ARCH = $(ARCH_INTEL)
build-arm: ARCH = $(ARCH_ARM)
build: ARCH = $(shell uname -m)

# Standard build (uses current architecture)
build:
	@echo "🔨 Building for architecture: $(ARCH)"
	@mkdir -p HFJobs.app/Contents/MacOS
	@mkdir -p HFJobs.app/Contents/Resources
	@swiftc -target $(ARCH)-apple-macosx14.0 -o HFJobs.app/Contents/MacOS/HFJobs -parse-as-library \
		src/Models.swift \
		src/JobService.swift \
		src/LogsStreamService.swift \
		src/MetricsService.swift \
		src/JobEventsService.swift \
		src/MetricsObservable.swift \
		src/LogsObservable.swift \
		src/LogsViewComponents.swift \
		src/MetricsViewComponents.swift \
		src/JobEventsViewComponents.swift \
		src/NotificationService.swift \
		src/JobDetailView.swift \
		src/HFJobs.swift \
		src/main.swift
	@chmod +x HFJobs.app/Contents/MacOS/HFJobs
	@cp src/Info.plist HFJobs.app/Contents/
	@echo "✅ Built HFJobs.app for $(ARCH)"

# Build for Intel architecture
build-intel:
	@mkdir -p build/$(ARCH_INTEL)/HFJobs.app/Contents/MacOS
	@mkdir -p build/$(ARCH_INTEL)/HFJobs.app/Contents/Resources
	@swiftc -target $(ARCH_INTEL)-apple-macosx14.0 -o build/$(ARCH_INTEL)/HFJobs.app/Contents/MacOS/HFJobs -parse-as-library \
		src/Models.swift \
		src/JobService.swift \
		src/LogsStreamService.swift \
		src/MetricsService.swift \
		src/JobEventsService.swift \
		src/MetricsObservable.swift \
		src/LogsObservable.swift \
		src/LogsViewComponents.swift \
		src/MetricsViewComponents.swift \
		src/JobEventsViewComponents.swift \
		src/NotificationService.swift \
		src/JobDetailView.swift \
		src/HFJobs.swift \
		src/main.swift
	@chmod +x build/$(ARCH_INTEL)/HFJobs.app/Contents/MacOS/HFJobs
	@cp src/Info.plist build/$(ARCH_INTEL)/HFJobs.app/Contents/
	@echo "✅ Built HFJobs.app for Intel ($(ARCH_INTEL))"

# Build for ARM architecture
build-arm:
	@mkdir -p build/$(ARCH_ARM)/HFJobs.app/Contents/MacOS
	@mkdir -p build/$(ARCH_ARM)/HFJobs.app/Contents/Resources
	@swiftc -target $(ARCH_ARM)-apple-macosx14.0 -o build/$(ARCH_ARM)/HFJobs.app/Contents/MacOS/HFJobs -parse-as-library \
		src/Models.swift \
		src/JobService.swift \
		src/LogsStreamService.swift \
		src/MetricsService.swift \
		src/JobEventsService.swift \
		src/MetricsObservable.swift \
		src/LogsObservable.swift \
		src/LogsViewComponents.swift \
		src/MetricsViewComponents.swift \
		src/JobEventsViewComponents.swift \
		src/NotificationService.swift \
		src/JobDetailView.swift \
		src/HFJobs.swift \
		src/main.swift
	@chmod +x build/$(ARCH_ARM)/HFJobs.app/Contents/MacOS/HFJobs
	@cp src/Info.plist build/$(ARCH_ARM)/HFJobs.app/Contents/
	@echo "✅ Built HFJobs.app for ARM ($(ARCH_ARM))"

# Universal build (builds for both Intel and ARM)
build-universal: build-intel build-arm
	@echo "🔄 Creating universal binary..."
	@mkdir -p HFJobs.app/Contents/MacOS
	@mkdir -p HFJobs.app/Contents/Resources
	@lipo -create \
		build/$(ARCH_INTEL)/HFJobs.app/Contents/MacOS/HFJobs \
		build/$(ARCH_ARM)/HFJobs.app/Contents/MacOS/HFJobs \
		-output HFJobs.app/Contents/MacOS/HFJobs
	@chmod +x HFJobs.app/Contents/MacOS/HFJobs
	@cp src/Info.plist HFJobs.app/Contents/
	@echo "✅ Created universal binary for HFJobs.app"

# Compile asset catalog
asset-catalog:
	@echo "🎨 Compiling asset catalog..."
	@xcrun actool --output-format human-readable-text \
		--notices --warnings \
		--platform macosx \
		--minimum-deployment-target 14.0 \
		--app-icon AppIcon \
		--compile HFJobs.app/Contents/Resources \
		--output-partial-info-plist HFJobs.app/Contents/Resources/asset-catalog-info.plist \
		src/Assets.xcassets
	@echo "🎨 Compiled asset catalog"

# Sign the application
sign:
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		echo "🔑 Signing application with Developer ID..."; \
		codesign --force \
			--options runtime \
			--timestamp \
			--entitlements src/HFJobs.entitlements \
			--sign $(SIGN_IDENTITY) \
			$(APP_NAME).app; \
		echo "🔑 Signed $(APP_NAME).app as $(SIGN_IDENTITY)"; \
	else \
		echo "ℹ️  SIGN_IDENTITY not set — skipping signing."; \
	fi


# Packaging & Notarization
package: sign
	@echo "📦 Zipping for distribution..."
	@ditto -c -k --sequesterRsrc --keepParent \
		$(APP_NAME).app $(APP_NAME).zip
	@echo "📦 Zipped to $(APP_NAME).zip"

# Store your notarization credentials once
store-credentials:
	@if [ -z "$(APPLE_ID)" ] || [ -z "$(NOTARY_PASSWORD)" ] || [ -z "$(TEAM_ID)" ] || [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "❌ Error: One or more required environment variables not set (APPLE_ID, NOTARY_PASSWORD, TEAM_ID, NOTARY_PROFILE)"; \
		exit 1; \
	fi
	@echo "🔐 Storing notarytool credentials profile '$(NOTARY_PROFILE)'…"
	@xcrun notarytool store-credentials \
	   --apple-id "$(APPLE_ID)" \
	   --password "$(NOTARY_PASSWORD)" \
	   --team-id "$(TEAM_ID)" \
	   "$(NOTARY_PROFILE)"
	@echo "✅ Credentials saved."

# Notarize with notarytool
notarize: package
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "❌ Error: NOTARY_PROFILE environment variable not set"; \
		exit 1; \
	fi
	@echo "☁️  Submitting $(APP_NAME).zip for notarization via notarytool…"
	@xcrun notarytool submit $(APP_NAME).zip \
	   --keychain-profile "$(NOTARY_PROFILE)" \
	   --wait
	@echo "☁️  Notarization complete."

staple:
	@echo "📎 Stapling notarization ticket..."
	@xcrun stapler staple $(APP_NAME).zip
	@echo "📎 Stapled. Ready to distribute."

# Quick dev build and run (no signing, no asset catalog)
dev:
	@echo "🔨 Dev build for architecture: $(ARCH)"
	@mkdir -p HFJobs.app/Contents/MacOS
	@mkdir -p HFJobs.app/Contents/Resources
	@swiftc -g -Onone -target $(ARCH)-apple-macosx14.0 -o HFJobs.app/Contents/MacOS/HFJobs -parse-as-library \
		src/Models.swift \
		src/JobService.swift \
		src/LogsStreamService.swift \
		src/MetricsService.swift \
		src/JobEventsService.swift \
		src/MetricsObservable.swift \
		src/LogsObservable.swift \
		src/LogsViewComponents.swift \
		src/MetricsViewComponents.swift \
		src/JobEventsViewComponents.swift \
		src/NotificationService.swift \
		src/JobDetailView.swift \
		src/HFJobs.swift \
		src/main.swift
	@chmod +x HFJobs.app/Contents/MacOS/HFJobs
	@cp src/Info.plist HFJobs.app/Contents/
	@echo "🚀 Running in dev mode..."
	./HFJobs.app/Contents/MacOS/HFJobs

# Build and run
run: build asset-catalog sign
	@echo "🚀 Launching application..."
	open HFJobs.app

# Run universal build
run-universal: build-universal asset-catalog sign
	@echo "🚀 Launching universal application..."
	open HFJobs.app

# Clean build artifacts
clean:
	rm -rf HFJobs.app build/
	@echo "🧹 Cleaned build artifacts"

# Create image set
create-image-set:
	@echo "🖼️ Creating image set..."
	@mkdir -p src/Assets.xcassets/AppIcon.appiconset
	@cp src/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon_original.png src/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.png
	@echo "🖼️ Created image set"
	@sips -z 16 16 src/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.png --out src/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.png
	@sips -z 32 32 src/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon_original.png --out src/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon@2x.png
	@sips -z 48 48 src/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon_original.png --out src/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon@3x.png
