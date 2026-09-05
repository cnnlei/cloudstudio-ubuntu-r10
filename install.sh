#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R10="$ROOT_DIR/cloudstudio-r10.sh"
CODEBUDDY_VERSION="${CODEBUDDY_VERSION:-2.37.11}"
NODE_VERSION="${NODE_VERSION:-22.13.1}"

say() { printf '[cloudstudio-template] %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "必须使用 root 执行 install.sh" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# CloudStudio 某些官方镜像预置的 GitHub CLI APT 源可能出现签名过期/
# 公钥缺失。它与本模板无关，但会让 apt-get update 整体失败。
# 首次 update 失败时，仅临时跳过 cli.github.com/packages 对应源，
# 安装完基础依赖后再恢复，避免永久改动用户的软件源配置。
APT_DISABLED_SOURCES=()

restore_apt_sources() {
  local item src dst
  for item in "${APT_DISABLED_SOURCES[@]:-}"; do
    src="${item%%|*}"
    dst="${item#*|}"
    [ -e "$src" ] && mv -f "$src" "$dst" || true
  done
}

disable_broken_github_cli_sources() {
  local f disabled=0
  for f in /etc/apt/sources.list.d/*; do
    [ -f "$f" ] || continue
    grep -q 'cli\.github\.com/packages' "$f" 2>/dev/null || continue
    case "$f" in
      *.cloudstudio-template-disabled) continue ;;
    esac
    mv "$f" "$f.cloudstudio-template-disabled"
    APT_DISABLED_SOURCES+=("$f.cloudstudio-template-disabled|$f")
    disabled=1
    say "临时跳过失效的 GitHub CLI APT 源：$f"
  done
  [ "$disabled" -eq 1 ]
}

say "安装基础依赖"
if ! apt-get update -qq; then
  say "apt-get update 失败，检查 CloudStudio 预置 GitHub CLI 软件源"
  if disable_broken_github_cli_sources; then
    apt-get update -qq
  else
    echo "APT 更新失败，且未检测到可自动跳过的 GitHub CLI 软件源" >&2
    exit 1
  fi
fi

apt-get install -y -qq \
  ca-certificates curl git openssh-server python3 procps util-linux coreutils \
  xz-utils tar gzip jq >/dev/null

restore_apt_sources
APT_DISABLED_SOURCES=()

install_node_exact() {
  local arch node_arch tmp url
  case "$(uname -m)" in
    x86_64|amd64) node_arch=x64 ;;
    aarch64|arm64) node_arch=arm64 ;;
    *) say "当前架构不自动安装固定 Node：$(uname -m)"; return 1 ;;
  esac

  if command -v node >/dev/null 2>&1 && [ "$(node -v 2>/dev/null || true)" = "v${NODE_VERSION}" ]; then
    say "Node 已是 v${NODE_VERSION}"
    return 0
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  for url in \
    "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
    "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; do
    if curl -fL --retry 3 --connect-timeout 10 "$url" -o "$tmp/node.tar.xz"; then
      break
    fi
  done
  [ -s "$tmp/node.tar.xz" ] || { say "Node 下载失败"; return 1; }

  rm -rf "/opt/node-v${NODE_VERSION}"
  mkdir -p "/opt/node-v${NODE_VERSION}"
  tar -xJf "$tmp/node.tar.xz" -C "/opt/node-v${NODE_VERSION}" --strip-components=1
  ln -sfn "/opt/node-v${NODE_VERSION}/bin/node" /usr/local/bin/node
  ln -sfn "/opt/node-v${NODE_VERSION}/bin/npm" /usr/local/bin/npm
  ln -sfn "/opt/node-v${NODE_VERSION}/bin/npx" /usr/local/bin/npx
  say "Node 已安装：$(node -v)"
}

install_codebuddy() {
  if command -v codebuddy >/dev/null 2>&1; then
    say "已检测到 CodeBuddy：$(command -v codebuddy)"
    return 0
  fi

  install_node_exact
  say "安装 CodeBuddy CLI @tencent-ai/codebuddy-code@${CODEBUDDY_VERSION}"
  mkdir -p /opt/codebuddy
  npm install -g --prefix /opt/codebuddy "@tencent-ai/codebuddy-code@${CODEBUDDY_VERSION}"
  ln -sfn /opt/codebuddy/bin/codebuddy /usr/local/bin/codebuddy
  say "CodeBuddy 已安装：$(command -v codebuddy)"
}

install_codebuddy

[ -f "$R10" ] || { echo "找不到 $R10" >&2; exit 1; }
grep -q '^# VERSION: 2026\.09\.05-r10$' "$R10" || {
  echo "cloudstudio-r10.sh 版本不是 2026.09.05-r10" >&2
  exit 1
}
chmod 0700 "$R10"

# 不在 Git 仓库保存任何账号/机器身份。首次创建时由 r10 自己生成 relay key；
# healthz Token 和 Tailscale Auth Key 后续可由 Manager 或手工重新配置。
say "安装/修复 r10 保活环境"
SSH_SETUP_MODE=keep \
FORCE_SSH_CONFIG=no \
WIZARD_ADD_APP=no \
CS_HEALTHZ_TOKEN="${CS_HEALTHZ_TOKEN:-}" \
TS_AUTHKEY="${TS_AUTHKEY:-}" \
/bin/bash "$R10" repair

say "完成。可执行：cs-init status"
