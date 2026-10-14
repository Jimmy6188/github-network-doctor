#!/usr/bin/env bash
# ssh_over_443.sh — SSH-over-443：github.com 的 SSH 入口改到 ssh.github.com:443
# 仅用于 22 端口被封的场景；写入 ~/.ssh/config 标记块，带备份，可回滚
# usage: bash ssh_over_443.sh apply|rollback|status
set -u

MARK_BEGIN="# >>> github-network-doctor ssh-over-443 >>>"
MARK_END="# <<< github-network-doctor ssh-over-443 <<<"
SSH_DIR="${HOME}/.ssh"
SSH_CFG="${SSH_DIR}/config"

remove_block() { # stdin: file content -> stdout: block removed
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" \
    '{ if (index($0,b)) skip=1; else if (index($0,e)) skip=0; else if (!skip) print }'
}

case "${1:-status}" in
  apply)
    mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR" 2>/dev/null
    [ -f "$SSH_CFG" ] && cp "$SSH_CFG" "${SSH_CFG}.gnd-bak.$(date +%Y%m%d-%H%M%S)"
    { [ -f "$SSH_CFG" ] && remove_block < "$SSH_CFG"
      printf '%s\nHost github.com\n  Hostname ssh.github.com\n  Port 443\n  User git\n%s\n' "$MARK_BEGIN" "$MARK_END"
    } > "${SSH_CFG}.gnd-new"
    mv "${SSH_CFG}.gnd-new" "$SSH_CFG"
    chmod 600 "$SSH_CFG" 2>/dev/null
    echo "ssh-over-443 已写入 $SSH_CFG（原配置已备份为 .gnd-bak.*）"
    ;;
  rollback)
    if [ -f "$SSH_CFG" ] && grep -qF "$MARK_BEGIN" "$SSH_CFG"; then
      remove_block < "$SSH_CFG" > "${SSH_CFG}.gnd-new"
      mv "${SSH_CFG}.gnd-new" "$SSH_CFG"
      echo "ssh-over-443 配置块已移除"
    else
      echo "未发现本技能写入的配置块，无需回滚"
    fi
    ;;
  status)
    if [ -f "$SSH_CFG" ] && grep -qF "$MARK_BEGIN" "$SSH_CFG"; then
      echo "已配置:"; sed -n "/$(printf '%s' "$MARK_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[][\.*^$/]/\\&/g')/p" "$SSH_CFG"
    else
      echo "未配置 ssh-over-443"
    fi
    r=$(ssh -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=no -T -p 443 git@ssh.github.com 2>&1 | head -1)
    case "$r" in
      *"successfully authenticated"*) echo "ssh.github.com:443 实测: OK (authenticated)";;
      *"Permission denied"*)          echo "ssh.github.com:443 实测: TCP 通（认证被拒属正常，说明没带匹配密钥）";;
      *)                              echo "ssh.github.com:443 实测: $r";;
    esac
    ;;
  *)
    echo "usage: $0 apply|rollback|status"; exit 1;;
esac
