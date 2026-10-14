#!/usr/bin/env bash
# hosts_repair.sh — DNS 污染修复：多源候选 IP + 逐条实测 + 标记块写入 + 备份回滚
#
# usage:
#   bash hosts_repair.sh collect    # 只收集并实测候选 IP，不写任何文件（只读）
#   bash hosts_repair.sh apply      # 写入 hosts 标记块（需要管理员 / sudo）
#   bash hosts_repair.sh status     # 查看标记块内容并复验其中每个 IP
#   bash hosts_repair.sh rollback   # 移除标记块（备份文件保留）
#
# 环境变量:
#   HOSTS_FILE  覆盖 hosts 路径（测试用；默认按平台自动定位）
#   DOMAINS     覆盖域名列表（空格分隔）
#
# IP 候选源：阿里 DoH / DNSPod DoH / GitHub520（经 akams 节点获取，raw 被墙时用）
# 实测标准：以该 IP + 正确 SNI 能完成 TLS+HTTP（200/301/302/400/403/404 均算通）
set -u

MARK_BEGIN="# >>> github-network-doctor hosts >>>"
MARK_END="# <<< github-network-doctor <<<"

if [ -n "${HOSTS_FILE:-}" ]; then
  HOSTS="$HOSTS_FILE"
elif uname -s | grep -qiE 'mingw|msys|cygwin'; then
  HOSTS="C:/Windows/System32/drivers/etc/hosts"
else
  HOSTS="/etc/hosts"
fi

DOMAINS="${DOMAINS:-github.com gist.github.com api.github.com codeload.github.com raw.githubusercontent.com assets.githubusercontent.com}"

doh_ali()    { curl -s --max-time 6 "https://dns.alidns.com/resolve?name=$1&type=A" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}'; }
doh_dnspod() { curl -s --max-time 6 -H "accept: application/dns-json" "https://doh.pub/dns-query?name=$1&type=A" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}'; }
gh520()      { curl -s --max-time 12 "https://github.tbap.top/https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts" 2>/dev/null | awk -v d="$1" '$2==d{print $1}'; }

is_private() { case "$1" in 0.0.0.0|127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*) return 0;; *) return 1;; esac; }

verify_ip() { # $1=domain $2=ip；必须 --noproxy：代理环境下 --resolve 不生效（CONNECT 走代理主机名），且 hosts 生效后系统本就是直连
  local code
  code=$(curl --noproxy '*' -o /dev/null -s -w "%{http_code}" --max-time 5 --resolve "$1:443:$2" "https://$1/" 2>/dev/null)
  case "$code" in 200|301|302|400|403|404) return 0;; *) return 1;; esac
}

# gather：对每个域名收集候选并实测，输出 "domain ip1 ip2 ..."（无可用 IP 时行尾为空）
gather() {
  local d cands ip n ok
  for d in $DOMAINS; do
    cands=$( { doh_ali "$d"; doh_dnspod "$d"; gh520 "$d"; } 2>/dev/null \
             | awk '!s[$0]++' )
    ok=""; n=0
    for ip in $cands; do
      is_private "$ip" && continue
      [ "$n" -ge 6 ] && break
      n=$((n+1))
      if verify_ip "$d" "$ip"; then ok="$ok $ip"; fi
    done
    printf '%s %s\n' "$d" "${ok# }"
  done
}

print_report() { # stdin: gather 输出；用词拆分代替 cut（read 会剥掉行尾空格，cut -f2- 会退化为整行）
  local line d ips
  while read -r line; do
    set -- $line; d="$1"; shift; ips="$*"
    if [ -n "$ips" ]; then
      printf '%-32s %s\n' "$d" "$ips"
    else
      printf '%-32s %s\n' "$d" "(无可用 IP)"
    fi
  done
}

remove_block() {
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" \
    '{ if (index($0,b)) skip=1; else if (index($0,e)) skip=0; else if (!skip) print }' "$1"
}

