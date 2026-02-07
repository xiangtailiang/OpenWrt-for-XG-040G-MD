#!/bin/bash
# 安装和更新第三方软件包
# 此脚本在 feeds update 后、feeds install 前运行

cd "$(dirname "$0")/../openwrt" || exit 1

UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local REPO_NAME=${PKG_REPO#*/}

	echo " "
	echo "=========================================="
	echo "Processing: $PKG_NAME from $PKG_REPO"
	echo "=========================================="

	# 删除本地可能存在的同名软件包
	for DIR in feeds/luci feeds/packages; do
		if [ -d "$DIR" ]; then
			FOUND=$(find "$DIR" -maxdepth 3 -type d -iname "*$PKG_NAME*" 2>/dev/null)
			if [ -n "$FOUND" ]; then
				echo "$FOUND" | while read -r D; do
					echo "Removing existing: $D"
					rm -rf "$D"
				done
			fi
		fi
	done

	# 克隆仓库
	git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git" "$REPO_NAME"

	if [ ! -d "$REPO_NAME" ]; then
		echo "ERROR: Failed to clone $PKG_REPO"
		return 1
	fi

	# 处理克隆的仓库
	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		# 从大杂烩仓库中提取特定包
		find "./$REPO_NAME" -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./feeds/luci/ \;
		rm -rf "./$REPO_NAME"
	elif [[ "$PKG_SPECIAL" == "name" ]]; then
		# 重命名仓库
		mv -f "$REPO_NAME" "./feeds/luci/$PKG_NAME"
	else
		# 直接移动到 feeds/luci
		mv -f "$REPO_NAME" "./feeds/luci/$PKG_NAME"
	fi

	echo "Done: $PKG_NAME"
}

echo "Starting package updates..."

# HomeProxy (代理软件)
UPDATE_PACKAGE "homeproxy" "immortalwrt/homeproxy" "master"

# PassWall (代理软件) - 从 openwrt-passwall 仓库提取
UPDATE_PACKAGE "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"

# PassWall 依赖包
git clone --depth=1 --single-branch --branch main "https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git" passwall-packages
if [ -d "passwall-packages" ]; then
	for pkg in passwall-packages/*/; do
		pkg_name=$(basename "$pkg")
		if [ -d "$pkg" ] && [ -f "$pkg/Makefile" ]; then
			echo "Installing passwall dependency: $pkg_name"
			rm -rf "./feeds/packages/$pkg_name"
			cp -rf "$pkg" "./feeds/packages/"
		fi
	done
	rm -rf passwall-packages
fi

echo " "
echo "=========================================="
echo "Package updates completed!"
echo "=========================================="
