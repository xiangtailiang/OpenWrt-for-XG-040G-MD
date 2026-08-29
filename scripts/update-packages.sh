#!/bin/bash
# 安装和更新第三方软件包
# 此脚本在 openwrt/package/ 目录下运行，在 feeds install 之后执行

UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local PKG_LIST=("$PKG_NAME" $5)
	local REPO_NAME=${PKG_REPO#*/}

	echo " "
	echo "=========================================="
	echo "Processing: $PKG_NAME from $PKG_REPO"
	echo "=========================================="

	# 删除 feeds 中可能存在的同名软件包
	for NAME in "${PKG_LIST[@]}"; do
		echo "Search directory: $NAME"
		local FOUND_DIRS=$(find ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)

		if [ -n "$FOUND_DIRS" ]; then
			while read -r DIR; do
				rm -rf "$DIR"
				echo "Delete directory: $DIR"
			done <<< "$FOUND_DIRS"
		else
			echo "Not found directory: $NAME"
		fi
	done

	# 克隆 GitHub 仓库
	git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git"

	if [ ! -d "$REPO_NAME" ]; then
		echo "ERROR: Failed to clone $PKG_REPO"
		return 1
	fi

	# 处理克隆的仓库
	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		# 从大杂烩仓库中提取特定包
		find ./$REPO_NAME/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./ \;
		rm -rf ./$REPO_NAME/
	elif [[ "$PKG_SPECIAL" == "name" ]]; then
		# 重命名仓库
		mv -f $REPO_NAME $PKG_NAME
	fi

	echo "Done: $PKG_NAME"
}

PATCH_PASSWALL_GLOBAL_LUA() {
	local CANDIDATES=(
		"./luci-app-passwall/luasrc/model/cbi/passwall/client/global.lua"
		"./passwall/luci-app-passwall/luasrc/model/cbi/passwall/client/global.lua"
	)
	local FOUND=0

	for FILE in "${CANDIDATES[@]}"; do
		if [ -f "$FILE" ]; then
			FOUND=1
			echo "Applying PassWall Lua compatibility hotfix: $FILE"

			# Guard optional form fields to avoid nil-index runtime errors.
			sed -i 's#local dns_shunt_val = s.fields\["dns_shunt"\]:formvalue(section)#local dns_shunt_val = (s.fields["dns_shunt"] and s.fields["dns_shunt"]:formvalue(section)) or ""#g' "$FILE"
			sed -i 's#s.fields\["dns_mode"\]:formvalue(section) == "xray" or s.fields\["smartdns_dns_mode"\]:formvalue(section) == "xray"#((s.fields["dns_mode"] and s.fields["dns_mode"]:formvalue(section)) == "xray") or ((s.fields["smartdns_dns_mode"] and s.fields["smartdns_dns_mode"]:formvalue(section)) == "xray")#g' "$FILE"
			sed -i 's#s.fields\["dns_mode"\]:formvalue(section) == "sing-box" or s.fields\["smartdns_dns_mode"\]:formvalue(section) == "sing-box"#((s.fields["dns_mode"] and s.fields["dns_mode"]:formvalue(section)) == "sing-box") or ((s.fields["smartdns_dns_mode"] and s.fields["smartdns_dns_mode"]:formvalue(section)) == "sing-box")#g' "$FILE"
		fi
	done

	if [ "$FOUND" -eq 0 ]; then
		echo "WARNING: PassWall global.lua not found, hotfix skipped."
	fi
}

