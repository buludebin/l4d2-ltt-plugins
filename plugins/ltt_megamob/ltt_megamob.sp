/**
 * =====================================================================================
 *  [LTT] Mega Mob（机关尸潮可调）—— 独立插件 v1.0.0
 * =====================================================================================
 *
 * 车主 2026-10-07 裁决：「机关尸潮可调」→ 明确要求 **直接独立一个插件**
 *（不并进 ltt_si_spawner：刷特插件已经 8100+ 行，尸潮强度是另一件事，独立才好单独卸、单独回滚）。
 *
 * ------------------------------------------------------------------ 一、它管什么
 *
 * 只改 L4D2 引擎的"大尸潮（mega mob）"三个 cvar —— 也就是**机关/事件尸潮**那一套：
 *
 *   | cvar                            | 引擎默认 | 含义                                     |
 *   |---------------------------------|---------|------------------------------------------|
 *   | z_mega_mob_size                 | 50      | 一次机关尸潮刷多少只普通感染者            |
 *   | z_mega_mob_spawn_min_interval   | 420     | 两次 mega mob 之间的最小间隔（秒）        |
 *   | z_mega_mob_spawn_max_interval   | 900     | 两次 mega mob 之间的最大间隔（秒）        |
 *
 * ⚠ 刻意**不碰**的（另一套，别混）：
 *   · z_mob_spawn_min_size / max_size（10/30）= 普通小尸潮（boomer 呕吐 / 游荡群）的规模；
 *   · z_common_limit（本服 20，引擎默认 30）、z_background_limit（本服 12，默认 20）——
 *     这两个是**车主自己写在 server.cfg 里**的，本插件不许覆盖；
 *   · z_mob_population_density（0.0064）同上。
 *   要扩到普通尸潮，照 ApplyMegamob() 里那三行加即可（cvar 名换成 z_mob_spawn_*）。
 *
 * ------------------------------------------------------------------ 二、四个档位
 *
 *   `ltt_megamob_mode`：
 *     0 = 原版（引擎默认 50 只 / 420~900 秒）—— **默认值，装上什么都不改**
 *     1 = 减半（25 只，间隔不变）
 *     2 = 关闭（0 只）—— z_mega_mob_size=0 是引擎接受的合法值（2026-10-07 已在服上实测：
 *         设 0 能读回 0，设回 50 也能读回 50）
 *     3 = 自定义（数量/最小间隔/最大间隔各自取 ltt_megamob_size / _min_interval / _max_interval）
 *
 *   `sm_megamob` 打开菜单选档（ADMFLAG_GENERIC），选完立刻生效并写回 cfg。
 *
 * ------------------------------------------------------------------ 三、为什么必须"每次开图重设"
 *
 * 同 ltt_si_spawner 踩过的坑（见那份文件头 v1.37.0 注释）：`z_*` 这类 **cheat cvar 会被引擎
 * 在地图初始化时重置回默认值**，写进 cfg 也保不住。所以本插件在
 *   OnPluginStart / OnMapStart / OnConfigsExecuted / 开图+1 秒 / 开图+6 秒
 * 五个点各套用一次，并每次打一行日志 —— **"装上了但没生效"是这类插件最典型的失败方式**，
 * 日志里必须能一眼看到它到底设成了多少。
 *
 * ------------------------------------------------------------------ 四、落档
 *
 * 每次套用打一行：`[MegaMob] v1.0.1 套用（开图）：档位=原版 z_mega_mob_size 50→50｜
 * 间隔 420~900（引擎会不会重置：本插件每图重设）`。
 * 档位写到 `cfg/sourcemod/ltt_megamob.cfg`（AutoExecConfig 生成，选档后插件自己重写），换图重载重启都不丢。
 *
 * ------------------------------------------------------------------ 五、v1.0.1 修复：换图就回原版
 *
 * v1.0.0 实测（2026-10-07 14:16）：菜单改成"关闭"当场生效（z_mega_mob_size 真的变 0），
 * 但 changelevel 之后 mode 又变回 0、size 变回 50。原因：`AutoExecConfig` 只在文件**不存在**时
 * 生成、之后只补**缺失**的 cvar，**不更新已有行的值** ⇒ 文件里永远是装载那一刻的 mode=0，
 * 换图 exec 一次就把运行时选的档覆盖掉，**菜单等于白选**。
 * 修法：选档后插件自己用当前值重写那个 cfg（延后 0.5 秒，避开"正在 exec 时把它重写"）。
 *
 * ------------------------------------------------------------------ 六、v2.0.0 真正的需求：机关事件尸潮【固定总量】
 *
 * 车主 2026-10-07 补充原话：「这个是要机关事件固定尸潮的功能，就是比如说机关开启原版默认刷 XX 只，
 * 然后就只刷这么多后续不再补充」。
 * ⇒ v1.0.x 改的 `z_mega_mob_size` 只是机关**单次规模**，管不住"后续一波波补充"——补充是引擎
 *   在机关事件期间**反复调用 `ZombieManager::SpawnMob`** 往待生成队列里加人造成的。
 *
 * 拦法（全部用本服 Left4DHooks 1.168 的现成 native，**不需要 gamedata、不猜事件名、不加依赖**）：
 *   · `L4D_OnSpawnMob(int &amount)`：机关/恐慌事件尸潮、自然定时尸潮、onslaught 都走这里。
 *     （`z_spawn mob` 与 Boomer 呕吐走 `L4D_OnSpawnITMob`，是另一套 —— 本插件**刻意不动 Boomer**。）
 *   · 怎么分清"机关"和"自然小尸潮"：**看 amount**。
 *     自然尸潮规模 = `z_mob_spawn_min_size..max_size`（本服 10~30）；
 *     机关 mega mob 规模 = `z_mega_mob_size`（原版 50）。
 *     ⇒ `amount > z_mob_spawn_max_size` 判为机关。两者之间有 20 的间隔，不会两边踩线；
 *       阈值读的是**服上实时 cvar**，不是我记的数。
 *   · 「原版刷 XX 只」的 XX = **该次机关第一次 SpawnMob 的 amount**（引擎自己给的，插件不猜）；
 *     默认 `ltt_megamob_limit = -1` 就用它 ⇒ 车主不需要配任何数字。
 *   · 之后每次补充：余量够 → 原样放；给多了 → **只放余量**（Plugin_Changed）；
 *     余量为 0 → **整笔拦掉**（amount=0 + Plugin_Handled）。⇒ 总量钉死在 XX，一只不多。
 *   · **默认不清空待生成队列**（horde_equaliser 会 `SetPendingMobCount(0)`，但那会把原版那 XX 只里
 *     还没刷出来的部分一起抹掉 ⇒ 实际刷不满）。要那种"硬停"可开 `ltt_megamob_clearpending 1`。
 *   · 事件窗口：出现一次机关排队即开窗；每 1 秒巡检，`eventgap`(默认 25) 秒内没有任何尸潮排队
 *     就判本次机关结束并结算 ⇒ **同图第二、第三个机关各自重新算 XX**
 *     （horde_equaliser 的计数器只在 round_start 重置，等于"一局只算一次"，这是我们的改进）。
 *
 * ⚠ 本功能**没能在服上做真人实测**：机关必须由生还者触发，而实装时服务器 0 玩家 0 bot
 *   （空服不补 bot，`sm_sispawn_burst` 回"没有生还者可作目标"）。所以：
 *   · 默认 `ltt_megamob_act 1`（车主明确要这个功能，装上就该生效）；
 *   · 但每次开窗/放行/截断/拦截/结算都**打日志**，第一个机关跑完就能从日志核对 XX 与原版是否一致；
 *   · 异常时一条命令即可停：`ltt_megamob_act 0`（只记录不拦）或 `ltt_megamob_finite 0`（完全关）。
 *
 * ------------------------------------------------------------------ 七、v2.1.0 对齐 anne 那台服的"有限尸潮"
 *
 * 车主 2026-10-07 贴了另一台服（anne服药役）的实况：
 *   `<尸潮> 一场有限尸潮开始了！本轮共有150个普通感染者！是冲还是等，你来决定！`（地图 C2M4）
 * 问"我们大概能做到吗"。⇒ 能。那条文案就是 l4d2_horde_equaliser 的 `FiniteEventStarted`，
 * 它的 **150 来自地图包 mission 文件里的 `horde_limit`**（竞技图自带该字段）；我们的官方图没有，
 * 所以本版补上两件事：
 *   ① **按图限量**：`cfg/sourcemod/ltt_megamob_maps.cfg`，一行一个图（`c2m4_barns 150`）。
 *      优先级 **按图文件 > `ltt_megamob_limit`**（-1=自动=原版那次量｜0=不限｜>0=固定）。
 *      文件不存在会自动生成模板；**每图重读一次**⇒改完换图即生效，不用重载插件。
 *   ② **玩家播报**（`ltt_megamob_announce`，默认 1）：
 *      开始 → `一场有限尸潮开始了！本轮共有 N 个普通感染者！是冲还是等，你来决定！`
 *      每过 1/4 → `还剩 N 个普通感染者！`（数的是**实际刷出来**的 infected）
 *      结束 → `本轮 N 只普通感染者已全部处理完！`
 *   · ⚠ 限量以**排队量**为准（精确），播报的"还剩"以**实际刷出量**为准 —— 两者口径不同是故意的：
 *     排队量决定"一共放多少"，实际刷出量决定"玩家还欠几只"。
 *   · ⚠ 本服 `z_common_limit=20`（车主自己调的，引擎默认 30）⇒ 150 只的尸潮是**分批**涌出的，
 *     场上同时最多 20 只左右，杀掉才补下一批 —— 这正是"有限尸潮"该有的样子。
 *
 * ------------------------------------------------------------------ 八、v2.2.0 三方图（自定义地图）支持
 *
 * 车主 2026-10-07 问「三方图的机关尸潮能控制吗」。⇒ **能**，机制与地图无关：
 *   · `L4D_OnSpawnMob` 是**引擎级** forward（钩 `ZombieManager::SpawnMob`），任何地图的机关尸潮都走它；
 *   · 按图限量按**短图名**匹配（`status`/`sm_map` 显示的那个名字），三方图写进去就生效；
 *   · 实测本图命中已在上线时验证（`ltt_megamob_maps.cfg` 的 c2m4_barns 命中）。
 *
 * 三方图会遇到、官图不会遇到的两个坑，本版都给了工具：
 *   ① **图名带 `_m1/_m2/...`**（三方战役十几张图一张张写很烦）
 *      ⇒ 支持**通配前缀**：`l4d_tgxl* 150` 一行覆盖整张战役。
 *   ② **机关排队的量不大**（有的三方图机关只排 20~30 只）
 *      ⇒ 那样会被 `amount > z_mob_spawn_max_size(=30)` 误判成"自然小尸潮"而放过。
 *      解决：`ltt_megamob_natmax` 手动覆盖阈值（先看 `verbose` 日志里该图机关的实际 amount 再定，
 *      例如它排 24 就设 15）。⚠ 调太低会把自然小尸潮也当机关，所以默认不动、按图按需调。
 *
 * 另外：能不能控住，还取决于**该图的机关是不是走引擎尸潮队列**。
 *   绝大多数三方图用的是标准 panic event（走 SpawnMob）⇒ 能控；
 *   极少数图用 `point_template`/`env_entity_maker` 直接刷 `infected`、或自写脚本绕开队列 ⇒ 那类控不到。
 *   判断办法：开 `verbose 1`，触发该图机关时看日志有没有 `SPAWNMOB` 行 —— 有就能控，没有就是绕开了引擎队列。
 *
 * 新增命令：`sm_megamob_reload`（改完按图限量文件**不用换图**，立刻重读并回显本图命中）。
 *
 * ------------------------------------------------------------------ 九、v2.3.0 **判定方式被实测推翻并重做**
 *
 * 车主 2026-10-07 进服实测（c2m4_barns，真人局）：**聊天框没有任何尸潮提示**。
 * 拉日志一看，v2.2.0 的"比数量"判定**全军覆没**：
 *   ```
 *   SPAWNMOB amount=30 自然上限=30 判定=自然 窗口=关 队列=30      ← 每秒一发
 *   SPAWNMOB amount=30 自然上限=30 判定=自然 窗口=关 队列=30        连了十几秒
 *   SPAWNMOB amount=10 自然上限=30 判定=自然 窗口=关 队列=60
 *   ```
 * **机关期间引擎每秒调一次 SpawnMob、每次正好 30 只**（待生成队列稳定在 30）——这就是
 * "无限补充"的真身；而 **30 恰好等于 `z_mob_spawn_max_size`** ⇒ `30 > 30` 为假，
 * **每一次都被当成自然尸潮放过**，所以既没播报也没拦截。
 *
 * ⇒ 判定改为**连续排队频率**（本版核心改动）：
 *   · 自然尸潮 = 几分钟才一发的**单发**调用；
 *   · 机关/无限尸潮 = **连续每秒一发**（实测 1 秒 vs 几分钟，区分度极高）；
 *   · `ltt_megamob_eventwin`（默认 5 秒）：距上次 SpawnMob ≤ 它 ⇒ 判为机关事件并开窗。
 * ⇒ `ltt_megamob_limit = -1`（默认）的含义随之改为 **不限（原版）**：
 *   引擎单次给的 30 不是"XX 总量"，拿它当上限会把总量错设成 30（比原版还少）。
 *   **要限量就写按图文件**（`c2m4_barns 150`）**或把 limit 设成正数**。
 * ⇒ 顺带把日志节流：机关每秒一发，逐条打会把日志刷爆（实测 14 秒 32 行）。
 *
 * ------------------------------------------------------------------ 十、v2.3.2 上限判据再修正（**必须数实际刷出，不能累加 amount**）
 *
 * v2.3.1 上线后车主实测：播报出来了（`一场有限尸潮开始了！…150` → `113 个…剩余`，节奏与 anne 完全一致），
 * 但**"之后就没刷了"** —— 尸潮断在 37 只。日志（2026-10-07 14:45）：
 *   ```
 *   14:45:08 机关事件开始（连续排队间隔 1.0s ⇒ 判为机关）｜上限 150
 *   14:45:08 放行 +30 → 已放 90/150 ｜队列=14
 *   14:45:09 放行 +30 → 已放 120/150｜队列=30
 *   14:45:10 放行 +30 → 已放 150/150｜队列=30     ← 3 秒就把 150 "用光"
 *   14:45:32 拦截补充…累计拦 660 只｜队列=17
 *   14:46:54 拦截补充（第 50 发）…队列=0          ← 队列排空 ⇒ 尸潮断供
 *   ```
 * **`amount` 是"补货量"，不是"总量预算"**：引擎每秒补 30、让队列水位稳定在 30 左右；
 * 把 amount 累加 ⇒ 几秒内凑满上限 ⇒ 连"保水位"的补货都被拦掉 ⇒ 尸潮提前断。
 * v2.3.2 改为 **`实际刷出 + 已在待生成队列 ≥ 上限` 才拦**（horde_equaliser 用的也是"数刷出来的"）：
 * 队列可以一直保水位，直到"已刷 + 在队列"真的够 150 才停止补货 ⇒ 恰好 150 只。
 * 同时去掉"部分截断"（截断会把水位掐死）。
 *
 * ------------------------------------------------------------------ 十一、v2.5.0 **全部地图适配（不用一张张配）**
 *
 * 车主 2026-10-07：「控制尸潮的能不能做全部地图适配这样，因为未来会打什么三方图不固定，
 * 每个图都单独适配有点麻烦」。
 * ⇒ 本版把**全局默认**打开，做到"装上就对每一张图生效，一行都不用写"：
 *   ① `ltt_megamob_limit` 默认从 **-1（不限）改成 150** —— 它是**所有地图的全局默认上限**，
 *      任何图（官图 + 以后新加的三方图）只要没有单独条目就吃这个数。
 *      ⚠ 因为引擎原版机关是"无限补货"，150 只会**减少**、不会增加尸潮 ⇒ 对未知图也不会失控。
 *      想改：一条命令 `ltt_megamob_limit 120` 全图生效（会写进 cfg）。
 *   ② `ltt_megamob_eventwin` 默认从 **5 秒放宽到 15 秒** —— 未知三方图的补货节奏可能没那么密，
 *      按图调太麻烦；自然尸潮是几分钟一发，放到 15 秒仍不会误判。
 *   ③ 按图文件 `ltt_megamob_maps.cfg` 从此**只写例外**（某张图想用别的数），
 *      并支持 `* <数字>`（给所有未单写的图另一个统一值）与通配前缀 `bdp_bunker* 200`。
 *   ⇒ 结论：**默认零配置覆盖全部地图**；要精细再逐图写。
 *
 * ------------------------------------------------------------------ 十二、v2.6.0 坦克期间暂停尸潮（车主指定「一定要加」）
 *
 * 来源：`D:\#2\#2 jsmod\JS-MODS\L4d2_plugins-main-dong\...\未分类\l4d2_horde_equaliser.sp`
 *（旧 Anne 服那份中文版，作者 Visor / A1m`，`l4d2_heq_no_tank_horde` 默认 1）里的这段：
 *   ```
 *   if ((hCvarNoEventHordeDuringTanks.BoolValue || commonTank > 0) && IsTankUp() && IsInfiniteHordeActive())
 *   { SetPendingMobCount(0); amount = 0; return Plugin_Handled; }
 *   ```
 * 本插件实现（`ltt_megamob_hold_tank`，**默认 1 = 开**）：
 *   · 场上有**活着的 Tank**（玩家或 AI，`m_zombieClass == 8`）⇒ 尸潮一律按住；
 *   · 与 anne 一致：**连已经排进待生成队列的也清零**（`SetPendingMobCount(0)`）⇒ 真"暂停"，
 *     不是"只拦新增"；Tank 死后引擎照常补货，尸潮自然恢复；
 *   · 判据放在 `L4D_OnSpawnMob` **最前面**：坦克在场时**根本不进入机关判定**，
 *     免得坦克局的排队把"机关窗口/上限记账"搞脏；
 *   · 日志 30 秒一条（坦克局每秒一发照样会刷爆日志）。
 * ⚠ 这是**改变玩法**的一条（坦克局没有小僵尸干扰）。车主指定要，所以默认开；
 *   想回原版一条命令：`ltt_megamob_hold_tank 0`。
 *
 * ------------------------------------------------------------------ 十三、v2.6.1 补"坦克被甩开"的豁免（从 anne 包挖出来的第 3 代实现）
 *
 * 来源：`...\未分类\l4d2_tank_horde_monitor.sp`（v1.3，坦克 + 无限尸潮监控，三代里最成熟的那份）。
 * 它比"二元暂停"更讲究：**按生还者推进的距离逐步恢复尸潮强度**（0% → 20% → … → 100%，
 * 推进百分比 = (最前生还者 flow − 坦克出生时的 flow − 引擎 director_tank_bypass_max_flow_travel)
 * ÷ (该值 + `l4d2_tank_bypass_extra_flow`=1500)），并在 0/20%…/100% 各播一句。
 *
 * 本插件采取**更简单可预测**的中间版（先解决最要命的副作用）：
 *   · `ltt_megamob_tank_bypass`（默认 **1500** 导航路程单位，0=永不豁免）：
 *     **最前生还者的 flow − 坦克的 flow > 该值 ⇒ 坦克已被甩开，尸潮放行**。
 *   · 为什么必须加：v2.6.0 的二元暂停下，**一只掉队/卡住的坦克会把整局尸潮按死**
 *     （按"每图 150 只"的设定，等于这张图后面全没有尸潮了）。
 *   · 1500 与引擎 `director_tank_bypass_max_flow_travel`（本服 = 1500）同量级。
 * 若以后想要 anne 那种"按推进距离逐步恢复强度 + 播报百分比"的版本，照上面公式移植即可。
 *
 * ------------------------------------------------------------------ 十四、v2.8.0 播报改成"定时器每 30 秒报剩余"
 *
 * 车主 2026-10-07：「我们这个目前还有一个小问题，**我没手动清理僵尸都提示减少了**，
 * 能不能改成**定时器播报间隔 30 秒播报还剩余多少**，而不是**清理了百分之多少就播报**」。
 *
 * 两件事分开说：
 *   ① **"没打也变少"不是 bug，是口径**：`剩余 = 上限 − 已刷出` ⇒ 它**随僵尸刷出来而下降**。
 *      anne 那台服也是这个口径（它的 `commonTotal` 同样在 `OnEntityCreated` 里自增）。
 *      真要"打掉一只少一只"，那是「场上活着的普通感染者数」，受 `z_common_limit`(本服 20) 限制，
 *      会一直贴着 20 上下浮动 —— 不适合当"还剩多少只要打"的进度。
 *   ② **播报触发方式照车主改**：原来按 `int(上限/4)` 的里程碑（150→113→76→39→2，anne 那套）
 *      改成 **固定间隔定时播报**：`ltt_megamob_announce_interval` 默认 **30 秒**（0=关掉定时播报）。
 *      窗口打开时 `StartAnnounceTimer()`，窗口关闭（`ResetEventWindow`）时 `StopAnnounceTimer()`，
 *      所以机关打完后不会再继续喊。开始（`一场有限尸潮开始了`）与结束（`没有普通感染者了！`）两条照旧。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
// 【v2.0.0】固定总量要用的 native 全在 Left4DHooks 里：
//   L4D2Direct_GetPendingMobCount / SetPendingMobCount（待生成队列）
//   L4D_GetMobSpawnTimerRemaining（可选的辅助判据）
// 注意：`public Action L4D_OnSpawnMob(int &amount)` 是 public 函数，**不 include 也能编译过**
//（SourceMod 运行时按名字匹配 forward），但 native 必须有 include ⇒ 少了这行会报
// "error 017: undefined symbol L4D2Direct_GetPendingMobCount"。
#include <left4dhooks>

#define PLUGIN_VERSION "2.10.0"

// 队伍 / 职业常量（本插件自己定义，不依赖 left4dhooks 是否导出这两个宏）
#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define ZC_TANK       8     // m_zombieClass 里的 Tank（注意：我们的 g_sClassName 只覆盖 1~6）

// 引擎默认值（2026-10-07 在服上核对：cfg 里无人写、无任何插件修改 ⇒ 这三个值就是引擎默认）
#define MEGAMOB_DEF_SIZE   50
#define MEGAMOB_DEF_MININT 420
#define MEGAMOB_DEF_MAXINT 900

ConVar g_cEnable;          // 总开关
ConVar g_cMode;            // 档位
ConVar g_cSize;            // 自定义档：数量
ConVar g_cMinInt;          // 自定义档：最小间隔
ConVar g_cMaxInt;          // 自定义档：最大间隔
ConVar g_cLog;             // 是否写日志

ConVar g_cvSize;           // 引擎 cvar 句柄
ConVar g_cvMinInt;
ConVar g_cvMaxInt;

// 【v1.0.1 修复】把档位落盘的合并定时器（见 OnMegamobCvarChanged 上方注释）
Handle g_hSaveTimer;

// =====================================================================================
// 【v2.0.0 · 机关事件尸潮"固定总量"】—— 车主 2026-10-07 追加的真实需求
//
// 车主原话：「这个是要机关事件固定尸潮的功能，就是比如说机关开启原版默认刷 XX 只，
//            然后就只刷这么多后续不再补充」。
// ⇒ v1.0.x 只改了 `z_mega_mob_size`（机关**单次规模**），管不住"后续一波波补充"，
//   而「补充」是引擎在机关事件期间**反复调用 ZombieManager::SpawnMob** 往待生成队列里加人造成的。
//
// 拦法（我们服上的 Left4DHooks 1.168 有现成 native，**不需要 gamedata、不猜事件名**）：
//   · `L4D_OnSpawnMob(int &amount)`：机关/恐慌事件尸潮 + 自然尸潮 + onslaught 都会走这里
//     （`z_spawn mob` 与 Boomer 呕吐走 SpawnITMob，是另一套，本插件**刻意不动 Boomer**）。
//   · 怎么区分"机关"与"自然小尸潮"：**看 amount**。
//     自然尸潮规模 = `z_mob_spawn_min_size..max_size`（本服 10~30），
//     机关 mega mob 规模 = `z_mega_mob_size`（原版 50）⇒ `amount > z_mob_spawn_max_size` 即机关。
//     （两条数据之间有 20 的间隔，判定不会两边踩线。阈值取自**服上的实时 cvar 值**，不是我记的数。）
//   · "原版刷 XX 只"里的 XX = **该次机关第一次 SpawnMob 的 amount**（引擎自己给的，插件不猜）。
//     默认 `ltt_megamob_limit = -1` 就用它当总量上限 ⇒ 车主不需要配任何数字。
//   · 之后每次补充：余量够就放，超了就**只放余量**（`Plugin_Changed`），余量为 0 就**整笔拦掉**
//     （`amount = 0` + `Plugin_Handled`）。⇒ 总量被钉死在 XX，一次不多。
//   · **不清空待生成队列**（`SetPendingMobCount(0)` 是 horde_equaliser 的做法，但那会把
//     初始那 XX 只里还没刷出来的部分一起抹掉 ⇒ 实际刷不满）。要那种"硬停"可以开
//     `ltt_megamob_clearpending 1`；默认 0 = 让原版那一波完整刷完，只是不再补。
//   · 事件窗口：出现一次机关排队即开窗；每 1 秒巡检，`eventgap` 秒内没有任何尸潮排队
//     就判本次机关结束并结算。⇒ **同一张图的第二个、第三个机关各自独立算 XX**，
//     不会像 horde_equaliser 那样"一局只算一次"（它的计数器只在 round_start 重置）。
//
// ⚠ 本功能**未能在服上做真人实测**：机关必须由生还者触发，而当时服务器 0 玩家 0 bot
//   （空服不补 bot，`sm_sispawn_burst` 也回"没有生还者可作目标"）。所以：
//   · 默认 `ltt_megamob_act 1`（车主明确要这个功能，装上就该生效）；
//   · 但每一次开窗/拦截/结算都会**打日志**，第一次机关跑完就能从日志里核对 XX 与原版是否一致；
//   · 任何异常一条命令即可停：`ltt_megamob_act 0`（只记录）或 `ltt_megamob_finite 0`（完全关）。
// =====================================================================================

ConVar g_cFinite;          // 固定总量总开关
ConVar g_cLimit;           // 总量上限（-1=自动=原版那次量 / 0=不限 / >0=固定）
ConVar g_cAct;             // 1=真拦 / 0=只记录
ConVar g_cEventGap;        // 多久没有尸潮排队就判事件结束
ConVar g_cClearPending;    // 是否连待生成队列一起清空（默认 0）
ConVar g_cVerbose;         // 【v2.0.1】每次尸潮排队都记一行（取证用）

// =====================================================================================
// 【v2.1.0 · 对齐"anne服药役"那套有限尸潮体验】
//
// 车主 2026-10-07 贴了另一台服的实况：
//   `<尸潮> 一场有限尸潮开始了！本轮共有150个普通感染者！是冲还是等，你来决定！`（地图 C2M4）
// 问「我们大概能做到吗」。
// ⇒ 能做。那条播报就是 l4d2_horde_equaliser 的 `FiniteEventStarted` 文案，
//   而它那个 **150 是地图包 mission 文件里的 `horde_limit`**（竞技图自带这个字段）。
//   我们的官方图没有该字段 ⇒ **数字要自己按图配**，这就是本版加的两个东西：
//   ① 按图限量文件 `cfg/sourcemod/ltt_megamob_maps.cfg`（一行一个图：`c2m4_barns 150`）
//   ② 玩家播报：开波报总数 / 每过 1/4 报剩余 / 结束报结算（可用 ltt_megamob_announce 关）
// =====================================================================================
ConVar g_cAnnounce;        // 播报开关
// 【v2.2.0】"自然尸潮上限"阈值的**手动覆盖**。默认 0 = 用引擎实时 z_mob_spawn_max_size。
//   为什么需要：`amount > 自然上限` 是用来把"机关 mega mob"和"自然小尸潮"分开的。
//   官方图机关量 ≈ z_mega_mob_size(50)、自然 10~30 ⇒ 30 这个阈值够用；
//   但**三方图**的机关量不一定大于 30（有的图机关只排 20~30 只），那种图会被误判成自然尸潮而放过。
//   遇到这种图，把 ltt_megamob_natmax 调到它下面（例如 15）即可让机关重新被识别。
//   ⚠ 调太低会把"自然小尸潮"也当机关（自然尸潮会被限量）—— 所以默认不动，按图按需调。
ConVar g_cNatMaxOverride;
char g_sMapLimitHit[64];   // 本图命中的那条条目原文（日志/命令回显用）
// 【v2.3.0】取代 v2.2.0 的"比数量"判定（实测证明它全失效，见文件头 §九）
ConVar g_cEventWin;        // 连续排队间隔窗口：距上次排队 ≤ 它 ⇒ 事件尸潮
float  g_flLastSpawnMobAt; // 最近一次 SpawnMob 的时刻
int    g_iEventCalls;      // 本次窗口内 SpawnMob 被调用的次数（日志节流用）
int    g_iPrevAmount;      // 上一发 SpawnMob 的 amount（开窗时把"第一发"补进总量）
// 【v2.6.0】坦克期间暂停尸潮（车主指定"一定要加"，搬自 anne 服的 l4d2_horde_equaliser）
ConVar g_cHoldTank;
int    g_iTankHoldCalls;   // 本图因坦克被拦下的尸潮次数
float  g_flTankHoldLogAt;  // 坦克暂停日志节流（30 秒一条）
// 【v2.6.1】"坦克被甩开"的豁免距离（导航路程）。0 = 永不豁免（坦克在场就一直按）
ConVar g_cTankBypass;
int    g_iTankBypassCalls; // 本图因"坦克被甩开"而恢复尸潮的次数
float  g_flTankBypassLogAt;
// 【v2.7.0】自然尸潮上限（z_mob_spawn_max_size）：amount 超过它 ⇒ 机关 mega mob
ConVar g_cvNatMax;
int    g_iPanicEvents;     // 本图收到多少次 create_panic_event（取证：这个事件到底存不存在/准不准）
bool   g_bPanicOpened;     // 窗口是 create_panic_event 开的、播报还没喊（等第一波尸潮到达再喊）
// 【v2.9.2】上一次窗口是不是「刷满上限」关闭的 —— 用来区分「引擎还在给已结束的尸潮补货」与「新机关」
bool   g_bLastWasCapped;
// 【v2.10.0】本次窗口是不是「警报车/panic event」开的 —— 车主指定：警报车只刷 50 只，地图机关仍 150
bool   g_bEventFromPanic;
ConVar g_cAlarmLimit;
float  g_flIgnoredLogAt;   // 【v2.9.2】"忽略补货"日志节流
// 【v2.8.0】定时播报（车主：每 30 秒报"还剩多少"，不再按清理百分比报）
ConVar g_cAnnounceInterval;
Handle g_hAnnTimer;

#define MAX_MAP_LIMITS 128
char g_sMapLimitName[MAX_MAP_LIMITS][64];
int  g_iMapLimitVal[MAX_MAP_LIMITS];
int  g_iMapLimitCount;
int  g_iMapLimitCur;       // 本图生效的按图上限；-2 = 本图没有条目（退回 ltt_megamob_limit）
int  g_iMapLimitDefault;   // 【v2.4.0】文件里 `* <数字>` 那一行 = 所有"没单独特写"的图的默认上限；-2 = 没写
int  g_iEventSpawned;      // 本次机关**实际刷出来**的机关尸潮 infected 数（播报用；限量仍以排队量为准）
int  g_iEventWander;       // 【v2.9.0】窗口期内刷出的**背景/游荡**普通感染者数（不计入机关份额，只供日志核对）
bool g_bEventDoneAnnounced;// 是否已经播过"没有普通感染者了"
char g_sMap[64];           // 当前地图名（按图限量用）

bool  g_bEventActive;      // 本次机关事件窗口是否打开
int   g_iEventNo;          // 本图第几次机关（日志用）
int   g_iEventCap;         // 本次机关的允许总量（0=不限）
int   g_iEventQueued;      // 本次机关已放行的排队量
int   g_iEventBlocked;     // 本次机关被拦掉的排队量
float g_flLastHordeAt;     // 最近一次尸潮排队的时刻
Handle g_hEventTimer;      // 事件窗口巡检定时器（1 秒）

public Plugin myinfo =
{
	name        = "[LTT] Mega Mob (机关尸潮)",
	author      = "LTT / DeepSeek Harness",
	description = "机关尸潮（mega mob）强度可调：原版 / 减半 / 关闭 / 自定义。引擎 cvar 每图重设",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cEnable = CreateConVar("ltt_megamob_enable", "1",
		"【v1.0.0】1=启用本插件（按档位套用机关尸潮 cvar）｜0=完全不干预（等于没装）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cMode = CreateConVar("ltt_megamob_mode", "0",
		"【v1.0.0】机关尸潮档位：0=原版（引擎默认 50 只 / 420~900 秒）｜1=减半（25 只）｜2=关闭（0 只）｜3=自定义（见 size/min_interval/max_interval）",
		FCVAR_NOTIFY, true, 0.0, true, 3.0);
	g_cSize = CreateConVar("ltt_megamob_size", "50",
		"【v1.0.0】自定义档（mode=3）的一次机关尸潮数量，直接写进 z_mega_mob_size",
		FCVAR_NOTIFY, true, 0.0, true, 500.0);
	g_cMinInt = CreateConVar("ltt_megamob_min_interval", "420",
		"【v1.0.0】自定义档（mode=3）的最小间隔秒数，写进 z_mega_mob_spawn_min_interval",
		FCVAR_NOTIFY, true, 1.0, true, 100000.0);
	g_cMaxInt = CreateConVar("ltt_megamob_max_interval", "900",
		"【v1.0.0】自定义档（mode=3）的最大间隔秒数，写进 z_mega_mob_spawn_max_interval",
		FCVAR_NOTIFY, true, 1.0, true, 100000.0);
	g_cLog = CreateConVar("ltt_megamob_log", "1",
		"【v1.0.0】1=每次套用写一行日志（强烈建议保持 1：这类插件失效时是静默的）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// ---- v2.0.0：机关事件尸潮【固定总量】----
	g_cFinite = CreateConVar("ltt_megamob_finite", "1",
		"【v2.0.0】1=机关事件尸潮固定总量（机关开启按原版刷 XX 只，之后不再一波波补充）｜0=关（原版无限补充）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cLimit = CreateConVar("ltt_megamob_limit", "150",
		"【v2.5.0】机关事件总量上限（**所有地图的全局默认值**）：>0=固定值（默认 150，装上就对每张图生效，不用一张张配）｜0=不限（回原版无限补充）｜-1=不限（旧值，等同 0）",
		FCVAR_NOTIFY, true, -1.0, true, 10000.0);
	g_cAct = CreateConVar("ltt_megamob_act", "1",
		"【v2.0.0】1=真的拦截超量补充｜0=只记录不拦（想先观察一局就设 0）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cEventGap = CreateConVar("ltt_megamob_eventgap", "60.0",
		"【v2.3.1】多久没有任何尸潮排队就判本次机关事件结束（秒）。实测同一次机关里两次排队可以间隔 18 秒（引擎按队列水位补货）⇒ 太紧会把一次机关切成两次、各自重算上限，所以默认放到 60",
		FCVAR_NOTIFY, true, 5.0, true, 600.0);
	g_cClearPending = CreateConVar("ltt_megamob_clearpending", "0",
		"【v2.0.0】1=拦截时连【待生成队列】一起清零（停得更硬，但会把原版那波还没刷出来的部分也抹掉）｜0=只拦住新增（默认，让原版那 XX 只完整刷完）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	// 【v2.0.1】为什么需要它：2026-10-07 空服用 director_force_panic_event 强触发后**没有任何日志**，
	// 无法区分"forward 没触发"还是"引擎给的 amount 没超过判定阈值（被当自然尸潮静默跳过）"。
	// 开了它，每一次 SpawnMob 的原始 amount 都落一行 ⇒ 一次机关就能核对：
	//   ① forward 到底有没有触发 ② 机关与自然各自的 amount 实际是多少 ③ 判定阈值要不要调。
	g_cVerbose = CreateConVar("ltt_megamob_verbose", "1",
		"【v2.0.1】1=每一次尸潮排队都记一行原始 amount（取证：机关/自然各是多少、阈值对不对）｜0=只记机关相关",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cAnnounce = CreateConVar("ltt_megamob_announce", "1",
		"【v2.1.0】1=向玩家播报有限尸潮（开始/剩余/结束），文案对齐竞技服的`一场有限尸潮开始了`｜0=不播报只记账",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	// 【v2.8.0】定时播报"还剩多少只" —— 车主 2026-10-07：
	//   「我没手动清理僵尸都提示减少了，能不能改成定时器播报间隔 30 秒播报还剩余多少，
	//     而不是清理了百分之多少就播报」。
	//   ⇒ 原来按 int(上限/4) 的里程碑播报（anne 那套）改为**固定间隔定时播报**。
	//   `剩余 = 上限 − 已刷出`（不是"打掉一只少一只"），所以它随时间下降是正常的，见 OnEntityCreated 注释。
	g_cAnnounceInterval = CreateConVar("ltt_megamob_announce_interval", "30.0",
		"【v2.8.0】定时播报间隔（秒）：每这么多秒向玩家报一次「N 个普通感染者剩余..」｜0=关掉定时播报（只留开始/结束两条）",
		FCVAR_NOTIFY, true, 0.0, true, 600.0);
	// 【v2.6.0】坦克期间暂停尸潮 —— 车主 2026-10-07 指定"一定要加"。	// 来源：anne 服的 `l4d2_horde_equaliser` 里那段
	//   `if (hCvarNoEventHordeDuringTanks.BoolValue && IsTankUp() && IsInfiniteHordeActive())
	//        { SetPendingMobCount(0); amount = 0; return Plugin_Handled; }`
	// 语义：**场上有活着的 Tank 时，尸潮一律按住**（连已经排进队列的也清零 ⇒ 真"暂停"，
	// 不是"只拦新增"）；Tank 死后尸潮自然恢复。默认开（车主指定）。
	// =================================================================================
	// 【v2.10.0】警报车（panic event）单独限量 —— 车主 2026-10-07：「警报车只刷50只」
	//
	// 背景：实测发现 `create_panic_event` 对**警报车**会触发（19:57 增城 M1 实测），
	//   而**地图机关按钮（crescendo）不触发**它（c2m2/c2m4 实测）⇒ 两条路天然可分：
	//     · 窗口由 create_panic_event 开 ⇒ 警报车 ⇒ 用本 cvar（默认 50 = 原版那发 mega mob 的量）
	//     · 窗口由「大额单发 / 连续排队」开 ⇒ 地图机关 ⇒ 用 ltt_megamob_limit（默认 150）
	//   50 这个数来自实测：警报车那波第一发就是 `amount=50`（= z_mega_mob_size），
	//   ⇒ 限成 50 就是「只刷原版那一发，后续不再补」。
	//   0 = 不限（警报车回原版无限补货）。
	// =================================================================================
	g_cAlarmLimit = CreateConVar("ltt_megamob_alarm_limit", "50",
		"【v2.10.0】警报车（panic event）尸潮上限：默认 50（= 原版那发 mega mob）｜0=不限（回原版无限补货）。地图机关仍用 ltt_megamob_limit",
		FCVAR_NOTIFY, true, 0.0, true, 10000.0);

	g_cHoldTank = CreateConVar("ltt_megamob_hold_tank", "1",
		"【v2.6.0】1=坦克期间暂停尸潮（有活着的 Tank 时拦住尸潮并清空待生成队列，Tank 死后恢复）｜0=不暂停（原版）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	// 【v2.6.1】"坦克被甩开"的豁免距离。来源：anne 包里的 `l4d2_tank_horde_monitor.sp`
	//   （它有更讲究的"按推进距离逐步恢复尸潮强度"版本：`l4d2_tank_bypass_extra_flow`=1500）。
	//   为什么需要：**一只掉队/卡住的坦克不该把整局尸潮按死**。
	//   判据：最前生还者的导航路程 − 坦克的导航路程 > 这个值 ⇒ 坦克已经没戏了，尸潮放行。
	//   1500 = 引擎 `director_tank_bypass_max_flow_travel` 的同一个量级（本服该 cvar = 1500）。
	g_cTankBypass = CreateConVar("ltt_megamob_tank_bypass", "1500.0",
		"【v2.6.1】坦克被甩开的豁免距离（导航路程单位）：最前生还者比坦克领先超过它 ⇒ 不再暂停尸潮｜0=永不豁免（坦克在场就一直按）",
		FCVAR_NOTIFY, true, 0.0);
	g_cNatMaxOverride = CreateConVar("ltt_megamob_natmax", "0",
		"【v2.2.0·v2.3.0 起已废弃】原本用于按数量区分机关/自然，实测失效（机关 amount 恰好=自然上限）。保留仅为兼容旧 cfg，不再参与判断",
		FCVAR_NOTIFY, true, 0.0, true, 1000.0);
	g_cEventWin = CreateConVar("ltt_megamob_eventwin", "15.0",
		"【v2.5.0】判定「机关事件尸潮」的连续排队间隔（秒）：距上次 SpawnMob ≤ 它 ⇒ 判为机关。默认 15（比 5 更耐受未知三方图的补货节奏；自然尸潮是几分钟一发，不会误判）",
		FCVAR_NOTIFY, true, 1.0, true, 60.0);

	AutoExecConfig(true, "ltt_megamob");

	// 引擎 cvar 句柄。找不到就明确报错并自我停用 —— 不许"静默空转"。
	g_cvSize   = FindConVar("z_mega_mob_size");
	g_cvMinInt = FindConVar("z_mega_mob_spawn_min_interval");
	g_cvMaxInt = FindConVar("z_mega_mob_spawn_max_interval");
	if (g_cvSize == null || g_cvMinInt == null || g_cvMaxInt == null)
	{
		LogError("[MegaMob] 找不到引擎 cvar（z_mega_mob_size=%s / min_interval=%s / max_interval=%s）—— 本插件不生效，请检查游戏版本",
			g_cvSize == null ? "缺" : "有",
			g_cvMinInt == null ? "缺" : "有",
			g_cvMaxInt == null ? "缺" : "有");
	}

	// 改了档位/数值立刻生效（不用等开图）
	g_cMode.AddChangeHook(OnMegamobCvarChanged);
	g_cSize.AddChangeHook(OnMegamobCvarChanged);
	g_cMinInt.AddChangeHook(OnMegamobCvarChanged);
	g_cMaxInt.AddChangeHook(OnMegamobCvarChanged);
	g_cEnable.AddChangeHook(OnMegamobCvarChanged);
	g_cFinite.AddChangeHook(OnMegamobCvarChanged);
	g_cLimit.AddChangeHook(OnMegamobCvarChanged);
	g_cAct.AddChangeHook(OnMegamobCvarChanged);
	g_cEventGap.AddChangeHook(OnMegamobCvarChanged);
	g_cClearPending.AddChangeHook(OnMegamobCvarChanged);
	g_cVerbose.AddChangeHook(OnMegamobCvarChanged);
	g_cAnnounce.AddChangeHook(OnMegamobCvarChanged);
	g_cAnnounceInterval.AddChangeHook(OnMegamobCvarChanged);
	g_cHoldTank.AddChangeHook(OnMegamobCvarChanged);
	g_cAlarmLimit.AddChangeHook(OnMegamobCvarChanged);
	g_cTankBypass.AddChangeHook(OnMegamobCvarChanged);
	g_cEventWin.AddChangeHook(OnMegamobCvarChanged);
	g_cNatMaxOverride.AddChangeHook(OnMegamobCvarChanged);

	// 【v2.2.0】管理员命令：改完按图限量文件不用换图（三方图调试很需要）
	RegAdminCmd("sm_megamob_reload", Cmd_ReloadLimits, ADMFLAG_GENERIC,
		"【v2.2.0】重读按图限量文件 ltt_megamob_maps.cfg 并回显本图命中情况");

	// 【v2.3.0】"比数量"那条判据被实测证伪（机关 amount 可以恰好 = 自然上限）；
	// 【v2.7.0】但 `z_mob_spawn_max_size` 有了新用途：**amount 超过它 ⇒ 机关 mega mob 的大额单发**
	//（实测 c3m1_plankcountry 的机关就是【一发 amount=50 之后再无第二发】）。
	g_cvNatMax = FindConVar("z_mob_spawn_max_size");
	if (g_cvNatMax == null && g_cLog.BoolValue)
		LogMessage("[MegaMob] 找不到 z_mob_spawn_max_size，大额单发判据退回 30");

	// 【v2.7.0】恐慌/机关事件开始 —— 精确的"机关开启"信号（解决 c2m2 那种"延迟 30 秒才播报"）
	//   注意用 HookEventEx（返回 bool）才能判断事件是否真的存在；HookEvent 返回 void。
	if (HookEventEx("create_panic_event", Event_PanicEvent, EventHookMode_PostNoCopy))
		LogMessage("[MegaMob] 已挂 create_panic_event（机关开启的精确信号）");
	else
		LogMessage("[MegaMob] ⚠ 挂不上 create_panic_event —— 机关判据退回「大额单发 + 连续排队」两条");

	// 【v2.0.0】每回合开始重置事件窗口（防止上一回合的计数带过来）
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	RegAdminCmd("sm_megamob", Cmd_Megamob, ADMFLAG_GENERIC,
		"【v1.0.0】机关尸潮档位菜单（原版/减半/关闭/自定义）");

	ApplyMegamob("插件加载");
}

public void OnMapStart()
{
	// 引擎会在开图时把 z_* 这类 cheat cvar 重置回默认值 ⇒ 每图都要重设。
	// 三次：开图当下、+1 秒、+6 秒（引擎重置的时机不完全固定，多打两次成本为零）。
	ApplyMegamob("开图");
	CreateTimer(1.0, Timer_ReApply, 0, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(6.0, Timer_ReApply, 1, TIMER_FLAG_NO_MAPCHANGE);

	// 【v2.0.0】机关事件窗口按图归零，并起一个 1 秒巡检
	ResetEventWindow("换图");
	g_iEventNo = 0;
	// 【v2.6.0】坦克暂停计数按图清零
	g_iTankHoldCalls = 0;
	g_flTankHoldLogAt = 0.0;
	g_iTankBypassCalls = 0;      // 【v2.6.1】
	g_flTankBypassLogAt = 0.0;
	g_iPanicEvents = 0;          // 【v2.7.0】
	// 【v2.1.0】每图重读按图限量文件（改完换图即生效，不用重载插件）
	GetCurrentMap(g_sMap, sizeof(g_sMap));
	LoadMapLimits();
	if (g_hEventTimer != null)
	{
		KillTimer(g_hEventTimer);
		g_hEventTimer = null;
	}
	g_hEventTimer = CreateTimer(1.0, Timer_EventWatch, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnConfigsExecuted()
{
	// cfg/sourcemod/ltt_megamob.cfg 在这个点被 exec ⇒ 车主手改的档位在这里生效
	ApplyMegamob("配置执行后");
}

public Action Timer_ReApply(Handle timer, any late)
{
	ApplyMegamob(late ? "开图+6秒复核" : "开图+1秒复核");
	return Plugin_Stop;
}

public void OnMegamobCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ApplyMegamob("cvar 变更");
	ScheduleSaveCfg();
}

/**
 * 【v1.0.1 修复 · 换图就回原版】
 *
 * 实测（2026-10-07 14:16）：菜单/ rcon 把 mode 改成 2（关闭）当场生效（z_mega_mob_size 真的变 0），
 * 但 **changelevel 之后 mode 又变回 0、size 变回 50** —— 原因是 `AutoExecConfig` 只在文件
 * **不存在**时生成、之后只补缺失的 cvar，**不会更新已有行的值**：文件里永远留着装载那一刻的
 * mode=0，换图 exec 一次就把运行时选的档覆盖掉。菜单等于白选。
 *
 * 修法：选择档位后**自己把 cfg 重写一遍**（当前值），并在 0.5 秒后合并执行 ——
 * 延后是为了避开"正在 exec 这个文件时把它重写"（OnConfigsExecuted 那次 exec 也会触发本回调）。
 */
