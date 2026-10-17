# syntax=docker/dockerfile:1
#
# 运行镜像（不在镜像里编译）：只装常用工具，放入**预编译好的 Linux 单二进制**。
# 二进制由 CI 的 binaries job 交叉编译（纯 Go、无 QEMU），按目标架构放在
# 构建上下文的 dist/<TARGETARCH>/artex。这样多架构构建时 arm64 只需模拟 apt 层，
# 不再模拟 Next/Go 编译，速度快得多。
#
# 本地手动构建镜像时，先自行准备二进制：
#   cd web && npm run build:static && cd ..
#   cp -r web/out server/webui/dist
#   CGO_ENABLED=0 GOARCH=amd64 go build -tags embedui -o dist/amd64/artex ./cmd/artex
#   docker build -t artex:local .
#
# 可写状态全部收敛到 /state（见下方 ENV 与 docker-entrypoint.sh）：运行时把宿主机
# 一个目录挂到 /state 即可，容器可写层保持接近 0，删容器重建只丢"重建该丢的东西"。
FROM python:3.12-slim-bookworm
ARG TARGETARCH
# 常用工具：ripgrep / curl / vim，加一批 recon 常备件（按需增删）。
# Node 从 NodeSource 装 20.x：bookworm 自带的 apt nodejs 是 18，Playwright 要求 >=20。
# hashcat + pocl-opencl-icd + ocl-icd-libopencl1：agent 在任务里反复 apt 安装的那套
# （hashcat + CPU OpenCL 运行时）。两个 OpenCL 包都不能省：pocl 只提供 ICD 厂商配置，
# 真正加载它的 libOpenCL.so.1 在 ocl-icd-libopencl1 里，而 --no-install-recommends 不会
# 自动带上它 —— 少了它 hashcat 会报 "No OpenCL installation found"。
# 预装进镜像可省掉每次约 600MB 的安装量和十来分钟等待。
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates ripgrep curl wget vim git jq unzip \
      dnsutils iputils-ping netcat-openbsd inetutils-telnet whois nmap \
      hashcat pocl-opencl-icd ocl-icd-libopencl1 \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*
# 浏览器固定装到镜像内路径。必须显式设 PLAYWRIGHT_BROWSERS_PATH：运行期 HOME 指向
# /state/home（把用户态文件收进挂载点），而 Playwright 默认按 $HOME/.cache/ms-playwright
# 找浏览器，不固定路径就会找不到、每次启动重新下载 680MB。
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
# 预装 Playwright MCP 与 CLI（全局），运行时不再 npx 联网下载。
# @playwright/mcp：browser MCP 直接 `npx @playwright/mcp`（已全局装好，无需 -y/@latest）。
# @playwright/cli：提供 playwright-cli，装完顺带 --help 验证可执行。
# 再装 playwright（提供浏览器管理），装完用 --with-deps 预置 chromium 及其系统依赖，
# 这样容器内 MCP/CLI 首次启动即可用，不再联网下载浏览器。
RUN npm install -g @playwright/mcp@latest @playwright/cli@latest playwright@latest \
    && playwright-cli --help \
    && playwright install --with-deps chromium \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/*
# ── 可写状态收敛到 /state ────────────────────────────────────────────────────
# 容器里会"往外写"的路径全部改指到 /state，运行时只需挂这一个目录：
#   HOME             ~/.ssh、~/.gitconfig、~/.npmrc 等用户态文件
#   XDG_CACHE_HOME   一切遵循 XDG 的缓存（uv/pocl/hashcat/pip…）
#   PIP_CACHE_DIR    pip 下载缓存（原来会在可写层里长到几百 MB）
#   npm_config_cache npm 缓存（npm 不认 XDG，必须单列）
#   PYTHONUSERBASE   pip install --user 的落点
#   TMPDIR           pip 解包等临时大文件（原来能堆到 300MB）
#   ARTEX_CONFIG     应用配置文件位置（可选文件，不存在也能跑）
#   ARTEX_SKILL_DIR  技能目录（data 目录由入口脚本传 -data）
# PATH 只在原值前追加 /state/python/bin（pip install --user 装出来的命令能被找到）。
ENV HOME=/state/home \
    XDG_CACHE_HOME=/state/cache \
    XDG_CONFIG_HOME=/state/home/.config \
    PIP_CACHE_DIR=/state/cache/pip \
    npm_config_cache=/state/cache/npm \
    PYTHONUSERBASE=/state/python \
    PYTHONDONTWRITEBYTECODE=1 \
    TMPDIR=/state/tmp \
    ARTEX_CONFIG=/state/config.json \
    ARTEX_SKILL_DIR=/state/skills \
    PATH=/state/python/bin:/usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# 先把目录建出来（挂载宿主目录后会遮住这里，docker-entrypoint.sh 会再补建一遍）。
RUN mkdir -p /state/home /state/cache/pip /state/cache/npm /state/cache/go \
             /state/tmp /state/python /state/data /state/skills /state/go
WORKDIR /app
# 预编译好的对应架构二进制（dist/amd64/artex 或 dist/arm64/artex）。
# 用 --chmod 而不是 "COPY + RUN chmod"：分开写会让 39MB 的二进制在镜像里存两份。
COPY --chmod=755 dist/${TARGETARCH}/artex /app/artex
# 守护启动脚本：进程退出后按退出码决定是否重新拉起，页面一键更新靠它完成换装。
# 它同时负责把 SIGTERM 转发给 artex —— docker stop 只把信号发给 PID 1，
# 不转发的话 artex 收不到、做不了优雅关闭，10 秒后被 SIGKILL 硬杀。
COPY --chmod=755 start.sh /app/start.sh
# 容器入口：补建 /state 目录、播种内置技能、jwt.key 软链到挂载点，
# 再以 -data /state/data 交给 start.sh。裸机 zip 部署不经过它。
COPY --chmod=755 docker-entrypoint.sh /app/docker-entrypoint.sh
COPY skills/ /app/skills/
EXPOSE 8787 8788
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["-addr", ":8787", "-proxy", ":8788"]
