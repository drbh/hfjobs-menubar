.PHONY: all build sign run clean

all: build sign

build:
	@mkdir -p HFJobs.app/Contents/MacOS
	@swiftc -o HFJobs.app/Contents/MacOS/HFJobs -parse-as-library src/HFJobs.swift src/main.swift
	@chmod +x HFJobs.app/Contents/MacOS/HFJobs
	@cp src/Info.plist HFJobs.app/Contents/
	@echo "✅ Built HFJobs.app"

sign:
	@codesign --force --entitlements src/HFJobs.entitlements --sign "-" HFJobs.app
	@echo "🔑 Signed HFJobs.app"
	@echo "🚀 Run the app with 'open HFJobs.app'"

run: build sign
	open HFJobs.app

clean:
	rm -rf HFJobs.app