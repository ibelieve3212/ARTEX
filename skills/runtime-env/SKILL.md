---
name: runtime-env
description: 在本环境里安装或使用外部工具、依赖之前调用（apt install、pip install、npm install -g、playwright install、下载二进制）。说明哪些已预装、安装会写到哪、以及为什么缺工具应当先报告而不是自己装。
---

# 运行环境与依赖纪律

本环境跑在**容器**里：可写层很小，且容器重建（换镜像）时会被清零 —— 在里面装的东西
活不过一次升级。所以"缺什么就装什么"在这里代价很高：既拖慢当前任务，又会在下次升级时
无声消失，留下一个"当时明明装好了"的假象。

## 三条硬规则

| 场景 | 正确做法 | 为什么 |
|---|---|---|
| 缺系统工具 | **先报告缺什么**，不要自己 `apt install` | 已预装一批常用工具（见下）；确实需要新工具时，告诉用户"需要预装进镜像"，由他重建镜像 —— 那才是永久生效的装法 |
| Python 依赖 | 在**任务工作区的 venv** 里装：`python -m venv .venv && .venv/bin/pip install ...` | 裸 `pip install` 写 `/usr/local`（重建即丢），还可能和系统包冲突 |
| Node 依赖 | 在任务工作区 `npm i`，用本地 `node_modules` | 全局 `npm i -g` 写 `/usr/lib/node_modules`，重建即丢 |

## 已经预装好的（直接用，别重装）

- **浏览器**：`playwright` / `playwright-cli` + chromium + ffmpeg，装在
  `PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright`。**不要再跑 `playwright install`** ——
  浏览器已在镜像里，重装只是浪费几分钟（若真缺某内核如 firefox，先报告）。
- **不做爆破类工具**：本环境**刻意不预装** hashcat / hydra / medusa / wfuzz 等口令爆破与
  字典破解工具。这不是缺件，是纪律（凭据靠“找”不靠“猜”，见「禁止爆破」类技能）。
  所以**不要**为了爆破去 `apt install hashcat` —— 那同时违反两条规则。
- **nmap、whois、dig/nslookup、ping、nc、telnet、curl、wget、jq、unzip、git、rg(ripgrep)、vim**
- **Python 3.12**、**Node 20**

## 该往哪儿写（会持久化）

| 想写的东西 | 位置 |
|---|---|
| 任务产物、脚本、venv | 当前**任务工作区**（`/state/data/tasks/...`，随任务一起保存） |
| 临时大文件 | `$TMPDIR`（= `/state/tmp`） |
| 需要长期存在的命令行工具 | 不要自己装 —— 汇报给用户，请他预装进镜像 |

## 反例（这样写会出问题）

```sh
apt-get install -y imagemagick      # ❌ 写系统目录、拖慢任务、重建后消失
apt-get install -y hashcat          # ❌ 爆破工具：纪律禁止，且写系统目录
pip install ddddocr                 # ❌ 写 /usr/local；应装进工作区 venv
npm install -g some-cli             # ❌ 写系统 node_modules；应在工作区 npm i
playwright install                  # ❌ 浏览器已在镜像内，重装纯属浪费时间
```

> 判断标准很简单：**这次装的东西，是不是下次换镜像还得再装一遍？**
> 是 → 那就是环境该有的东西，报告给用户。