void ScheduleSaveCfg()
{
	if (g_hSaveTimer == null)
		g_hSaveTimer = CreateTimer(0.5, Timer_SaveCfg, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SaveCfg(Handle timer)
{
	g_hSaveTimer = null;
	SaveMegamobCfg();
	return Plugin_Stop;
}

/** 用当前值重写 cfg/sourcemod/ltt_megamob.cfg（与 AutoExecConfig 生成的是同一个文件）。 */
void SaveMegamobCfg()
{
	// 【源码 1.12 只有 Path_SM】SourceMod 根 = left4dead2/addons/sourcemod，
	// 而 AutoExecConfig 写的 cfg 在 left4dead2/cfg/sourcemod/ ⇒ 相对路径要退两级。
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "../../cfg/sourcemod/ltt_megamob.cfg");

	File f = OpenFile(sPath, "wt");
	if (f == null)
	{
		LogError("[MegaMob] 写不进 %s —— 档位只在本次运行内有效，换图会被 cfg 里的旧值覆盖回去", sPath);
		return;
	}

	f.WriteLine("// 【LTT】机关尸潮（mega mob）档位 —— 本文件由插件自动维护（选档后重写），手改也认。");
	f.WriteLine("// 档位 mode：0=原版(50只/420~900秒) 1=减半(25只) 2=关闭(0只) 3=自定义");
	f.WriteLine("// 说明：z_mega_mob_* 是引擎 cheat cvar，开图会被引擎重置，所以插件每图重设一次。");
	f.WriteLine("");

	char sLine[128];
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_enable \"%d\"", g_cEnable.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_mode \"%d\"", g_cMode.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_size \"%d\"", g_cSize.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_min_interval \"%d\"", g_cMinInt.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_max_interval \"%d\"", g_cMaxInt.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_log \"%d\"", g_cLog.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_finite \"%d\"", g_cFinite.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_limit \"%d\"", g_cLimit.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_act \"%d\"", g_cAct.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_eventgap \"%d\"", g_cEventGap.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_eventwin \"%d\"", g_cEventWin.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_clearpending \"%d\"", g_cClearPending.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_verbose \"%d\"", g_cVerbose.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_announce \"%d\"", g_cAnnounce.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_announce_interval \"%d\"", g_cAnnounceInterval.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_hold_tank \"%d\"", g_cHoldTank.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_alarm_limit \"%d\"", g_cAlarmLimit.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_tank_bypass \"%d\"", g_cTankBypass.IntValue);
	f.WriteLine(sLine);
	FormatEx(sLine, sizeof(sLine), "ltt_megamob_natmax \"%d\"", g_cNatMaxOverride.IntValue);
	f.WriteLine(sLine);

	delete f;
}