PATCH_SING_BOX_GO127() {
	local SING_BOX_MAKEFILE="./sing-box/Makefile"
	local PATCHED_MAKEFILE
	local GO127_TAG_LINE='GO_PKG_TAGS:=$(if $(strip $(GO_PKG_TAGS)),$(strip $(GO_PKG_TAGS))$(comma))http2legacy'

	if [ ! -f "$SING_BOX_MAKEFILE" ]; then
		echo "ERROR: Sing-box Makefile not found: $SING_BOX_MAKEFILE"
		return 1
	fi

	if awk '!/^[[:space:]]*#/ && /http2legacy/ { found = 1 } END { exit !found }' "$SING_BOX_MAKEFILE"; then
		echo "Sing-box already enables the Go http2legacy build tag."
		return 0
	fi

	echo "Applying sing-box Go 1.27 compatibility hotfix..."
	# Go 1.27 makes x/net/http2 wrap the standard-library implementation by
	# default. Sing-box 1.13.x links to internals from the legacy implementation.
	PATCHED_MAKEFILE=$(mktemp "${SING_BOX_MAKEFILE}.XXXXXX") || return 1
	if ! awk -v tag_line="$GO127_TAG_LINE" '
		$0 == "$(eval $(call GoBinPackage,sing-box))" && !patched {
			print "# Go 1.27 compatibility: keep the legacy x/net/http2 implementation."
			print tag_line
			patched = 1
		}
		{ print }
		END { if (!patched) exit 1 }
	' "$SING_BOX_MAKEFILE" > "$PATCHED_MAKEFILE"; then
		rm -f "$PATCHED_MAKEFILE"
		echo "ERROR: Failed to locate the sing-box build-package declaration."
		return 1
	fi
	mv -f "$PATCHED_MAKEFILE" "$SING_BOX_MAKEFILE"

	if ! grep -Fq "$GO127_TAG_LINE" "$SING_BOX_MAKEFILE"; then
		echo "ERROR: Failed to patch sing-box for Go 1.27."
		return 1
	fi

	echo "Done applying sing-box Go 1.27 compatibility hotfix"
}

echo "Starting package updates..."

# 首先删除 feeds 中的 sing-box 相关包，避免与第三方包冲突
echo " "
echo "=========================================="
echo "Removing conflicting sing-box packages from feeds..."
echo "=========================================="
rm -rf ../feeds/packages/net/sing-box
rm -rf ../package/feeds/packages/sing-box
echo "Done removing sing-box from feeds"

# HomeProxy (代理软件) - 使用第5个参数指定额外要删除的包名
UPDATE_PACKAGE "homeproxy" "immortalwrt/homeproxy" "master"

# Argon 主题
UPDATE_PACKAGE "luci-theme-argon" "jerrykuku/luci-theme-argon" "master"
UPDATE_PACKAGE "luci-app-argon-config" "jerrykuku/luci-app-argon-config" "master"

# 修改 LuCI 默认主题为 Argon（保留 bootstrap 包可共存）
echo " "
echo "=========================================="
echo "Setting default LuCI theme to argon..."
echo "=========================================="
COLLECTION_MAKEFILES=$(find ../feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null)
if [ -n "$COLLECTION_MAKEFILES" ]; then
	sed -i "s/luci-theme-bootstrap/luci-theme-argon/g" $COLLECTION_MAKEFILES
	echo "Done setting default LuCI theme to argon"
else
	echo "WARNING: No LuCI collection Makefile found, skip theme default patch"
fi

# PassWall (代理软件)
UPDATE_PACKAGE "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"
PATCH_PASSWALL_GLOBAL_LUA

# OpenWrt 25.12 下 shadowsocksr-libev 的上游归档内容已变化，旧 MIRROR_HASH 失效。
# 先禁用 SSR 组件，避免 passwall 选择该包导致下载阶段直接失败。
PASSWALL_MAKEFILE="./luci-app-passwall/Makefile"
if [ -f "$PASSWALL_MAKEFILE" ]; then
	echo "Patching PassWall defaults to disable broken ShadowsocksR components..."
	sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_ShadowsocksR_Libev_Client/,/default y/s/default y/default n/' "$PASSWALL_MAKEFILE"
	sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_ShadowsocksR_Libev_Server/,/default n/s/default n/default n/' "$PASSWALL_MAKEFILE"
fi

# PassWall 依赖包
echo " "
echo "=========================================="
echo "Installing PassWall dependencies..."
echo "=========================================="
git clone --depth=1 --single-branch --branch main "https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git"
if [ -d "openwrt-passwall-packages" ]; then
	for pkg in openwrt-passwall-packages/*/; do
		pkg_name=$(basename "$pkg")
		if [ -d "$pkg" ] && [ -f "$pkg/Makefile" ]; then
			echo "Installing: $pkg_name"
			rm -rf "./$pkg_name"
			cp -rf "$pkg" ./
		fi
	done
	rm -rf openwrt-passwall-packages
fi

PATCH_SING_BOX_GO127 || exit 1

echo " "
echo "=========================================="
echo "Package updates completed!"
echo "=========================================="
