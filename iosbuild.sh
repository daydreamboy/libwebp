#!/bin/bash
#
# This script generates 'WebP.framework' and 'WebPDecoder.framework',
# 'WebPDemux.framework' and 'WebPMux.framework'.
# An iOS app can decode WebP images by including 'WebPDecoder.framework' and
# both encode and decode WebP images by including 'WebP.framework'.
#
# Run ./iosbuild.sh to generate the frameworks under the current directory
# (the previous build will be erased if it exists).
#
# This script is inspired by the build script written by Carson McDonald.
# (https://www.ioncannon.net/programming/1483/using-webp-to-reduce-native-ios-app-size/).

set -e

# ============================================================
# 关键修复：重置 TMPDIR，解决 clang 无法创建临时文件的问题
# 原因：macOS 的 TMPDIR 通常是 /var/folders/... 这样的路径
#       某些情况下该目录权限异常，导致 clang 报 Permission denied
# ============================================================
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

PLATFORMS="iPhoneSimulator64"
PLATFORMS+=" iPhoneOS-arm64"
readonly PLATFORMS

# 使用绝对路径，避免切换目录后路径失效
readonly SRCDIR=$(cd "$(dirname $0)" && pwd)
readonly TOPDIR=$(pwd)
readonly BUILDDIR="${TOPDIR}/iosbuild"
readonly TARGETDIR="${TOPDIR}/WebP.framework"
readonly DECTARGETDIR="${TOPDIR}/WebPDecoder.framework"
readonly MUXTARGETDIR="${TOPDIR}/WebPMux.framework"
readonly DEMUXTARGETDIR="${TOPDIR}/WebPDemux.framework"
readonly SHARPYUVTARGETDIR="${TOPDIR}/SharpYuv.framework"
readonly DEVELOPER=$(xcode-select --print-path)
readonly PLATFORMSROOT="${DEVELOPER}/Platforms"
readonly LIPO=$(xcrun -sdk iphoneos${SDK} -find lipo)

LIBLIST=''
DECLIBLIST=''
MUXLIBLIST=''
DEMUXLIBLIST=''
SHARPYUVLIBLIST=''

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

if [[ -e "${BUILDDIR}" || -e "${TARGETDIR}" || -e "${DECTARGETDIR}" \
      || -e "${MUXTARGETDIR}" || -e "${DEMUXTARGETDIR}" \
      || -e "${SHARPYUVTARGETDIR}" ]]; then
  cat << EOF
WARNING: The following directories will be deleted:
WARNING:   ${BUILDDIR}
WARNING:   ${TARGETDIR}
WARNING:   ${DECTARGETDIR}
WARNING:   ${MUXTARGETDIR}
WARNING:   ${DEMUXTARGETDIR}
WARNING:   ${SHARPYUVTARGETDIR}
WARNING: The build will continue in 5 seconds...
EOF
  sleep 5
fi

rm -rf "${BUILDDIR}" "${TARGETDIR}" "${DECTARGETDIR}" \
    "${MUXTARGETDIR}" "${DEMUXTARGETDIR}" "${SHARPYUVTARGETDIR}"