case "${1:-status}" in
  collect)
    echo "== 候选 IP 收集与实测（只读，不写文件）=="
    echo "实测走直连(--noproxy)，模拟 hosts 生效后的系统路径；在 WorkBuddy 沙箱内运行时直连出口为沙箱网络，与真实环境可能有差异"
    gather | print_report
    ;;
  apply)
    [ -f "$HOSTS" ] || { echo "hosts 文件不存在: $HOSTS"; exit 1; }
    [ -w "$HOSTS" ] || { echo "无写权限（$HOSTS）。Windows 请以管理员身份重开终端，macOS/Linux 请用 sudo 重跑。"; exit 1; }
    echo "== 收集并实测候选 IP =="
    RESULTS=$(gather)
    printf '%s\n' "$RESULTS" | print_report
    if ! printf '%s\n' "$RESULTS" | grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}'; then
      echo "没有任何域名实测通过，放弃写入（诚实原则：不写救不了的东西）"; exit 1
    fi
    BAK="$HOSTS.gnd-bak.$(date +%Y%m%d-%H%M%S)"
    cp "$HOSTS" "$BAK" && echo "已备份: $BAK"
    ls -1t "$HOSTS".gnd-bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f
    NEW="$HOSTS.gnd-new"
    remove_block "$HOSTS" > "$NEW"
    {
      echo "$MARK_BEGIN"
      echo "# 由 github-network-doctor 于 $(date '+%Y-%m-%d %H:%M:%S') 写入；执行 hosts_repair.sh rollback 或删除本段还原"
      printf '%s\n' "$RESULTS" | while read -r line; do
        set -- $line; d="$1"; shift; ips="$*"
        if [ -n "$ips" ]; then
          for ip in $ips; do printf '%s %s\n' "$ip" "$d"; done
        else
          echo "# $d: 无可用 IP，未写入"
        fi
      done
      echo "$MARK_END"
    } >> "$NEW"
    mv "$NEW" "$HOSTS"
    echo "已写入 $HOSTS。如系统缓存 DNS，请执行 ipconfig /flushdns（Windows）或 sudo dscacheutil -flushcache（macOS）"
    echo "验证: bash diagnose.sh"
    ;;
  rollback)
    [ -f "$HOSTS" ] || { echo "hosts 文件不存在: $HOSTS"; exit 1; }
    if grep -qF "$MARK_BEGIN" "$HOSTS"; then
      [ -w "$HOSTS" ] || { echo "无写权限，请管理员/sudo 重跑"; exit 1; }
      cp "$HOSTS" "$HOSTS.gnd-bak.$(date +%Y%m%d-%H%M%S)"
      remove_block "$HOSTS" > "$HOSTS.gnd-new" && mv "$HOSTS.gnd-new" "$HOSTS"
      echo "标记块已移除（回滚前状态已备份）"
    else
      echo "未发现本技能写入的标记块，无需回滚"
    fi
    ;;
  status)
    if grep -qF "$MARK_BEGIN" "$HOSTS" 2>/dev/null; then
      echo "== hosts 中的本技能标记块 =="
      sed -n "/$(printf '%s' "$MARK_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[][\.*^$/]/\\&/g')/p" "$HOSTS"
      echo "== 逐条复验 =="
      sed -n "/$(printf '%s' "$MARK_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[][\.*^$/]/\\&/g')/p" "$HOSTS" \
        | awk 'NF==2 && $1 ~ /^[0-9.]+$/ {print $2, $1}' \
        | while read -r d ip; do
            if verify_ip "$d" "$ip"; then echo "OK   $ip $d"; else echo "FAIL $ip $d"; fi
          done
    else
      echo "hosts 中无本技能标记块（未修复或已回滚）"
    fi
    ;;
  *)
    echo "usage: $0 collect|apply|rollback|status"; exit 1;;
esac
