#!/usr/bin/env bash
# fix_gh_protocol.sh — 切换 gh 的 git 协议，绕开 github.com 超时
# usage: bash fix_gh_protocol.sh ssh|https|status
set -u

CMD="${1:-status}"

case "$CMD" in
  ssh|https)
    gh config set git_protocol "$CMD"
    echo "git_protocol -> $(gh config get git_protocol 2>/dev/null)"
    ;;
  status)
    p=$(gh config get git_protocol 2>/dev/null)
    echo "git_protocol: ${p:-（未设置，默认 https）}"
    ;;
  *)
    echo "usage: $0 ssh|https|status"; exit 1;;
esac

# 附带实测当前协议的 ls-remote 探针（只读）
if command -v git >/dev/null 2>&1; then
  proto=$(gh config get git_protocol 2>/dev/null)
  [ -z "$proto" ] && proto="https"
  if [ "$proto" = "ssh" ]; then
    r=$(GIT_SSH_COMMAND="ssh -o ConnectTimeout=8 -o BatchMode=yes" git ls-remote git@github.com:cli/cli.git HEAD 2>&1 | head -1)
  else
    r=$(git ls-remote https://github.com/cli/cli.git HEAD 2>&1 | head -1)
  fi
  if printf '%s' "$r" | grep -q 'HEAD'; then echo "ls-remote($proto): OK"; else echo "ls-remote($proto): FAIL -> $r"; fi
fi
