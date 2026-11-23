#!/usr/bin/env bash
# 在 macOS 上把 Unity（Windows 端）导出的 Xcode 工程编译成未签名 IPA。
#
# 用法：把本脚本放在与 Unity-iPhone.xcodeproj 同一目录，然后
#   chmod +x build_unsigned_ipa.sh && ./build_unsigned_ipa.sh
# 产物：./dist/HimeAlpha_1.05_unsigned.ipa
#
# 可用环境变量覆盖：SCHEME、IPA_NAME、BUILD_DIR、DIST_DIR
#
# 兼容性说明（本项目特性）：
#   · 工程由 Unity 2021.3.19 导出，objectVersion=46 / compatibilityVersion="Xcode 3.2"
#   · 部分配置块残留 ENABLE_BITCODE = YES，Xcode 15+ 已移除 bitcode 支持 → 命令行强制 NO
#   · Xcode 15 起默认开启 ENABLE_USER_SCRIPT_SANDBOXING → Unity 生成的脚本会被拦截 → 强制 NO
#   · Xcode 16 默认开启 ENABLE_MODULE_VERIFIER → 对预编译 UnityFramework 会校验失败 → 强制 NO
#   · Xcode 15 新链接器（ld_prime）对旧工程偶发 undefined symbol → 首次失败自动用 -ld_classic 重试
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJ="$ROOT/Unity-iPhone.xcodeproj"
SCHEME="${SCHEME:-Unity-iPhone}"
BUILD="${BUILD_DIR:-$ROOT/build}"
DIST="${DIST_DIR:-$ROOT/dist}"
IPA_NAME="${IPA_NAME:-HimeAlpha_1.05_unsigned.ipa}"

if [ ! -d "$PROJ" ]; then
  echo "错误：找不到 $PROJ" >&2
  echo "请把本脚本放到 Unity-iPhone.xcodeproj 所在目录后再运行。" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "错误：未安装 Xcode 命令行工具。请先执行 xcode-select --install" >&2
  exit 1
fi

echo "==> 环境"
xcodebuild -version
echo "SDK: $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo unknown)"
echo "工程: $PROJ"
echo "Scheme: $SCHEME"

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

# ---------------------------------------------------------------- 编译函数
# $1 = 额外的链接器参数（空字符串表示不追加），$2 = 日志路径
build_once() {
  local extra_ld="$1"
  local log="$2"
  local -a args

  args=(
    -project "$PROJ"
    -scheme "$SCHEME"
    -configuration Release
    -sdk iphoneos
    -destination "generic/platform=iOS"
    -derivedDataPath "$BUILD/DerivedData"
    ARCHS=arm64
    ONLY_ACTIVE_ARCH=NO
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
    ENABLE_BITCODE=NO
    ENABLE_USER_SCRIPT_SANDBOXING=NO
    ENABLE_MODULE_VERIFIER=NO
    GCC_TREAT_WARNINGS_AS_ERRORS=NO
    COMPILER_INDEX_STORE_ENABLE=NO
  )

  if [ -n "$extra_ld" ]; then
    args+=("OTHER_LDFLAGS=\$(inherited) $extra_ld")
    echo "==> 追加链接器参数: $extra_ld"
  fi

  echo "==> 开始编译（日志: ${log}）"
  set +e
  xcodebuild "${args[@]}" build 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  set -e
  return $rc
}

if build_once "" "$BUILD/xcodebuild.log"; then
  echo "==> 编译成功"
else
  echo
  echo "!! 首次编译失败，下面是关键错误行："
  grep -nE "error:|fatal error:|Undefined symbols|The following build commands failed" "$BUILD/xcodebuild.log" | head -40 || true
  echo "--- 日志尾部 80 行 ---"
  tail -n 80 "$BUILD/xcodebuild.log" || true
  echo
  echo "!! 清理产物后用 -ld_classic（Xcode 15 旧链接器）重试"
  echo
  rm -rf "$BUILD/DerivedData"
  build_once "-ld_classic" "$BUILD/xcodebuild-ldclassic.log" || {
    echo "错误：两次编译均失败，下面是第二次的关键错误行：" >&2
    grep -nE "error:|fatal error:|Undefined symbols|The following build commands failed" "$BUILD/xcodebuild-ldclassic.log" | head -40 >&2 || true
    tail -n 120 "$BUILD/xcodebuild-ldclassic.log" >&2 || true
    exit 1
  }
  echo "==> 编译成功（-ld_classic）"
fi

# ---------------------------------------------------------------- 打包 IPA
APP="$(find "$BUILD/DerivedData/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' | head -1)"
if [ -z "$APP" ]; then
  echo "错误：找不到 .app 产物，请检查 build/xcodebuild.log" >&2
  exit 1
fi
echo "==> 产物: $APP ($(du -sh "$APP" | cut -f1))"

echo "==> 清理残留签名"
find "$APP" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true
MAIN_BIN="$APP/$(basename "$APP" .app)"
if [ -f "$MAIN_BIN" ] && command -v codesign >/dev/null 2>&1; then
  codesign --remove-signature "$MAIN_BIN" 2>/dev/null || true
fi

echo "==> 封装 IPA"
rm -rf "$BUILD/Payload"
mkdir -p "$BUILD/Payload"
cp -R "$APP" "$BUILD/Payload/"
(cd "$BUILD" && /usr/bin/zip -qry "$DIST/$IPA_NAME" Payload)

echo
echo "完成：$DIST/$IPA_NAME"
ls -lh "$DIST/$IPA_NAME"
echo
echo "下一步：用 Sideloadly / AltStore / TrollStore 等工具，以你自己的 Apple ID 重签后安装。"
echo "免费 Apple ID 签名的有效期是 7 天，到期重签即可。"