/** 按档位算出三个值并套用。sWhy 只用于日志（"到底哪一次套用生效了"）。 */
void ApplyMegamob(const char[] sWhy)
{
	if (g_cvSize == null || g_cvMinInt == null || g_cvMaxInt == null)
		return;

	if (!g_cEnable.BoolValue)
		return;   // 关掉总开关 = 完全不干预（不还原、不写值），交给引擎自己

	int iMode = g_cMode.IntValue;
	int size, mn, mx;
	char sName[16];

	switch (iMode)
	{
		case 1:
		{
			size = MEGAMOB_DEF_SIZE / 2;     // 减半：只减数量，间隔保持原版
			mn   = MEGAMOB_DEF_MININT;
			mx   = MEGAMOB_DEF_MAXINT;
			strcopy(sName, sizeof(sName), "减半");
		}
		case 2:
		{
			size = 0;                        // 关闭：实测引擎接受 0
			mn   = MEGAMOB_DEF_MININT;
			mx   = MEGAMOB_DEF_MAXINT;
			strcopy(sName, sizeof(sName), "关闭");
		}
		case 3:
		{
			size = g_cSize.IntValue;
			mn   = g_cMinInt.IntValue;
			mx   = g_cMaxInt.IntValue;
			strcopy(sName, sizeof(sName), "自定义");
		}
		default:
		{
			size = MEGAMOB_DEF_SIZE;
			mn   = MEGAMOB_DEF_MININT;
			mx   = MEGAMOB_DEF_MAXINT;
			strcopy(sName, sizeof(sName), "原版");
		}
	}

	if (size < 0) size = 0;
	if (mn < 1)   mn = 1;
	if (mx < mn)  mx = mn;

	char sDetail[128];
	FormatEx(sDetail, sizeof(sDetail), "z_mega_mob_size %d→%d｜间隔 %d~%d→%d~%d",
		g_cvSize.IntValue, size,
		g_cvMinInt.IntValue, g_cvMaxInt.IntValue, mn, mx);

	SetEngineCvar(g_cvSize, size);
	SetEngineCvar(g_cvMinInt, mn);
	SetEngineCvar(g_cvMaxInt, mx);

	if (g_cLog.BoolValue)
		LogMessage("[MegaMob] v%s 套用（%s）：档位=%s（mode=%d）｜%s｜实际读回 size=%d 间隔 %d~%d",
			PLUGIN_VERSION, sWhy, sName, iMode, sDetail,
			g_cvSize.IntValue, g_cvMinInt.IntValue, g_cvMaxInt.IntValue);
}

