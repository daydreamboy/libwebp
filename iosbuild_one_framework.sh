#!/usr/bin/env bash
#
# This script generates a single 'WebP.framework' containing all WebP libraries:
# - libwebp (encode/decode)
# - libwebpdecoder (decode only)
# - libwebpmux (mux/demux)
# - libwebpdemux
# - libsharpyuv
#
# An iOS app can include this framework to both encode and decode WebP images.
#
# Run ./iosbuild.sh to generate the framework under the current directory.

set -e

# 关键修复：重置 TMPDIR，解决 clang 无法创建临时文件的问题
export TMPDIR=$(mktemp -d)
echo "TMPDIR reset to: ${TMPDIR}"

# Set this variable based on the desired minimum deployment target.
readonly IOS_MIN_VERSION=6.0

# Extract the latest SDK version from the final field of the form: iphoneosX.Y
readonly SDK=$(xcodebuild -showsdks \
  | grep --color=never iphoneos | sort | tail -n 1 | awk '{print substr($NF, 9)}'
)

# Extract Xcode version.
readonly XCODE=$(xcodebuild -version | grep --color=never Xcode | cut -d " " -f2)
if [[ -z "${XCODE}" ]]; then
  echo "Xcode not available"
  exit 1
fi

readonly OLDPATH=${PATH}

PLATFORMS="iPhoneSimulator64 iPhoneOS-arm64"
readonly PLATFORMS

# 使用绝对路径，避免切换目录后路径失效
readonly SRCDIR=$(cd "$(dirname $0)" && pwd)
readonly TOPDIR=$(pwd)
readonly BUILDDIR="${TOPDIR}/iosbuild"
readonly TARGETDIR="${TOPDIR}/WebP.framework"
readonly DEVELOPER=$(xcode-select --print-path)
readonly PLATFORMSROOT="${DEVELOPER}/Platforms"
readonly LIPO=$(xcrun -sdk iphoneos${SDK} -find lipo)

LIBOBJLIST=''

if [[ -z "${SDK}" ]]; then
  echo "iOS SDK not available"
  exit 1
elif [[ ${SDK%%.*} -gt 8 && "${XCODE%%.*}" -lt 16 ]]; then
  EXTRA_CFLAGS="-fembed-bitcode"
elif [[ ${SDK%%.*} -le 6 ]]; then
  echo "You need iOS SDK version 6.0 or above"
  exit 1
fi

echo "Xcode Version: ${XCODE}"
echo "iOS SDK Version: ${SDK}"

if [[ -e "${BUILDDIR}" || -e "${TARGETDIR}" ]]; then
  cat << EOF
WARNING: The following directories will be deleted:
WARNING:   ${BUILDDIR}
WARNING:   ${TARGETDIR}
WARNING: The build will continue in 5 seconds...
EOF
  sleep 5
fi

rm -rf "${BUILDDIR}" "${TARGETDIR}"
mkdir -p "${BUILDDIR}" "${TARGETDIR}/Headers/" "${TARGETDIR}/Modules/"

if [[ ! -e "${SRCDIR}/configure" ]]; then
  if ! (cd "${SRCDIR}" && sh autogen.sh); then
    cat << EOF
Error creating configure script!
This script requires the autoconf/automake and libtool to build. MacPorts can
be used to obtain these:
https://www.macports.org/install.php
EOF
    exit 1
  fi
fi

for PLATFORM in ${PLATFORMS}; do
  ARCH2=""
  if [[ "${PLATFORM}" == "iPhoneOS-arm64" ]]; then
    PLATFORM="iPhoneOS"
    ARCH="aarch64"
    ARCH2="arm64"
  elif [[ "${PLATFORM}" == "iPhoneSimulator64" ]]; then
    PLATFORM="iPhoneSimulator"
    ARCH="x86_64"
  else
    ARCH="i386"
  fi

  # 安装目录
  ROOTDIR="${BUILDDIR}/${PLATFORM}-${SDK}-${ARCH}"
  # 独立构建目录（configure 在此目录运行，避免污染源码目录）
  BUILDSUBDIR="${BUILDDIR}/build-${PLATFORM}-${SDK}-${ARCH}"
  mkdir -p "${ROOTDIR}"
  mkdir -p "${BUILDSUBDIR}"

  SDKROOT="${PLATFORMSROOT}/${PLATFORM}.platform/Developer/SDKs/${PLATFORM}${SDK}.sdk"

  if [[ ! -d "${SDKROOT}" ]]; then
    echo "ERROR: SDK not found at ${SDKROOT}"
    exit 1
  fi

  # 获取工具链路径
  CC=$(xcrun --sdk "${SDKROOT}" --find clang)
  AR=$(xcrun --sdk "${SDKROOT}" --find ar)
  RANLIB=$(xcrun --sdk "${SDKROOT}" --find ranlib)
  STRIP=$(xcrun --sdk "${SDKROOT}" --find strip)
  NM=$(xcrun --sdk "${SDKROOT}" --find nm)

  CFLAGS="-arch ${ARCH2:-${ARCH}} -pipe -isysroot ${SDKROOT} -O3 -DNDEBUG"
  CFLAGS+=" -miphoneos-version-min=${IOS_MIN_VERSION} ${EXTRA_CFLAGS}"

  echo ""
  echo "========================================"
  echo "Platform  : ${PLATFORM}"
  echo "Arch      : ${ARCH2:-${ARCH}}"
  echo "CC        : ${CC}"
  echo "AR        : ${AR}"
  echo "SDKROOT   : ${SDKROOT}"
  echo "BUILDDIR  : ${BUILDSUBDIR}"
  echo "TMPDIR    : ${TMPDIR}"
  echo "========================================"

  export PATH="${DEVELOPER}/Toolchains/XcodeDefault.xctoolchain/usr/bin:${OLDPATH}"

  cd "${BUILDSUBDIR}"

  set -x
  "${SRCDIR}/configure" \
    --host="${ARCH}-apple-darwin" \
    --prefix="${ROOTDIR}" \
    --build=$("${SRCDIR}/config.guess") \
    --disable-shared \
    --enable-static \
    --enable-libwebpdecoder \
    --enable-swap-16bit-csp \
    --enable-libwebpmux \
    --enable-libwebpdemux \
    CC="${CC}" \
    AR="${AR}" \
    RANLIB="${RANLIB}" \
    STRIP="${STRIP}" \
    NM="${NM}" \
    CFLAGS="${CFLAGS}"
  set +x

  make V=0 -C sharpyuv install
  make V=0 -C src install

  # 提取所有的 .o 文件，并为每种架构保存
  for lib in libwebp.a libwebpdecoder.a libwebpmux.a libwebpdemux.a libsharpyuv.a; do
    obj_dir="${BUILDDIR}/objs/${PLATFORM}-${SDK}-${ARCH}"
    mkdir -p "$obj_dir"
    xcrun -sdk "${SDKROOT}" ar x "${ROOTDIR}/lib/${lib}"
    find . -name "*.o" -exec mv {} "${obj_dir}/" \;
  done

  make clean

  cd "${TOPDIR}"
  export PATH="${OLDPATH}"
