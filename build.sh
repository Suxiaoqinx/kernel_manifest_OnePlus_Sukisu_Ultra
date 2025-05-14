#!/bin/bash
set -e

# ===== 获取脚本目录 =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ===== 设置自定义参数 =====
echo ">>> 读取用户配置..."
read -p "请输入 SoC 分支名称（默认：sm8650）: " SOC_BRANCH
SOC_BRANCH=${SOC_BRANCH:-sm8650}

read -p "请输入 manifest 文件名（默认：oneplus_ace3_pro_v.xml）: " MANIFEST_FILE
MANIFEST_FILE=${MANIFEST_FILE:-oneplus_ace3_pro_v.xml}

read -p "请输入自定义内核后缀（默认：oki-Coolapk@Suxiaoqing）: " CUSTOM_SUFFIX
CUSTOM_SUFFIX=${CUSTOM_SUFFIX:-oki-Coolapk@Suxiaoqing}

read -p "请输入 Bazel 构建目标（默认：pineapple）: " BAZEL_TARGET
BAZEL_TARGET=${BAZEL_TARGET:-pineapple}

read -p "是否使用 patch_linux 工具添加KPM补丁内核？(y/n，默认：y): " USE_PATCH_LINUX
USE_PATCH_LINUX=${USE_PATCH_LINUX:-y}

read -p "是否应用 lz4kd 补丁？(y/n，默认：y): " APPLY_LZ4KD
APPLY_LZ4KD=${APPLY_LZ4KD:-y}

echo
echo "===== 配置信息 ====="
echo "SoC 分支: $SOC_BRANCH"
echo "manifest: $MANIFEST_FILE"
echo "后缀: -$CUSTOM_SUFFIX"
echo "构建目标: $BAZEL_TARGET"
echo "使用 patch_linux: $USE_PATCH_LINUX"
echo "应用 lz4kd 补丁: $APPLY_LZ4KD"
echo "===================="
echo

# ===== 创建工作目录 =====
WORKDIR="$SCRIPT_DIR/kernel_workspace"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ===== 安装构建依赖 =====
echo ">>> 安装构建依赖..."
sudo apt-get update
sudo apt-get install -y git curl zip perl make gcc python3

# ===== 下载 repo 工具到脚本目录 =====
echo ">>> 下载 repo 工具到当前目录..."
cd "$SCRIPT_DIR"
curl --tlsv1.2 -LSs -o repo https://storage.googleapis.com/git-repo-downloads/repo
chmod +x repo
echo ">>> repo 安装完成: $SCRIPT_DIR/repo"
echo

# ===== 初始化仓库 =====
cd "$WORKDIR"
echo ">>> 初始化仓库..."
"$SCRIPT_DIR/repo" init -u https://github.com/OnePlusOSS/kernel_manifest.git -b refs/heads/oneplus/${SOC_BRANCH} -m ${MANIFEST_FILE} --depth=1
echo ">>> repo init 完成"
"$SCRIPT_DIR/repo" sync -j16 --fail-fast
echo ">>> repo sync 完成"

cd kernel_platform

# ===== 清除 abi 文件、去除 -dirty 后缀 =====
echo ">>> 正在清除 ABI 文件及去除 dirty 后缀..."
rm common/android/abi_gki_protected_exports_* || true
rm msm-kernel/android/abi_gki_protected_exports_* || true

for f in common/scripts/setlocalversion msm-kernel/scripts/setlocalversion external/dtc/scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
  sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' "$f"
done

# ===== 替换版本后缀 =====
echo ">>> 替换内核版本后缀..."
for f in ./common/scripts/setlocalversion ./msm-kernel/scripts/setlocalversion ./external/dtc/scripts/setlocalversion; do
  sed -i "\$s|echo \"\\\$res\"|echo \"-${CUSTOM_SUFFIX}\"|" "$f"
done

# ===== 拉取 SukiSU-Ultra 并设置版本号 =====
echo ">>> 拉取 SukiSU-Ultra 并设置版本..."
curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-dev
cd KernelSU
KSU_VERSION=$(expr $(/usr/bin/git rev-list --count main) "+" 10606)
export KSU_VERSION=$KSU_VERSION
sed -i "s/DKSU_VERSION=12800/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile

# ===== 克隆补丁仓库 =====
echo ">>> 克隆补丁仓库..."
cd "$WORKDIR/kernel_platform"
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android14-6.1
git clone https://github.com/Xiaomichael/kernel_patches.git
git clone https://github.com/ShirkNeko/SukiSU_patch.git

# ===== 应用 SUSFS 补丁 =====
echo ">>> 应用 SUSFS 补丁..."
cp ./susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch ./common/
cp ./kernel_patches/next/syscall_hooks.patch ./common/
cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/
cd ./common
patch -p1 < 50_add_susfs_in_gki-android14-6.1.patch || true
cp ../kernel_patches/69_hide_stuff.patch ./
patch -p1 -F 3 < 69_hide_stuff.patch
patch -p1 -F 3 < syscall_hooks.patch
cd ../