/** 只在值真变了才写（少一次 cvar 变更通知，也少一行"引擎 changed cvar"噪音）。 */
void SetEngineCvar(ConVar cv, int iValue)
{
	if (cv == null)
		return;
	if (cv.IntValue != iValue)
		cv.SetInt(iValue);
}

public Action Cmd_Megamob(int client, int args)
{
	ShowMegamobMenu(client);
	return Plugin_Handled;
}

// =====================================================================================
// 【v2.1.0】按图限量 + 玩家播报 —— 对齐 anne 那台服的"有限尸潮"体验
// =====================================================================================

/** 读按图限量文件；文件不存在就生成一份带示例的模板（车主拿到就能照抄改数字）。 */
void LoadMapLimits()
{
	g_iMapLimitCount = 0;
	g_iMapLimitCur   = -2;      // -2 = 本图无条目
	g_iMapLimitDefault = -2;    // -2 = 没写 `*` 默认行
	g_sMapLimitHit[0] = '\0';

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "../../cfg/sourcemod/ltt_megamob_maps.cfg");

	File f = OpenFile(sPath, "rt");
	if (f == null)
	{
		f = OpenFile(sPath, "wt");
		if (f != null)
		{
			f.WriteLine("// 【LTT】机关事件尸潮·按图限量 —— 一行一个图：<地图名> <总数>");
			f.WriteLine("//   ★ 全局默认已经是 150（cvar `ltt_megamob_limit`）⇒ **本文件一行都不写也全图生效**。");
			f.WriteLine("//     所以这里**只写例外**（某张图想用别的数字）。优先级：本图条目 > `*` 行 > ltt_megamob_limit。");
			f.WriteLine("//   改完换图即生效，也可用 sm_megamob_reload 立刻重读（不用换图）。");
			f.WriteLine("//   三方战役图名带 _m1/_m2 的，可只写一行通配前缀：  bdp_bunker* 200");
			f.WriteLine("//   想给「所有没单写的图」另一个统一数字，就写一行：  * 200");
			f.WriteLine("//   数字参考：竞技服 anne 的 C2M4 是 150（那是他们地图 mission 的 horde_limit）。");
			f.WriteLine("");
			f.WriteLine("c2m4_barns 150");
			f.WriteLine("");
			f.WriteLine("// ---- 本服已装的三方战役（`maps *` 实测，写的时候照抄图名）----");
			f.WriteLine("//   深埋        bdp_bunker01 ~ bdp_bunker05a        （可写 bdp_bunker* 150）");
			f.WriteLine("//   广州增城    zc_m1~m5 / zc1_m1~m5                （可写 zc* 150 / zc1* 150）");
			f.WriteLine("//   秋名市      azcity_new_street / azcity_senter / azcity_end");
			f.WriteLine("//   沙海恒音    dune_01 ~ dune_05                   （可写 dune_* 150）");
			f.WriteLine("//   布拉格      prague_1_old_town ~ prague_4_bus_depo");
			f.WriteLine("//   闪电突袭2   l4d2_mimp1 ~ l4d2_mimp6 / l4d2_stadium1~5_*");
			f.WriteLine("//   潮汐激战    c3m1_jungle / c3m2_jungle / c3m3_jungle   ← 当初「地底舌头」那张");
			f.WriteLine("//   血腥荒野    beta_thecity1 等");
			f.WriteLine("//   训练图      tgxl / tgxlbf");
			f.WriteLine("");
			f.WriteLine("// ---- 官方图要限就取消下面注释（想全用 * 就不用逐张写）----");
			f.WriteLine("// c1m4_atrium 150");
			f.WriteLine("// c3m2_swamp 150");
			f.WriteLine("// c5m4_quarter 150");
			delete f;
			LogMessage("[MegaMob] 已生成按图限量模板 %s（含 c2m4_barns 150）", sPath);
		}
		else
		{
			LogError("[MegaMob] 建不了按图限量文件 %s", sPath);
		}
		return;
	}

	char sLine[160];
	while (f.ReadLine(sLine, sizeof(sLine)))
	{
		TrimString(sLine);
		if (sLine[0] == '\0' || sLine[0] == '#'
			|| (sLine[0] == '/' && sLine[1] == '/'))
			continue;

		// 手工切分（不用 SplitString：它对"任意分隔符 + 取余下部分"不直观）
		char sMap[64], sVal[32];
		int i = 0;
		while (sLine[i] != '\0' && sLine[i] != ' ' && sLine[i] != '\t' && i < sizeof(sMap) - 1)
		{
			sMap[i] = sLine[i];
			i++;
		}
		sMap[i] = '\0';
		while (sLine[i] == ' ' || sLine[i] == '\t')
			i++;
		int j = 0;
		while (sLine[i] != '\0' && sLine[i] != ' ' && sLine[i] != '\t' && j < sizeof(sVal) - 1)
		{
			sVal[j] = sLine[i];
			i++; j++;
		}
		sVal[j] = '\0';
		if (sMap[0] == '\0' || sVal[0] == '\0')
			continue;

		int iVal = StringToInt(sVal);
		if (iVal < 0)
			continue;

		// 【v2.4.0】`* <数字>` = **所有没单独特写的图的默认上限**（三方图特别有用：
		//   不必给 55 张三方图一张张写，一行 `* 150` 就全兜住；官方图想让它们保持不限，
		//   就在上面给官方图单独写 0 或者干脆不用 `*`）。
		if (strcmp(sMap, "*", false) == 0)
		{
			g_iMapLimitDefault = iVal;
			continue;
		}

		if (g_iMapLimitCount < MAX_MAP_LIMITS)
		{
			strcopy(g_sMapLimitName[g_iMapLimitCount], 64, sMap);
			g_iMapLimitVal[g_iMapLimitCount] = iVal;
			g_iMapLimitCount++;
		}

		// 【v2.2.0】支持**通配前缀**：`l4d_tgxl* 150` 可覆盖同一张三方战役的多张图
		//   （三方战役常见命名 xxx_m1 / xxx_m2 ... 一个星号全包，不用一张张写）
		int iLen = strlen(sMap);
		bool bMatch;
		if (iLen > 1 && sMap[iLen - 1] == '*')
		{
			sMap[iLen - 1] = '\0';
			bMatch = (strncmp(sMap, g_sMap, iLen - 1) == 0);
		}
		else
		{
			bMatch = (strcmp(sMap, g_sMap, false) == 0);
		}

		if (bMatch)
		{
			g_iMapLimitCur = iVal;
			FormatEx(g_sMapLimitHit, sizeof(g_sMapLimitHit), "%s %d", sMap, iVal);
		}
	}
	delete f;

	if (g_cLog.BoolValue)
		LogMessage("[MegaMob] 按图限量：文件 %d 条，`*` 默认=%s，本图(%s) %s%s", g_iMapLimitCount,
			(g_iMapLimitDefault >= 0) ? "有" : "无",
			g_sMap,
			(g_iMapLimitCur >= 0) ? "命中按图数值 → " : ((g_iMapLimitDefault >= 0) ? "无本图条目→用 `*` 默认 " : "无条目→用 ltt_megamob_limit "),
			(g_iMapLimitCur >= 0) ? g_sMapLimitHit : "");
}

