#!/bin/sh
# TransWork 演示环境自检
# 用法：sh verify.sh（在 演示部署 目录，或任意位置用绝对路径）
#
# 这个文件可能在 Windows 上被编辑过（CRLF）。dash 会把 "\r" 当成选项的一部分，
# 报 "set: Illegal option -"。这里先自愈：去掉 \r 后重新执行自己。

CR=$(printf '\r')
if head -c 600 "$0" | grep -q "$CR"; then
  TMP="/tmp/transwork-verify.$$.sh"
  tr -d '\r' < "$0" > "$TMP"
  VERIFY_DIR=$(cd "$(dirname "$0")" && pwd)
  export VERIFY_DIR
  exec sh "$TMP" "$@"
fi

set -u
cd "${VERIFY_DIR:-$(dirname "$0")}" || exit 1

if [ ! -f docker-compose.yaml ]; then
  echo "当前目录没有 docker-compose.yaml（$PWD）"
  echo "请把 verify.sh 和部署文件放在同一目录，或在 演示部署 目录下执行：sh verify.sh"
  exit 1
fi

if command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
elif docker compose version >/dev/null 2>&1; then
  DC="docker compose"
else
  echo "找不到 docker-compose，请先安装 Docker Compose"
  exit 1
fi

FAIL=0
ok() { printf '  [ok]   %s\n' "$1"; }
bad() { printf '  [fail] %s\n' "$1"; FAIL=1; }
info() { printf '  [--]   %s\n' "$1"; }

# 环境变量以容器里实际生效的为准，不依赖当前目录有没有 .env
cenv() { docker exec transwork-webagent sh -c "echo \${$1:-}" 2>/dev/null || echo ""; }

echo "== 1. 容器状态 =="
$DC ps || bad "docker-compose ps 执行失败"

echo
echo "== 2. 健康检查 =="
if docker exec transwork-web node -e "fetch('http://127.0.0.1:3000/readyz').then(function(r){process.exit(r.ok?0:1)}).catch(function(){process.exit(1)})" >/dev/null 2>&1; then
  ok "后台 /readyz 正常"
else
  bad "后台 /readyz 不通（docker logs transwork-web 看看）"
fi

if docker exec transwork-webagent node -e "fetch('http://127.0.0.1:4100/api/health').then(function(r){process.exit(r.ok?0:1)}).catch(function(){process.exit(1)})" >/dev/null 2>&1; then
  ok "WebAgent /api/health 正常"
else
  bad "WebAgent /api/health 不通（docker logs transwork-webagent 看看）"
fi

echo
echo "== 3. 命令执行 =="
SANDBOX_MODE=$(cenv WEBAGENT_SANDBOX)
[ -z "$SANDBOX_MODE" ] && SANDBOX_MODE="unset"
info "容器内 WEBAGENT_SANDBOX=$SANDBOX_MODE"

LAST_LOG=$(docker logs --tail 200 transwork-webagent 2>&1 | grep -i "\[sandbox\]" | tail -1)
if [ -n "$LAST_LOG" ]; then
  info "$LAST_LOG"
else
  info "日志里还没有 [sandbox] 行（可能是旧镜像，见手册第 7 节）"
fi

case "$SANDBOX_MODE" in
  off|unset)
    info "命令执行已关闭：docx/xlsx 等需要跑脚本的技能不可用，这是演示环境默认配置"
    ;;
  docker)
    if docker exec transwork-webagent sh -c 'command -v docker >/dev/null 2>&1' 2>/dev/null; then
      ok "容器内有 docker CLI"
    else
      bad "容器内没有 docker CLI（叠加 docker-compose.sandbox.yaml 或重建镜像）"
    fi
    if docker exec transwork-webagent sh -c 'test -S /var/run/docker.sock' 2>/dev/null; then
      if docker exec transwork-webagent sh -c 'test -w /var/run/docker.sock' 2>/dev/null; then
        ok "已挂载 /var/run/docker.sock（可写）"
      else
        bad "/var/run/docker.sock 已挂载但不可写（容器用户不在 docker 组）"
      fi
    else
      bad "没有挂载 /var/run/docker.sock"
    fi
    SANDBOX_IMAGE=$(cenv WEBAGENT_SANDBOX_IMAGE)
    [ -z "$SANDBOX_IMAGE" ] && SANDBOX_IMAGE="path2ai-webagent-sandbox:1"
    if docker image inspect "$SANDBOX_IMAGE" >/dev/null 2>&1; then
      ok "沙箱镜像存在：$SANDBOX_IMAGE"
    else
      bad "宿主机上没有沙箱镜像 $SANDBOX_IMAGE（见手册第 7 节构建）"
    fi
    HOST_DIR=$(cenv WEBAGENT_SANDBOX_HOST_DATA_DIR)
    if [ -z "$HOST_DIR" ]; then
      bad "WEBAGENT_SANDBOX_HOST_DATA_DIR 为空，产物可能写不回宿主机工作区"
    elif [ ! -d "$HOST_DIR" ]; then
      bad "WEBAGENT_SANDBOX_HOST_DATA_DIR 指向的目录不存在：$HOST_DIR"
    else
      ok "WEBAGENT_SANDBOX_HOST_DATA_DIR=$HOST_DIR"
    fi
    ;;
  *)
    info "未知取值：$SANDBOX_MODE（应为 off 或 docker）"
    ;;
esac

echo
if [ "$FAIL" -eq 0 ]; then
  echo "自检通过。"
else
  echo "自检发现问题，见上面 [fail] 行。"
fi
exit "$FAIL"
