---
name: github-network-doctor
description: GitHub 网络故障诊断与修复一体化技能。当 gh CLI（clone/release download/api）、git push/pull、raw.githubusercontent.com 文件下载、安装 GitHub 上的 skill、浏览器访问 github.com 出现超时或连接失败，或怀疑 DNS 污染、SSH 22 端口被封时使用。核心是诊断驱动：先全通道实测，再按最小侵入顺序用脚本修复并复测，杜绝盲目重试和虚假成功。
agent_created: true
---

# GitHub Network Doctor

## 目的

诊断并修复本机到 GitHub 的各条网络通道故障。三条铁律：诊断驱动（每个结论必须来自真实探测输出，禁止凭经验断言）、最小侵入（按干预强度从低到高逐层修复，每层修完即验证）、诚实报告（救不了就明说原因并给替代出路，严禁假装修复成功）。

## 触发场景

- gh 命令超时或连接失败（gh repo clone、gh release download、gh api 等）
- git clone/push/pull 卡住或超时
- raw.githubusercontent.com 下载失败、无法安装 GitHub 来源的 skill
- 浏览器打不开 github.com
- 用户怀疑 DNS 污染或 22 端口封锁，要求"加速 GitHub"

## 工作流（严格按序执行）

### 第 1 步：全通道诊断（只读，不改任何东西）

运行 `scripts/diagnose.sh`（bash 环境；Windows 经 Git Bash）。脚本只输出事实数据，不做判定。

采集面：DNS 解析（github.com / raw.githubusercontent.com / api.github.com / codeload.github.com）、HTTPS 探测（上述域名 + release 资产链路 objects.githubusercontent.com）、SSH 探测（github.com:22 与 ssh.github.com:443）、gh 状态（gh auth status、当前 git_protocol）。

判定基线：

- api.github.com 通 → gh API 健康，api 类操作不该重试
- github.com:22 SSH 通 → git SSH 通道可用，gh clone 可改走 SSH
- DNS 解析出 0.0.0.0，或解析 IP 不在 GitHub 公布段内 → DNS 污染实锤（实时 IP 段：`curl -s https://api.github.com/meta` 的 `git` 字段）
- HTTPS 返回 000 且耗时接近超时值 → 连接被阻断；耗时 <1s 的 000 → DNS 层就失败
- remote_ip=127.0.0.1 → 存在本地拦截器（fake-ip 代理/沙箱 shim），curl 与 nslookup 可能走不同解析路径，两侧对照判读

### 第 2 步：故障分类

按 `references/channels.md` 第一节/第二节的通道矩阵，把第 1 步数据映射到故障域，确定修复路由。禁止跳过分类直接修复。

### 第 3 步：按最小侵入顺序修复（每个 apply 类操作执行前必须向用户说明改动内容并取得同意）

| 故障域 | 脚本 | 说明 |
|---|---|---|
| gh clone / release download 挂，SSH 通 | `scripts/fix_gh_protocol.sh ssh` | 零风险，改回用 `fix_gh_protocol.sh https` |
| git HTTPS 全灭但 SSH 存活 | `scripts/git_ssh_only.sh apply` | 全局 insteadOf 改写，`rollback` 撤销 |
| DNS 污染（github.com / raw 挂，api 通） | `scripts/hosts_repair.sh collect` 先看结果 → 用户确认后 `apply` | 多源候选 + 逐条实测 + 标记块写入 + 自动备份；`rollback` 随时还原，`status` 复验 |
| SSH 22 端口不通，443 通 | `scripts/ssh_over_443.sh apply` | 写 ~/.ssh/config 标记块，带备份，`rollback` 撤销 |
| 下载类临时需求（release、大文件） | `scripts/akams_fetch.sh <URL> -o <输出>` | 社区节点前缀代理竞速；第三方中转，须用户同意后用 |
| 全通道挂 | 不脚本化 | 如实报告，引导 Watt Toolkit 等合法加速工具，不提供任何 VPN 方法 |

hosts 修复引擎为本技能自包含实现（references 第五节有多源 IP 与标记块规范），无需依赖外部 skill。

### 第 4 步：验证

每层修复后重跑 `scripts/diagnose.sh` 同口径对比；配置类修复用各脚本的 `status` 子命令复验。只认实测输出，不认"应该好了"。

### 第 5 步：报告

用大白话向用户说明：哪条通道坏了、根因、做了什么（含具体改动和备份位置）、修复后实测结果。没好就如实说，并给替代出路。

## 安全红线

- hosts / ssh config 写入前必须备份，只写标记块内内容，逐条实测通过才写入，不碰文件中其他行
- 所有修改状态的子命令（apply / set / ssh / https 切换）执行前，先向用户说明改动内容并取得同意
- akams 节点中转、第三方镜像流量，必须明确告知并征得用户同意
- 所有结论必须来自真实工具输出；未探测到的通道标注"未探测"，禁止推断

## 资源

| 文件 | 用途 |
|---|---|
| `scripts/diagnose.sh` | 全通道只读诊断，输出原始数据表 |
| `scripts/fix_gh_protocol.sh ssh\|https\|status` | 切换 gh git 协议并实测 ls-remote |
| `scripts/git_ssh_only.sh apply\|rollback\|status` | git 全局 SSH-only（insteadOf 改写） |
| `scripts/hosts_repair.sh collect\|apply\|rollback\|status` | DNS 污染修复：多源候选 IP + 实测 + 标记块写入 |
| `scripts/ssh_over_443.sh apply\|rollback\|status` | SSH 入口改走 ssh.github.com:443 |
| `scripts/akams_fetch.sh <URL> [-o out]` | akams 节点前缀代理下载，自动竞速 |
| `references/channels.md` | 通道矩阵、故障域映射、IP 源规范、akams 节点状态、ssh-over-443 细节、Watt Toolkit 出路 |
