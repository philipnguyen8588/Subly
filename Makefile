APP      = build/ScreenTranslator.app
# Command Line Tools không có macro plugin (SwiftUIMacros) cho SDK 27 → build với SDK 26.5
export SDKROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
BIN      = .build/release/ScreenTranslator
# Dùng chứng chỉ self-signed ổn định nếu có (giữ quyền Screen Recording qua các lần build),
# nếu không thì ad-hoc ("-").
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"ScreenTranslator Dev"' | head -1)
ifeq ($(SIGN_IDENTITY),)
SIGN_IDENTITY = -
endif

.PHONY: build app run clean debug icon

# Sinh icon app (chỉ cần chạy lại khi đổi thiết kế icon)
icon:
	rm -rf build/AppIcon.iconset
	swift Scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

build:
	sh Scripts/fetch-sherpa.sh
	sh Scripts/build-chiaki.sh
	swift build -c release

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/ScreenTranslator
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	@[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns || true
	mkdir -p $(APP)/Contents/Frameworks
	cp Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib Vendor/sherpa-onnx/lib/libonnxruntime.dylib $(APP)/Contents/Frameworks/
	codesign --force --sign $(SIGN_IDENTITY) $(APP)/Contents/Frameworks/*.dylib
	codesign --force --sign $(SIGN_IDENTITY) --identifier com.lipnguyen.ScreenTranslator $(APP)
	@echo "Built $(APP) (signed with: $(SIGN_IDENTITY))"

run: app
	open $(APP)

# Chạy từ terminal để xem log trực tiếp
debug: app
	pkill -x ScreenTranslator || true
	$(APP)/Contents/MacOS/ScreenTranslator

clean:
	rm -rf .build build
