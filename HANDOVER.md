# HANDOVER —— LTT 多特服插件：交接与运维手册

> 给接手的人（同样用 **DSH / DeepSeek Harness** 管服）看的一份「10 分钟上手 + 踩坑清单」。
> 源码在 `plugins/`，本文件讲**怎么改、怎么发、怎么查、别踩什么坑**。

---

## 一、这是什么

一套 L4D2 多特（对战特感）服务器的 SourceMod 插件源码，前缀统一 `ltt_`。
每个插件都是**单文件**，依赖 SourceMod **1.12.x**，部分依赖 `left4dhooks 1.168`。

插件清单见 `README.md` 的表（版本号从源码里自动抽取）。

> 📄 **另附一份 `docs/设计稿_v3_脱敏.md`**（1.2 MB / 1.6 万行）——这是这套服务器从零到现在的
> **完整设计与踩坑过程记录**：每个决策为什么这么定、每次事故怎么取证、每轮改动实测了什么数据。
> **已脱敏**（rcon 密码与服务器 IP 全部换成 `<RCON_PW>` 这类占位符，正文一字未改）。
> **想快速上手看本文件；想弄明白「为什么这么设计」就查设计稿。**

---

## 二、用 DSH 管服的推荐工作流

DSH 的价值在于：**你说目标，它去 SSH 上编译、上传、重载、查日志、验数据**。
但前提是给它两样东西：**SSH 别名** 和 **三个小工具脚本**（本仓库不含，因为里面有服务器凭据）。

### 2.1 需要准备的三个脚本（接口约定）

| 脚本 | 用法 | 作用 |
|---|---|---|
| `ssh_run.js` | `node ssh_run.js [--sudo] <别名> "<命令>"` | 在远端执行命令 |
| `ssh_put.js` | `node ssh_put.js <别名> <本地文件> <远端路径>` | 上传（**自动留 `.bak-<时间戳>`**） |
| `ssh_download.js` | `node ssh_download.js <别名> <远端文件> <本地路径>` | 下载 |

> 凭据放本地 `secrets.env`（已在 `.gitignore`），**不要入库**。

### 2.2 源码 → 上线，标准四步

```bash
# 1) 编译（SourceMod 1.12 的 spcomp；本工程要求 0 错 0 警）
spcomp plugins/ltt_kd/ltt_kd.sp -o ltt_kd.smx -i <sm>/scripting/include

# 2) 上传（ssh_put 会自动备份旧文件）
node ssh_put.js <别名> ltt_kd.smx /path/left4dead2/addons/sourcemod/plugins/ltt_kd.smx

# 3) 热重载（不重启、不踢人）
node ssh_run.js <别名> 'python3 /path/rcon_min.py 127.0.1.1 <端口> <rcon密码> "sm plugins reload ltt_kd"'

# 4) 验证（版本 + 失败数 + 今天的 errors 日志）
node ssh_run.js <别名> '<rcon> "sm plugins list" | grep -i kd'
```

### 2.3 三条铁律（吃过亏总结的）

1. **每次改动都留回滚点**：上传自动生成 `.bak-<时间戳>`；改配置先 `cp x.cfg x.cfg.bak-<时间戳>`。
2. **改完必须实测验证**：查插件列表版本、查 cvar 实际值、查当天 `errors_<日期>.log`。
   *"应该好了"不算交付。*
3. **记录 md5 与版本号**（`md5sum *.smx`）——两台服务器之间**逐文件比对 md5** 是最可靠的同步校验方式。

---

## 三、日志在哪、怎么看

| 日志 | 路径 | 用途 |
|---|---|---|
| SourceMod 主日志 | `addons/sourcemod/logs/L<YYYYMMDD>.log` | **按天切**。所有插件的 `LogMessage` 都在这（刷特/投票/团灭/守卫…） |
| 插件错误 | `addons/sourcemod/logs/errors_<YYYYMMDD>.log` | 异常与 `SetFailState`，**部署后必看** |
| 专用投票日志 | `addons/sourcemod/logs/ltt_svote.log` | 一行一次投票（发起人+SteamID / 类型 / 票数 / 结果）。插件内 `sm_vtlog` 看最近 15 条 |
| 引擎日志 | `left4dead2/logs/L127_*.log` | 回合/死亡/换图/`Round_Start`/`Survivors_Dead` 等引擎事件 |

