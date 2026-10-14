# 通道矩阵与修复路由参考

## 一、通道矩阵

| 端点 | 服务谁 | 故障含义 | 修复路由 |
|---|---|---|---|
| api.github.com | gh CLI 全部 api 类操作（gh pr / gh api / gh repo view） | 被污染或阻断 | hosts / 代理 |
| github.com | 浏览器、git HTTPS smart-http、release 跳转第一跳 | 超时 | hosts 修复 |
| raw.githubusercontent.com | raw 文件下载、GitHub 来源 skill 安装 | 秒失败（DNS 投毒常见） | hosts 修复 |
| codeload.github.com | git HTTPS clone 的 pack 下载 | 失败 | hosts 修复 |
| objects.githubusercontent.com | release 资产实际下载 | 失败 | hosts / akams 前缀 |
| github.com:22 | git SSH 推送/拉取、gh clone（SSH 协议时） | 连接失败 | ssh-over-443 |
| ssh.github.com:443 | SSH 备用入口 | — | 仅当 22 被封时启用 |

## 二、故障域映射（症状组合 → 根因）

| 症状组合 | 根因 | 路由 |
|---|---|---|
| api 通 + github.com/raw 挂 | DNS 污染 | gh git_protocol ssh + hosts 修复 |
| api 通 + SSH 22 通 + 仅 gh clone/release 挂 | gh 走 https 踩 github.com | `gh config set git_protocol ssh` |
| raw 解析 0.0.0.0 | DNS 投毒 | hosts 写入真实 IP |
| github.com 解析出非 GitHub 段 IP | DNS 污染（伪 IP） | hosts 写入真实 IP |
| 22 不通 + 443 通 | 端口封锁 | ssh-over-443 |
| 全通道 000 | 需要代理或镜像 | Watt Toolkit / akams |
| 单个通道偶发超时、其余正常 | IP 时效性 / 节点抖动 | 重跑诊断，不盲目重试 |

GitHub 真实 IP 段以 `curl -s https://api.github.com/meta` 的 `git` 字段为准（实时）。常见段：140.82.x.x、20.205.x.x、20.27.x.x。解析结果落在这些段之外（如 0.0.0.0、219.x.x.x）即污染实锤。

## 三、akams 前缀代理（第三方中转，须用户同意）

入口 https://github.akams.cn/ 只作节点列表，直接拼前缀会 404。可用格式：

```
https://<节点>/<原URL含协议>
例: https://github.tbap.top/https://raw.githubusercontent.com/user/repo/main/file.txt
例: https://github.tbap.top/https://github.com/user/repo/archive/refs/heads/main.zip
git clone https://github.tbap.top/https://github.com/user/repo
```

节点实测状态（2026-10-14，本机）：

| 节点 | raw 200 | clone | 备注 |
|---|---|---|---|
| github.tbap.top | 0.9s | 2.7s 成功，内容校验一致 | 首选 |
| gh.dpik.top | 1.2s | 未测 | 可用 |
| ghfile.geekertao.top | 302 | 未测 | 跳转型，可用性差 |

节点为社区贡献，无 SLA，随时可能失效；失效时重测或换节点。适合 release、大文件、临时 clone；不适合需要固定 URL 的场景（如 skill 安装管线）。

## 四、ssh-over-443 配置（仅 22 被封时）

`~/.ssh/config` 追加：

```
Host github.com
  Hostname ssh.github.com
  Port 443
  User git
```

不落配置的临时验证：`ssh -T -p 443 git@ssh.github.com`，返回 "Permission denied (publickey)" 即 TCP 通（认证失败是因为没带匹配密钥，正常现象）。撤销 = 删掉该段。局限：公司代理对 443 做 TLS 中间人拦截时不通；只影响 SSH remote 的仓库，HTTPS remote 不走此路。

## 五、hosts 手动修复要点（hosts_repair.sh 的实现依据）

`scripts/hosts_repair.sh` 已按以下规范实现，手动修时同样遵守：

- 写入前备份 hosts（Windows: C:\Windows\System32\drivers\etc\hosts，需管理员权限；脚本自动定位平台路径，可用 HOSTS_FILE 覆盖）
- 只写标记块内（`# >>> github-network-doctor hosts >>>` ... `# <<< github-network-doctor <<<`），不碰其他行
- IP 候选三源：阿里 DoH（dns.alidns.com/resolve）、DNSPod DoH（doh.pub/dns-query）、GitHub520 hosts（经 akams 节点获取，规避 raw 被墙）
- 逐条实测通过才写入；实测标准：该 IP + 正确 SNI 能完成 TLS+HTTP（200/301/302/400/403/404 均算通）
- raw 全灭时可试用 github.com 同组已通过的 IP（同 IP 池、SNI 区分），仍须逐条实测
- IP 有时效，污染更换后重跑 collect/apply
- 备份保留 3 份（*.gnd-bak.*），rollback 移除标记块

## 六、github-accelerator skill（majiabin2020/github-accelerator，MIT）——可选替代

本技能的 hosts 修复为自包含实现，accelerator 是同类替代而非依赖。用户明确要求或想对比时再引入。

```
# macOS / Linux
bash scripts/accelerate.sh check     # 只读诊断
bash scripts/accelerate.sh apply     # 诊断+修复（sudo）
bash scripts/accelerate.sh rollback  # 一键回滚

# Windows
powershell -ExecutionPolicy Bypass -File scripts\accelerate.ps1 check
powershell -ExecutionPolicy Bypass -File scripts\accelerate.ps1 apply
powershell -ExecutionPolicy Bypass -File scripts\accelerate.ps1 rollback
```

注意：直连失败时它会配置 git 走第三方公益镜像（如 ghfast.top）中转下载，须用户同意；Windows 版为 beta；写入 hosts 前自动备份（保留 3 份）。

## 七、gh 协议切换与 git SSH-only

```
gh config set git_protocol ssh     # clone 走 SSH，绕开 github.com（脚本 fix_gh_protocol.sh 已包装）
gh config set git_protocol https   # 改回

git config --global url."git@github.com:".insteadOf "https://github.com/"      # git_ssh_only.sh apply
git config --global url."git@gist.github.com:".insteadOf "https://gist.github.com/"
git config --global --unset url."git@github.com:".insteadOf                    # rollback
```

## 八、脚本速查

| 脚本 | 子命令 | 是否改状态 |
|---|---|---|
| diagnose.sh | 无（全量只读） | 否 |
| fix_gh_protocol.sh | ssh / https / status | ssh、https 改 gh 配置 |
| git_ssh_only.sh | apply / rollback / status | apply 改 git 全局配置 |
| hosts_repair.sh | collect / apply / rollback / status | apply、rollback 写 hosts |
| ssh_over_443.sh | apply / rollback / status | apply 写 ~/.ssh/config |
| akams_fetch.sh | `<URL> [-o out]` | 只写输出文件 |

所有 apply 类操作执行前须向用户说明改动内容并取得同意（用户硬规则）。

## 九、全通道挂死时的出路

如实报告，引导合法工具：Watt Toolkit（Windows 走微软商店官方上架 / macOS 官网国内直连）、或用户自有代理。不提供任何 VPN 方法，不假装修复成功。