mkdir -p "${BUILDDIR}" "${TARGETDIR}/Headers/" "${DECTARGETDIR}/Headers/" \
    "${MUXTARGETDIR}/Headers/" "${DEMUXTARGETDIR}/Headers/" \
    "${SHARPYUVTARGETDIR}/Headers/"

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
  elif [[ "${PLATFORM}" == "iPhoneOS-V7s" ]]; then
    PLATFORM="iPhoneOS"
    ARCH="armv7s"
  elif [[ "${PLATFORM}" == "iPhoneOS-V7" ]]; then
    PLATFORM="iPhoneOS"
    ARCH="armv7"
  elif [[ "${PLATFORM}" == "iPhoneOS-V6" ]]; then
    PLATFORM="iPhoneOS"
    ARCH="armv6"
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

  DEVROOT="${DEVELOPER}/Toolchains/XcodeDefault.xctoolchain"
  SDKROOT="${PLATFORMSROOT}/"
  SDKROOT+="${PLATFORM}.platform/Developer/SDKs/${PLATFORM}${SDK}.sdk"

  # 验证 SDK 路径是否存在
  if [[ ! -d "${SDKROOT}" ]]; then
    echo "ERROR: SDK not found at ${SDKROOT}"
    exit 1
  fi

  # 使用 xcrun 获取工具链中各工具的完整路径
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

  export PATH="${DEVROOT}/usr/bin:${OLDPATH}"

  # 切换到独立构建目录后再运行 configure
  set -x
  cd "${BUILDSUBDIR}"

  "${SRCDIR}/configure" \
    --host="${ARCH}-apple-darwin" \
    --prefix="${ROOTDIR}" \
    --build=$("${SRCDIR}/config.guess") \
    --disable-shared \
    --enable-static \
    --enable-libwebpdecoder \
    --enable-swap-16bit-csp \
    --enable-libwebpmux \
    CC="${CC}" \
    AR="${AR}" \
    RANLIB="${RANLIB}" \
    STRIP="${STRIP}" \
    NM="${NM}" \
    CFLAGS="${CFLAGS}"
  set +x

  # 在构建目录中编译并安装
  make V=0 -C sharpyuv install
  make V=0 -C src install

  LIBLIST+=" ${ROOTDIR}/lib/libwebp.a"
  DECLIBLIST+=" ${ROOTDIR}/lib/libwebpdecoder.a"
  MUXLIBLIST+=" ${ROOTDIR}/lib/libwebpmux.a"
  DEMUXLIBLIST+=" ${ROOTDIR}/lib/libwebpdemux.a"
  SHARPYUVLIBLIST+=" ${ROOTDIR}/lib/libsharpyuv.a"

  make clean

  # 返回顶层目录，准备下一次循环
  cd "${TOPDIR}"
  export PATH="${OLDPATH}"
done

# ============================================================
# 合并多架构库，组装 Framework
# ============================================================
echo ""
echo "LIBLIST = ${LIBLIST}"
cp -a "${SRCDIR}/src/webp/"{decode,encode,types}.h "${TARGETDIR}/Headers/"
${LIPO} -create ${LIBLIST} -output "${TARGETDIR}/WebP"

echo "DECLIBLIST = ${DECLIBLIST}"
cp -a "${SRCDIR}/src/webp/"{decode,types}.h "${DECTARGETDIR}/Headers/"
${LIPO} -create ${DECLIBLIST} -output "${DECTARGETDIR}/WebPDecoder"

echo "MUXLIBLIST = ${MUXLIBLIST}"
cp -a "${SRCDIR}/src/webp/"{types,mux,mux_types}.h "${MUXTARGETDIR}/Headers/"
${LIPO} -create ${MUXLIBLIST} -output "${MUXTARGETDIR}/WebPMux"

echo "DEMUXLIBLIST = ${DEMUXLIBLIST}"
cp -a "${SRCDIR}/src/webp/"{decode,types,mux_types,demux}.h \
    "${DEMUXTARGETDIR}/Headers/"
${LIPO} -create ${DEMUXLIBLIST} -output "${DEMUXTARGETDIR}/WebPDemux"

echo "SHARPYUVLIBLIST = ${SHARPYUVLIBLIST}"
cp -a "${SRCDIR}/sharpyuv/"{sharpyuv,sharpyuv_csp}.h \
    "${SHARPYUVTARGETDIR}/Headers/"
${LIPO} -create ${SHARPYUVLIBLIST} -output "${SHARPYUVTARGETDIR}/SharpYuv"

# ============================================================
# 验证生成结果
# ============================================================
echo ""
echo "Verifying Frameworks architecture..."
for FW in \
    "${TARGETDIR}/WebP" \
    "${DECTARGETDIR}/WebPDecoder" \
    "${MUXTARGETDIR}/WebPMux" \
    "${DEMUXTARGETDIR}/WebPDemux" \
    "${SHARPYUVTARGETDIR}/SharpYuv"; do
  echo -n "  $(basename ${FW}): "
  ${LIPO} -info "${FW}"
done

# 清理临时目录
rm -rf "${TMPDIR}"

echo ""
echo "SUCCESS"