/** 【v2.2.0】改完文件不用换图（三方图调试/临时加图很实用） */
public Action Cmd_ReloadLimits(int client, int args)
{
	GetCurrentMap(g_sMap, sizeof(g_sMap));
	LoadMapLimits();

	char sMsg[224];
	if (g_iMapLimitCur >= 0)
		FormatEx(sMsg, sizeof(sMsg), "[MegaMob] 本图 %s 命中按图限量：%s（文件共 %d 条，将用 %d 只）",
			g_sMap, g_sMapLimitHit, g_iMapLimitCount, g_iMapLimitCur);
	else if (g_iMapLimitDefault >= 0)
		FormatEx(sMsg, sizeof(sMsg), "[MegaMob] 本图 %s 无单独条目 → 用 `*` 默认 %d 只（文件共 %d 条）",
			g_sMap, g_iMapLimitDefault, g_iMapLimitCount);
	else
		FormatEx(sMsg, sizeof(sMsg), "[MegaMob] 本图 %s 无按图条目、也没有 `*` 默认（文件共 %d 条）→ 用 ltt_megamob_limit=%d（-1/0=不限）",
			g_sMap, g_iMapLimitCount, g_cLimit.IntValue);

	if (client > 0)
		ReplyToCommand(client, "%s", sMsg);
	PrintToServer("%s", sMsg);
	LogMessage("%s", sMsg);
	return Plugin_Handled;
}

