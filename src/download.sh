#!/bin/bash
# Download helpers. Every remote request in this file targets GitHub only.

# 统一的临时目录清理: 失败或被中断时也不留残留
IS_CORE_TMPDIR=""
_cleanup_core_tmp() {
    [[ -n ${IS_CORE_TMPDIR:-} && -d ${IS_CORE_TMPDIR:-} ]] && rm -rf "$IS_CORE_TMPDIR"
}
trap _cleanup_core_tmp EXIT INT TERM

# curl wrapper with retries.
_curl() {
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "$@"
}

# Fetch the latest release tag of the sing-box repository via the GitHub API.
is_latest_version() {
    _curl -fsSL "${IS_CORE_API}?v=${RANDOM}" | jq -r '.tag_name // empty'
}

# Fetch all linux release assets for an architecture.
# Output per line: name <TAB> url <TAB> sha256
is_release_assets() {
    local tag=$1 arch=$2
    _curl -fsSL "https://api.github.com/repos/${IS_CORE_REPO}/releases/tags/${tag}" |
        jq -r --arg a "linux-${arch}" '
            .assets[]
            | select(.name | test($a))
            | select(.name | test("[.]tar[.]gz$"))
            | [.name, .browser_download_url, ((.digest // "") | sub("^sha256:"; ""))]
            | @tsv'
}

# Pick the preferred asset for an architecture.
# Preference: plain > glibc > musl > any other matching variant.
is_pick_asset() {
    local tag=$1 arch=$2 assets name
    assets=$(is_release_assets "$tag" "$arch")
    [[ -z $assets ]] && return 1

    for suffix in "" "-glibc" "-musl"; do
        name=$(awk -F'\t' -v s="-linux-${arch}${suffix}.tar.gz" 'index($1, s) == length($1) - length(s) + 1 {print $1; exit}' <<<"$assets")
        if [[ -n $name ]]; then
            awk -F'\t' -v n="$name" '$1 == n' <<<"$assets"
            return 0
        fi
    done

    # Fall back to the first matching variant.
    head -n1 <<<"$assets"
}

# Verify a downloaded file against a sha256 digest.
# Usage: is_verify_sha256 <file> <sha256>
is_verify_sha256() {
    local file=$1 expect=$2 actual
    [[ -z $expect ]] && return 0
    actual=$(sha256sum "$file" | awk '{print $1}')
    [[ $actual == "$expect" ]] && return 0
    err "SHA256 校验失败: ${file}
期望: ${expect}
实际: ${actual}"
}

# Download the sing-box core binary for this architecture.
# Usage: is_download_core [version-tag]
is_download_core() {
    local ver=${1:-} arch meta name url digest tmpdir
    arch=$(is_arch)
    tmpdir=$(mktemp -d)
    IS_CORE_TMPDIR="$tmpdir"

    if [[ -z $ver ]]; then
        ver=$(is_latest_version)
        [[ -z $ver ]] && err "无法从 GitHub 获取 ${IS_CORE_NAME} 最新版本."
    fi

    # 已安装同版本内核时跳过下载, 使重复安装 / 升级更轻量
    if [[ -x $IS_CORE_BIN ]] && "$IS_CORE_BIN" version 2>/dev/null | head -n1 | grep -qF "$ver"; then
        msg "已安装 ${IS_CORE_NAME} ${ver}, 跳过下载."
        return
    fi

    meta=$(is_pick_asset "$ver" "$arch")
    [[ -z $meta ]] && err "在 GitHub 上未找到适用于 ${arch} 的 ${IS_CORE_NAME} 发布包 (${ver})."

    name=$(awk -F'\t' '{print $1}' <<<"$meta")
    url=$(awk -F'\t' '{print $2}' <<<"$meta")
    digest=$(awk -F'\t' '{print $3}' <<<"$meta")

    msg "下载 ${IS_CORE_NAME} ${ver} (${arch}) ..."
    _curl -fL --retry 3 --progress-bar -o "${tmpdir}/${name}" "$url" || err "下载失败: ${url}"

    is_verify_sha256 "${tmpdir}/${name}" "$digest"

    tar zxf "${tmpdir}/${name}" -C "$tmpdir" || err "解压失败."
    find "$tmpdir" -name "$IS_CORE_NAME" -type f -exec cp -f {} "$IS_CORE_BIN" \;
    [[ ! -x $IS_CORE_BIN ]] && err "未找到 ${IS_CORE_NAME} 可执行文件."

    chmod +x "$IS_CORE_BIN"
    _rm "$tmpdir"
    msg "已安装: $("$IS_CORE_BIN" version | head -n1)"
}
