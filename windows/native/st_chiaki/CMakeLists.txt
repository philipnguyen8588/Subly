# st_chiaki.dll: cầu nối libchiaki (PS5 Remote Play, AGPL-3.0) + giải mã H.264 (FFmpeg) cho app C#.
# Dựng trong MSYS2 MINGW64 bằng windows/Scripts/build-chiaki.sh (script tự clone chiaki-ng và dựng FFmpeg tối giản).
cmake_minimum_required(VERSION 3.16)
project(st_chiaki C CXX)

set(CHIAKI_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../../Vendor/chiaki-ng" CACHE PATH "Thư mục mã nguồn chiaki-ng")
set(FFMPEG_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/../../Vendor/ffmpeg" CACHE PATH "FFmpeg tĩnh (avcodec, avutil, swscale)")

# Chỉ dựng phần lõi của chiaki-ng: không GUI/CLI/test, không giải mã FFmpeg của chiaki (app tự giải mã).
set(CHIAKI_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(CHIAKI_ENABLE_CLI OFF CACHE BOOL "" FORCE)
set(CHIAKI_ENABLE_GUI OFF CACHE BOOL "" FORCE)
set(CHIAKI_ENABLE_FFMPEG_DECODER OFF CACHE STRING "" FORCE)
set(CHIAKI_ENABLE_SETSU OFF CACHE STRING "" FORCE)
set(CHIAKI_ENABLE_STEAMDECK_NATIVE OFF CACHE STRING "" FORCE)
set(CHIAKI_ENABLE_STEAM_SHORTCUT OFF CACHE BOOL "" FORCE)
set(CHIAKI_ENABLE_SPEEX OFF CACHE STRING "" FORCE)
set(CHIAKI_USE_SYSTEM_NANOPB OFF CACHE STRING "" FORCE)
set(CHIAKI_USE_SYSTEM_JERASURE OFF CACHE STRING "" FORCE)
set(CHIAKI_USE_SYSTEM_CURL ON CACHE STRING "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
add_subdirectory("${CHIAKI_SRC}" chiaki-ng EXCLUDE_FROM_ALL)

add_library(st_chiaki SHARED bridge.c decoder.c)
set_target_properties(st_chiaki PROPERTIES PREFIX "" OUTPUT_NAME "st_chiaki" C_VISIBILITY_PRESET hidden)
target_include_directories(st_chiaki PRIVATE include "${FFMPEG_PREFIX}/include")
target_link_libraries(st_chiaki PRIVATE chiaki-lib
    "${FFMPEG_PREFIX}/lib/libavcodec.a" "${FFMPEG_PREFIX}/lib/libswscale.a" "${FFMPEG_PREFIX}/lib/libavutil.a"
    bcrypt ws2_32 iphlpapi)
# libgcc / libwinpthread tĩnh để bớt DLL phải mang theo.
target_link_options(st_chiaki PRIVATE -static-libgcc -Wl,--exclude-libs,ALL)