/** 【v2.3.0】本次机关的实际上限：按图文件 > 固定值 > 不限。
 *  注意 `-1`（默认）现在 = **不限（原版）**，不再"用引擎那次量"当上限 ——
 *  因为实测证明引擎单次给的不是"XX 总量"，而是**每秒一发 30 只、无限补**，
 *  拿它当上限会把总量错设成 30（比原版还少）。要限量就写按图文件或把 limit 设成正数。 */
int ResolveEventCap()
{
	// 【v2.10.0】警报车/panic event：走自己的上限（默认 50），不参与按图文件与全局 limit
	if (g_bEventFromPanic)
		return (g_cAlarmLimit.IntValue > 0) ? g_cAlarmLimit.IntValue : 0;

	if (g_iMapLimitCur >= 0)
		return g_iMapLimitCur;
	if (g_iMapLimitDefault >= 0)     // 【v2.4.0】文件里 `* N` 的默认值
		return g_iMapLimitDefault;
	if (g_cLimit.IntValue > 0)
		return g_cLimit.IntValue;
	return 0;                            // -1 / 0 = 不限（保持原版无限补充）
}

/** 【v2.4.0】上限是从哪来的（日志用） */
void GetCapSource(char[] sBuf, int iMaxLen)
{
	if (g_iMapLimitCur >= 0)
		strcopy(sBuf, iMaxLen, "按图限量文件(本图)");
	else if (g_iMapLimitDefault >= 0)
		strcopy(sBuf, iMaxLen, "按图限量文件(* 默认行)");
	else
		strcopy(sBuf, iMaxLen, "ltt_megamob_limit");
}

/**
 * 【v2.1.0】数"实际刷出来的"普通感染者。
 * 【v2.8.0 · 按车主口径改播报】这里**只负责计数**，不再按"清理到 1/4"播报 ——
 *   车主 2026-10-07：「我没手动清理僵尸都提示减少了，能不能改成定时器播报间隔 30 秒播报还剩余多少，
 *   而不是清理了百分之多少就播报」。⇒ 播报改由 `Timer_AnnounceTick`（默认每 30 秒）负责。
 *
 * ⚠ 口径说明（车主关心的"为什么没打也变少"）：
 *   `剩余 = 上限 − 已刷出`，所以它**随僵尸刷出来而下降**，不是"被你打掉才下降"。
 *   例：150 只的上限，场上刷出 37 只时就会显示"113 个剩余"（= 还没出现的 113 只，
 *   场上活着的那些也算在"还没处理完"里）。这与 anne 那台服的口径完全一致。
 *   真正"打掉一只就少一只"的数是「场上活着的普通感染者数」，受 `z_common_limit`(本服 20) 限制，
 *   会一直贴着 20 上下浮动 —— 那个数不适合做"还剩多少只要打"的进度条。
 *
 * 【v2.9.0 · 必修缺陷】**只数"机关尸潮的"普通感染者，不数地图背景/游荡的**。
 *   实测（2026-10-07 19:00 c2m2_fairgrounds）：日志打出 `实际刷出 173 只`，而上限是 150 ——
 *   173 里混进了**窗口期内自然刷出的游荡小怪**。后果两个：
 *     ① 数字虚高、玩家看不懂（"我只放 150，怎么刷了 173"）；
 *     ② 更糟：**游荡小怪会白吃掉 150 的份额** ⇒ 机关实际刷不到 150 就提前封顶。
 *   判据：机关尸潮从**待生成队列**出来（`m_nPendingMobCount > 0`），背景/游荡不走这个队列
 *   ⇒ `pending <= 0` 时创建的 infected **不计入机关份额**，单独累计到 `g_iEventWander` 供日志核对。
 *
 * ⚠ 与击杀数的差异（车主问的"面板才 129"）：**刷出 ≠ 击杀**。
 *   KD 面板数的是**被生还者打死的**；被队伍甩在后面被引擎回收、或被世界处死的不会计入击杀。
 *   所以 `150 刷出 → 129 击杀` 这类差值属正常（差多少取决于这张图跑了多远）。
 */
public void OnEntityCreated(int entity, const char[] classname)
{
	if (!g_bEventActive || g_iEventCap <= 0)
		return;
	if (classname[0] != 'i' || strcmp(classname, "infected") != 0)
		return;

	// 【v2.9.0】背景/游荡的不算机关份额（详见上面注释）
	if (L4D2Direct_GetPendingMobCount() <= 0)
	{
		g_iEventWander++;
		return;
	}

	g_iEventSpawned++;

	if (!g_cAnnounce.BoolValue)
		return;

	// 刷满：报"没有普通感染者了！"（与实况同文案）
	if (g_iEventSpawned >= g_iEventCap && !g_bEventDoneAnnounced)
	{
		g_bEventDoneAnnounced = true;
		PrintToChatAll("\x04<尸潮>\x01 没有普通感染者了！");
	}
}

/**
 * 【v2.8.0】定时播报"还剩多少只" —— 车主指定：**每 30 秒报一次，而不是按清理百分比报**。
 * 间隔由 `ltt_megamob_announce_interval` 控制（默认 30 秒，0 = 关掉定时播报）。
 * 窗口打开时启动、窗口关闭时杀掉（见 ResetEventWindow），所以不会在机关结束后继续喊。
 */
public Action Timer_AnnounceTick(Handle timer)
{
	if (!g_bEventActive || g_iEventCap <= 0)
		return Plugin_Stop;                  // 窗口已关，自己收工（双保险）

	if (!g_cAnnounce.BoolValue)
		return Plugin_Continue;

	int iLeft = g_iEventCap - g_iEventSpawned;
	if (iLeft <= 0)
		return Plugin_Continue;              // 已经刷满，"没有普通感染者了！"由上面负责

	PrintToChatAll("\x04<尸潮>\x01 %d 个普通感染者剩余..", iLeft);
	if (g_cLog.BoolValue)
		LogMessage("[MegaMob] 定时播报（每 %.0f 秒）：上限 %d − 已刷 %d = 剩余 %d｜队列 %d",
			g_cAnnounceInterval.FloatValue, g_iEventCap, g_iEventSpawned, iLeft,
			L4D2Direct_GetPendingMobCount());
	return Plugin_Continue;
}

/** 【v2.8.0】窗口打开时启动定时播报（已在跑就不重复开）。 */
void StartAnnounceTimer()
{
	if (g_cAnnounceInterval.FloatValue <= 0.0)
		return;
	if (g_hAnnTimer != null)
		return;
	g_hAnnTimer = CreateTimer(g_cAnnounceInterval.FloatValue, Timer_AnnounceTick, _,
		TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

/** 【v2.8.0】窗口关闭时停掉定时播报。 */
void StopAnnounceTimer()
{
	if (g_hAnnTimer != null)
	{
		KillTimer(g_hAnnTimer);
		g_hAnnTimer = null;
	}
}

// =====================================================================================
// 【v2.0.0】机关事件尸潮【固定总量】—— 机制与判据见文件头 v2.0.0 段
// =====================================================================================

// =====================================================================================
// 【v2.6.0】坦克期间暂停尸潮 —— 详见 L4D_OnSpawnMob 里的注释
// =====================================================================================

/** 【v2.7.0】尸潮计时器剩余秒数（-1 = 计时器还没启动）。
 *  用新 API：旧的 `L4D_GetMobSpawnTimerRemaining` 已被标 deprecated，
 *  直接调用会吃 warning 234 —— 本工程要求 0 错 0 警，所以包一层。 */
float LttMobTimerRemaining()
{
	if (!L4D2_CTimerHasStarted(L4D2CT_MobSpawnTimer))
		return -1.0;
	return L4D2_CTimerGetRemainingTime(L4D2CT_MobSpawnTimer);
}

/** 场上有没有活着的 Tank（玩家或 AI 控制都算）。*/
bool LttTankUp()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i))
			continue;
		if (GetEntProp(i, Prop_Send, "m_zombieClass") == ZC_TANK)
			return true;
	}
	return false;
}

/** 【v2.6.1】最前生还者比坦克领先多少导航路程（>0 = 生还者在前面）。取不到返回 0。 */
float LttFlowGap()
{
	float tankFlow = -1.0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsPlayerAlive(i))
			continue;
		if (GetEntProp(i, Prop_Send, "m_zombieClass") != ZC_TANK)
			continue;
		float f = L4D2Direct_GetFlowDistance(i);
		if (f > tankFlow)
			tankFlow = f;
	}
	if (tankFlow < 0.0)
		return 0.0;

	float survFlow = -1.0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
			continue;
		float f = L4D2Direct_GetFlowDistance(i);
		if (f > survFlow)
			survFlow = f;
	}
	if (survFlow < 0.0)
		return 0.0;

	return survFlow - tankFlow;
}

/** 【v2.6.1】坦克是不是已经被甩开（生还者按导航路程领先超过豁免距离）。 */
bool LttTankBypassed()
{
	if (g_cTankBypass.FloatValue <= 0.0)
		return false;                    // 0 = 永不豁免
	return LttFlowGap() > g_cTankBypass.FloatValue;
}