done

# 收集所有目标文件
OBJFILES=()
for dir in "${BUILDDIR}/objs"/*; do
  if [ -d "$dir" ]; then
    for obj in "$dir"/*.o; do
      OBJFILES+=("$obj")
    done
  fi
done

# 创建通用的 Info.plist 模板
INFO_PLIST='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>com.webp.framework</string>
    <key>CFBundleName</key>
    <string>WebP</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>NSPrincipalClass</key>
    <string></string>
</dict>
</plist>'

# 创建 umbrella header 文件 WebP.h
UMBRELLA_HEADER="#ifndef __WEBP_H__
#define __WEBP_H__

#include \"decode.h\"
#include \"encode.h\"
#include \"types.h\"
#include \"demux.h\"
#include \"mux.h\"
#include \"mux_types.h\"
#include \"format_constants.h\"
#include \"sharpyuv.h\"
#include \"sharpyuv_csp.h\"

#endif // __WEBP_H__"

# 写入 Info.plist
echo "$INFO_PLIST" > "${TARGETDIR}/Info.plist"

# 写入 umbrella header
mkdir -p "${TARGETDIR}/Headers"
echo "$UMBRELLA_HEADER" > "${TARGETDIR}/Headers/WebP.h"

# 复制所有需要的头文件
cp -a "${SRCDIR}/src/webp/"{decode,encode,types,demux,mux,mux_types,format_constants}.h "${TARGETDIR}/Headers/"
cp -a "${SRCDIR}/sharpyuv/"{sharpyuv,sharpyuv_csp}.h "${TARGETDIR}/Headers/"

# 创建 Modules/module.modulemap
mkdir -p "${TARGETDIR}/Modules"
cat << EOF > "${TARGETDIR}/Modules/module.modulemap"
framework module WebP {
    umbrella header "WebP.h"

    export *
}
EOF

# 将所有目标文件打包成一个静态库
FINAL_A_FILE="${TARGETDIR}/WebP"
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# 将所有目标文件复制到临时目录
for obj in "${OBJFILES[@]}"; do
  cp "$obj" .
done

# 模拟关联数组：格式为 "arch:obj1 obj2 obj3"
archs=()

for obj in *.o; do
  arch=$(file "$obj" | grep -oE 'Mach-O ([^ ]+) object')
  if [[ -n "$arch" ]]; then
    # 提取架构名（如 "x86_64", "arm64"）
    arch_name="${arch#Mach-O }"
    arch_name="${arch_name% object}"

    # 检查是否已经添加过该架构
    found=false
    for i in "${!archs[@]}"; do
      if [[ "${archs[$i]}" == "$arch_name:"* ]]; then
        # 已存在该架构，追加目标文件
        archs[$i]="${archs[$i]} $obj"
        found=true
        break
      fi
    done

    if ! $found; then
      # 新架构，新建条目
      archs+=("$arch_name:$obj")
    fi
  fi
done

# 创建 fat binary
fat_binary="libWebP.a"
touch "$fat_binary"

# 先为每个架构创建 thin binary
for entry in "${archs[@]}"; do
  IFS=':' read -r arch obj_list <<< "$entry"

  thin_lib="libWebP-$arch.a"
  xcrun -sdk iphoneos${SDK} ar rcs "$thin_lib" $obj_list
done

# 将所有 thin binary 用 lipo 合并为一个 fat binary
all_thin_libs=()
for entry in "${archs[@]}"; do
  IFS=':' read -r arch _ <<< "$entry"
  all_thin_libs+=("libWebP-$arch.a")
done

xcrun -sdk iphoneos${SDK} lipo -create "${all_thin_libs[@]}" -output "$fat_binary"

# 移动最终的 fat binary 到 Framework
mv "$fat_binary" "${FINAL_A_FILE}"

# 验证架构
echo ""
echo "Verifying Framework architecture..."
xcrun -sdk iphoneos${SDK} lipo -info "${FINAL_A_FILE}"

# 清理临时目录
cd "${TOPDIR}"
rm -rf "$TEMP_DIR" "${BUILDDIR}/objs"

# 清理临时目录
rm -rf "${TMPDIR}"

echo ""
echo "SUCCESS"
