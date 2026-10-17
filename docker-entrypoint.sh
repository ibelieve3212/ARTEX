#!/bin/sh
# ARTEX 容器入口（仅 Docker 用；裸机 zip 部署直接用 start.sh，不经过这里）。
#
# 它只做四件事，然后把控制权 exec 给 start.sh（守护重启 + 信号转发都在那边）：
#   ① 在挂载点里补建目录结构（宿主目录会遮住镜像里预建的那份）
#   ② 把镜像内置技能"缺哪个补哪个"到挂载点（不会覆盖你改过的同名技能）
#   ③ 把 jwt.key 固定到挂载点（容器重建后登录态不失效）
#   ④ 以 -data <挂载点>/data 启动，让数据目录也落在挂载点里
#
# 容器内可写路径统一由 Dockerfile 的 ENV 指到 /state，这里只负责把 /state 本身
# 准备好。所以运行时挂一个目录就够了：  -v 宿主目录:/state
set -u

STATE=/state

# ① 目录结构。逐个 mkdir，失败也不致命（例如挂载点只读）。
for d in home cache cache/pip cache/npm cache/go tmp python data skills go; do
	mkdir -p "$STATE/$d" 2>/dev/null || true
done

# 忘了挂载点时给个明确警告：数据会落进容器可写层，删容器即丢。
if command -v mountpoint >/dev/null 2>&1 && ! mountpoint -q "$STATE" 2>/dev/null; then
	echo "[entrypoint] 警告：$STATE 不是挂载点，数据将写入容器可写层（删容器即丢）。请加 -v 宿主目录:/state" >&2
fi

# ② 技能播种：逐个子目录判断，缺的才补。
#    这样镜像里新增的内置技能会在下次启动自动出现，用户改过/删过的不会被还原。
if [ -d /app/skills ] && [ -d "$STATE/skills" ]; then
	for src in /app/skills/*/; do
		[ -d "$src" ] || continue
		name=$(basename "$src")
		[ -e "$STATE/skills/$name" ] && continue
		cp -a "$src" "$STATE/skills/$name" 2>/dev/null \
			|| echo "[entrypoint] 内置技能 $name 播种失败（不影响启动）" >&2
	done
fi

# ③ jwt.key：程序按"可执行文件同目录"读写，即 /app/jwt.key。但 /app 在可写层，
#    容器一重建密钥就没了（登录态全失效）。这里用软链把它指向挂载点：
#    程序用的是 os.WriteFile，会顺着链接写；它自带的"从 data 目录迁移旧密钥"逻辑
#    也能穿过链接，把 state/data/jwt.key 搬到 state/jwt.key。
if [ ! -s "$STATE/jwt.key" ] && [ -s /app/jwt.key ]; then
	cp -a /app/jwt.key "$STATE/jwt.key" 2>/dev/null || true
fi
rm -f /app/jwt.key 2>/dev/null || true
ln -sf "$STATE/jwt.key" /app/jwt.key 2>/dev/null || true

echo "[entrypoint] 状态目录 $STATE（data / skills / cache / tmp / home / jwt.key）"

# ④ -data 放最前面：用户若自己再传一个 -data，后面的会覆盖它（flag 后写先赢）。
exec /app/start.sh -data "$STATE/data" "$@"
