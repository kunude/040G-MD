#!/bin/bash
# 工作目录：openwrt/package/
set -e

UPDATE_PACKAGE() {
    local PKG_NAME=$1
    local PKG_REPO=$2
    local PKG_BRANCH=$3
    local PKG_SPECIAL=$4
    local PKG_LIST=("$PKG_NAME" $5)
    local REPO_NAME=${PKG_REPO#*/}

    echo "Processing: $PKG_NAME from $PKG_REPO"
    for NAME in "${PKG_LIST[@]}"; do
        find ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null | xargs -r rm -rf
    done

    git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git"
    if [[ "$PKG_SPECIAL" == "pkg" ]]; then
        find "./$REPO_NAME"/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./ \;
        rm -rf "./$REPO_NAME"
    elif [[ "$PKG_SPECIAL" == "name" ]]; then
        mv -f "$REPO_NAME" "$PKG_NAME"
    fi
}

# 1. 删除 feeds 中冲突的 sing-box
rm -rf ../feeds/packages/net/sing-box ../feeds/packages/net/sing-box
rm -rf ../package/feeds/packages/sing-box

# 2. 克隆 passwall2
UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"

# 3. 修补 passwall2 的 Lua 文件（防 nil 错误）
CANDIDATES=(
    "./luci-app-passwall2/luasrc/model/cbi/passwall2/client/global.lua"
    "./passwall2/luci-app-passwall2/luasrc/model/cbi/passwall2/client/global.lua"
)
for FILE in "${CANDIDATES[@]}"; do
    if [ -f "$FILE" ]; then
        sed -i 's#local dns_shunt_val = s.fields\["dns_shunt"\]:formvalue(section)#local dns_shunt_val = (s.fields["dns_shunt"] and s.fields["dns_shunt"]:formvalue(section)) or ""#g' "$FILE"
        sed -i 's#s.fields\["dns_mode"\]:formvalue(section) == "xray" or s.fields\["smartdns_dns_mode"\]:formvalue(section) == "xray"#((s.fields["dns_mode"] and s.fields["dns_mode"]:formvalue(section)) == "xray") or ((s.fields["smartdns_dns_mode"] and s.fields["smartdns_dns_mode"]:formvalue(section)) == "xray")#g' "$FILE"
        sed -i 's#s.fields\["dns_mode"\]:formvalue(section) == "sing-box" or s.fields\["smartdns_dns_mode"\]:formvalue(section) == "sing-box"#((s.fields["dns_mode"] and s.fields["dns_mode"]:formvalue(section)) == "sing-box") or ((s.fields["smartdns_dns_mode"] and s.fields["smartdns_dns_mode"]:formvalue(section)) == "sing-box")#g' "$FILE"
        break
    fi
done

# 4. 禁用 passwall2 中可能坏掉的 ShadowsocksR 组件（如果有）
if [ -f "./luci-app-passwall2/Makefile" ]; then
    sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_ShadowsocksR_Libev_Client/,/default y/s/default y/default n/' "./luci-app-passwall2/Makefile"
    sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_ShadowsocksR_Libev_Server/,/default n/s/default n/default n/' "./luci-app-passwall2/Makefile"
fi

# 5. 克隆 passwall 依赖包（sing-box, xray 等）
git clone --depth=1 --single-branch --branch main "https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git"
if [ -d "openwrt-passwall-packages" ]; then
    for pkg in openwrt-passwall-packages/*/; do
        pkg_name=$(basename "$pkg")
        if [ -d "$pkg" ] && [ -f "$pkg/Makefile" ]; then
            rm -rf "./$pkg_name"
            cp -rf "$pkg" ./
        fi
    done
    rm -rf openwrt-passwall-packages
fi

# 6. 将 passwall2 相关包写入 .config
CONFIG_FILE="../.config"
if [ -f "$CONFIG_FILE" ]; then
    for pkg in luci-app-passwall2 luci-i18n-passwall2-zh-cn luci-app-passwall2_Nftables_Transparent_Proxy; do
        sed -i "/CONFIG_PACKAGE_${pkg}/d" "$CONFIG_FILE"
        echo "CONFIG_PACKAGE_${pkg}=y" >> "$CONFIG_FILE"
    done
fi

echo "Custom packages (passwall2) installed and configured."