**排查玩家的"感觉不对"时，先把引擎日志和 SM 日志按同一个时间点对齐看** —— 我们的每次关键决策都写了带时间戳的日志。

---

## 四、踩坑清单（按"再遇到就省两小时"排序）

### 4.1 c2m2「重开就 0 秒团灭」——已修，但要懂原理

**症状**：c2m2_fairgrounds 团灭后每 ~7 秒一轮 `本局计时 0:00`、`特感0 僵尸0 友伤0`，直到有人重载地图。

**根因**（引擎日志铁证）：回合重启时引擎走 `Restoring player … after changelevel`，
把「已死」状态塞回来，**同一秒**就触发 `L4D_Scenario_Survivors_Dead` → `Round_End`。
关键点是：**`round_start` 钩子跑在这次注入之前**，所以在 `round_start` 里无论怎么判据都抢不到。

**修法**：`ltt_level_heal` **v1.7.0** 的 `OnGameFrame()` **帧级看门狗** —— `round_start` 后开 2 秒窗口，
每游戏帧检查 `!IsPlayerAlive || m_isGoingToDie != 0`，命中当场复活+补血。实测**每次都第 1 帧抢到**。
- 开关：`ltt_levelheal_watch`（默认 1，**这是修复本体，别关**）／`watch_window`（默认 2.0 秒）

> **教训**：当"钩子明明挂了、条件明明该命中，却一次都没打印"时，**第一件事是打快照日志**，
> 而不是继续加判据。我们在这上面白做两个版本。

### 4.2 `sb_all_bot_game` 是 cheat cvar

普通 `rcon` 读它会被拒（`Can't use cheat cvar … unless sv_cheats 1`），必须用 **`sm_cvar <名字>`** 读。

### 4.3 rcon 只绑内网

服务端 rcon 只监听 `127.0.1.1`。用 `127.0.0.1` 或局域网 IP 都连不上 —— 别在这上面浪费时间。

### 4.4 Steam 跨境抖动 → 玩家「会话不可用」/ 服务器在列表里消失

**表现**：`steamcommunity.com`/`store.steampowered.com` 超时，但 `api.steampowered.com` 正常；
玩家点进服报**「会话不可用」**。

**原因**：服务器设了 `sv_allow_lobby_connect_only 1`（只认 Steam 大厅），大厅那侧断了 ⇒ 大厅条目失效。

**解法**（二选一）：
- 临时：`sm_cvar sv_allow_lobby_connect_only 0` 放开直连（`connect IP:端口` 即可进）
- 永久：把 `cfg/server.cfg` 里那行改成 `0`（代价：路人匹配进来会显示「正在加入一场游戏」而非「战役模式」）

### 4.5 `pkill -f "srcds_linux.*port 22330"` 会**杀掉自己的 SSH 会话**

因为这条 SSH 命令行里本身就含这个模式。**用中括号断开自匹配**：`pkill -f "srcds_lin[u]x"`。

### 4.6 其他小坑

- `sm plugins list` 里**只显示文件名**（没有版本/作者）= 该插件**没写 `myinfo`**，不是加载失败。
- 插件编译要 **0 错 0 警**：删掉函数/变量后会报 `warning 203/204（未使用符号）`，**连同函数一起删干净**。
- `HookEvent` 返回 void，要判断事件是否存在得用 **`HookEventEx`**。
- 换图让 `GetGameTime()` 归零：跨图比较时间戳前记得清零缓存（我们踩过"负间隔 -44.8 秒"）。

---

## 五、注意事项

- **密钥不入库**：本仓库的源码已验证**不含**任何 rcon 密码 / 服务器 IP；
  运维脚本与内部设计稿**不要**放进这个仓库（它们含凭据）。
- **第三方插件不在本仓库**（见 `NOTICE.md`）：AlliedModders 各家作者、`豆瓣酱な` 的插件源码版权归原作者；
  我们**改过**的少数第三方插件属衍生作品，也另行单独提供。
- 改别人的插件前，先读它的**头注释**：我们习惯在头注释里写"为什么这么写 / 踩过什么坑"。
