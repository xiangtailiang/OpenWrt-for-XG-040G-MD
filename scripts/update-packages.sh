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
			sed -i 's#local v = s.fields\["shunt_udp_node"\]:formvalue(section)#local v = (s.fields["shunt_udp_node"] and s.fields["shunt_udp_node"]:formvalue(section))#g' "$FILE"
			sed -i 's#if not f then#if not v then#g' "$FILE"
			sed -i 's#local dns_shunt_val = s.fields\["dns_shunt"\]:formvalue(section)#local dns_shunt_val = (s.fields["dns_shunt"] and s.fields["dns_shunt"]:formvalue(section)) or ""#g' "$FILE"
			sed -i 's#s.fields\["dns_mode"\]:formvalue(section) == "xray" or s.fields\["smartdns_dns_mode"\]:formvalue(section) == "xray"#((s.fields["dns_mode"] and s.fields["dns_mode"]:formvalue(section)) == "xray") or ((s.fields["smartdns_dns_mode"] and s.fields["smartdns_dns_mode"]:formvalue(section)) == "xray")#g' "$FILE"
			sed -i 's#s.fields\["dns_mode"\]:formvalue(section) == "sing-box" or s.fields\["smartdns_dns_mode"\]:formvalue(section) == "sing-box"#((s.fields["dns_mode"] and s.fields["dns_mode"]:formvalue(section)) == "sing-box") or ((s.fields["smartdns_dns_mode"] and s.fields["smartdns_dns_mode"]:formvalue(section)) == "sing-box")#g' "$FILE"
		fi
	done

	if [ "$FOUND" -eq 0 ]; then
		echo "WARNING: PassWall global.lua not found, hotfix skipped."
	fi
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

# PassWall (代理软件)
UPDATE_PACKAGE "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"
PATCH_PASSWALL_GLOBAL_LUA

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

echo " "
echo "=========================================="
echo "Package updates completed!"
echo "=========================================="