/** 关窗并结算本次机关（放行/拦掉各多少只）。 */
void ResetEventWindow(const char[] sWhy)
{
	// =================================================================================
	// 【v2.9.1 · 关键顺序修正】**先把状态清干净，再做其它任何事**。
	//
	// 实测事故（2026-10-07 19:08 c2m3→c2m4 换图）：日志打出了两条 `机关事件结束`（说明本函数跑了），
	// 但**之后 19:10/19:11 的日志显示计数器根本没被清零**（`已刷 150` / `期间游荡 42→104` 一路累加）
	// ⇒ 新地图的机关一进来就被判"已经刷满 150" ⇒ **整局被拦、不播报**（车主："C2M4 的机关没提示了"）。
	//
	// 最可能的原因：原来重置语句排在 `StopAnnounceTimer()` **之后**，而播报定时器带
	// `TIMER_FLAG_NO_MAPCHANGE`（换图时被引擎自己杀掉）⇒ `g_hAnnTimer` 成了**悬空句柄**，
	// 下一次 `KillTimer(悬空句柄)` 一旦出问题，**后面的赋值全被跳过**（日志已打完，所以看不出来）。
	//
	// 修法（不管根因是哪个，这样都不可能再犯）：
	//   ① 要打日志的数值先抓下来，**状态清零提到函数最前面**，任何后续操作失败都不影响；
	//   ② `g_hAnnTimer` / `g_hEventTimer` 在 `OnMapEnd()` 里置空（定时器被引擎杀掉时不让句柄悬空）。
	// =================================================================================
	bool bWasActive = g_bEventActive;
	int  iNo = g_iEventNo, iAllow = g_iEventQueued, iBlock = g_iEventBlocked;
	int  iCap = g_iEventCap, iSpawn = g_iEventSpawned, iWander = g_iEventWander;

	g_bEventActive  = false;
	g_iEventCap     = 0;
	g_iEventQueued  = 0;
	g_iEventBlocked = 0;
	g_iEventSpawned = 0;
	g_iEventWander  = 0;
	g_iEventCalls   = 0;
	g_flLastHordeAt = 0.0;
	g_flLastSpawnMobAt = 0.0;   // 【v2.7.0】换图必须清，否则 GetGameTime() 归零会算出负间隔
	g_iPrevAmount      = 0;
	g_bPanicOpened     = false;
	g_bEventDoneAnnounced = false;
	g_bLastWasCapped = (bWasActive && iCap > 0 && iSpawn >= iCap);   // 【v2.9.2】
	g_bEventFromPanic = false;                                       // 【v2.10.0】

	if (bWasActive && g_cLog.BoolValue)
	{
		// 【v2.9.3】措辞修正：「放行/拦掉」是**引擎补货请求量**的累加（补货语义是"刷新队列到 N"，会重复计），
		//   不是僵尸数 —— 车主看到 `放行 1540 只` 会以为刷了 1540 只。真正有意义的是「实际刷出」那一项。
		LogMessage("[MegaMob] 机关事件结束（%s）：本图第 %d 次机关 ｜机关实际刷出 %d 只（上限 %d）+ 期间游荡 %d 只（不计份额）｜引擎补货请求累计：放行 %d / 拦掉 %d（按请求量计，非实际刷出数）",
			sWhy, iNo, iSpawn, iCap, iWander, iAllow, iBlock);
	}

	StopAnnounceTimer();          // 【v2.8.0】窗口关了就别再喊"还剩多少"
}

/** 【v2.9.1】地图结束时把两个定时器句柄置空 —— 它们带 TIMER_FLAG_NO_MAPCHANGE，
 *  会被引擎自己杀掉；不置空就成了悬空句柄，下次 KillTimer 可能抛错并跳过后续语句。 */
public void OnMapEnd()
{
	g_hAnnTimer   = null;
	g_hEventTimer = null;
}

public void Event_RoundStart(Event hEvent, const char[] sName, bool bDontBroadcast)
{
	ResetEventWindow("新回合");
}

/**
 * 【v2.7.0】恐慌/机关事件开始 —— 精确的"机关开启"信号（不需要 gamedata、不需要猜事件名）。
 *
 * 为什么加它：c2m2_fairgrounds 实测（2026-10-07 18:44:44 第一发 amount=30 → 18:45:15 amount=21，
 * **中间隔了 30.5 秒** → 18:45:16 才连续）⇒ 只靠"连续两发"会**延迟 30 秒才播报**，
 * 车主原话："C2M2 后面的机关开启一瞬间没提示，过一会才有"。
 * 这个事件在机关开启的瞬间就触发 ⇒ 窗口立刻打开，第一波尸潮一到就播报（延迟从 30 秒降到 1 秒级）。
 *
 * ⚠ 防误报：**开窗时先不播报**（`g_bPanicOpened`），等第一波尸潮真到了再喊 ——
 *   所以就算车喇叭/别的什么东西也触发这个事件，玩家也不会看到假的"有限尸潮"。
 *   日志会记录每次 create_panic_event（含尸潮计时器剩余），验一两次就知道它准不准。
 */
public void Event_PanicEvent(Event hEvent, const char[] sName, bool bDontBroadcast)
{
	g_iPanicEvents++;

	if (g_cLog.BoolValue)
		LogMessage("[MegaMob] create_panic_event（本图第 %d 次）：尸潮计时器剩余=%.1fs｜窗口=%s",
			g_iPanicEvents, LttMobTimerRemaining(), g_bEventActive ? "已开" : "未开");

	if (!g_cEnable.BoolValue || !g_cFinite.BoolValue)
		return;

	if (g_bEventActive)
	{
		g_flLastHordeAt = GetGameTime();     // 已开窗：只刷新活跃时间（别把结算切断）
		return;
	}

	g_bEventActive  = true;
	g_bEventFromPanic = true;   // 【v2.10.0】警报车：用 alarm_limit（默认 50）
	g_bPanicOpened  = true;                  // 播报延到"第一波尸潮到达"那一刻
	g_iEventNo++;
	g_iEventQueued  = 0;
	g_iEventBlocked = 0;
	g_iEventSpawned = 0;
	g_iEventWander  = 0;
	g_bEventDoneAnnounced = false;
	g_iEventCalls = 0;
	g_iEventCap = ResolveEventCap();
	g_flLastHordeAt = GetGameTime();

	char sSrc[48];
	GetCapSource(sSrc, sizeof(sSrc));
	if (g_cLog.BoolValue)
		LogMessage("[MegaMob] 机关事件开始（本图第 %d 次）：来源=create_panic_event｜上限 %d｜来源=%s",
			g_iEventNo, g_iEventCap, sSrc);

	StartAnnounceTimer();     // 【v2.8.0】即使播报要等第一波尸潮，定时播报也可以先起来
}

/** 每 1 秒巡检：eventgap 秒内没有任何尸潮排队 ⇒ 判本次机关事件结束（下一处机关重新算 XX） */
public Action Timer_EventWatch(Handle timer)
{
	if (g_bEventActive && g_cEventGap.FloatValue > 0.0
		&& GetGameTime() - g_flLastHordeAt > g_cEventGap.FloatValue)
	{
		ResetEventWindow("安静超时");
	}
	return Plugin_Continue;
}

/**
 * 机关 / 自然定时 / onslaught 尸潮都会走这里（Boomer 呕吐与 z_spawn mob 走 SpawnITMob，刻意不碰）。
 *
 * 【v2.3.0 判定改了 —— 实测逼出来的】
 *   v2.2.0 用 `amount > z_mob_spawn_max_size` 判"机关"，结果**真人局里一条都没命中**：
 *   2026-10-07 14:41 c2m4_barns 真人局的原始日志是
 *       `SPAWNMOB amount=30 自然上限=30 判定=自然 窗口=关 队列=30`  ← **每秒一发，连了十几秒**
 *   —— 机关期间引擎**每秒**调一次、每次正好 **30**，而 30 **恰好等于** `z_mob_spawn_max_size`
 *   ⇒ `30 > 30` 为假，全被当成自然尸潮放过。**"比单次数量"这条路是死的。**
 *
 *   改用**连续排队频率**：自然尸潮是几分钟才一发的单发调用；机关/无限尸潮是**连续每秒一发**。
 *   ⇒ 距上次 SpawnMob ≤ `ltt_megamob_eventwin`（默认 5 秒）即判为事件尸潮。
 *   实测区分度极高（1 秒 vs 几分钟），不会两边踩线。
 *
 * 处理：余量够→放；超了→只放余量（Plugin_Changed）；余量为 0→整笔拦掉（Plugin_Handled）。
 */