# ===== 选择应用 LZ4KD 补丁 =====
if [[ "$APPLY_LZ4KD" == "y" || "$APPLY_LZ4KD" == "Y" ]]; then
  echo ">>> 应用 LZ4KD 补丁..."
  cp -r ./SukiSU_patch/other/zram/lz4k/include/linux/* ./common/include/linux/
  cp -r ./SukiSU_patch/other/zram/lz4k/lib/* ./common/lib
  cp -r ./SukiSU_patch/other/zram/lz4k/crypto/* ./common/crypto
  cp ./SukiSU_patch/other/zram/zram_patch/6.1/lz4kd.patch ./common/
  cd "$WORKDIR/kernel_platform/common"
  patch -p1 -F 3 < lz4kd.patch || true
  cd "$WORKDIR/kernel_platform"
else
  echo ">>> 跳过 LZ4KD 补丁应用"
  cd "$WORKDIR/kernel_platform"
fi

# ===== 添加 defconfig 配置项 =====
echo ">>> 添加 defconfig 配置项..."
DEFCONFIG_FILE=./common/arch/arm64/configs/gki_defconfig

# 写入通用 SUSFS/KSU 配置
cat >> "$DEFCONFIG_FILE" <<EOF
CONFIG_KSU=y
CONFIG_KSU_SUSFS_SUS_SU=n
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
EOF

# 仅在启用了 patch_linux 时添加 KPM 支持
if [[ "$USE_PATCH_LINUX" == "y" || "$USE_PATCH_LINUX" == "Y" ]]; then
  echo "CONFIG_KPM=y" >> "$DEFCONFIG_FILE"
fi

# 仅在启用了 LZ4KD 补丁时添加相关算法支持
if [[ "$APPLY_LZ4KD" == "y" || "$APPLY_LZ4KD" == "Y" ]]; then
  cat >> "$DEFCONFIG_FILE" <<EOF
CONFIG_ZSMALLOC=y
CONFIG_CRYPTO_LZ4HC=y
CONFIG_CRYPTO_LZ4K=y
CONFIG_CRYPTO_LZ4KD=y
CONFIG_CRYPTO_842=y
EOF
fi


# ===== 禁用 defconfig 检查 =====
echo ">>> 禁用 defconfig 检查..."
sed -i 's/check_defconfig//' ./common/build.config.gki

# ===== 再次替换版本后缀 =====
echo ">>> 再次替换版本后缀..."
for f in ./common/scripts/setlocalversion ./msm-kernel/scripts/setlocalversion ./external/dtc/scripts/setlocalversion; do
  sed -i "\$s|echo \"\\\$res\"|echo \"-${CUSTOM_SUFFIX}\"|" "$f"
done

# ===== 编译内核 =====
echo ">>> 开始编译内核..."
#cd "$WORKDIR/kernel_platform"
./build_with_bazel.py -t "$BAZEL_TARGET" gki

# ===== 选择使用 patch_linux (KPM补丁)=====
OUT_DIR="./kernel_platform/out/msm-kernel-${BAZEL_TARGET}-gki/dist"
if [[ "$USE_PATCH_LINUX" == "y" || "$USE_PATCH_LINUX" == "Y" ]]; then
  echo ">>> 使用 patch_linux 工具处理输出..."
  cd "$OUT_DIR"
  curl -LO https://github.com/ShirkNeko/SukiSU_KernelPatch_patch/releases/download/0.11-beta/patch_linux
  chmod +x patch_linux
  ./patch_linux
  rm -f Image
  mv oImage Image
  echo ">>> 已成功打上KPM补丁"
  cd ../../..  # 返回到 kernel_platform 根目录
else
  echo ">>> 跳过 patch_linux 操作"
fi

# ===== 克隆并打包 AnyKernel3 =====
cd "$WORKDIR"
echo ">>> 克隆 AnyKernel3 项目..."
git clone https://github.com/Suxiaoqinx/AnyKernel3 --depth=1

echo ">>> 清理 AnyKernel3 Git 信息..."
rm -rf ./AnyKernel3/.git

echo ">>> 拷贝内核镜像到 AnyKernel3 目录..."
cp "$OUT_DIR/Image" ./AnyKernel3/

echo ">>> 进入 AnyKernel3 目录并打包 zip..."
cd "$WORKDIR/AnyKernel3"

# ===== 如果启用 lz4kd，则下载 zram.zip 并放入当前目录 =====
if [[ "$APPLY_LZ4KD" == "y" || "$APPLY_LZ4KD" == "Y" ]]; then
  echo ">>> 检测到启用了 lz4kd，准备下载 zram.zip..."
  curl -LO https://raw.githubusercontent.com/Suxiaoqinx/kernel_manifest_OnePlus_Sukisu_Ultra/main/zram.zip
  echo ">>> 已下载 zram.zip 并放入打包目录"
fi

# ===== 生成 ZIP 文件名 =====
MANIFEST_BASENAME=$(basename "$MANIFEST_FILE" .xml)
ZIP_NAME="Anykernel3-${MANIFEST_BASENAME}"

if [[ "$APPLY_LZ4KD" == "y" || "$USE_PATCH_LINUX" == "y" ]]; then
  ZIP_NAME="${ZIP_NAME}-lz4kd-kpm"
elif [[ "$APPLY_LZ4KD" == "y" || "$APPLY_LZ4KD" == "Y" ]]; then
  ZIP_NAME="${ZIP_NAME}-lz4kd"
elif [[ "$USE_PATCH_LINUX" == "y" || "$USE_PATCH_LINUX" == "Y" ]]; then
  ZIP_NAME="${ZIP_NAME}-kpm"
fi

ZIP_NAME="${ZIP_NAME}-v$(date +%Y%m%d).zip"

# ===== 打包 ZIP 文件，包括 zram.zip（如果存在） =====
echo ">>> 打包文件: $ZIP_NAME"
zip -r "../$ZIP_NAME" ./*

ZIP_PATH="$(realpath "../$ZIP_NAME")"
echo ">>> 打包完成 文件所在目录: $ZIP_PATH"
