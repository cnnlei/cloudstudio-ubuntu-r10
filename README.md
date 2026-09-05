# CloudStudio Ubuntu 24.04 + CodeBuddy + r10 Template

用于 CloudStudio 官网「创建应用 -> 从 Git 仓库导入」。

## 包含

- Ubuntu 24.04 基础环境
- Node.js 22.13.1（缺失时安装）
- `@tencent-ai/codebuddy-code@2.37.11`（缺失时安装）
- `cloudstudio-r10.sh` / `cs-init`
- netapp / watchdog / Supervisor 接入
- CodeBuddy OpenAI-compatible relay
- Tailscale 程序（由 r10 安装；身份不写入仓库）

## 安全设计

仓库不保存：

- CloudStudio API Token
- `/root/.cs-token`
- `/root/.relay-key`
- Tailscale machine state
- SSH 私钥/host key

首次创建时 relay key 会重新生成；healthz Token、Tailscale Auth Key 可在创建后由 Manager 的「修复安装」或 `cs-init reconfigure` 配置。

## CloudStudio 使用

1. 把本仓库推到 GitHub。
2. CloudStudio 官网 -> 创建应用 -> 从 Git 仓库导入。
3. 填 GitHub 仓库 URL。
4. 如果平台识别 `workspace.yml`，首次初始化会自动执行 `install.sh`。
5. 如果新版界面要求手选自定义环境，则选择仓库根目录的 `Dockerfile`；进入 Workspace 后执行一次 `./install.sh`。
6. 校验：`./verify.sh` 或 `cs-init status`。

> `cloudstudio-r10.sh` 必须保留为 `2026.09.05-r10`，不要换回旧 r8/r9。
