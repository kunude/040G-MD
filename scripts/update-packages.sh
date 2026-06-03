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

echo "Starting package updates..."

# 首先删除 feeds 中的 sing-box 相关包，避免与第三方包冲突
echo " "
echo "=========================================="
echo "Removing conflicting sing-box packages from feeds..."
echo "=========================================="
rm -rf ../feeds/packages/net/sing-box
rm -rf ../package/feeds/packages/sing-box
echo "Done removing sing-box from feeds"

# PassWall (代理软件)
UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"
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

# ddns-go 使用项目仓库中的自定义版本（如果存在）
if [ -d "../package/custom/ddns-go" ]; then
    echo "Using custom ddns-go from project repository"
elif [ -f "../feeds/packages/net/ddns-go/Makefile" ]; then
    echo "Using official ddns-go from feeds"
else
    echo "ddns-go not available, skipping"
fi

# ========== 强制写入第三方包到 .config ==========
CONFIG_FILE="../.config"

if [ -f "$CONFIG_FILE" ]; then
    echo "Writing third-party packages to .config..."
    
    # 只写入 passwall2（第三方包）
    THIRD_PARTY_PKGS=(
        "luci-app-passwall2"
        "luci-i18n-passwall2-zh-cn"
        "luci-app-passwall2_Nftables_Transparent_Proxy"
    )
    
    for pkg in "${THIRD_PARTY_PKGS[@]}"; do
        key="CONFIG_PACKAGE_${pkg}"
        sed -i "/${key}/d" "$CONFIG_FILE"
        echo "${key}=y" >> "$CONFIG_FILE"
        echo "Enabled: ${key}=y"
    done
    
    echo "Done writing .config"
else
    echo "WARNING: .config not found at $CONFIG_FILE"
fi
