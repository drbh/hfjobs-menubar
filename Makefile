.PHONY: all build build-universal build-intel build-arm asset-catalog sign run clean

# Default target that builds for current architecture
all: build asset-catalog sign

# Define architectures
ARCH_INTEL = x86_64
ARCH_ARM = arm64

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
		src/MetricsObservable.swift \
		src/LogsObservable.swift \
		src/LogsViewComponents.swift \
		src/MetricsViewComponents.swift \
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
		src/MetricsObservable.swift \
		src/LogsObservable.swift \
		src/LogsViewComponents.swift \
		src/MetricsViewComponents.swift \
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
		src/MetricsObservable.swift \
		src/LogsObservable.swift \
		src/LogsViewComponents.swift \
		src/MetricsViewComponents.swift \
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
	@echo "🔑 Signing application..."
	@codesign --force --entitlements src/HFJobs.entitlements --sign "-" HFJobs.app
	@echo "🔑 Signed HFJobs.app"
	@echo "🚀 Run the app with 'open HFJobs.app'"

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