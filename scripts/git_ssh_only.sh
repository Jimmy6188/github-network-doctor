#!/usr/bin/env bash
# git_ssh_only.sh — git 全局 SSH-only 模式：https://github.com/ remote 改写为 SSH
# 用于 HTTPS 全灭但 SSH 存活的网络；配合 ssh_over_443.sh 可走 443
# usage: bash git_ssh_only.sh apply|rollback|status
set -u

CMD="${1:-status}"

unset_insteadof() { # $1 pattern；注意 git config 输出键名为小写，grep 须 -i
  git config --global --get-regexp '^url\.' 2>/dev/null \
    | grep -iF "insteadOf $1" \
    | sed 's/^\(url\.[^ ]*\) .*/\1/' \
    | while read -r key; do git config --global --unset "$key" 2>/dev/null; done
}

case "$CMD" in
  apply)
    git config --global url."git@github.com:".insteadOf "https://github.com/"
    git config --global url."git@gist.github.com:".insteadOf "https://gist.github.com/"
    echo "git SSH-only 已生效（全局 insteadOf 改写）"
    ;;
  rollback)
    unset_insteadof "https://github.com/"
    unset_insteadof "https://gist.github.com/"
    echo "git SSH-only 已撤销"
    ;;
  status)
    rules=$(git config --global --get-regexp '^url\.' 2>/dev/null)
    if [ -n "$rules" ]; then
      echo "当前 insteadOf 规则:"; printf '%s\n' "$rules"
    else
      echo "当前无 insteadOf 规则（git 按 remote 原协议走）"
    fi
    r=$(GIT_SSH_COMMAND="ssh -o ConnectTimeout=8 -o BatchMode=yes" git ls-remote git@github.com:cli/cli.git HEAD 2>&1 | head -1)
    if printf '%s' "$r" | grep -q 'HEAD'; then echo "ssh ls-remote: OK"; else echo "ssh ls-remote: FAIL -> $r"; fi
    ;;
  *)
    echo "usage: $0 apply|rollback|status"; exit 1;;
esac
