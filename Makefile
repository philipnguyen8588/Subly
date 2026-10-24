APP      = build/Subly.app
# Command Line Tools không có macro plugin (SwiftUIMacros) cho SDK 27 → build với SDK 26.5
export SDKROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
BIN      = .build/release/ScreenTranslator
# Dùng chứng chỉ self-signed ổn định nếu có (giữ quyền Screen Recording qua các lần build),
# nếu không thì ad-hoc ("-").
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"ScreenTranslator Dev"' | head -1)
ifeq ($(SIGN_IDENTITY),)
SIGN_IDENTITY = -
endif

# Nơi cài app (make install): mở từ Launchpad / Spotlight / thư mục Applications như app bình thường.
INSTALL_DIR ?= /Applications
INSTALLED = $(INSTALL_DIR)/Subly.app
# Các file của app Subtitle TV (windows/tizen/SubtitleTV): đóng kèm app và đóng gói lên server.
TV_FILES  = config.xml index.html main.js style.css icon.png

.PHONY: build app install run clean debug icon tv-zip

# Zip mã nguồn app Subtitle TV (chưa ký) để nạp lên server: subly-server import-tv build/SubtitleTV.zip.
# App Mac / Windows tải bản này khi bấm "Cài app lên TV" → cập nhật app TV không cần build lại app máy tính.
tv-zip:
	mkdir -p build
	rm -f build/SubtitleTV.zip
	cd windows/tizen/SubtitleTV && zip -q -X -9 ../../../build/SubtitleTV.zip $(TV_FILES)
	@unzip -l build/SubtitleTV.zip

# Sinh icon app (chỉ cần chạy lại khi đổi thiết kế icon)
icon:
	rm -rf build/AppIcon.iconset
	swift Scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

build:
	sh Scripts/fetch-sherpa.sh
	sh Scripts/build-chiaki.sh
	python3 Scripts/gen_runtime_config.py
	swift build -c release -Xswiftc -gnone

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/Subly
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	@[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns || true
	# Thuật ngữ game đóng kèm: tạo sẵn profile cho các game thông dụng ở lần chạy đầu.
	mkdir -p $(APP)/Contents/Resources/glossaries
	cp glossaries/*.json $(APP)/Contents/Resources/glossaries/
	# Hướng dẫn sử dụng (mở bằng nút Hướng dẫn trong app).
	mkdir -p $(APP)/Contents/Resources/guide
	cp Resources/guide/*.html $(APP)/Contents/Resources/guide/
	# Cài app Subtitle TV lên TV Samsung (nút "Cài app lên TV"): CA của Samsung để ghép chứng chỉ + mã nguồn app TV
	# (bản dự phòng; app tải bản mới nhất từ server, xem `make tv-zip`).
	mkdir -p $(APP)/Contents/Resources/tv/SubtitleTV $(APP)/Contents/Resources/tv/ca
	cp $(addprefix windows/tizen/SubtitleTV/,$(TV_FILES)) $(APP)/Contents/Resources/tv/SubtitleTV/
	cp windows/tizen/ca/*.cer windows/tizen/ca/*.crt $(APP)/Contents/Resources/tv/ca/
	mkdir -p $(APP)/Contents/Frameworks
	cp Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib Vendor/sherpa-onnx/lib/libonnxruntime.dylib $(APP)/Contents/Frameworks/
	# Bỏ bảng ký hiệu khỏi file chạy (khó đọc hơn khi dịch ngược). Ký là bước cuối cùng.
	strip -rSTx $(APP)/Contents/MacOS/Subly
	codesign --force --sign $(SIGN_IDENTITY) --timestamp=none $(APP)/Contents/Frameworks/*.dylib
	# Hardened runtime: chặn tiêm qua DYLD_*, chặn attach debugger. disable-library-validation để nạp dylib trong bundle.
	codesign --force --options runtime --entitlements Resources/hardened.entitlements \
		--sign $(SIGN_IDENTITY) --identifier com.lipnguyen.ScreenTranslator $(APP)
	@echo "Built $(APP) (signed with: $(SIGN_IDENTITY))"

# Build rồi cài vào /Applications. Chép sang bản tạm rồi mới thay, để không bao giờ để lại một app cài dở.
# Subly đang chạy thì KHÔNG thay: macOS chặn mạng LAN của tiến trình có bundle vừa bị thay (PS5 rớt và không kết nối
# lại được cho tới khi mở lại app). Khi đó chỉ để sẵn bản mới ở Subly.app.new; thoát app rồi chạy lại `make install`.
install: app
	rm -rf "$(INSTALL_DIR)/ScreenTranslator.app"
	rm -rf "$(INSTALLED).new"
	ditto $(APP) "$(INSTALLED).new"
	@if [ -z "$(FORCE)" ] && pgrep -x Subly >/dev/null; then \
		echo "Subly đang chạy: CHƯA cài (thay app lúc đang chạy làm PS5 mất kết nối)."; \
		echo "Bản mới để sẵn ở $(INSTALLED).new. Thoát Subly (⌘Q) rồi chạy lại: make install"; \
	else \
		rm -rf "$(INSTALLED)" && mv "$(INSTALLED).new" "$(INSTALLED)" && echo "Đã cài $(INSTALLED)"; \
	fi

run: install
	open "$(INSTALLED)"

# Chạy từ terminal để xem log trực tiếp
debug: app
	pkill -x Subly || true
	$(APP)/Contents/MacOS/Subly

clean:
	rm -rf .build build