public Action L4D_OnSpawnMob(int &amount)
{
	if (!g_cEnable.BoolValue || !g_cFinite.BoolValue || amount <= 0)
		return Plugin_Continue;

	// =================================================================================
	// 【v2.6.0】坦克期间暂停尸潮（车主指定"一定要加"）
	//   搬到最前面：坦克在场时**根本不进入机关判定**，避免开窗/记账被坦克局污染。
	//   与 anne 一致：连"已经排进待生成队列"的也清零 ⇒ 是真"暂停"，不是"只拦新增"。
	//   Tank 死后：引擎会继续照常补货，那时才可能开窗、按上限限流。
	// =================================================================================
	if (g_cHoldTank.BoolValue && LttTankUp())
	{
		// 【v2.6.1】坦克"已经被甩开"就不按了 —— 一只掉队/卡住的坦克不该把整局尸潮按死。
		if (LttTankBypassed())
		{
			g_iTankBypassCalls++;
			float nowB = GetGameTime();
			if (g_cLog.BoolValue && (nowB - g_flTankBypassLogAt) >= 30.0)
			{
				g_flTankBypassLogAt = nowB;
				LogMessage("[MegaMob] 坦克已被甩开 ⇒ 尸潮放行（不暂停）：最前生还者领先坦克 %.0f > 豁免 %.0f（本图累计 %d 次｜tank_bypass=%.0f）",
					LttFlowGap(), g_cTankBypass.FloatValue, g_iTankBypassCalls, g_cTankBypass.FloatValue);
			}
		}
		else
		{
			L4D2Direct_SetPendingMobCount(0);
			g_iTankHoldCalls++;
			float nowT = GetGameTime();
			if (g_cLog.BoolValue && (nowT - g_flTankHoldLogAt) >= 30.0)
			{
				g_flTankHoldLogAt = nowT;
				LogMessage("[MegaMob] 坦克期间暂停尸潮：本次 %d 只拦下 + 待生成队列清零（本图累计 %d 次｜hold_tank=%d｜坦克领先差=%.0f）",
					amount, g_iTankHoldCalls, g_cHoldTank.IntValue, LttFlowGap());
			}
			if (!g_cAct.BoolValue)
				return Plugin_Continue;      // 只记录模式：不动游戏
			amount = 0;
			return Plugin_Handled;
		}
	}

	float now = GetGameTime();
	float fGap = (g_flLastSpawnMobAt > 0.0) ? (now - g_flLastSpawnMobAt) : 999999.0;
	bool bBurst = (fGap <= g_cEventWin.FloatValue);   // 连续排队 = 事件尸潮
	// 【v2.7.0】大额单发判据：amount 超过自然尸潮上限 ⇒ 机关 mega mob。
	//   实测（2026-10-07 18:42 c3m1_plankcountry）：机关就是**一发 amount=50 之后再无第二发**
	//   ⇒ 只靠"连续两发"永远不触发（车主的原话："C3M1 实测开了机关没反应"）。
	int iNatMax = (g_cvNatMax != null) ? g_cvNatMax.IntValue : 30;
	bool bBig = (amount > iNatMax);
	// 【v2.3.1】记住"上一发"：开窗是由**第二发**触发的，第一发也要算进总量，
	//   否则一次 150 的限量会实际放出 150+30（第一发漏计）。
	int iPrev = (g_flLastSpawnMobAt > 0.0) ? g_iPrevAmount : 0;
	g_flLastSpawnMobAt = now;
	g_iPrevAmount = amount;

	// =================================================================================
	// 【v2.9.2】忽略"已刷满后引擎继续补货" —— 车主 C2M4 体感问题的根因之一
	//   实测（2026-10-07 19:06~19:08 c2m3）：尸潮刷满 150 后，**引擎仍然每秒调 SpawnMob 试图补货**
	//   （19:07:31 / 19:07:56 …），而拦截时我**也刷新了"最后活跃时间"** ⇒ 安静超时永远不成立
	//   ⇒ **窗口一直开着、`已刷` 一直是 150** ⇒ 同一张图的**第二个机关一进来就被整局拦掉、连播报都没有**。
	//   修法：上一次是"刷满关闭"、而引擎仍在持续补货（间隔 < eventgap）⇒ 那只是已结束的尸潮在补货，
	//   不是新机关 ⇒ 直接忽略（否则第二次开窗会把 150 的份额再放一遍）。
	// =================================================================================
	if (!g_bEventActive && g_bLastWasCapped && fGap < g_cEventGap.FloatValue)
	{
		if (g_cLog.BoolValue && (now - g_flIgnoredLogAt) >= 30.0)
		{
			g_flIgnoredLogAt = now;
			LogMessage("[MegaMob] 忽略补货：上次机关已刷满 %d，引擎仍在补货（距上次 %.1fs < eventgap %.1fs）⇒ 不当成新机关",
				g_iEventCap, fGap, g_cEventGap.FloatValue);
		}
		return Plugin_Continue;
	}

	// ---- 没开窗、既不是大额单发也不是连续排队 ⇒ 自然尸潮，完全不碰 ----
	if (!g_bEventActive && !bBurst && !bBig)
	{
		if (g_cVerbose.BoolValue && g_cLog.BoolValue)
			LogMessage("[MegaMob] SPAWNMOB amount=%d 距上次=%.1fs 自然上限=%d 尸潮计时器剩余=%.1fs 判=自然单发（不干预）",
				amount, fGap, iNatMax, LttMobTimerRemaining());
		return Plugin_Continue;
	}

	// ---- 开窗：连续排队的下一发 / 大额单发 / 恐慌事件已开窗 ----
	if (!g_bEventActive)
	{
		g_bEventActive  = true;
		g_bEventFromPanic = false;  // 【v2.10.0】非警报车：用 ltt_megamob_limit（默认 150）
		g_bLastWasCapped = false;   // 【v2.9.2】新窗口开始，清掉「上次刷满」标记
		g_iEventNo++;
		// 大额单发时不要把"上一发"（可能是上一张图/上一次自然尸潮的量）算进来
		g_iEventQueued  = (bBurst ? (iPrev + amount) : amount);
		g_iEventBlocked = 0;
		g_iEventSpawned = 0;
	g_iEventWander  = 0;
		g_bEventDoneAnnounced = false;
		g_iEventCalls = 1;
		g_iEventCap = ResolveEventCap();
		g_flLastHordeAt = now;

		if (g_cLog.BoolValue)
		{
			char sSrc[48];
			GetCapSource(sSrc, sizeof(sSrc));
			LogMessage("[MegaMob] 机关事件开始（本图第 %d 次）：%s｜amount=%d 距上次=%.1fs 自然上限=%d 尸潮计时器剩余=%.1fs｜计入总量 %d｜上限 %d｜来源=%s｜limit=%d｜act=%d",
				g_iEventNo,
				bBig ? "大额单发(>自然上限)" : "连续排队",
				amount, fGap, iNatMax, LttMobTimerRemaining(),
				g_iEventQueued, g_iEventCap, sSrc, g_cLimit.IntValue, g_cAct.IntValue);
		}

		// 【v2.1.0】开波播报（文案对齐 anne 那台服）
		if (g_cAnnounce.BoolValue && g_iEventCap > 0)
			PrintToChatAll("\x04<尸潮>\x01 一场有限尸潮开始了！本轮共有 \x03%d\x01 个普通感染者！是冲还是等，你来决定！",
				g_iEventCap);

		StartAnnounceTimer();     // 【v2.8.0】起定时播报（每 30 秒报一次剩余）
	}
	else
	{
		// 【v2.9.2】**不再在这里刷新 g_flLastHordeAt**：刷满了就让它安静下来，
		//   否则引擎一直补货、窗口永远不关（旧行为）。真正"放行"时才刷新（见下面的放行分支）。
		g_iEventCalls++;

		// 【v2.7.0】窗口是 create_panic_event 开的、播报还欠着 ⇒ **第一波尸潮真到了才喊**
		//（这样即使那个事件被车喇叭之类误触发，也不会出现假的"有限尸潮"播报）
		if (g_bPanicOpened)
		{
			g_bPanicOpened = false;
			if (g_cLog.BoolValue)
				LogMessage("[MegaMob] 第一波尸潮到达 ⇒ 补播报（窗口由 create_panic_event 开）：amount=%d 上限 %d",
					amount, g_iEventCap);
			if (g_cAnnounce.BoolValue && g_iEventCap > 0)
				PrintToChatAll("\x04<尸潮>\x01 一场有限尸潮开始了！本轮共有 \x03%d\x01 个普通感染者！是冲还是等，你来决定！",
					g_iEventCap);
		}

		// 【v2.3.0】日志节流：机关期间每秒一发，逐条打会把日志刷爆（实测 14 秒 32 行）
		if (g_cVerbose.BoolValue && g_cLog.BoolValue && (g_iEventCalls <= 3 || (g_iEventCalls % 25) == 0))
			LogMessage("[MegaMob] SPAWNMOB(窗口内第 %d 发) amount=%d 距上次=%.1fs 已刷 %d + 队列 %d / 上限 %d",
				g_iEventCalls, amount, fGap, g_iEventSpawned,
				L4D2Direct_GetPendingMobCount(), g_iEventCap);
	}

	// ---- 上限 0 = 不限（原版无限补充）----
	if (g_iEventCap <= 0)
		return Plugin_Continue;

	// 【v2.3.2 · 关键修正】上限判据改成 "**实际刷出 + 已在待生成队列** ≥ 上限"。
	//
	// 为什么不能累加每次的 amount（v2.0.0~v2.3.1 的错）——2026-10-07 14:45 真人局日志：
	//     14:45:08 放行 +30 → 已放 90/150 ｜队列=14
	//     14:45:09 放行 +30 → 已放 120/150 ｜队列=30
	//     14:45:10 放行 +30 → 已放 150/150 ｜队列=30     ← 3 秒就"用光"了 150
	//     14:45:32 拦截补充…累计拦 660 只｜队列=17
	//     14:46:54 拦截补充…队列=0                        ← 队列排空，尸潮**断在 37 只**
	// 车主原话："之后就没刷了"。
	// ⇒ **`amount` 是"补货量"不是"预算"**：引擎每秒补 30、队列水位稳定在 30 左右；
	//   累加 amount 会在几秒内把上限用光，然后连保持水位的补货都拦掉 ⇒ 尸潮提前断。
	// ⇒ 正确判据 = **数"实际刷出来的"**（horde_equaliser 用的也是这个口径），
	//   并且把"已经排在队列里、马上要出来的"也算上，才不会超发。
	int iPending = L4D2Direct_GetPendingMobCount();
	int iRemain = g_iEventCap - (g_iEventSpawned + iPending);

	// 余量已为 0 / 负数：整笔拦掉
	if (iRemain <= 0)
	{
		g_iEventBlocked += amount;
		if (g_cClearPending.BoolValue)
			L4D2Direct_SetPendingMobCount(0);
		// 【v2.3.1】节流：机关每秒一发，逐条记会刷爆日志
		if (g_cLog.BoolValue && (g_iEventCalls <= 3 || (g_iEventCalls % 25) == 0))
			LogMessage("[MegaMob] 机关拦截补充（第 %d 次/窗口内第 %d 发）：已刷 %d + 队列 %d ≥ 上限 %d，本次 %d 只拦下｜累计拦 %d 只｜clearpending=%d",
				g_iEventNo, g_iEventCalls, g_iEventSpawned, iPending, g_iEventCap,
				amount, g_iEventBlocked, g_cClearPending.IntValue);
		if (!g_cAct.BoolValue)
			return Plugin_Continue;      // 只记录模式：不动游戏
		amount = 0;
		return Plugin_Handled;
	}

	// 【v2.3.3】还差一点点：把这一发补货**按余量截断**（余量 5 就只补 5）。
	//   为什么要截断：v2.3.2 放行了"最后一整发"，实测刷到 **180 只**（上限 150，超发一整发 30）——
	//   因为放行那一刻 `已刷+队列` 还差一点没到上限，补完 30 只就冲过去了。
	//   截断不会把水位掐死：补完这一发，队列刚好够"刷到上限"，之后走上面的整笔拦截。
	if (amount > iRemain)
	{
		g_iEventBlocked += (amount - iRemain);
		if (g_cLog.BoolValue)
			LogMessage("[MegaMob] 机关末发截断（第 %d 次/窗口内第 %d 发）：本次 %d 只 → 只补余量 %d 只（已刷 %d + 队列 %d，上限 %d）",
				g_iEventNo, g_iEventCalls, amount, iRemain, g_iEventSpawned, iPending, g_iEventCap);
		if (!g_cAct.BoolValue)
			return Plugin_Continue;
		amount = iRemain;
		return Plugin_Changed;
	}

	// 余量充足：照原版放（保持引擎自己的"补货"节奏）
	g_flLastHordeAt = now;          // 【v2.9.2】只有"真的放行"才算机关还活着
	g_iEventQueued += amount;
	if (g_cLog.BoolValue && (g_iEventCalls <= 3 || (g_iEventCalls % 25) == 0))
		LogMessage("[MegaMob] 机关放行（第 %d 次/窗口内第 %d 发）：+%d → 已刷 %d + 队列 %d = %d / 上限 %d",
			g_iEventNo, g_iEventCalls, amount, g_iEventSpawned, iPending,
			g_iEventSpawned + iPending, g_iEventCap);
	return Plugin_Continue;
}

void ShowMegamobMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Megamob);

	char sMode[16];
	GetModeName(g_cMode.IntValue, sMode, sizeof(sMode));

	char sTitle[128];
	FormatEx(sTitle, sizeof(sTitle), "机关尸潮（mega mob）—— 档位：%s\n固定总量：%s（拦截：%s）\n ",
		sMode,
		g_cFinite.BoolValue ? "开" : "关",
		g_cAct.BoolValue ? "真拦" : "只记录");
	menu.SetTitle(sTitle);

	char sItem[96];

	FormatEx(sItem, sizeof(sItem), "%s 原版（50 只 / 420~900 秒）", g_cMode.IntValue == 0 ? "✓" : "　");
	menu.AddItem("0", sItem);

	FormatEx(sItem, sizeof(sItem), "%s 减半（25 只 / 间隔不变）", g_cMode.IntValue == 1 ? "✓" : "　");
	menu.AddItem("1", sItem);

	FormatEx(sItem, sizeof(sItem), "%s 关闭机关尸潮（0 只）", g_cMode.IntValue == 2 ? "✓" : "　");
	menu.AddItem("2", sItem);

	FormatEx(sItem, sizeof(sItem), "%s 自定义（当前 %d 只 / %d~%d 秒）",
		g_cMode.IntValue == 3 ? "✓" : "　",
		g_cSize.IntValue, g_cMinInt.IntValue, g_cMaxInt.IntValue);
	menu.AddItem("3", sItem);

	// 【v2.0.0】机关事件固定总量（车主真正要的那条）
	FormatEx(sItem, sizeof(sItem), "%s 机关固定总量：%s（机关只刷原版那么多，后续不补）",
		g_cFinite.BoolValue ? "✓" : "　", g_cFinite.BoolValue ? "开" : "关");
	menu.AddItem("10", sItem);

	FormatEx(sItem, sizeof(sItem), "%s 拦截动作：%s",
		g_cAct.BoolValue ? "✓" : "　", g_cAct.BoolValue ? "真拦" : "只记录不拦");
	menu.AddItem("11", sItem);

	// 【v2.1.0】玩家播报
	FormatEx(sItem, sizeof(sItem), "%s 玩家播报：%s（开始/剩余/结束）",
		g_cAnnounce.BoolValue ? "✓" : "　", g_cAnnounce.BoolValue ? "开" : "关");
	menu.AddItem("12", sItem);

	// 【v2.6.0】坦克期间暂停尸潮
	FormatEx(sItem, sizeof(sItem), "%s 坦克期间暂停尸潮：%s",
		g_cHoldTank.BoolValue ? "✓" : "　", g_cHoldTank.BoolValue ? "开" : "关");
	menu.AddItem("13", sItem);

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Megamob(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char sInfo[8];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		int iId = StringToInt(sInfo);

		// 【v2.0.0】10/11 是开关，不是档位（档位只有 0~3）
		if (iId == 10)
			g_cFinite.SetInt(g_cFinite.BoolValue ? 0 : 1);
		else if (iId == 11)
			g_cAct.SetInt(g_cAct.BoolValue ? 0 : 1);
		else if (iId == 12)
			g_cAnnounce.SetInt(g_cAnnounce.BoolValue ? 0 : 1);
		else if (iId == 13)
			g_cHoldTank.SetInt(g_cHoldTank.BoolValue ? 0 : 1);
		else
			g_cMode.SetInt(iId);      // 立刻触发 ApplyMegamob（AddChangeHook）

		ShowMegamobMenu(param1);      // 回显，让车主看见 ✓ 挪过去了
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

/** 档位名。SourcePawn 不能返回数组字面量，所以用"拷进缓冲"的写法。 */
void GetModeName(int iMode, char[] sBuf, int iMaxLen)
{
	switch (iMode)
	{
		case 1:  { strcopy(sBuf, iMaxLen, "减半");   return; }
		case 2:  { strcopy(sBuf, iMaxLen, "关闭");   return; }
		case 3:  { strcopy(sBuf, iMaxLen, "自定义"); return; }
	}
	strcopy(sBuf, iMaxLen, "原版");
}
