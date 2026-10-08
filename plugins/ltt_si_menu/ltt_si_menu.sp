/**
 *  ltt_si_menu  v1.2.13  —— 刷特设置的玩家菜单 + 原生投票（F1 同意 / F2 反对）
 *
 *  ================== v1.2.21：坦克期策略 + 特感游戏模式 ==================
 *
 *  服主 2026-10-05 定：再加两个可投票项，**都只是把值转发给刷特插件的已有 cvar**，
 *  本插件照旧只 FindConVar，不引用刷特插件的任何函数（软连接不变）。
 *
 *    ① 坦克期策略   -> ltt_sispawn_tank_action（int 0/1/2）
 *         0 = 不干预（原版行为）
 *         1 = 接管·坦克期收紧（默认）：坦克期上限收到 8、每职业最多 2~3 只，照常刷
 *         2 = 坦克期一只都不刷（坦克登场期间完全不刷特感，坦克死了自动恢复）
 *       注：这个 cvar 在 BindCvars() 里早就绑了，但一直**只用于显示**
 *       （"坦克在场：上限已收紧到 N"那段显示逻辑本次一字未动）。
 *
 *    ② 特感游戏模式 -> ltt_sispawn_classes（int 位掩码：1烟鬼 2胖子 4猎人 8毒妇 16骑师 32牛）
 *         63 = 全部六种（默认：烟鬼/胖子/猎人/毒妇/骑师/牛 都会出）
 *         53 = 四控模式（1+4+16+32）：只出能控人的四种，不出胖子、毒妇
 *       档位表按"档"写（g_iClasses[] 里放的是 cvar 原值 63/53），以后加档
 *       只在**末尾**追加，下标顺序不动 —— 存档里存的是下标。
 *
 *  写值之前都夹了值域（tank_action 0~2 / classes 1~63）；两个 cvar 都判空，
 *  刷特插件没加载时菜单只显示"! 没读到 …"，不会崩。
 *  存档新增 "tank" / "classes" 两个键（存下标）；空服还原 / sm_sireset 也一起还原。
 *
 *  v1.2.13 【口径 bug 修复 · 服主 2026-09-27 实测反馈】
 *    现象：第 5 个玩家进服时刷特播报"每波 6 只"，但菜单/查询里还是显示 4 只。
 *    根因（两个函数，同一类错）：
 *      ① `GetEffWaveSafe()` —— 名字和注释都说是【生效值】，正文却只
 *         `return g_cWave.IntValue`（设的值）。于是调用点那句
 *         `if (GetEffWaveSafe() != g_cWave.IntValue)` 是**恒假**的：
 *         「人数缩放 +N」那行永远不会打印，"每波数量"永远显示设的值。
 *      ② `EffectiveCap()` —— 本地算坦克上限+槽位硬上限，**漏了人数缩放**，
 *         于是 9 处"实际生效 X 只"在 5 人时全都少报（显示 8、实际 12）。
 *    修法：两个函数都改成**优先读 ltt_si_spawner v1.18.2+ 的只读镜像 cvar**
 *      `ltt_sispawn_effwave` / `ltt_sispawn_effcap`（每 0.1 秒维护），
 *      读不到才退回本地算法。**不再自己维护第二份缩放公式。**
 *
 *  为什么要单独一个插件：
 *    最初选 Neko 多特的原因之一就是"自带投票插件方便点"。我们的 ltt_si_spawner
 *    本身只有管理员命令没有菜单，所以这里单独做一个玩家菜单，
 *    这样【刷特核心 + 刷特菜单 + 多特投票】可以各自独立打包，开箱即用。
 *
 *  与 ltt_si_spawner 的关系：软连接，不硬依赖。
 *    · 只用 FindConVar 读/写刷特插件的 cvar，不引用它的任何函数
 *    · 刷特插件没加载时菜单会提示"刷特插件未加载"，不会报错
 *
 *  v1.1.0 修的两个问题（服主 2026-09-23 截图反馈）：
 *    1. 【方框】原来把 \x05 之类颜色码写进了菜单标题，L4D2 的菜单**不解析颜色码**，
 *       会直接渲染成一个个方框。现在菜单标题/选项一律纯文本，
 *       颜色码只用在 PrintToChat / PrintToChatAll 里。
 *    2. 【没走游戏原生投票】原来是"点一下直接生效"。现在改成：
 *       选档位(SM菜单) → L4D2 原生投票面板 → F1 同意 / F2 反对 → 按通过率决定是否生效。
 *       和 Neko、以及本服 ltt_svote 用的是同一套 L4D2NativeVote 封装。
 *       · ltt_si_menu_vote 0 可以退回"点一下直接生效"
 *       · 原生投票不可用 / 在场真人不足 2 人时，自动直接生效（一个人没法投票）
 *
 *  菜单（标题只显示"几特几秒"，服主要求）：
 *      刷特设置
 *      当前: 4 特 / 40 秒
 *       1. 每波特感数量
 *       2. 特感刷新间隔
 *       3. 同时存活上限
 *       4. 刷新距离（离生还者多远）
 *       5. 查看本局设置
 *
 *  持久化：投过的结果写进 data/ltt_si_menu.txt，换图后由本插件在 cfg 执行完之后
 *  重新套用，不用每张图重投一次。管理员 sm_sireset 可一键恢复 cfg 默认值。
 *
 *  依赖：sourcemod + l4d2_nativevote（本服已装 L4D2 Native vote 0.4）
 *
 *  ================== v1.2.2：修「旁观者投票会把引擎投票锁卡死」 ==================
 *
 *  【事故现象】服主 2026-09-23 实测：
 *    进旁观 → 用 !si 菜单投票 → 投票卡住（面板出现但结束不了）
 *    → 之后切回生还者也发不出任何投票
 *    → **连 !chmap 换图投票都发不出来**
 *    → 最后只能重启服务器（服务器上只有他一个人才能安全重启）
 *
 *  【日志铁证】
 *      19:33:58 [SIMenu] 投票被拒：本地进行中=0 IsAllowNewVote=0
 *      19:38:40 [SIMenu] 投票被拒：本地进行中=0 IsAllowNewVote=0
 *    `本地进行中=0` 说明本插件没有任何投票在跑，而 `IsAllowNewVote=0`
 *    说明 **L4D2 引擎的全局投票锁还挂着** —— 引擎认为"有一个投票没结束"，
 *    于是拒绝一切新投票（包括别的插件的 !chmap）。
 *
 *  【根因】v1.1.0 里投票人名单写的是"所有在场真人（含旁观）"，当时的理由是
 *    "服主经常旁观测试，只算生还者的话他自己看不到投票面板"。但这个改动有致命副作用：
 *    旁观者会收下原生投票面板，**而引擎不把投票按键(F1/F2)交给旁观者** →
 *    这个投票永远等不到"所有人都投完" → 引擎投票锁一直挂着。
 *
 *  【参考实现】豆瓣酱整合包里的 `l4d2_map_vote`（fdxx）收投票人的条件是
 *    `... || (team = GetClientTeam(i)) < 2 || team > 3` → **只收 team 2/3**；
 *    而且它的换图投票菜单连 team 1 都直接拒绝打开。我们之前那套正好相反。
 *
 *  【本次修复】
 *    1. **投票人只算 team 2(生还者) / team 3(感染者)**，旁观一律排除 —— 根因修复。
 *    2. 发起人如果是旁观（他没有投票资格，起投票没意义）→ 走"直接生效"分支，
 *       这样服主旁观时菜单照样能用，和 v1.1.0 的初衷不冲突，但绝不会产生
 *       "旁观者在投票人名单里"的死锁。
 *    3. 新增【投票锁看门狗】(ltt_si_menu_lockwatch)：本插件没有投票在跑、
 *       而引擎锁连续挂住超过 ltt_si_menu_locksecs 秒（默认 30，比任何合法投票都长）
 *       就自动广播 VoteFail 尽力解锁并记日志 —— 兜住"别的插件把锁搞死"的情况。
 *
 *  【已知局限】`l4d2_nativevote` 只暴露了 `L4D2NativeVote_IsAllowNewVote()`，
 *    **没有任何"解锁/复位"原生**，所以看门狗只能广播 VoteFail（和 sm_siclose 同一手法）。
 *    它能不能真正释放引擎那把锁，**本机尚未复现验证过** —— 日志里会记录触发次数，
 *    下次真出现死锁时可以据此判断它到底管不管用。根治手段是第 1 条。
 *
 *  ================== v1.2.3：多特管理员菜单（!sia） ==================
 *
 *  服主 2026-09-23 定稿：**不给新插件，直接在 ltt_si_menu 里加管理员入口**。
 *  理由：① 同一个包（开箱即用，符合"多特插件跟多特投票菜单一起打包"的原意）
 *        ② `wave/time/cap/min/max` 的档位数组和 ApplySetting() 本来就在这里，
 *           **管理员菜单 = 复用同一套档位、只是跳过投票**。
 *
 *  结构（顶层 3 项，各子菜单 ≤7 项，所以不需要分页）：
 *      !sia → 【多特管理员菜单】
 *               1. 刷特设置（直接生效，不走投票）
 *               2. 现场操作
 *               3. 维护
 *               0. 退出
 *
 *  **软连接仍然成立**：本插件对 ltt_si_spawner 依旧只 FindConVar，不引用函数。
 *  需要刷特插件做动作时走 `ServerCommand("sm_sispawn_xxx")`（控制台命令解耦）。
 *
 *  **明确不做**：菜单里的"重载插件"。插件重载是异步的，失败会让插件处于
 *  **未加载**状态（今天踩过两次），放进菜单太容易把服务器搞挂。要重载请手动敲。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <usermessages>
#include <l4d2_nativevote>

#define PLUGIN_VERSION "1.2.23"

#define SET_WAVE 0
#define SET_TIME 1
#define SET_CAP  2
#define SET_DIST 3
#define SET_MODE 4          // 【v1.2.4】刷特挡位（0/1/2）
#define SET_PERPLAYER 5     // 【v1.2.11】进人加特感（ltt_sispawn_perplayer）
#define SET_RESCUE 6        // 【v1.2.18】救援关不刷特（ltt_sispawn_rescue_off，0/1/2）
#define SET_NEARBIAS 7      // 【v1.2.19】距离偏好（ltt_sispawn_nearbias，0/1）
#define SET_TANK 8          // 【v1.2.21】坦克期策略（ltt_sispawn_tank_action，0/1/2）
#define SET_GAMEMODE 9      // 【v1.2.21】特感游戏模式（ltt_sispawn_classes，位掩码 63/53）

// 【v1.2.1】按服主要求加大档位：
//   · 每波数量加上 12 / 20 / 26（26 = 4 生还者时"留 1 空位"下的物理满员值）
//   · 刷新间隔加一个最低档 5 秒
//   · 存活上限补 26，免得投了 26 特却被上限挡住
// 项数上限：见 ShowValueMenu() 里的分页设置 —— **每页 7 项**，第 8/9 格留给
// 「下一页 / 上一页」，退出占 "0"。档位表超过 7 项会自动翻页。
// 本节原来的说法（"退出按钮占第 10 格，所以每页最多 9 项"）描述的是
// `MENU_NO_PAGINATION` 的口径；v1.2.9 起显式启用了分页，口径已经不同。
// ⚠️ SourceMod 的**默认**分页值在核心二进制里，menus.inc 只有 `property` 声明、查不到
//    （我抓 sourcemod.net 的 API 页也只拿回索引）。所以这里是**显式**设 7、不依赖默认。
//    后果要说清：「每波」9 档现在也会翻页（7 项 + 下一页，第 2 页 2 项）。
#define WAVE_COUNT 9
#define TIME_COUNT 8
#define CAP_COUNT  7
#define DIST_COUNT 5

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

static const int  g_iWaves[WAVE_COUNT]      = { 2, 3, 4, 5, 6, 8, 12, 20, 26 };
// 【v1.2.9 · 服主定档】间隔档位：1/5/10/15/20/25/30/40（8 档）。
// 原来只有 {5,10,20,30,40,60} 六档：缺 1 秒（服主偶尔要极限快刷），也缺 15/25 这种中间档；
// 60 秒没人用（和空服还原的 cfg 默认 40 秒差太远），去掉。
// 8 档 > 每页 7 项 → **会翻页**（7 项 + 下一页，第 2 页 1 项）。这正是服主要试的形态，
// 用一段时间看有没有蹩脚的地方再定。
static const int  g_iTimes[TIME_COUNT]      = { 1, 5, 10, 15, 20, 25, 30, 40 };
static const int  g_iCaps[CAP_COUNT]        = { 4, 6, 8, 10, 14, 20, 26 };
// 【v1.2.5】新增第 5 档「宽松 1~1500」，并作为默认档。
//
// 起因：服主 2026-09-24 让参考两家的刷特插件，读完发现距离带都比我们宽得多：
//   · 豆瓣酱 specialspawner  v1.3.7：ss_spawnrange_min 100 / max 1500
//   · fdxx   l4d2_si_spawn_control：z_spawn_safety_range = 1 / spawn_range = 1500
//       （注释原文 "randomly spawn from 1 to this range"）
// 我们原来的「中 200~900」圈面积只有它们的约 1/3，这是开阔地形"找不到藏点"
// （进而凭空刷）的直接原因之一。
//
// 服主定稿：**默认就跟 fdxx 一样 1~1500**，但把 200~900 保留成一档，
// 因为那是另一种难度，要能随时切回来对比。
// 新档插在【末尾】—— 存档里存的是下标，插在中间会让老存档指到别的档。
static const int  g_iDistMin[DIST_COUNT]    = { 100, 200, 200, 400, 200 };
static const int  g_iDistMax[DIST_COUNT]    = { 500, 600, 900, 1500, 2000 };
static const char g_sDistName[DIST_COUNT][] = { "贴脸 100~500", "近 200~600", "中 200~900", "远 400~1500", "开阔 200~2000" };

// 【v1.2.4】刷特挡位（对应刷特插件的 ltt_sispawn_mode）
// 服主 2026-09-23 定稿：三档，做成投票项，且要能对比日志。
#define MODE_COUNT 3
static const char g_sModeName[MODE_COUNT][] =
{
	"原版引擎点位",
	"引擎+视野+分散",
	"自建落点优先"
};
static const char g_sModeDesc[MODE_COUNT][] =
{
	"纯引擎，不看视野",
	"引擎优先，看视野",
	"自建落点，最凶"
};

// 【v1.2.11】进人加特感（对应刷特插件的 ltt_sispawn_perplayer）
// 口径照抄刷特插件的 GetScaleStep / GetEffWave / GetEffCap：
//   每多 1 个生还者（超过 4 人之后）→ 每波 +N 只，存活上限同步 +N×2 只
// 前提：刷特插件的 ltt_sispawn_scaling 必须 = 1，否则这个 N 完全不起作用。
// cvar 允许 0~8，这里只挑 6 档，避免投票菜单翻页。
#define PERPLAYER_COUNT 6
static const int  g_iPerPlayers[PERPLAYER_COUNT]       = { 0, 1, 2, 3, 4, 6 };
static const char g_sPerPlayerName[PERPLAYER_COUNT][]  =
{
	"关",
	"+1 只/波（上限+2）",
	"+2 只/波（上限+4）",
	"+3 只/波（上限+6）",
	"+4 只/波（上限+8）",
	"+6 只/波（上限+12）"
};

// 【v1.2.18】救援关不刷特（ltt_sispawn_rescue_off 0/1/2）——
// 服主 2026-10-03 定：救援关大家都不爱打 ⇒ 进救援关直接关掉刷特，美美通关。
// 真正做这件事的是刷特插件（ltt_si_spawner v1.30+）：它收到值后会自己重算"救援关闸门"，
// 顺带把引擎并发上限/找位区间还原成原值（不让导演替我们多刷）。
#define RESCUE_COUNT 3
static const int  g_iRescues[RESCUE_COUNT]      = { 0, 1, 2 };
static const char g_sRescueName[RESCUE_COUNT][] =
{
	"关",
	"整关不刷★",
	"救援后不刷"
};
static const char g_sRescueDesc[RESCUE_COUNT][] =
{
	"照常刷",
	"开图就停",
	"开救援才停"
};

// 【v1.2.19】距离偏好（ltt_sispawn_nearbias 0/1）——
// 服主 2026-10-03：「局内玩家改刷特数据多数情况还是得靠投票」⇒ 把这一项也做成投票项。
// 它管的是"同档位里怎么挑点"：开着就优先挑离生还者近的（<500 → <900 → <1400），
// 关掉则同档位内只比"落点分散"，不刻意贴脸。与「刷新距离」是两个正交的旋钮：
//   距离档 = 允许刷多远（区间本身）；距离偏好 = 在这个区间里先挑近的还是先挑散的。
#define NEAR_COUNT 2
static const int  g_iNears[NEAR_COUNT]      = { 0, 1 };
// 【v1.2.20】菜单文字只用"L4D2 菜单字体一定有的字形"：
//   ✅ 汉字 / 全角括号（）/ 逗号，、/ 顿号 / 数字 / ASCII
//   ❌ ※ 『』 「」 → ⚠ ★ 等符号 —— 菜单渲染器遇到没有字形的字符会**把后面整行吃掉**
//      （服主 2026-10-03 实测反馈："有些中文字符会显示异常导致后面字全部看不见"）
//   同时按服主要求把注释写短：一行说完，别让玩家在投票框里读作文。
static const char g_sNearName[NEAR_COUNT][] =
{
	"均衡（远近一样挑）",
	"就近优先（先挑近的）"
};
static const char g_sNearDesc[NEAR_COUNT][] =
{
	"只按落点分散挑，不刻意贴脸",
	"优先 500 内，其次 900，再次 1400"
};

// 【v1.2.21】坦克期策略（ltt_sispawn_tank_action 0/1/2）——
// 这是刷特插件里**早就有的 cvar**（本插件第 415 行就绑了它，但一直只用于显示），
// 现在终于能投票改它。真正干活的是刷特插件：它收到值会自己切换坦克期的参数集。
// 数组插在【末尾】—— 存档里存的是下标，插在中间会让老存档指到别的档。
#define TANK_COUNT 3
static const int  g_iTanks[TANK_COUNT]      = { 0, 1, 2 };
static const char g_sTankName[TANK_COUNT][] =
{
	"不干预（原版行为）",
	"接管·坦克期收紧（默认）",
	"坦克期一只都不刷"
};
static const char g_sTankDesc[TANK_COUNT][] =
{
	"坦克期照常用普通参数刷",
	"坦克期上限收到 8、每职业最多 2~3 只，照常刷",
	"坦克登场期间完全不刷特感（坦克死了自动恢复）"
};

// 【v1.2.21】特感游戏模式（ltt_sispawn_classes，int 位掩码）——
// 位值：1烟鬼 2胖子 4猎人 8毒妇 16骑师 32牛。
// ⚠ 这里存的是【cvar 原值（位掩码）】，不是档位序号：g_iClasses[0]=63 全部、g_iClasses[1]=53 四控。
// 以后加档（比如 63-2=61 不要胖子）只要在**末尾**追加一个值 + 名字 + 说明，下标顺序不动。
//
// ⚠⚠【跨插件依赖，必须先确认再上线】2026-10-05 读本仓库的 ltt_si_spawner.sp（v1.48.1）：
//   它那边的 `ltt_sispawn_classes` 还是【逗号分隔的职业表】，默认值 "1,2,3,4,5,6"
//   （CreateConVar 在 L1450，ParseClasses() 在 L2289：只用 GetString + ExplodeString
//   解析、并且只认 1~6）。往它里面写 63 / 53 → 解析成"没有可用职业"→ **一只特感都不刷**
//   （它会打日志"本波没有可用职业（检查 ltt_sispawn_classes）"）。
//   所以这一项要真正能用，刷特插件那侧必须先把该 cvar 改成按位掩码解析
//   （或改成"含逗号当职业表、纯数字当位掩码"的兼容解析）。本文件只按位掩码写值。
#define GAMEMODE_COUNT 2
static const int  g_iClasses[GAMEMODE_COUNT]      = { 63, 53 };
static const char g_sGameModeName[GAMEMODE_COUNT][] =
{
	"全部六种（默认）",
	"四控模式（烟鬼+猎人+骑师+牛）"
};
static const char g_sGameModeDesc[GAMEMODE_COUNT][] =
{
	"烟鬼/胖子/猎人/毒妇/骑师/牛 都会出",
	"只出能控人的四种；不出胖子、毒妇"
};

// 刷特插件的 cvar（软连接）
ConVar g_cWave, g_cTime, g_cCap, g_cMin, g_cMax;
ConVar g_cEnable, g_cReserve, g_cTankAction, g_cTankCap;

// 【v1.2.3】管理员菜单要读的其它 cvar（都是软连接，取不到就 null）
ConVar g_cPerPlayer, g_cScaling, g_cGuard, g_cSlotStop, g_cGrowMax;
ConVar g_cMode;                          // 【v1.2.4】刷特挡位
ConVar g_cRescueOff;                     // 【v1.2.18】救援关不刷特（0关/1整张/2救援开始后）
ConVar g_cNearBias;                      // 【v1.2.19】距离偏好（0均衡/1就近）
ConVar g_cClasses;                       // 【v1.2.21】特感游戏模式位掩码（ltt_sispawn_classes）
ConVar g_cWitchEnable, g_cWitchMax;      // ltt_si_witch（独立插件，可能没加载）

// 本插件自己的
ConVar g_cApply, g_cOwnDebug, g_cVote, g_cVoteTime, g_cRatio, g_cMinVoters;
ConVar g_cIdleReset, g_cIdleSeconds;
int    g_iIdleSince;
// 【v1.2.8】Timer_IdleCheck 在这张图跑过几跳 —— P0 修复的验收探针，不是统计量。
// 必须声明在这里：SourcePawn 的全局声明要早于使用点，而 OnConfigsExecuted(L343) 就要重置它。
int    g_iIdleTicks;

// 【v1.2.2】投票锁看门狗
ConVar g_cLockWatch, g_cLockSecs;
int    g_iLockSince;      // 引擎投票锁从什么时候开始挂住（0=没挂）
int    g_iLockRecover;    // 累计自动解锁次数（判断看门狗到底有没有用）

// cfg 里的"出厂值"（cfg 执行完之后抓一次），用于 sm_sireset 恢复
bool  g_bDefaultsReady;
int   g_iDefWave, g_iDefTime, g_iDefCap, g_iDefDist;
int   g_iDefMode, g_iDefPer;          // 【v1.2.16】出厂默认的挡位 / 进人加特感档位下标
int   g_iDefRescue;                   // 【v1.2.18】出厂默认的"救援关不刷特"档位下标
int   g_iDefNear;                     // 【v1.2.19】出厂默认的"距离偏好"档位下标
int   g_iDefTank;                     // 【v1.2.21】出厂默认的"坦克期策略"档位下标
int   g_iDefGameMode;                 // 【v1.2.21】出厂默认的"特感游戏模式"档位下标

bool  g_bHasSaved;
int   g_iSavedWave, g_iSavedTime, g_iSavedCap, g_iSavedDist, g_iSavedMode;
// 【v1.2.19】距离偏好也进存档（否则投票改了、一换图就被 cfg 顶回去）
int   g_iSavedNear;
int   g_iSavedPer;      // 【v1.2.11】进人加特感，存的是档位下标（不是 cvar 原值）
int   g_iSavedRescue;   // 【v1.2.18】救援关不刷特（档位下标）
// 【v1.2.21】坦克期策略 / 特感游戏模式也进存档（存档位下标，不存 cvar 原值）
int   g_iSavedTank;
int   g_iSavedGameMode;

bool  g_bDirty;

// 原生投票
bool  g_bHasNative;
bool  g_bVoteActive;
int   g_iPendKind = -1;
int   g_iPendIdx  = -1;
int   g_iPendBy   = 0;

// ============================================================================
// 【LTT v1.2.23 · 2026-10-08 · A2 投票日志统一】
// 为什么要有这段：`ltt_svote_siforward = 1` 时，`!vt` 里的「特感设置」被**转发到本菜单**，
// 用菜单自带的投票跑；而 `ltt_svote` 的那个"专用投票日志"（logs/ltt_svote.log，
// 管理员的 `sm_vtlog` 就是读它）只记它自己发起的投票 ⇒ **特感投票一条都进不去**，
// 想查"谁什么时候把每波改成 12 只"只能翻 SM 主日志，而主日志按天切、几天后就不好找。
// 这里让本菜单也往**同一个文件**按**同一种格式**追加一行一次投票 ⇒ sm_vtlog 一次看全。
char g_sSimVoteLogFile[PLATFORM_MAX_PATH];
ConVar g_cSimVoteLog;
char g_sSimVoterName[MAX_NAME_LENGTH];   // 记下发起人，投票通过/未通过那两行也要带名字
char g_sSimVoterAuth[32];

void SimVoteLog(const char[] fmt, any ...)
{
	if (g_cSimVoteLog == null || !g_cSimVoteLog.BoolValue)
		return;

	char sMsg[320];
	VFormat(sMsg, sizeof(sMsg), fmt, 2);
	LogToFile(g_sSimVoteLogFile, "%s", sMsg);
}

public Plugin myinfo =
{
	name        = "[LTT] SI Spawner Menu",
	author      = "DeepSeek Harness",
	description = "刷特设置的玩家菜单：数量/间隔/上限/距离，选完走游戏原生投票（F1 同意 F2 反对）",
	version     = PLUGIN_VERSION,
	url         = ""
};

// ==================================================================== 启动

public void OnPluginStart()
{
	g_cApply = CreateConVar("ltt_si_menu_apply", "1",
		"1=换图后自动套用上次投票通过的设置（存在 data/ltt_si_menu.txt）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 【v1.2.23】A2：特感投票也写进 ltt_svote 的专用投票日志（同一个文件，sm_vtlog 一次看全）
	g_cSimVoteLog = CreateConVar("ltt_simenu_votelog", "1",
		"1=把「特感设置」投票也写进 logs/ltt_svote.log（与 ltt_svote 同一个文件，管理员的 sm_vtlog 能一起看到）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	// 绝对路径，省得依赖 LogToFile 的相对目录规则（写法与 ltt_svote.sp 完全一致）
	BuildPath(Path_SM, g_sSimVoteLogFile, sizeof(g_sSimVoteLogFile), "logs/ltt_svote.log");
	g_cVote = CreateConVar("ltt_si_menu_vote", "1",
		"1=改设置要走游戏原生投票（F1 同意 / F2 反对）0=点一下直接生效", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cVoteTime = CreateConVar("ltt_si_menu_votetime", "15",
		"投票持续秒数", FCVAR_NOTIFY, true, 5.0, true, 60.0);
	g_cRatio = CreateConVar("ltt_si_menu_ratio", "60",
		"通过所需同意票占在场生还者的百分比（不投票视为反对）", FCVAR_NOTIFY, true, 1.0, true, 100.0);
	g_cMinVoters = CreateConVar("ltt_si_menu_minvoters", "1",
		"在场真人少于此数就直接生效（不弹投票面板）。默认 1 = 单人也会弹面板（与 ltt_svote 行为一致）", FCVAR_NOTIFY, true, 1.0, true, 10.0);
	g_cIdleReset = CreateConVar("ltt_si_menu_idlereset", "1",
		"1=空服一段时间后把刷特设置还原成 cfg 默认值并清掉存档（与 ltt_svote 同一套空服还原思路）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cIdleSeconds = CreateConVar("ltt_si_menu_idleseconds", "300",
		"空服多少秒后还原", FCVAR_NOTIFY, true, 30.0, true, 7200.0);
	g_cOwnDebug = CreateConVar("ltt_si_menu_debug", "1",
		"1=输出菜单相关日志", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 【v1.2.2】投票锁看门狗
	g_cLockWatch = CreateConVar("ltt_si_menu_lockwatch", "1",
		"【v1.2.2】1=投票锁看门狗：引擎投票锁被挂住、而本插件没有投票在跑时，自动广播 VoteFail 尽力解锁（专治连 !chmap 都发不出来的死锁）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cLockSecs = CreateConVar("ltt_si_menu_locksecs", "30",
		"【v1.2.2】投票锁连续挂住多少秒才自动解锁。必须比任何合法投票的时长长，否则会误杀正常投票",
		FCVAR_NOTIFY, true, 10.0, true, 600.0);

	CreateConVar("ltt_si_menu_version", PLUGIN_VERSION, "菜单插件版本", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	RegConsoleCmd("sm_si",     Cmd_OpenMenu, "打开刷特设置菜单");
	RegConsoleCmd("sm_simenu", Cmd_OpenMenu, "打开刷特设置菜单");
	RegAdminCmd("sm_sireset",  Cmd_Reset,     ADMFLAG_GENERIC, "恢复刷特设置到 cfg 默认值（清掉存档）");
	RegAdminCmd("sm_siclose",  Cmd_CloseVote, ADMFLAG_GENERIC, "应急：广播 VoteFail 关掉卡住的投票面板");
	RegAdminCmd("sm_sia",      Cmd_AdminMenu, ADMFLAG_GENERIC, "【v1.2.3】多特管理员菜单");

	g_bHasNative = (GetFeatureStatus(FeatureType_Native, "L4D2NativeVote_IsAllowNewVote") == FeatureStatus_Available);

	BindCvars();
	LoadSaved();

	CreateTimer(1.0, Timer_Bind, _, TIMER_FLAG_NO_MAPCHANGE);
	// 【v1.2.8 修复】下面两个是【常驻】看门狗，绝不能带 TIMER_FLAG_NO_MAPCHANGE。
	// 该标志会在换图时杀掉定时器，而本插件**没有 OnMapStart** → 换图后永远不重建。
	// 实测后果（设计稿 §8 第 4 条）：空服自动还原全天只触发 3 次、之后空置 1h45m 触发 0 次，
	// 存档因此一直卡在 26/5/32；投票锁看门狗同样换图即失效。
	// 两个回调体（Timer_IdleCheck / Timer_VoteLockWatch）只碰全局变量和客户端列表，
	// 不依赖任何地图态句柄，所以跨图存活是安全的；OnPluginStart 建一次即够。
	// 重载插件时 SourceMod 会随插件卸载回收它自己的定时器，不会累积重复实例。
	CreateTimer(30.0, Timer_IdleCheck, _, TIMER_REPEAT);
	CreateTimer(5.0, Timer_VoteLockWatch, _, TIMER_REPEAT);   // 【v1.2.2】

	LogMessage("[SIMenu] v%s 就绪 | 原生投票=%s | 走投票=%d 时长=%ds 通过率=%d%% 起投人数=%d | 投票锁看门狗=%d/%ds",
		PLUGIN_VERSION, g_bHasNative ? "可用" : "不可用(将直接生效)",
		g_cVote.IntValue, g_cVoteTime.IntValue, g_cRatio.IntValue, g_cMinVoters.IntValue,
		g_cLockWatch.IntValue, g_cLockSecs.IntValue);

	// 【v1.2.9】把档位表打进启动横幅。
	// 理由：选项表是编译期常量，改错了（少一档、写错值）**在运行时没有任何信号** ——
	// 只有玩家点开菜单才发现"找不到我要的档"。打出来就变成可验证的了。
	{
		char sTimes[128];
		sTimes[0] = '\0';
		for (int i = 0; i < TIME_COUNT; i++)
		{
			char sOne[12];
			Format(sOne, sizeof(sOne), "%s%d", (i > 0) ? "/" : "", g_iTimes[i]);
			StrCat(sTimes, sizeof(sTimes), sOne);
		}
		LogMessage("[SIMenu] v%s 间隔档位 %d 档（每页 7 项，超过会翻页）: %s 秒",
			PLUGIN_VERSION, TIME_COUNT, sTimes);
	}

	// 【v1.2.11】进人加特感档位表也打进横幅 —— 同一个理由：
	// 选项表是编译期常量，改错了运行时没有任何信号，打出来才可验证。
	{
		char sPer[160];
		sPer[0] = '\0';
		for (int i = 0; i < PERPLAYER_COUNT; i++)
		{
			char sOne[16];
			Format(sOne, sizeof(sOne), "%s%d", (i > 0) ? "/" : "", g_iPerPlayers[i]);
			StrCat(sPer, sizeof(sPer), sOne);
		}
		// 【v1.2.12 修正】这一段是在 OnPluginStart 里打的，那一刻刷特插件可能【还没加载】，
		// FindConVar 返回 null。原来写成 null→"关"，实测在重启后真的打出过
		// 「人数缩放=关」而服务器上明明是 1 —— 代码在说假话。null 必须单独说清楚。
		char sScale[48];
		if (g_cScaling == null)
			strcopy(sScale, sizeof(sScale), "未加载(刷特插件尚未就绪，1 秒后自动重绑)");
		else
			strcopy(sScale, sizeof(sScale), g_cScaling.BoolValue ? "开" : "关");

		LogMessage("[SIMenu] v%s 进人加特感 %d 档（每多 1 人、每波加几只；存活上限是它的 2 倍）: %s | 人数缩放=%s",
			PLUGIN_VERSION, PERPLAYER_COUNT, sPer, sScale);
	}

	// 【v1.2.18】救援关不刷特档位表也打出来（编译期常量，打出来才可验证）
	LogMessage("[SIMenu] v%s 救援关不刷特 %d 档：0=%s ｜ 1=%s ｜ 2=%s（当前 cvar=%s）",
		PLUGIN_VERSION, RESCUE_COUNT, g_sRescueName[0], g_sRescueName[1], g_sRescueName[2],
		g_cRescueOff == null ? "未读到" : g_sRescueName[RescueIndexFromCvar()]);

	// 【v1.2.21】坦克期策略 / 特感游戏模式档位表也打出来（同一个理由：编译期常量，
	// 改错了运行时没有任何信号，打出来才可验证）。
	LogMessage("[SIMenu] v%s 坦克期策略 %d 档：0=%s ｜ 1=%s ｜ 2=%s",
		PLUGIN_VERSION, TANK_COUNT, g_sTankName[0], g_sTankName[1], g_sTankName[2]);
	LogMessage("[SIMenu] v%s 特感游戏模式 %d 档：%d=%s ｜ %d=%s（当前 cvar=%s）",
		PLUGIN_VERSION, GAMEMODE_COUNT, g_iClasses[0], g_sGameModeName[0],
		g_iClasses[1], g_sGameModeName[1],
		g_cClasses == null ? "未读到" : g_sGameModeName[GameModeIndexFromCvar()]);
}

void BindCvars()
{
	g_cWave       = FindConVar("ltt_sispawn_wave");
	g_cTime       = FindConVar("ltt_sispawn_time");
	g_cCap        = FindConVar("ltt_sispawn_cap");
	g_cMin        = FindConVar("ltt_sispawn_min");
	g_cMax        = FindConVar("ltt_sispawn_max");
	g_cEnable     = FindConVar("ltt_sispawn_enable");
	g_cReserve    = FindConVar("ltt_sispawn_reserve");
	g_cTankAction = FindConVar("ltt_sispawn_tank_action");
	g_cTankCap    = FindConVar("ltt_sispawn_tank_cap");
	// 【v1.2.3】管理员菜单用（取不到就是 null，用之前判空）
	g_cPerPlayer  = FindConVar("ltt_sispawn_perplayer");
	g_cScaling    = FindConVar("ltt_sispawn_scaling");
	g_cGuard      = FindConVar("ltt_sispawn_guard");
	g_cSlotStop   = FindConVar("ltt_sispawn_slotstop");
	g_cGrowMax    = FindConVar("ltt_sispawn_growmax");
	g_cMode       = FindConVar("ltt_sispawn_mode");     // 【v1.2.4】
	g_cRescueOff  = FindConVar("ltt_sispawn_rescue_off");   // 【v1.2.18】救援关不刷特（spawner v1.30+）
	g_cNearBias   = FindConVar("ltt_sispawn_nearbias");     // 【v1.2.19】距离偏好（0均衡/1就近）
	g_cClasses    = FindConVar("ltt_sispawn_classes");      // 【v1.2.21】特感游戏模式位掩码（刷特插件的已有 cvar）
	g_cWitchEnable = FindConVar("ltt_siwitch_enable");
	g_cWitchMax    = FindConVar("ltt_siwitch_max");
}

public Action Timer_Bind(Handle timer)
{
	if (g_cWave == null)
		BindCvars();
	return Plugin_Stop;
}

/** 从 cfg/sourcemod/ltt_si_spawner.cfg 里读某个键的值。
 *
 *  为什么要读文件而不是读 cvar：
 *    本插件会在换图后把"玩家存档"写进 cvar，所以 cvar 里的值可能已经被改过。
 *    如果在那时去抓"出厂默认值"，抓到的是存档值 —— 实测踩过：
 *    玩家把每波改成 2、间隔 10、上限 4 之后重启，出厂默认就被记成了 2/10/4，
 *    sm_sireset 于是恢复不到真正的 cfg 默认值。cfg 文件才是唯一可信来源。 */
bool ReadCfgDefault(const char[] key, int &out)
{
	char p[PLATFORM_MAX_PATH];
	// 这个 SM 版的 PathType 只有 Path_SM，所以从 addons/sourcemod 往上两级到 left4dead2
	BuildPath(Path_SM, p, sizeof(p), "../../cfg/sourcemod/ltt_si_spawner.cfg");

	File f = OpenFile(p, "r");
	if (f == null)
		return false;

	char line[256];
	bool found = false;

	while (f.ReadLine(line, sizeof(line)))
	{
		TrimString(line);
		if (line[0] == '\0' || line[0] == '/' || line[0] == ';')
			continue;
		if (StrContains(line, key, false) != 0)
			continue;
		// 【v1.2.15 · 2026-10-02 源码审核修复】精确匹配键名。旧代码只用前缀匹配：
		// ltt_sispawn_min 会命中 ltt_sispawn_minsi、ltt_sispawn_max 会命中 ltt_sispawn_maxdz
		// ⇒ "出厂默认（取自 cfg 文件）"读到的值完全取决于 cfg 行序，读错了也没人发现。
		// 键名后面必须紧跟空格/制表符/引号，否则不算命中。
		int iKeyLen = strlen(key);
		char cNext = line[iKeyLen];
		if (cNext != ' ' && cNext != '\t' && cNext != '"')
			continue;

		int q1 = FindCharInString(line, '"');
		if (q1 < 0)
			continue;
		int q2 = FindCharInString(line[q1 + 1], '"');
		if (q2 < 0)
			continue;

		char val[32];
		strcopy(val, sizeof(val), line[q1 + 1]);
		val[q2] = '\0';

		out = StringToInt(val);
		found = true;
		break;
	}

	delete f;
	return found;
}

public void OnConfigsExecuted()
{
	g_bDirty = false;
	g_iIdleTicks = 0;   // 【v1.2.8】换图后重置存活探针，下一跳应当重新出现
	CreateTimer(1.0, Timer_Apply, _, TIMER_FLAG_NO_MAPCHANGE);
}

/** cfg 是在 OnConfigsExecuted 之后才真正 exec 的，所以延后 1 秒：
 *  ① 抓出厂默认值 ② 套用上次投票通过的设置 */
public Action Timer_Apply(Handle timer)
{
	if (g_cWave == null)
		BindCvars();

	if (g_cWave == null)
	{
		if (g_cOwnDebug.BoolValue)
			LogMessage("[SIMenu] 找不到 ltt_sispawn_* 的 cvar —— 刷特插件没加载？菜单会提示不可用");
		return Plugin_Stop;
	}

	// 【v1.2.17 · 2026-10-02 服主实测踩到】出厂默认必须【每次换图都重读 cfg】。
	// 旧代码用 g_bDefaultsReady 只读一次（插件加载那一刻）：cfg 后来被改了它也不知道，
	// 于是【恢复默认 / 空服还原】会按缓存里的旧值写回去 —— 实测把服主刚开启的
	// ltt_sispawn_perplayer=1（人数缩放）写回了 0，表现就是出门提示少掉「N 人已加成」。
	// 每张图读一次小文件，代价可忽略；好处是改 cfg 立刻生效、不必重载插件。
	{
		// 优先读 cfg 文件里的值（唯一可信来源）；读不到再退回插件内置常量
		int v;
		g_iDefWave = ReadCfgDefault("ltt_sispawn_wave", v) ? v : 4;
		g_iDefTime = ReadCfgDefault("ltt_sispawn_time", v) ? v : 40;
		g_iDefCap  = ReadCfgDefault("ltt_sispawn_cap",  v) ? v : 8;

		int dmin, dmax;
		if (ReadCfgDefault("ltt_sispawn_min", dmin) && ReadCfgDefault("ltt_sispawn_max", dmax))
		{
			g_iDefDist = 2;
			for (int i = 0; i < DIST_COUNT; i++)
			{
				if (dmin == g_iDistMin[i] && dmax == g_iDistMax[i])
				{
					g_iDefDist = i;
					break;
				}
			}
		}
		else
			g_iDefDist = 2;

		// 【v1.2.16 · 2026-10-02 源码审核修复】挡位与"进人加特感"也归本菜单管，
		// 所以"出厂默认"必须把它们一起读出来（否则"恢复默认"没法还原这两项）。
		g_iDefMode = ReadCfgDefault("ltt_sispawn_mode", v) ? v : 0;

		// 【v1.2.18】救援关不刷特也归本菜单管 ⇒ 出厂默认同样从 cfg 读
		int dr = ReadCfgDefault("ltt_sispawn_rescue_off", v) ? v : 1;
		g_iDefRescue = 0;
		for (int i = 0; i < RESCUE_COUNT; i++)
		{
			if (g_iRescues[i] == dr)
			{
				g_iDefRescue = i;
				break;
			}
		}
		int pv, dper = ReadCfgDefault("ltt_sispawn_perplayer", pv) ? pv : 0;
		g_iDefPer = 0;
		for (int i = 0; i < PERPLAYER_COUNT; i++)
		{
			if (g_iPerPlayers[i] == dper)
			{
				g_iDefPer = i;
				break;
			}
		}

		// 【v1.2.19】距离偏好也归本菜单管 ⇒ 出厂默认同样从 cfg 读
		int dn = ReadCfgDefault("ltt_sispawn_nearbias", v) ? v : 0;
		g_iDefNear = 0;
		for (int i = 0; i < NEAR_COUNT; i++)
		{
			if (g_iNears[i] == dn)
			{
				g_iDefNear = i;
				break;
			}
		}

		// 【v1.2.21】坦克期策略 / 特感游戏模式也归本菜单管 ⇒ 出厂默认同样从 cfg 读。
		// 读不到 cfg（没写这两个键）时的兜底 = 刷特插件侧的默认值：tank_action 1、classes 63。
		int dta = ReadCfgDefault("ltt_sispawn_tank_action", v) ? v : 1;
		g_iDefTank = 0;
		for (int i = 0; i < TANK_COUNT; i++)
		{
			if (g_iTanks[i] == dta)
			{
				g_iDefTank = i;
				break;
			}
		}

		int dcl = ReadCfgDefault("ltt_sispawn_classes", v) ? v : 63;
		g_iDefGameMode = 0;
		for (int i = 0; i < GAMEMODE_COUNT; i++)
		{
			if (g_iClasses[i] == dcl)
			{
				g_iDefGameMode = i;
				break;
			}
		}

		g_bDefaultsReady = true;

		if (g_cOwnDebug.BoolValue)
			LogMessage("[SIMenu] 出厂默认（取自 cfg 文件）：每波=%d 间隔=%d 上限=%d 距离档=%d 挡位=%d 进人加特感=%d 救援关不刷特=%d 距离偏好=%d 坦克期策略=%d 特感游戏模式=%d",
				g_iDefWave, g_iDefTime, g_iDefCap, g_iDefDist, g_iDefMode,
				g_iPerPlayers[g_iDefPer], g_iRescues[g_iDefRescue], g_iNears[g_iDefNear],
				g_iTanks[g_iDefTank], g_iClasses[g_iDefGameMode]);
	}

	if (g_bHasSaved && g_cApply.BoolValue)
	{
		g_cWave.SetInt(g_iSavedWave);
		g_cTime.SetInt(g_iSavedTime);
		g_cCap.SetInt(g_iSavedCap);
		g_cMin.SetInt(g_iDistMin[g_iSavedDist]);
		g_cMax.SetInt(g_iDistMax[g_iSavedDist]);

		// 【v1.2.4】挡位也要跟着存档走（刷特插件会据它展开三个子 cvar）
		if (g_cMode != null)
			g_cMode.SetInt(g_iSavedMode);

		// 【v1.2.11】进人加特感也跟着存档走
		if (g_cPerPlayer != null)
			g_cPerPlayer.SetInt(g_iPerPlayers[g_iSavedPer]);

		// 【v1.2.18】救援关不刷特也跟着存档走
		if (g_cRescueOff != null)
			g_cRescueOff.SetInt(g_iRescues[g_iSavedRescue]);

		// 【v1.2.19】距离偏好也跟着存档走（否则投票改了、一换图就被 cfg 顶回去）
		if (g_cNearBias != null)
			g_cNearBias.SetInt(g_iNears[g_iSavedNear]);

		// 【v1.2.21】坦克期策略也跟着存档走（写之前夹到 cvar 认的值域 0~2）
		if (g_cTankAction != null)
			g_cTankAction.SetInt(ClampInt(g_iTanks[g_iSavedTank], 0, 2));

		// 【v1.2.21】特感游戏模式（位掩码）也跟着存档走（夹到 1~63）
		if (g_cClasses != null)
			g_cClasses.SetInt(ClampInt(g_iClasses[g_iSavedGameMode], 1, 63));

		if (g_cOwnDebug.BoolValue)
			LogMessage("[SIMenu] 已套用存档：每波=%d 间隔=%d 上限=%d 距离=%s 挡位=%d(%s) 进人加特感=+%d/人 救援关不刷特=%d 距离偏好=%d 坦克期策略=%d 特感游戏模式=%d",
				g_iSavedWave, g_iSavedTime, g_iSavedCap, g_sDistName[g_iSavedDist],
				g_iSavedMode, g_sModeName[g_iSavedMode], g_iPerPlayers[g_iSavedPer],
				g_iRescues[g_iSavedRescue], g_iNears[g_iSavedNear],
				g_iTanks[g_iSavedTank], g_iClasses[g_iSavedGameMode]);
	}

	return Plugin_Stop;
}

// ==================================================================== 存档

void DataPath(char[] out, int maxlen)
{
	BuildPath(Path_SM, out, maxlen, "data/ltt_si_menu.txt");
}

void LoadSaved()
{
	char p[PLATFORM_MAX_PATH];
	DataPath(p, sizeof(p));

	g_bHasSaved = false;

	KeyValues kv = new KeyValues("ltt_si_menu");
	if (!kv.ImportFromFile(p))
	{
		delete kv;
		return;
	}

	int w = kv.GetNum("wave", -1);
	int t = kv.GetNum("time", -1);
	int c = kv.GetNum("cap",  -1);
	int d = kv.GetNum("dist", -1);
	int m = kv.GetNum("mode", 1);      // 【v1.2.4】老存档没这个键 → 默认 1（日常档）
	int pIdx = kv.GetNum("per", -1);   // 【v1.2.11】老存档没这个键 → -1，下面回落到当前 cvar 值
	int rIdx = kv.GetNum("rescue", -1);   // 【v1.2.18】老存档没这个键 → -1，回落
	int nIdx = kv.GetNum("near", -1);     // 【v1.2.19】距离偏好（老存档没这个键 → 回落）
	int tkIdx = kv.GetNum("tank", -1);    // 【v1.2.21】坦克期策略（老存档没这个键 → 回落当前 cvar 值）
	int gmIdx = kv.GetNum("classes", -1); // 【v1.2.21】特感游戏模式（同上）
	delete kv;

	if (w > 0 && t > 0 && c > 0 && d >= 0 && d < DIST_COUNT)
	{
		g_iSavedWave = w;
		g_iSavedTime = t;
		g_iSavedCap  = c;
		g_iSavedDist = d;
		g_iSavedMode = (m >= 0 && m < MODE_COUNT) ? m : 1;
		// 【v1.2.11】存档里存的是档位下标；老存档没有 → 按当前 cvar 值就近取一档
		g_iSavedPer  = (pIdx >= 0 && pIdx < PERPLAYER_COUNT) ? pIdx : PerIndexFromCvar();
		g_iSavedRescue = (rIdx >= 0 && rIdx < RESCUE_COUNT) ? rIdx : RescueIndexFromCvar();   // 【v1.2.18】
		g_iSavedNear = (nIdx >= 0 && nIdx < NEAR_COUNT) ? nIdx : NearIndexFromCvar();        // 【v1.2.19】
		// 【v1.2.21】同上：老存档没有这两个键 → 按当前 cvar 值就近取一档
		g_iSavedTank = (tkIdx >= 0 && tkIdx < TANK_COUNT) ? tkIdx : TankIndexFromCvar();
		g_iSavedGameMode = (gmIdx >= 0 && gmIdx < GAMEMODE_COUNT) ? gmIdx : GameModeIndexFromCvar();
		g_bHasSaved  = true;
	}
	else
	{
		LogError("[SIMenu] 存档内容不完整，已忽略（wave=%d time=%d cap=%d dist=%d mode=%d per=%d rescue=%d near=%d tank=%d classes=%d）",
			w, t, c, d, m, pIdx, rIdx, nIdx, tkIdx, gmIdx);
	}
}

void SaveCurrent()
{
	char p[PLATFORM_MAX_PATH];
	DataPath(p, sizeof(p));

	g_iSavedWave = g_cWave.IntValue;
	g_iSavedTime = g_cTime.IntValue;
	g_iSavedCap  = g_cCap.IntValue;
	g_iSavedDist = DistIndexFromCvars();
	g_iSavedMode = (g_cMode != null) ? g_cMode.IntValue : 1;   // 【v1.2.4】
	g_iSavedPer  = PerIndexFromCvar();                          // 【v1.2.11】
	g_iSavedRescue = RescueIndexFromCvar();                     // 【v1.2.18】
	g_iSavedNear   = NearIndexFromCvar();                       // 【v1.2.19】距离偏好
	g_iSavedTank     = TankIndexFromCvar();                     // 【v1.2.21】坦克期策略
	g_iSavedGameMode = GameModeIndexFromCvar();                 // 【v1.2.21】特感游戏模式
	g_bHasSaved  = true;

	KeyValues kv = new KeyValues("ltt_si_menu");
	kv.SetNum("wave", g_iSavedWave);
	kv.SetNum("time", g_iSavedTime);
	kv.SetNum("cap",  g_iSavedCap);
	kv.SetNum("dist", g_iSavedDist);
	kv.SetNum("mode", g_iSavedMode);
	kv.SetNum("per",  g_iSavedPer);      // 【v1.2.11】进人加特感（存档位下标）
	kv.SetNum("rescue", g_iSavedRescue);   // 【v1.2.18】救援关不刷特（档位下标）
	kv.SetNum("near", g_iSavedNear);       // 【v1.2.19】距离偏好（档位下标）
	kv.SetNum("tank", g_iSavedTank);          // 【v1.2.21】坦克期策略（档位下标；cvar 原值 0/1/2）
	kv.SetNum("classes", g_iSavedGameMode);   // 【v1.2.21】特感游戏模式（档位下标；cvar 原值是位掩码 63/53）
	kv.ExportToFile(p);
	delete kv;
}

void ClearSaved()
{
	char p[PLATFORM_MAX_PATH];
	DataPath(p, sizeof(p));

	if (FileExists(p))
		DeleteFile(p);

	g_bHasSaved = false;
}

// ==================================================================== 计算

int CountSurvivorSlots()
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR)
			n++;
	}
	return n;
}

bool IsTankAlive()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_INFECTED)
			continue;
		if (GetEntProp(i, Prop_Send, "m_zombieClass") == 8)
			return true;
	}
	return false;
}

/** 与 ltt_si_spawner 的 GetEffCap() 同一套槽位算法（软连接，不引用它的函数） */
int HardCap()
{
	if (g_cWave == null)
		return 0;

	int keep = (g_cReserve != null) ? g_cReserve.IntValue : 1;
	if (keep < 1)
		keep = 1;

	int hard = MaxClients - CountSurvivorSlots() - keep;
	if (hard < 1)
		hard = 1;
	return hard;
}

int EffectiveCap()
{
	if (g_cCap == null)
		return 0;

	// 【v1.2.13】优先读 spawner 的只读镜像 ltt_sispawn_effcap。
	// 为什么必须这样：spawner 的 GetEffCap() 含【人数缩放(每多 1 人 +2)、坦克期上限、
	// 槽位硬上限】三层，而下面这段本地算法**漏了人数缩放** ⇒ 5 人时这里返回 8、
	// 实际是 12，于是本文件 **9 处**"实际生效 X"（菜单标题 / 改动回执 / 本局设置面板）
	// 全是错的。镜像就是为这件事造的（spawner v1.18.2 的注释原话：
	// "别的插件用 FindConVar 读它来对齐口径"）。
	// 镜像读不到（旧版 spawner / 未加载 / 还没跑过 Tick）才用下面的本地算法兜底。
	ConVar cEff = FindConVar("ltt_sispawn_effcap");
	if (cEff != null && cEff.IntValue > 0)
		return cEff.IntValue;

	int n = g_cCap.IntValue;

	if (g_cTankAction != null && g_cTankAction.BoolValue && IsTankAlive() && g_cTankCap != null)
	{
		int t = g_cTankCap.IntValue;
		if (t < n)
			n = t;
	}

	int hard = HardCap();
	if (n > hard)
		n = hard;
	if (n < 1)
		n = 1;
	return n;
}

int DistIndexFromCvars()
{
	if (g_cMin == null || g_cMax == null)
		return 2;

	int mn = g_cMin.IntValue;
	int mx = g_cMax.IntValue;

	for (int i = 0; i < DIST_COUNT; i++)
	{
		if (mn == g_iDistMin[i] && mx == g_iDistMax[i])
			return i;
	}
	return 2;
}

// ==================================================================== 菜单

public Action Cmd_OpenMenu(int client, int args)
{
	if (client <= 0)
	{
		ReplyToCommand(client, "[刷特] 这个菜单只能在游戏里打开");
		return Plugin_Handled;
	}
	ShowMain(client);
	return Plugin_Handled;
}

/** 注意：菜单标题和选项一律【纯文本】。
 *  L4D2 的菜单不解析 \x01~\x05 颜色码，写了会显示成一个个方框（服主截图反馈过）。 */
void ShowMain(int client)
{
	if (g_cWave == null)
	{
		PrintToChat(client, "\x01[\x05刷特\x01] 刷特插件未加载，菜单不可用");
		return;
	}

	char sTitle[192];
	// 【v1.2.13】这是玩家敲 !si 第一眼看到的标题 —— 原来直接打 g_cWave（设的值），
	// 所以 5 人时显示"当前: 4 特"，而实际每波刷 6 只。改成"当前生效 X 特（设 Y）"。
	{
		int iEffW = GetEffWaveSafe();
		if (iEffW != g_cWave.IntValue)
			Format(sTitle, sizeof(sTitle), "刷特设置%s\n当前生效: %d 特（设 %d） / %d 秒\n ",
				g_bDirty ? "（本局已调整）" : "", iEffW, g_cWave.IntValue, g_cTime.IntValue);
		else
			Format(sTitle, sizeof(sTitle), "刷特设置%s\n当前: %d 特 / %d 秒\n ",
				g_bDirty ? "（本局已调整）" : "", g_cWave.IntValue, g_cTime.IntValue);
	}

	Menu menu = new Menu(MenuHandler_Main);
	menu.SetTitle(sTitle);
	menu.AddItem("wave", "每波特感数量");
	menu.AddItem("time", "特感刷新间隔");
	menu.AddItem("cap",  "同时存活上限");
	menu.AddItem("dist", "刷新距离（离生还者多远）");
	menu.AddItem("mode", "刷特挡位（找位策略）");     // 【v1.2.4】
	menu.AddItem("per",  "进人加特感（人数缩放）");   // 【v1.2.11】
	menu.AddItem("rescue", "救援关不刷特");            // 【v1.2.18】
	menu.AddItem("near", "距离偏好（就近 or 均衡）");   // 【v1.2.19】
	menu.AddItem("tank",    "坦克期策略（坦克登场时）");      // 【v1.2.21】
	menu.AddItem("classes", "特感游戏模式（出哪几种特感）");   // 【v1.2.21】
	menu.AddItem("show", "查看本局设置");
	// 【v1.2.11】主菜单项数逐版增加 —— 显式放开每页，免得翻页
	// 【v1.2.18】7 项变 8 项：改用 MENU_NO_PAGINATION（menus.inc 原文：不翻页时最多 10 项），
	//   8 项 + 退出行 = 9 行，一页放全。
	//   ⚠ menus.inc 的坑：设置 Pagination 时会清掉"退出键"标记 ⇒ 这一行**必须**在
	//   `menu.ExitButton = true;` 之前（现有顺序正好满足，别调换）。
	// 【v1.2.21】坦克期策略 / 特感游戏模式各加一项 ⇒ 11 项，**超过了"不翻页最多 10 项"**，
	//   继续用 MENU_NO_PAGINATION 会静默丢掉最后几项（玩家点不到，却看不出哪里坏了）。
	//   所以这里改回显式分页 7 项/页（与 ShowValueMenu 同一口径：
	//   7 项 + 下一页 + 上一页 + 退出 = 10 格）。顺序仍然是 Pagination 在前、ExitButton 在后。
	menu.Pagination = 7;
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Main(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char s[16];
		menu.GetItem(item, s, sizeof(s));

		if (StrEqual(s, "wave"))
			ShowValueMenu(client, SET_WAVE, false);
		else if (StrEqual(s, "time"))
			ShowValueMenu(client, SET_TIME, false);
		else if (StrEqual(s, "cap"))
			ShowValueMenu(client, SET_CAP, false);
		else if (StrEqual(s, "dist"))
			ShowValueMenu(client, SET_DIST, false);
		else if (StrEqual(s, "mode"))
			ShowValueMenu(client, SET_MODE, false);   // 【v1.2.4】
		else if (StrEqual(s, "per"))
			ShowValueMenu(client, SET_PERPLAYER, false);   // 【v1.2.11】
		else if (StrEqual(s, "rescue"))
			ShowValueMenu(client, SET_RESCUE, false);      // 【v1.2.18】
		else if (StrEqual(s, "near"))
			ShowValueMenu(client, SET_NEARBIAS, false);    // 【v1.2.19】距离偏好
		else if (StrEqual(s, "tank"))
			ShowValueMenu(client, SET_TANK, false);        // 【v1.2.21】坦克期策略
		else if (StrEqual(s, "classes"))
			ShowValueMenu(client, SET_GAMEMODE, false);    // 【v1.2.21】特感游戏模式
		else if (StrEqual(s, "show"))
		{
			PrintCurrent(client);
			ShowMain(client);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

/** kind + 档位下标编码进 info（首字母 W/T/C/D + 下标）。
 *  这个 SM 版的 Menu.AddItem 只有 3 个参数，没有 value 参数可用。
 *  【v1.2.3】管理员模式在 info 前面加个 'A'（如 "AW3"）——
 *  这样"直接生效"和"走投票"两条路能共存，而且**不依赖全局状态**，
 *  多个管理员同时用菜单也不会串。 */
void ShowValueMenu(int client, int kind, bool admin)
{
	Menu menu = new Menu(MenuHandler_Value);
	// 【v1.2.9】显式钉住每页项数，**不依赖 SM 的默认值** —— 默认值在核心二进制里，
	// 光看 menus.inc 查不到（.inc 只有 `property int Pagination` 的声明）。
	// 7 项内容 + 第 8 格「下一页」+ 第 9 格「上一页」+ "0" 退出 = 10 格，正好占满。
	// 档位表超过 7 项就自动翻页：现在「每波」9 档和「间隔」8 档都会翻。
	// 若哪天想「一页放满、不翻页」，改成 `menu.Pagination = MENU_NO_PAGINATION;`（上限 10 项）。
	menu.Pagination = 7;
	char sTitle[128];
	char sInfo[16];
	char sDisp[64];

	char sPfx[2];
	strcopy(sPfx, sizeof(sPfx), admin ? "A" : "");

	int cur = 0;
	switch (kind)
	{
		case SET_WAVE: cur = g_cWave.IntValue;
		case SET_TIME: cur = g_cTime.IntValue;
		case SET_CAP:  cur = g_cCap.IntValue;
		case SET_DIST: cur = DistIndexFromCvars();
		case SET_MODE: cur = (g_cMode != null) ? g_cMode.IntValue : 1;   // 【v1.2.4】
		case SET_PERPLAYER: cur = PerIndexFromCvar();                    // 【v1.2.11】
		case SET_RESCUE: cur = RescueIndexFromCvar();                    // 【v1.2.18】
		case SET_NEARBIAS: cur = NearIndexFromCvar();                    // 【v1.2.19】
		case SET_TANK: cur = TankIndexFromCvar();                        // 【v1.2.21】坦克期策略
		case SET_GAMEMODE: cur = GameModeIndexFromCvar();                // 【v1.2.21】特感游戏模式
	}

	switch (kind)
	{
		case SET_WAVE:
		{
			Format(sTitle, sizeof(sTitle), "%s每波特感数量\n当前: %d 只\n ", admin ? "[管理员] 直接生效\n" : "", cur);
			for (int i = 0; i < WAVE_COUNT; i++)
			{
				Format(sInfo, sizeof(sInfo), "%sW%d", sPfx, i);
				Format(sDisp, sizeof(sDisp), "%d 只%s", g_iWaves[i], g_iWaves[i] == cur ? "  << 当前" : "");
				menu.AddItem(sInfo, sDisp);
			}
		}
		case SET_TIME:
		{
			Format(sTitle, sizeof(sTitle), "%s特感刷新间隔\n当前: %d 秒\n ", admin ? "[管理员] 直接生效\n" : "", cur);
			for (int i = 0; i < TIME_COUNT; i++)
			{
				Format(sInfo, sizeof(sInfo), "%sT%d", sPfx, i);
				Format(sDisp, sizeof(sDisp), "%d 秒%s", g_iTimes[i], g_iTimes[i] == cur ? "  << 当前" : "");
				menu.AddItem(sInfo, sDisp);
			}
		}
		case SET_CAP:
		{
			Format(sTitle, sizeof(sTitle), "%s同时存活上限\n设的 %d 只 / 实际生效 %d 只\n ", admin ? "[管理员] 直接生效\n" : "", cur, EffectiveCap());
			for (int i = 0; i < CAP_COUNT; i++)
			{
				Format(sInfo, sizeof(sInfo), "%sC%d", sPfx, i);
				Format(sDisp, sizeof(sDisp), "%d 只%s", g_iCaps[i], g_iCaps[i] == cur ? "  << 当前" : "");
				menu.AddItem(sInfo, sDisp);
			}
		}
		case SET_DIST:
		{
			Format(sTitle, sizeof(sTitle), "%s刷新距离\n当前: %s\n ", admin ? "[管理员] 直接生效\n" : "", g_sDistName[cur]);
			for (int i = 0; i < DIST_COUNT; i++)
			{
				Format(sInfo, sizeof(sInfo), "%sD%d", sPfx, i);
				Format(sDisp, sizeof(sDisp), "%s%s", g_sDistName[i], i == cur ? "  << 当前" : "");
				menu.AddItem(sInfo, sDisp);
			}
		}
		case SET_MODE:
		{
			// 【v1.2.4】挡位：显示名 + 一句说明，玩家看得懂才投得下去
			Format(sTitle, sizeof(sTitle), "%s刷特挡位（找位策略）\n当前: %d %s\n ", admin ? "[管理员] 直接生效\n" : "",
				cur, g_sModeName[cur]);
			for (int i = 0; i < MODE_COUNT; i++)
			{
				Format(sInfo, sizeof(sInfo), "%sM%d", sPfx, i);
				Format(sDisp, sizeof(sDisp), "%d %s%s\n    %s", i, g_sModeName[i],
					i == cur ? "  << 当前" : "", g_sModeDesc[i]);
				menu.AddItem(sInfo, sDisp);
			}
		}
		case SET_PERPLAYER:
		{
			// 【v1.2.11】进人加特感：每多 1 个生还者（超过 4 人后）→ 每波 +N 只，存活上限 +N×2
			Format(sTitle, sizeof(sTitle), "%s进人加特感\n当前: %s\n ",
				admin ? "[管理员] 直接生效\n" : "", g_sPerPlayerName[cur]);
			for (int i = 0; i < PERPLAYER_COUNT; i++)
			{
				Format(sInfo, sizeof(sInfo), "%sP%d", sPfx, i);
				Format(sDisp, sizeof(sDisp), "%s%s", g_sPerPlayerName[i], i == cur ? "  << 当前" : "");
				menu.AddItem(sInfo, sDisp);
			}
			// 这个值只在刷特插件 scaling=1 时才有意义；关着就等于白设，必须当场讲清楚。
			// 【v1.2.12】把"没绑上 cvar"和"真的关着"分开说 —— 否则又是一句假话。
			if (g_cScaling == null)
				menu.AddItem("warn", "! 没读到 scaling（刷特插件没加载?）", ITEMDRAW_DISABLED);
			else if (!g_cScaling.BoolValue)
				menu.AddItem("warn", "! 人数缩放已关闭，此设置当前不生效", ITEMDRAW_DISABLED);
		}
		case SET_RESCUE:
		{
			// 【v1.2.18】救援关不刷特：和挡位一样把说明打出来，玩家/管理员才看得懂敢投
			Format(sTitle, sizeof(sTitle), "%s救援关不刷特\n当前: %s\n ",
				admin ? "[管理员] 直接生效\n" : "", g_sRescueName[cur]);
			for (int i = 0; i < RESCUE_COUNT; i++)
			{
				Format(sInfo, sizeof(sInfo), "%sR%d", sPfx, i);
				Format(sDisp, sizeof(sDisp), "%s%s\n    %s", g_sRescueName[i],
					i == cur ? "  << 当前" : "", g_sRescueDesc[i]);
				menu.AddItem(sInfo, sDisp);
			}
			// 刷特插件没加载/版本太旧（v1.30 以下没这个 cvar）→ 当场说清楚，别让人以为改了有用
			if (g_cRescueOff == null)
				menu.AddItem("warn", "! 没读到 rescue_off（刷特插件没加载或版本太旧）", ITEMDRAW_DISABLED);
		}
		case SET_NEARBIAS:
		{
			// 【v1.2.19】距离偏好：和挡位一样把说明打出来，玩家才看得懂敢投
			Format(sTitle, sizeof(sTitle), "%s距离偏好\n当前: %s\n ",
				admin ? "[管理员] 直接生效\n" : "", g_sNearName[cur]);
			for (int i = 0; i < NEAR_COUNT; i++)
			{
				Format(sInfo, sizeof(sInfo), "%sN%d", sPfx, i);
				Format(sDisp, sizeof(sDisp), "%s%s\n    %s", g_sNearName[i],
					i == cur ? "  << 当前" : "", g_sNearDesc[i]);
				menu.AddItem(sInfo, sDisp);
			}
			// 距离偏好和"刷新距离"是两个旋钮，菜单里必须说清楚，否则会被当成同一件事。
			// 【v1.2.20】短句 + 只用安全字形（见 g_sNearName 上方那段说明）
			menu.AddItem("note", "距离档管能刷多远，本项管先挑近还是先挑散", ITEMDRAW_DISABLED);
			if (g_cNearBias == null)
				menu.AddItem("warn", "! 没读到 nearbias（刷特插件没加载或版本太旧）", ITEMDRAW_DISABLED);
		}
		case SET_TANK:
		{
			// 【v1.2.21】坦克期策略：转发给刷特插件的【已有】cvar ltt_sispawn_tank_action（0/1/2）。
			// 本插件原来只读它做显示（"坦克在场：上限已收紧到 N"），现在也能投票改。
			Format(sTitle, sizeof(sTitle), "%s坦克期策略\n当前: %s\n ",
				admin ? "[管理员] 直接生效\n" : "", g_sTankName[cur]);
			for (int i = 0; i < TANK_COUNT; i++)
			{
				Format(sInfo, sizeof(sInfo), "%sK%d", sPfx, i);
				Format(sDisp, sizeof(sDisp), "%s%s\n    %s", g_sTankName[i],
					i == cur ? "  << 当前" : "", g_sTankDesc[i]);
				menu.AddItem(sInfo, sDisp);
			}
			if (g_cTankAction == null)
				menu.AddItem("warn", "! 没读到 tank_action（刷特插件没加载?）", ITEMDRAW_DISABLED);
		}
		case SET_GAMEMODE:
		{
			// 【v1.2.21】特感游戏模式：转发位掩码 ltt_sispawn_classes（63=全部六种 / 53=四控）
			Format(sTitle, sizeof(sTitle), "%s特感游戏模式\n当前: %s\n ",
				admin ? "[管理员] 直接生效\n" : "", g_sGameModeName[cur]);
			for (int i = 0; i < GAMEMODE_COUNT; i++)
			{
				Format(sInfo, sizeof(sInfo), "%sG%d", sPfx, i);
				Format(sDisp, sizeof(sDisp), "%s%s\n    %s", g_sGameModeName[i],
					i == cur ? "  << 当前" : "", g_sGameModeDesc[i]);
				menu.AddItem(sInfo, sDisp);
			}
			menu.AddItem("note", "改了立刻生效（刷特插件收到掩码就换出怪表）", ITEMDRAW_DISABLED);
			if (g_cClasses == null)
				menu.AddItem("warn", "! 没读到 classes（刷特插件没加载?）", ITEMDRAW_DISABLED);
		}
		default:
		{
			delete menu;
			return;
		}
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Value(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char s[16];
		menu.GetItem(item, s, sizeof(s));

		// 【v1.2.3】'A' 前缀 = 管理员模式 → 直接生效，不走投票
		bool admin = (s[0] == 'A');
		int  o     = admin ? 1 : 0;

		int kind;
		switch (s[o])
		{
			case 'W': kind = SET_WAVE;
			case 'T': kind = SET_TIME;
			case 'C': kind = SET_CAP;
			case 'D': kind = SET_DIST;
			case 'M': kind = SET_MODE;      // 【v1.2.4】挡位
			case 'P': kind = SET_PERPLAYER; // 【v1.2.11】进人加特感
			case 'R': kind = SET_RESCUE;    // 【v1.2.18】救援关不刷特
			case 'N': kind = SET_NEARBIAS;  // 【v1.2.19】距离偏好
			case 'K': kind = SET_TANK;      // 【v1.2.21】坦克期策略（K = tanK，A 已被管理员前缀占用）
			case 'G': kind = SET_GAMEMODE;  // 【v1.2.21】特感游戏模式
			default:  return 0;
		}

		int idx = StringToInt(s[o + 1]);
		if (idx < 0)
			return 0;

		if (admin)
		{
			if (g_cOwnDebug.BoolValue)
				LogMessage("[SIMenu] 管理员直接生效（跳过投票）：%N kind=%d idx=%d", client, kind, idx);
			ApplySetting(client, kind, idx);
			ShowAdminMain(client);        // 改完回管理员菜单，方便连改几项
		}
		else
		{
			ProposeSetting(client, kind, idx);
		}
	}
	else if (action == MenuAction_Cancel)
	{
		if (item == MenuCancel_ExitBack)
			ShowMain(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

// ==================================================================== 发起投票

/** 投票面板上显示的文字（L4D2 的投票框很窄，尽量短） */
void GetVoteText(int kind, int idx, char[] buf, int maxlen)
{
	switch (kind)
	{
		case SET_WAVE: Format(buf, maxlen, "每波特感 %d 只 ?（现 %d）", g_iWaves[idx], g_cWave.IntValue);
		case SET_TIME: Format(buf, maxlen, "刷新间隔 %d 秒 ?（现 %d）", g_iTimes[idx], g_cTime.IntValue);
		case SET_CAP:  Format(buf, maxlen, "存活上限 %d 只 ?（现 %d）", g_iCaps[idx], g_cCap.IntValue);
		case SET_DIST: Format(buf, maxlen, "刷新距离改成 %s ?", g_sDistName[idx]);
		case SET_MODE: Format(buf, maxlen, "刷特挡位改成 %d %s ?", idx, g_sModeName[idx]);   // 【v1.2.4】
		case SET_PERPLAYER:   // 【v1.2.11】投票框很窄，这里用短句
		{
			if (g_iPerPlayers[idx] == 0)
				Format(buf, maxlen, "进人不再加特感（关）?");
			else
				Format(buf, maxlen, "进人加特感 每多1人 +%d 只 ?", g_iPerPlayers[idx]);
		}
		case SET_RESCUE:      // 【v1.2.18】投票框很窄，同样用短句
		{
			if (g_iRescues[idx] == 0)
				Format(buf, maxlen, "救援关照旧刷特感 ?");
			else if (g_iRescues[idx] == 1)
				Format(buf, maxlen, "救援关整张不刷特感 ?");
			else
				Format(buf, maxlen, "救援关只在开救援后停刷 ?");
		}
		case SET_NEARBIAS:    // 【v1.2.19】距离偏好（短句）
		{
			if (g_iNears[idx] == 1)
				Format(buf, maxlen, "特感优先刷近处（贴脸）?");
			else
				Format(buf, maxlen, "特感距离均衡（不刻意就近）?");
		}
		case SET_TANK:        // 【v1.2.21】坦克期策略（投票框很窄，同样用短句）
		{
			if (g_iTanks[idx] == 0)
				Format(buf, maxlen, "坦克期照常刷特（不干预）?");
			else if (g_iTanks[idx] == 1)
				Format(buf, maxlen, "坦克期收紧刷特参数 ?");
			else
				Format(buf, maxlen, "坦克期一只特感都不刷 ?");
		}
		case SET_GAMEMODE:    // 【v1.2.21】特感游戏模式（短句）
		{
			if (g_iClasses[idx] == 63)
				Format(buf, maxlen, "六种特感全出（默认）?");
			else
				Format(buf, maxlen, "只出四控特感（不出胖子毒妇）?");
		}
	}
}

/** 通过所需同意票：基准 = 在场生还者人数（不投票视为反对） */
int VoteNeed(int players, int yes, int no)
{
	int base = players;
	if (base < 1)
		base = yes + no;
	if (base < 1)
		base = 1;

	int need = RoundToCeil(float(base) * g_cRatio.FloatValue / 100.0);
	if (need < 1)
		need = 1;
	if (need > base)
		need = base;
	return need;
}

void ProposeSetting(int client, int kind, int idx)
{
	if (g_cWave == null)
		return;

	// 【v1.2.2 根因修复】有投票权的**只算 team 2(生还者) / team 3(感染者)**，旁观必须排除。
	//
	// v1.1.0 写的是"所有在场真人（含旁观）"，理由是"服主经常旁观测试，
	// 只算生还者的话他自己看不到投票面板"。这个改动造成了 2026-09-23 的严重事故：
	//   旁观者会收下原生投票面板，但**引擎不把投票按键交给旁观者** →
	//   这个投票永远等不到结束 → **L4D2 引擎的全局投票锁**一直挂着 →
	//   之后连 !chmap 换图投票都再也发不出来，最后只能重启服务器。
	// 参考实现（豆瓣酱整合包 l4d2_map_vote）收人的条件就是 team 2 或 3。
	//
	// 兼顾两边：投票人只算 team 2/3；发起人若是旁观，下面会走"直接生效"分支
	// （他没有投票资格，起投票本来就没意义），所以服主旁观时菜单照样能用。
	int voters[MAXPLAYERS + 1];
	int n = 0;
	int nSpec = 0;              // 旁观/未选择的人数，只用于日志排查
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		int team = GetClientTeam(i);
		if (team == TEAM_SURVIVOR || team == TEAM_INFECTED)
			voters[n++] = i;
		else
			nSpec++;            // team 1 = 旁观/未选择 → 不给投票权
	}

	bool byIsVoter = false;
	for (int i = 0; i < n; i++)
	{
		if (voters[i] == client)
		{
			byIsVoter = true;
			break;
		}
	}

	// 不需要投票的情形：关掉了 / 原生不可用 / 有投票权的人太少 / 【发起人自己没有投票权】
	// 【重要】这条分支必须打日志。服主反馈"选了一档没看到投票面板"时，
	// 就是因为这里没日志，只能靠翻别的日志间接推断，白白绕了一圈。
	if (!g_cVote.BoolValue || !g_bHasNative || n < g_cMinVoters.IntValue || !byIsVoter)
	{
		if (g_cOwnDebug.BoolValue)
			LogMessage("[SIMenu] 直接生效（没走投票）：走投票=%d 原生可用=%d 投票人=%d 旁观=%d 发起人有投票权=%d 门槛=%d",
				g_cVote.IntValue, g_bHasNative ? 1 : 0, n, nSpec,
				byIsVoter ? 1 : 0, g_cMinVoters.IntValue);

		// 【v1.2.23】专用投票日志：直接生效（没走投票）也必须留痕 ——
		// 这是"没人投票就把设置改了"的唯一记录；注意这里**不受 ltt_simenu_debug 影响**。
		{
			char sVT[96], sWho2[MAX_NAME_LENGTH], sAuth2[32];
			GetVoteText(kind, idx, sVT, sizeof(sVT));
			if (client > 0 && client <= MaxClients && IsClientInGame(client))
			{
				GetClientName(client, sWho2, sizeof(sWho2));
				if (!GetClientAuthId(client, AuthId_Steam2, sAuth2, sizeof(sAuth2)))
					strcopy(sAuth2, sizeof(sAuth2), "?");
			}
			else
			{
				strcopy(sWho2, sizeof(sWho2), "控制台");
				strcopy(sAuth2, sizeof(sAuth2), "-");
			}
			SimVoteLog("[特感-直接生效] 发起=%s(%s) 类型=%s kind=%d idx=%d 投票人=%d 门槛=%d 发起人有投票权=%d",
				sWho2, sAuth2, sVT, kind, idx, n, g_cMinVoters.IntValue, byIsVoter ? 1 : 0);
		}

		if (g_cVote.BoolValue && !g_bHasNative)
			PrintToChatAll("\x01[\x05刷特\x01] 原生投票不可用，本次直接生效");
		else if (g_cVote.BoolValue && !byIsVoter && client > 0)
			PrintToChat(client, "\x01[\x05刷特\x01] 你在旁观（没有投票权），本次直接生效");
		else if (g_cVote.BoolValue && n < g_cMinVoters.IntValue && n >= 1)
			PrintToChatAll("\x01[\x05刷特\x01] 在场投票人只有 %d 人（需 %d 人才投票），本次直接生效",
				n, g_cMinVoters.IntValue);

		ApplySetting(client, kind, idx);
		return;
	}

	if (g_bVoteActive || !L4D2NativeVote_IsAllowNewVote())
	{
		PrintToChat(client, "\x01[\x05刷特\x01] 当前已有别的投票在进行，等它结束再试");
		if (g_cOwnDebug.BoolValue)
			LogMessage("[SIMenu] 投票被拒：本地进行中=%d IsAllowNewVote=%d",
				g_bVoteActive ? 1 : 0, L4D2NativeVote_IsAllowNewVote() ? 1 : 0);
		return;
	}

	char sText[96];
	GetVoteText(kind, idx, sText, sizeof(sText));

	g_iPendKind = kind;
	g_iPendIdx  = idx;
	g_iPendBy   = client;

	L4D2NativeVote vote = L4D2NativeVote(Handler_NativeVote);
	vote.Initiator = client;
	vote.SetDisplayText("%s", sText);

	int duration = g_cVoteTime.IntValue;

	if (!vote.DisplayVote(voters, n, duration))
	{
		g_iPendKind = -1;
		g_iPendIdx  = -1;
		PrintToChat(client, "\x01[\x05刷特\x01] 投票发起失败，请稍后再试");
		if (g_cOwnDebug.BoolValue)
			LogMessage("[SIMenu] DisplayVote 返回 false（在场真人=%d 时长=%d）", n, duration);
		return;
	}

	g_bVoteActive = true;

	char sWho[MAX_NAME_LENGTH];
	GetClientName(client, sWho, sizeof(sWho));
	PrintToChatAll("\x01[\x05刷特\x01] \x04%s\x01 发起投票：%s —— %d 秒内 \x04F1 同意\x01 / \x04F2 反对\x01",
		sWho, sText, duration);

	if (g_cOwnDebug.BoolValue)
		LogMessage("[SIMenu] 已发起投票：%s kind=%d idx=%d（投票人 %d 人，旁观 %d 人不计）面板文字=%s",
			sWho, kind, idx, n, nSpec, sText);

	// 【v1.2.23】专用投票日志：发起（不受 debug 开关影响，普通玩家都能触发投票）
	strcopy(g_sSimVoterName, sizeof(g_sSimVoterName), sWho);
	if (!GetClientAuthId(client, AuthId_Steam2, g_sSimVoterAuth, sizeof(g_sSimVoterAuth)))
		strcopy(g_sSimVoterAuth, sizeof(g_sSimVoterAuth), "?");
	SimVoteLog("[特感-发起] 发起=%s(%s) 类型=%s kind=%d idx=%d 投票人=%d 旁观=%d 时长=%ds",
		sWho, g_sSimVoterAuth, sText, kind, idx, n, nSpec, duration);
}

public void Handler_NativeVote(L4D2NativeVote vote, VoteAction action, int param1, int param2)
{
	if (action == VoteAction_Start)
	{
		int need = VoteNeed(vote.PlayerCount, vote.YesCount, vote.NoCount);
		PrintToChatAll("\x01[\x05刷特\x01] 通过条件：在场 \x04%d\x01 人中需 \x04%d\x01 票同意（不投票视为反对）",
			vote.PlayerCount, need);
		return;
	}

	if (action != VoteAction_End)
		return;

	// 【v1.2.6 · 关键修复】同一次投票可能收到【两次】VoteAction_End。
	//
	// 2026-09-24 18:35 实测（服主报"四个人同意都不通过"），日志同一秒出现两行：
	//     18:35:05 [SIMenu] 投票通过:   kind=0  idx=8  (同意3 反对0 需3)   ← 第一次
	//     18:35:05 [SIMenu] 投票未通过: kind=-1 idx=-1 (同意4 反对0 需3)   ← 第二次
	// 第一次已经正常通过、设置也真的生效了（同秒还有 `生效: 每波=26…`），
	// 但第二次 End 进来时 `g_iPendKind` 已被清成 -1，而下面"未通过"那条分支
	// **没有做 kind 守卫**，于是又发了一次 SetFail + 广播"未通过" ——
	// 玩家看到的就是"四个都同意，却提示未通过"。
	//
	// `g_iPendKind` 在第一次处理时就被清空，所以它天然就是"本次投票已处理"的标记。
	// 这里直接忽略重复的 End。**注意绝不能再发一次 SetPass/SetFail**：
	// 在 SetPass 之后再 SetFail 会让引擎的投票状态自相矛盾，
	// 那正是"面板卡住 + 全服投票锁死"的成因（2026-09-23 已经因此重启过一次）。
	if (g_iPendKind < 0)
	{
		if (g_cOwnDebug.BoolValue)
			LogMessage("[SIMenu] 收到重复的 VoteAction_End（本次投票已处理过），已忽略");
		return;
	}

	int need = VoteNeed(vote.PlayerCount, vote.YesCount, vote.NoCount);
	int kind = g_iPendKind;
	int idx  = g_iPendIdx;
	int by   = g_iPendBy;

	g_bVoteActive = false;
	g_iPendKind   = -1;
	g_iPendIdx    = -1;

	char sText[96];
	if (kind >= 0 && idx >= 0)
		GetVoteText(kind, idx, sText, sizeof(sText));
	else
		strcopy(sText, sizeof(sText), "设置");

	if (kind >= 0 && vote.YesCount >= need && vote.YesCount > vote.NoCount)
	{
		ApplySetting(by, kind, idx);
		// 必须先发 VotePass，面板才会关、库里的 ResetVote() 才会跑
		vote.SetPass("%s 通过", sText);
		PrintToChatAll("\x01[\x05刷特\x01] \x04通过！\x01%s（同意 %d / 反对 %d，需 %d）",
			sText, vote.YesCount, vote.NoCount, need);
		// 【v1.2.16】长期跑图要能按图 grep，关键日志必须带地图名（与 spawner 的写法一致）
		char sMapVote[64];
		GetCurrentMap(sMapVote, sizeof(sMapVote));
		LogMessage("[SIMenu] 地图=%s 投票通过: kind=%d idx=%d (同意%d 反对%d 需%d)",
			sMapVote, kind, idx, vote.YesCount, vote.NoCount, need);
		// 【v1.2.23】专用投票日志：通过（带发起人 + 地图，方便按图 grep）
		SimVoteLog("[特感-通过] 发起=%s(%s) 类型=%s kind=%d idx=%d 票=同意%d/反对%d 需%d 地图=%s",
			g_sSimVoterName, g_sSimVoterAuth, sText, kind, idx,
			vote.YesCount, vote.NoCount, need, sMapVote);
	}
	else
	{
		// 不通过也必须发 VoteFail，否则面板卡住 + 投票锁死
		vote.SetFail();
		PrintToChatAll("\x01[\x05刷特\x01] \x02未通过\x01，维持原设置（同意 %d / 反对 %d，需 %d）",
			vote.YesCount, vote.NoCount, need);
		LogMessage("[SIMenu] 投票未通过: kind=%d idx=%d (同意%d 反对%d 需%d)", kind, idx, vote.YesCount, vote.NoCount, need);
		// 【v1.2.23】专用投票日志：未通过（"发起了但没成"也要留痕）
		SimVoteLog("[特感-未通过] 发起=%s(%s) 类型=%s kind=%d idx=%d 票=同意%d/反对%d 需%d",
			g_sSimVoterName, g_sSimVoterAuth, sText, kind, idx,
			vote.YesCount, vote.NoCount, need);
	}
}

// ==================================================================== 应用

void ApplySetting(int client, int kind, int idx)
{
	if (g_cWave == null)
		return;

	char sWho[MAX_NAME_LENGTH];
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
		GetClientName(client, sWho, sizeof(sWho));
	else
		strcopy(sWho, sizeof(sWho), "服务器");

	char sMsg[192];

	switch (kind)
	{
		case SET_WAVE:
		{
			if (idx < 0 || idx >= WAVE_COUNT)
				return;
			int w = g_iWaves[idx];
			g_cWave.SetInt(w);

			// 沿用既有设计：上限 ≈ 每波的 2 倍，否则"上一波剩下的会吃掉下一波额度"。
			// 只升不降 —— 玩家手动设过的上限不因为调小每波而被压掉。
			// 【v1.2.1】要夹在 cvar 上界(32)内：投 26 特时 want=52，直接 SetInt 会被引擎
			// 静默截断成 32，日志里却显示"跟到 52"，看着像生效了其实没有。
			int want = w * 2;
			if (want > 32)
				want = 32;

			if (g_cCap != null && g_cCap.IntValue < want)
			{
				g_cCap.SetInt(want);
				Format(sMsg, sizeof(sMsg), "每波改成 \x05%d\x01 只（上限自动跟到 \x05%d\x01，实际生效 \x05%d\x01）",
					w, want, EffectiveCap());
			}
			else
				Format(sMsg, sizeof(sMsg), "每波改成 \x05%d\x01 只（实际生效 \x05%d\x01）", w, EffectiveCap());
		}
		case SET_TIME:
		{
			if (idx < 0 || idx >= TIME_COUNT)
				return;
			int t = g_iTimes[idx];
			g_cTime.SetInt(t);
			Format(sMsg, sizeof(sMsg), "刷新间隔改成 \x05%d\x01 秒", t);
		}
		case SET_CAP:
		{
			if (idx < 0 || idx >= CAP_COUNT)
				return;
			int c = g_iCaps[idx];
			g_cCap.SetInt(c);
			Format(sMsg, sizeof(sMsg), "存活上限改成 \x05%d\x01 只（实际生效 \x05%d\x01）", c, EffectiveCap());
		}
		case SET_DIST:
		{
			if (idx < 0 || idx >= DIST_COUNT)
				return;
			g_cMin.SetInt(g_iDistMin[idx]);
			g_cMax.SetInt(g_iDistMax[idx]);
			Format(sMsg, sizeof(sMsg), "刷新距离改成 \x05%s\x01", g_sDistName[idx]);
		}
		case SET_MODE:
		{
			// 【v1.2.4】挡位：写 ltt_sispawn_mode，刷特插件会自己展开三个子 cvar 并记日志
			if (idx < 0 || idx >= MODE_COUNT)
				return;
			if (g_cMode == null)
			{
				PrintToChatAll("\x01[\x05刷特\x01] 刷特插件没有 mode cvar（版本太旧？），挡位切换失败");
				return;
			}
			g_cMode.SetInt(idx);
			Format(sMsg, sizeof(sMsg), "刷特挡位改成 \x05%d\x01（%s）", idx, g_sModeName[idx]);
		}
		case SET_PERPLAYER:
		{
			// 【v1.2.11】进人加特感：写 ltt_sispawn_perplayer
			if (idx < 0 || idx >= PERPLAYER_COUNT)
				return;
			if (g_cPerPlayer == null)
			{
				PrintToChatAll("\x01[\x05刷特\x01] 刷特插件没有 perplayer cvar（版本太旧？），进人加特感切换失败");
				return;
			}
			g_cPerPlayer.SetInt(g_iPerPlayers[idx]);
			if (g_cScaling != null && !g_cScaling.BoolValue)
				PrintToChatAll("\x01[\x05刷特\x01] \x02注意\x01：人数缩放是关的，这条要等 scaling=1 才会生效");
			if (g_iPerPlayers[idx] == 0)
				Format(sMsg, sizeof(sMsg), "进人加特感改成 \x05关\x01（人数不再改变特感量）");
			else
				Format(sMsg, sizeof(sMsg), "进人加特感改成 \x05每多 1 人 +%d 只/波\x01（存活上限 +%d）",
					g_iPerPlayers[idx], g_iPerPlayers[idx] * 2);
		}
		case SET_RESCUE:
		{
			// 【v1.2.18】救援关不刷特：写 ltt_sispawn_rescue_off。
			// 刷特插件 v1.30.1 起挂了变更钩子 ⇒ 收到值会【立刻】重算救援关闸门（不用等换图）。
			if (idx < 0 || idx >= RESCUE_COUNT)
				return;
			if (g_cRescueOff == null)
			{
				PrintToChatAll("\x01[\x05刷特\x01] 刷特插件没有 rescue_off cvar（版本太旧？），救援关开关切换失败");
				return;
			}
			g_cRescueOff.SetInt(g_iRescues[idx]);
			if (g_iRescues[idx] == 0)
				Format(sMsg, sizeof(sMsg), "救援关不刷特改成 \x05关\x01（救援关照旧刷）");
			else if (g_iRescues[idx] == 1)
				Format(sMsg, sizeof(sMsg), "救援关不刷特改成 \x05整张救援关不刷\x01");
			else
				Format(sMsg, sizeof(sMsg), "救援关不刷特改成 \x05救援开始后才停刷\x01");
		}
		case SET_NEARBIAS:
		{
			// 【v1.2.19】距离偏好：写 ltt_sispawn_nearbias。
			// 刷特插件 v1.28.4 起这个 cvar 就是"就近优先"的总开关（1=开 0=关），
			// 名字里带 nearbias 的日志/播报都会跟着变；服务器名里的 {nearbias} 也会立刻刷新
			//（ltt_servername v1.0.13 给它挂了变更钩子）。
			if (idx < 0 || idx >= NEAR_COUNT)
				return;
			if (g_cNearBias == null)
			{
				PrintToChatAll("\x01[\x05刷特\x01] 刷特插件没有 nearbias cvar（版本太旧？），距离偏好切换失败");
				return;
			}
			g_cNearBias.SetInt(g_iNears[idx]);
			Format(sMsg, sizeof(sMsg), "距离偏好改成 \x05%s\x01", g_sNearName[idx]);
		}
		case SET_TANK:
		{
			// 【v1.2.21】坦克期策略：写刷特插件的【已有】cvar ltt_sispawn_tank_action。
			// 软连接不变：只 FindConVar + SetInt，不引用它的函数（它自己挂钩子重算坦克期参数）。
			// 值域 0~2，照现有写法夹一下再写。
			if (idx < 0 || idx >= TANK_COUNT)
				return;
			if (g_cTankAction == null)
			{
				PrintToChatAll("\x01[\x05刷特\x01] 刷特插件没有 tank_action cvar（没加载？），坦克期策略切换失败");
				return;
			}
			g_cTankAction.SetInt(ClampInt(g_iTanks[idx], 0, 2));
			Format(sMsg, sizeof(sMsg), "坦克期策略改成 \x05%s\x01", g_sTankName[idx]);
		}
		case SET_GAMEMODE:
		{
			// 【v1.2.21】特感游戏模式：写位掩码 ltt_sispawn_classes（1烟2胖4猎8妇16骑32牛）。
			// 值域 1~63（0 等于"一只都不出"，不是本菜单的表达范围），照现有写法夹一下再写。
			// ⚠ 刷特插件那侧必须按【位掩码】解析这个 cvar —— 它现在还是职业表 "1,2,3,4,5,6"
			// （只认 1~6），写 63 会让它"没有可用职业"⇒ 一只特感都不刷。详见 g_iClasses 上方的说明。
			if (idx < 0 || idx >= GAMEMODE_COUNT)
				return;
			if (g_cClasses == null)
			{
				PrintToChatAll("\x01[\x05刷特\x01] 刷特插件没有 classes cvar（没加载？），特感游戏模式切换失败");
				return;
			}
			g_cClasses.SetInt(ClampInt(g_iClasses[idx], 1, 63));
			Format(sMsg, sizeof(sMsg), "特感游戏模式改成 \x05%s\x01（掩码 %d）", g_sGameModeName[idx], g_iClasses[idx]);
		}
		default:
			return;
	}

	g_bDirty = true;
	SaveCurrent();

	PrintToChatAll("\x01[\x05刷特\x01] \x04%s\x01 把 %s", sWho, sMsg);
	PrintSettingsToAll();

	if (g_cOwnDebug.BoolValue)
	{
		char sMapEffect[64];
		GetCurrentMap(sMapEffect, sizeof(sMapEffect));
		LogMessage("[SIMenu] 地图=%s 生效: %s kind=%d idx=%d → 每波=%d 间隔=%d 上限=%d(生效 %d) 距离=%d~%d 挡位=%d 进人加特感=%d 救援关不刷特=%d 距离偏好=%d 坦克期策略=%d 特感游戏模式=%d",
			sMapEffect, sWho, kind, idx, g_cWave.IntValue, g_cTime.IntValue,
			g_cCap.IntValue, EffectiveCap(), g_cMin.IntValue, g_cMax.IntValue,
			g_cMode != null ? g_cMode.IntValue : -1,
			g_cPerPlayer != null ? g_cPerPlayer.IntValue : -1,
			g_cRescueOff != null ? g_cRescueOff.IntValue : -1,
			g_cNearBias != null ? g_cNearBias.IntValue : -1,
			g_cTankAction != null ? g_cTankAction.IntValue : -1,
			g_cClasses != null ? g_cClasses.IntValue : -1);
	}
}

void PrintSettingsToAll()
{
	// 【v1.2.4】把挡位也带上 —— 服主要求"出门提示是哪一档"
	int m = (g_cMode != null) ? g_cMode.IntValue : 1;
	// 【v1.2.13】每波数量也改成生效值 —— 原来这句里 wave 用的是【设的值】(g_cWave)、
	// 上限却用的是【生效值】(EffectiveCap())，同一行两个口径，服主说的
	// "刷特和刷特插件对不上"就是这类。现在一律生效值。
	PrintToChatAll("\x01[\x05刷特\x01] 当前: 每波 \x05%d\x01 只 / 间隔 \x05%d\x01 秒 / 上限 \x05%d\x01 / 距离 \x05%d~%d\x01 / 挡位 \x05%d\x01",
		GetEffWaveSafe(), g_cTime.IntValue, EffectiveCap(), g_cMin.IntValue, g_cMax.IntValue, m);

	// 【v1.2.11】进人加特感：连 scaling 开关一起说，否则设了没效果玩家会以为插件坏了
	int pp = (g_cPerPlayer != null) ? g_cPerPlayer.IntValue : 0;
	char sScale[48];
	if (g_cScaling == null)
		strcopy(sScale, sizeof(sScale), "未读到(刷特插件没加载?)");
	else
		strcopy(sScale, sizeof(sScale), g_cScaling.BoolValue ? "开" : "关");
	if (pp > 0)
		PrintToChatAll("\x01[\x05刷特\x01] 进人加特感: 每多 1 人 \x05+%d 只/波\x01（上限 +%d）/ 人数缩放 \x05%s\x01",
			pp, pp * 2, sScale);
	else
		PrintToChatAll("\x01[\x05刷特\x01] 进人加特感: \x02关\x01（人数不改变特感量）/ 人数缩放 \x05%s\x01", sScale);

	// 【v1.2.18】救援关不刷特也播一句（默认档就说"整张救援关不刷"，
	// 免得玩家在救援关里看不到特感、以为是刷特插件坏了）
	if (g_cRescueOff == null)
		PrintToChatAll("\x01[\x05刷特\x01] 救援关不刷特: \x02未读到设置\x01（刷特插件没加载?）");
	else
		PrintToChatAll("\x01[\x05刷特\x01] 救援关不刷特: \x05%s\x01", g_sRescueName[RescueIndexFromCvar()]);

	// 【v1.2.19】距离偏好也播一句 —— 它和"距离档"是两回事，
	// 不播的话玩家会把它跟上面那行"距离 200~2000"混为一谈。
	if (g_cNearBias == null)
		PrintToChatAll("\x01[\x05刷特\x01] 距离偏好: \x02未读到设置\x01（刷特插件没加载?）");
	else
		PrintToChatAll("\x01[\x05刷特\x01] 距离偏好: \x05%s\x01", g_sNearName[NearIndexFromCvar()]);

	// 【v1.2.21】坦克期策略：不播的话玩家看到"坦克在场：上限收到 8"会以为刷特插件坏了
	if (g_cTankAction == null)
		PrintToChatAll("\x01[\x05刷特\x01] 坦克期策略: \x02未读到设置\x01（刷特插件没加载?）");
	else
		PrintToChatAll("\x01[\x05刷特\x01] 坦克期策略: \x05%s\x01", g_sTankName[TankIndexFromCvar()]);

	// 【v1.2.21】特感游戏模式（出哪几种特感）也播一句
	if (g_cClasses == null)
		PrintToChatAll("\x01[\x05刷特\x01] 特感游戏模式: \x02未读到设置\x01（刷特插件没加载?）");
	else
		PrintToChatAll("\x01[\x05刷特\x01] 特感游戏模式: \x05%s\x01", g_sGameModeName[GameModeIndexFromCvar()]);
}

/**
 * 【v1.2.11】把 cvar 里的 perplayer 原值（0~8 任意值）就近折成档位下标。
 * 档位表是 { 0,1,2,3,4,6 }，服主若用 cfg 直接写了 5 或 7，这里也能显示成最近的一档，
 * 不会出现 cur 越界。
 */
/** 【v1.2.18】把 cvar 里的 rescue_off 原值（0/1/2）折成档位下标。
 *  读不到 cvar（刷特插件没加载/版本旧）按 1 = "整张救援关不刷" —— 这是插件侧的默认值，
 *  显示口径必须跟插件一致，否则又是一处"显示与实效不一致"。 */
int RescueIndexFromCvar()
{
	int v = (g_cRescueOff != null) ? g_cRescueOff.IntValue : 1;

	if (v <= 0)
		return 0;
	if (v == 1)
		return 1;
	return 2;
}

/** 【v1.2.19】把 cvar 里的 nearbias 原值折成档位下标。
 *  cvar 只有 0/1 两种取值；读不到（刷特插件没加载）按 0 = "均衡" ——
 *  这也是刷特插件侧的默认值，显示口径必须一致。 */
int NearIndexFromCvar()
{
	if (g_cNearBias == null)
		return 0;
	return g_cNearBias.BoolValue ? 1 : 0;
}

/** 【v1.2.21】写 cvar 之前把值夹进 [lo, hi]。
 *  为什么要有：tank_action 只认 0~2、classes 只认 1~63，SetInt 越界会被 cvar 系统
 *  **静默截断**（和 v1.2.1 每波 26 撞上 cap 上界那次同一个坑）：日志显示"改成 X"，
 *  实际 cvar 里是另一个值。档位表本身都是合法值，夹一下只是兜底 + 让口径写在明面上。 */
int ClampInt(int v, int lo, int hi)
{
	if (v < lo)
		return lo;
	if (v > hi)
		return hi;
	return v;
}

/** 【v1.2.21】把 cvar 里的 tank_action 原值（0/1/2）折成档位下标。
 *  读不到 cvar（刷特插件没加载/版本旧）按 1 = "接管·坦克期收紧" ——
 *  这是刷特插件侧的默认档，显示口径必须跟它一致（同 rescue/near 那两条的做法）。 */
int TankIndexFromCvar()
{
	int v = (g_cTankAction != null) ? g_cTankAction.IntValue : 1;

	for (int i = 0; i < TANK_COUNT; i++)
	{
		if (g_iTanks[i] == v)
			return i;
	}

	// 表外的值（服主在 cfg 里写了别的数）就近折，绝不越界
	if (v <= 0)
		return 0;
	if (v == 1)
		return 1;
	return 2;
}

/** 【v1.2.21】把 cvar 里的 classes 位掩码折成档位下标。
 *  读不到（刷特插件没加载）按 0 = "全部六种"（掩码 63）—— 也是刷特插件侧的默认值。
 *  表外的掩码（以后新加的档、或服主手写的组合）暂时都显示成第 0 档"全部六种"；
 *  以后加档时记得在 g_iClasses[] 末尾补上，这里就会自动认出来。 */
int GameModeIndexFromCvar()
{
	int v = (g_cClasses != null) ? g_cClasses.IntValue : 63;

	for (int i = 0; i < GAMEMODE_COUNT; i++)
	{
		if (g_iClasses[i] == v)
			return i;
	}
	return 0;
}

int PerIndexFromCvar()
{
	int v = (g_cPerPlayer != null) ? g_cPerPlayer.IntValue : 0;

	int best = 0;
	for (int i = 0; i < PERPLAYER_COUNT; i++)
	{
		if (g_iPerPlayers[i] == v)
			return i;

		int dv = (v > g_iPerPlayers[i])     ? v - g_iPerPlayers[i]     : g_iPerPlayers[i]     - v;
		int db = (v > g_iPerPlayers[best])  ? v - g_iPerPlayers[best]  : g_iPerPlayers[best]  - v;
		if (dv < db)
			best = i;
	}
	return best;
}

void PrintCurrent(int client)
{
	int m = (g_cMode != null) ? g_cMode.IntValue : 1;
	if (m < 0 || m >= MODE_COUNT)
		m = 1;

	PrintToChat(client, "\x01[\x05刷特\x01] \x04本局设置\x01");
	// 【v1.2.10】原来这里显示的是【设的值】，人数缩放开着时和第 5 人进服后的实际不符 ——
	// 且与下面那句「存活上限：设的 / 实际生效」自相矛盾（同一个面板里两个口径）。
	// 改成显示生效值，并在两者不同时把设的值也标出来。
	if (GetEffWaveSafe() != g_cWave.IntValue)
		PrintToChat(client, "\x01  每波数量: \x05%d\x01 只（设 %d，人数缩放 +%d）",
			GetEffWaveSafe(), g_cWave.IntValue, GetEffWaveSafe() - g_cWave.IntValue);
	else
		PrintToChat(client, "\x01  每波数量: \x05%d\x01 只", g_cWave.IntValue);
	PrintToChat(client, "\x01  刷新间隔: \x05%d\x01 秒", g_cTime.IntValue);
	PrintToChat(client, "\x01  存活上限: 设的 \x05%d\x01 只 / 实际生效 \x05%d\x01 只（槽位硬上限 %d）",
		g_cCap.IntValue, EffectiveCap(), HardCap());
	PrintToChat(client, "\x01  刷新距离: \x05%d~%d\x01（%s）",
		g_cMin.IntValue, g_cMax.IntValue, g_sDistName[DistIndexFromCvars()]);
	PrintToChat(client, "\x01  刷特挡位: \x05%d\x01 %s —— %s", m, g_sModeName[m], g_sModeDesc[m]);

	// 【v1.2.11】进人加特感（连带 scaling 状态；缩放关着时这个值是不生效的）
	{
		char sScale[48];
		if (g_cScaling == null)
			strcopy(sScale, sizeof(sScale), "未读到缩放开关");
		else
			strcopy(sScale, sizeof(sScale), g_cScaling.BoolValue ? "缩放开" : "缩放关，暂不生效");

		int pv = (g_cPerPlayer != null) ? g_cPerPlayer.IntValue : 0;
		if (pv > 0)
			PrintToChat(client, "\x01  进人加特感: 每多 1 人 \x05+%d 只/波\x01（上限 +%d，%s）", pv, pv * 2, sScale);
		else
			PrintToChat(client, "\x01  进人加特感: \x02关\x01（人数不改变特感量）");
	}

	// 【v1.2.18】救援关不刷特（救援关里最容易被问"为什么没特感"的一项）
	if (g_cRescueOff == null)
		PrintToChat(client, "\x01  救援关不刷特: \x02未读到设置\x01（刷特插件没加载?）");
	else
		PrintToChat(client, "\x01  救援关不刷特: \x05%s\x01", g_sRescueName[RescueIndexFromCvar()]);

	// 【v1.2.19】距离偏好（和上面的"刷新距离"是两个旋钮，这里点明区别）
	if (g_cNearBias == null)
		PrintToChat(client, "\x01  距离偏好: \x02未读到设置\x01（刷特插件没加载?）");
	else
		PrintToChat(client, "\x01  距离偏好: \x05%s\x01（区间内先挑近的还是先挑散的）",
			g_sNearName[NearIndexFromCvar()]);

	// 【v1.2.21】坦克期策略（下面是原来就有的"坦克在场：上限已收紧到 N"，两行配合着看）
	if (g_cTankAction == null)
		PrintToChat(client, "\x01  坦克期策略: \x02未读到设置\x01（刷特插件没加载?）");
	else
		PrintToChat(client, "\x01  坦克期策略: \x05%s\x01", g_sTankName[TankIndexFromCvar()]);

	// 【v1.2.21】特感游戏模式（出哪几种特感；四控模式不出胖子、毒妇）
	if (g_cClasses == null)
		PrintToChat(client, "\x01  特感游戏模式: \x02未读到设置\x01（刷特插件没加载?）");
	else
		PrintToChat(client, "\x01  特感游戏模式: \x05%s\x01（%s）",
			g_sGameModeName[GameModeIndexFromCvar()], g_sGameModeDesc[GameModeIndexFromCvar()]);

	if (g_cTankAction != null && g_cTankAction.BoolValue && IsTankAlive() && g_cTankCap != null)
		PrintToChat(client, "\x01  \x04坦克在场\x01：上限已收紧到 \x05%d\x01 只", g_cTankCap.IntValue);

	if (g_cEnable != null)
		PrintToChat(client, "\x01  刷特开关: %s", g_cEnable.BoolValue ? "\x04开" : "\x02关");

	PrintToChat(client, "\x01  改设置: 菜单里选一档 → 走游戏投票（F1 同意 / F2 反对）");
}

// ==================================================================== 管理员

/** 恢复 cfg 默认值并清掉存档。
 *  announce=true 时聊天框播报（管理员手动触发用）；空服自动还原时静默。 */
void ResetToDefaults(int client, bool announce)
{
	if (g_cWave == null)
		return;

	ClearSaved();

	int dw = 4, dt = 40, dc = 8, dd = 4;   // 【v1.2.5】dd 默认改成 4 = 宽松 1~1500（新默认档）
	if (g_bDefaultsReady)
	{
		dw = g_iDefWave;
		dt = g_iDefTime;
		dc = g_iDefCap;
		dd = g_iDefDist;
	}

	g_cWave.SetInt(dw);
	g_cTime.SetInt(dt);
	g_cCap.SetInt(dc);
	g_cMin.SetInt(g_iDistMin[dd]);
	g_cMax.SetInt(g_iDistMax[dd]);

	// 【v1.2.16 · 2026-10-02 源码审核修复】挡位与进人加特感也必须一起还原。
	// 旧代码只写 wave/time/cap/min/max ⇒ 这两项既没还原、存档又被 ClearSaved() 清了，
	// 服务器会停在玩家上次选的挡位上，而聊天框却说"已恢复默认值"（长期跑图时
	// 空服 5 分钟自动还原正是走这条路，结果每次回来挡位都不是出厂值）。
	if (g_cMode != null)
		g_cMode.SetInt(g_iDefMode);
	if (g_cPerPlayer != null)
		g_cPerPlayer.SetInt(g_iPerPlayers[g_iDefPer]);
	// 【v1.2.18】救援关不刷特也一起还原（否则"已恢复默认值"又是一句假话）
	if (g_cRescueOff != null)
		g_cRescueOff.SetInt(g_iRescues[g_iDefRescue]);
	// 【v1.2.19】距离偏好也一起还原（同上）
	if (g_cNearBias != null)
		g_cNearBias.SetInt(g_iNears[g_iDefNear]);
	// 【v1.2.21】坦克期策略 / 特感游戏模式也一起还原（否则"已恢复默认值"又是一句假话）
	if (g_cTankAction != null)
		g_cTankAction.SetInt(ClampInt(g_iTanks[g_iDefTank], 0, 2));
	if (g_cClasses != null)
		g_cClasses.SetInt(ClampInt(g_iClasses[g_iDefGameMode], 1, 63));

	g_bDirty = false;

	if (announce)
	{
		if (client > 0)
			ReplyToCommand(client, "[刷特] 已恢复 cfg 默认值并清掉存档");
		PrintToChatAll("\x01[\x05刷特\x01] \x04管理员\x01 已把刷特设置恢复为默认值");
		PrintSettingsToAll();
	}

	if (g_cOwnDebug.BoolValue)
		LogMessage("[SIMenu] 恢复默认（播报=%d）：每波=%d 间隔=%d 上限=%d 距离=%d~%d 挡位=%d 进人加特感=%d 救援关不刷特=%d 距离偏好=%d 坦克期策略=%d 特感游戏模式=%d",
			announce ? 1 : 0, dw, dt, dc, g_iDistMin[dd], g_iDistMax[dd],
			g_iDefMode, g_iPerPlayers[g_iDefPer], g_iRescues[g_iDefRescue], g_iNears[g_iDefNear],
			g_iTanks[g_iDefTank], g_iClasses[g_iDefGameMode]);
}

/** 【v1.2.8 · 存活探针】g_iIdleTicks 的声明在文件头部的全局区（L172 附近）。
 *  它是 P0 修复的【验收点】：换图后每个图只打一条心跳日志。
 *  修复前（带 TIMER_FLAG_NO_MAPCHANGE 且本插件没有 OnMapStart）换图后这个定时器
 *  永久消失，日志里再也看不到心跳 —— 空服自动还原与投票锁看门狗同时失效，
 *  而且因为【完全没有信号】，一整天都没人发现。所以这里必须留下可见的痕迹。 */

/** 空服还原：和 ltt_svote 同一套思路 —— 投过的东西不该永远留在服务器上。
 *  （ltt_svote v1.2.2 起不再管刷特三项，还原权交给本插件，避免两边互相打架） */
public Action Timer_IdleCheck(Handle timer)
{
	// 心跳放在所有分支【之前】：无论开关怎么设，它都能证明定时器活着。
	if (g_iIdleTicks == 0)
		LogMessage("[SIMenu] v1.2.8 空服还原定时器存活（本图首次心跳，周期 30 秒）");
	g_iIdleTicks++;

	if (!g_cIdleReset.BoolValue)
		return Plugin_Continue;

	int humans = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			humans++;
	}

	if (humans > 0)
	{
		g_iIdleSince = 0;
		return Plugin_Continue;
	}

	int now = GetTime();
	if (g_iIdleSince == 0)
	{
		g_iIdleSince = now;
		return Plugin_Continue;
	}
	if (now - g_iIdleSince < g_cIdleSeconds.IntValue)
		return Plugin_Continue;

	g_iIdleSince = 0;

	if (!g_bHasSaved)
		return Plugin_Continue;    // 玩家没改过，不用动

	LogMessage("[SIMenu] 空服已 %d 秒，把刷特设置还原成 cfg 默认值并清掉存档", g_cIdleSeconds.IntValue);
	ResetToDefaults(0, false);
	return Plugin_Continue;
}

public Action Cmd_Reset(int client, int args)
{
	if (g_cWave == null)
	{
		ReplyToCommand(client, "[刷特] 刷特插件未加载");
		return Plugin_Handled;
	}

	ResetToDefaults(client, true);
	return Plugin_Handled;
}

/** 广播一条引擎级 VoteFail（关掉卡住的面板）。sm_siclose 与看门狗共用。 */
void BroadcastVoteFail()
{
	BfWrite bf = UserMessageToBfWrite(StartMessageAll("VoteFail", USERMSG_RELIABLE));
	bf.WriteByte(-1);
	EndMessage();
}

/** 【v1.2.2 新增】投票锁看门狗。
 *
 *  病症（2026-09-23 实测）：本插件并没有投票在跑，但引擎的全局投票锁一直挂着
 *  （日志 `投票被拒：本地进行中=0 IsAllowNewVote=0`），连 !chmap 都发不出来。
 *
 *  已知局限：`l4d2_nativevote` 只暴露了 `L4D2NativeVote_IsAllowNewVote()`，
 *  **没有任何"解锁/复位"原生**，所以拿不到干净的复位接口，只能广播 VoteFail 尽力顶掉
 *  （与 sm_siclose 同一手法）。它能不能真正释放引擎那把锁，本机尚未复现验证 ——
 *  所以这里把每次触发都记进日志并累计计数，下次真出现死锁就能据此判断它管不管用。
 *  根治手段是 ProposeSetting 里那条"投票人只算 team 2/3"的修复。
 *
 *  保守设计，避免误杀正常投票：
 *    · 只在"本地没有投票在跑"时才计时；
 *    · 连续挂住超过 ltt_si_menu_locksecs 秒（默认 30，比任何合法投票都长）才动手；
 *    · 锁自行恢复时也记一条，方便确认看门狗没在乱动。 */
public Action Timer_VoteLockWatch(Handle timer)
{
	if (!g_cLockWatch.BoolValue || !g_bHasNative)
		return Plugin_Continue;

	int now = GetTime();

	if (g_bVoteActive || L4D2NativeVote_IsAllowNewVote())
	{
		if (g_iLockSince != 0)
		{
			if (g_cOwnDebug.BoolValue)
				LogMessage("[SIMenu] 投票锁看门狗：锁已自行恢复（曾挂住 %d 秒，未干预）", now - g_iLockSince);
			g_iLockSince = 0;
		}
		return Plugin_Continue;
	}

	if (g_iLockSince == 0)
	{
		g_iLockSince = now;
		if (g_cOwnDebug.BoolValue)
			LogMessage("[SIMenu] 投票锁看门狗：IsAllowNewVote=0 且本地无投票，开始计时（%d 秒后强制解锁）",
				g_cLockSecs.IntValue);
		return Plugin_Continue;
	}

	if (now - g_iLockSince < g_cLockSecs.IntValue)
		return Plugin_Continue;

	int hung = now - g_iLockSince;
	g_iLockSince = 0;
	g_iLockRecover++;

	BroadcastVoteFail();

	LogMessage("[SIMenu] 投票锁看门狗：引擎投票锁被挂住 %d 秒且本地无投票 → 已广播 VoteFail 强制解锁（累计第 %d 次）",
		hung, g_iLockRecover);
	PrintToChatAll("\x01[\x05刷特\x01] 检测到投票锁卡住 %d 秒，已自动解锁", hung);
	return Plugin_Continue;
}

/** 应急：投票面板万一卡住（没发 VotePass/VoteFail），广播一条 VoteFail 把它顶掉。
 *  与 ltt_svote 的 sm_svoteclose 同一套做法。 */
public Action Cmd_CloseVote(int client, int args)
{
	BroadcastVoteFail();

	g_bVoteActive = false;
	g_iPendKind   = -1;
	g_iPendIdx    = -1;

	ReplyToCommand(client, "[刷特] 已广播 VoteFail，卡住的投票面板会关闭");
	LogMessage("[SIMenu] 管理员强制关闭投票面板 (admin=%d)", client);
	return Plugin_Handled;
}

// ==================================================================== v1.2.3 管理员菜单

int CountAliveSI()
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i))
			n++;
	}
	return n;
}

public Action Cmd_AdminMenu(int client, int args)
{
	if (client <= 0)
	{
		ReplyToCommand(client, "[刷特] 管理员菜单只能在游戏里打开");
		return Plugin_Handled;
	}
	ShowAdminMain(client);
	return Plugin_Handled;
}

void ShowAdminMain(int client)
{
	if (g_cWave == null)
	{
		PrintToChat(client, "\x01[\x05刷特\x01] 刷特插件未加载，管理员菜单不可用");
		return;
	}

	char sTitle[160];
	Format(sTitle, sizeof(sTitle), "多特管理员菜单\n当前: %d 特 / %d 秒 / 上限 %d\n生效: %d 特 上限 %d\n ",
		g_cWave.IntValue, g_cTime.IntValue, g_cCap.IntValue,
		GetEffWaveSafe(), EffectiveCap());

	Menu menu = new Menu(MenuHandler_AdminMain);
	menu.SetTitle(sTitle);
	menu.AddItem("cfg",   "刷特设置（直接生效，不走投票）");
	menu.AddItem("live",  "现场操作");
	menu.AddItem("maint", "维护");
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int GetEffWaveSafe()
{
	if (g_cWave == null)
		return 0;

	// 【v1.2.13 修一个"名字说谎"的 bug —— 服主 2026-09-27 实测反馈】
	// 本函数 v1.2.10 引入，注释与调用点都当它是【生效值】，但正文只写了
	// `return g_cWave.IntValue` ⇒ **返回的是【设的值】**。
	// 后果：第 5 人进服时刷特实际每波 6 只，而这里恒等于设的值
	//   ⇒ 下面那句 `if (GetEffWaveSafe() != g_cWave.IntValue)` **恒假**，
	//     "人数缩放 +N"那一行永远不会打印，而"每波数量"永远显示设的值。
	//   ⇒ 静默失效，比报错难发现得多。
	// 现在改成读 ltt_si_spawner v1.18.2+ 的只读镜像 cvar（每 0.1 秒维护）；
	// 镜像读不到（旧版 spawner / 未加载）才退回设的值。
	ConVar cEff = FindConVar("ltt_sispawn_effwave");
	if (cEff != null && cEff.IntValue > 0)
		return cEff.IntValue;

	return g_cWave.IntValue;
}

public int MenuHandler_AdminMain(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char s[16];
		menu.GetItem(item, s, sizeof(s));

		if (StrEqual(s, "cfg"))
			ShowAdminCfg(client);
		else if (StrEqual(s, "live"))
			ShowAdminLive(client);
		else if (StrEqual(s, "maint"))
			ShowAdminMaint(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

/** 刷特设置页：直接复用玩家的档位菜单，只是带上 admin 标记（跳过投票） */
void ShowAdminCfg(int client)
{
	Menu menu = new Menu(MenuHandler_AdminCfg);
	// 【v1.2.13】管理员页原来只写"当前: 4 特 / 40 秒 / 上限 8"，而这一页是"改设置"用的，
	// 玩家看到的"当前"和管理员看到的"当前"必须是不同口径才对 —— 所以这里明确拆成
	// "当前设置"（要改的那个值）与"实际生效"（场上真跑的），两者不同时都列出来。
	{
		int iEffW = GetEffWaveSafe();
		int iEffC = EffectiveCap();
		if (iEffW != g_cWave.IntValue || iEffC != g_cCap.IntValue)
			menu.SetTitle("刷特设置（管理员 · 直接生效）\n当前设置: %d 特 / %d 秒 / 上限 %d\n实际生效: %d 特 / 上限 %d\n ",
				g_cWave.IntValue, g_cTime.IntValue, g_cCap.IntValue, iEffW, iEffC);
		else
			menu.SetTitle("刷特设置（管理员 · 直接生效）\n当前: %d 特 / %d 秒 / 上限 %d\n ",
				g_cWave.IntValue, g_cTime.IntValue, g_cCap.IntValue);
	}
	menu.AddItem("wave", "每波特感数量");
	menu.AddItem("time", "特感刷新间隔");
	menu.AddItem("cap",  "同时存活上限");
	menu.AddItem("dist", "刷新距离");
	menu.AddItem("mode", "刷特挡位（找位策略 0/1/2）");   // 【v1.2.4】
	menu.AddItem("per",  "进人加特感（人数缩放）");      // 【v1.2.11】
	menu.AddItem("rescue", "救援关不刷特（0关/1整张/2救援开始后）");   // 【v1.2.18】
	menu.AddItem("near", "距离偏好（就近 or 均衡）");                 // 【v1.2.19】
	menu.AddItem("tank",    "坦克期策略（坦克登场时）");               // 【v1.2.21】
	menu.AddItem("classes", "特感游戏模式（出哪几种特感）");            // 【v1.2.21】
	menu.AddItem("stat", "查看本局状态（简要）");
	// 【v1.2.11】管理员页项数逐版增加，放开每页
	// 【v1.2.18】8 项 + 退出/返回行 ⇒ 改用 MENU_NO_PAGINATION（不翻页时最多 10 项）
	// 【v1.2.21】坦克期策略 / 特感游戏模式各加一项 ⇒ 11 项，超过"不翻页最多 10 项"，
	//   继续不翻页会把末尾几项静默丢掉 ⇒ 改回显式分页 7 项/页（和 ShowValueMenu 同口径）。
	menu.Pagination = 7;
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_AdminCfg(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char s[16];
		menu.GetItem(item, s, sizeof(s));

		if (StrEqual(s, "wave"))      ShowValueMenu(client, SET_WAVE, true);
		else if (StrEqual(s, "time")) ShowValueMenu(client, SET_TIME, true);
		else if (StrEqual(s, "cap"))  ShowValueMenu(client, SET_CAP,  true);
		else if (StrEqual(s, "dist")) ShowValueMenu(client, SET_DIST, true);
		else if (StrEqual(s, "mode")) ShowValueMenu(client, SET_MODE, true);   // 【v1.2.4】
		else if (StrEqual(s, "per"))  ShowValueMenu(client, SET_PERPLAYER, true);   // 【v1.2.11】
		else if (StrEqual(s, "rescue")) ShowValueMenu(client, SET_RESCUE, true);   // 【v1.2.18】
		else if (StrEqual(s, "near"))   ShowValueMenu(client, SET_NEARBIAS, true); // 【v1.2.19】距离偏好
		else if (StrEqual(s, "tank"))    ShowValueMenu(client, SET_TANK, true);     // 【v1.2.21】坦克期策略
		else if (StrEqual(s, "classes")) ShowValueMenu(client, SET_GAMEMODE, true); // 【v1.2.21】特感游戏模式
		else if (StrEqual(s, "stat"))
		{
			PrintAdminStatus(client);
			ShowAdminCfg(client);
		}
	}
	else if (action == MenuAction_Cancel)
	{
		if (item == MenuCancel_ExitBack)
			ShowAdminMain(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

void PrintAdminStatus(int client)
{
	int alive = CountAliveSI();
	int occ   = GetClientCount(false);

	PrintToChat(client, "\x01[\x05刷特\x01] 档位: 每波 \x04%d\x01 只 / 间隔 \x04%d\x01 秒 / 上限设 \x04%d\x01 生效 \x04%d\x01",
		g_cWave.IntValue, g_cTime.IntValue, g_cCap.IntValue, EffectiveCap());
	PrintToChat(client, "\x01[\x05刷特\x01] 距离 \x04%.0f~%.0f\x01 ｜ 开关=%d 挡位守卫=%d 槽位停机=%d 扩窗=%.0f",
		g_cMin.FloatValue, g_cMax.FloatValue,
		g_cEnable != null ? g_cEnable.IntValue : -1,
		g_cGuard != null ? g_cGuard.IntValue : -1,
		g_cSlotStop != null ? g_cSlotStop.IntValue : -1,
		g_cGrowMax != null ? g_cGrowMax.FloatValue : 0.0);
	PrintToChat(client, "\x01[\x05刷特\x01] 场上特感 \x04%d\x01 只 ｜ 客户端占用 \x04%d/%d\x01 ｜ 生还者 %d 人",
		alive, occ, MaxClients, CountSurvivorSlots());
	if (g_cScaling != null && g_cPerPlayer != null && g_cScaling.BoolValue)
		PrintToChat(client, "\x01[\x05刷特\x01] 人数缩放=开（每多 1 人 +%d 只/波）→ 这就是「实际生效」和「设的值」不一样的原因",
			g_cPerPlayer.IntValue);
}

// ---------------------------------------------------------- 现场操作

void ShowAdminLive(int client)
{
	char s1[64], s2[64];
	Format(s1, sizeof(s1), "立刻刷特感（选数量）");
	Format(s2, sizeof(s2), g_cEnable != null && g_cEnable.BoolValue ? "暂停刷特（当前: 开）" : "恢复刷特（当前: 已暂停）");

	Menu menu = new Menu(MenuHandler_AdminLive);
	menu.SetTitle("现场操作\n场上特感 %d 只 · 客户端 %d/%d\n ", CountAliveSI(), GetClientCount(false), MaxClients);
	menu.AddItem("burst", s1);
	menu.AddItem("toggle", s2);
	menu.AddItem("clear", "清空场上特感（只踢假人，真人不动）");
	menu.AddItem("status", "查看本局状态（简要）");
	menu.AddItem("witch", "女巫控制");
	menu.AddItem("closevote", "关掉卡住的投票面板");
	menu.AddItem("hint", "控制台诊断命令提示");
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_AdminLive(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char s[16];
		menu.GetItem(item, s, sizeof(s));

		if (StrEqual(s, "burst"))
			ShowAdminBurst(client);
		else if (StrEqual(s, "toggle"))
		{
			if (g_cEnable != null)
			{
				bool on = !g_cEnable.BoolValue;
				g_cEnable.SetInt(on ? 1 : 0);
				PrintToChatAll("\x01[\x05刷特\x01] 管理员把刷特\x04%s\x01了", on ? "开启" : "暂停");
				LogMessage("[SIMenu] 管理员 %N 把 ltt_sispawn_enable 设为 %d", client, on ? 1 : 0);
			}
			ShowAdminLive(client);
		}
		else if (StrEqual(s, "clear"))
		{
			// 软连接：不引用刷特插件的函数，走控制台命令触发它自己的簿记逻辑
			ServerCommand("sm_sispawn_clear");
			PrintToChat(client, "\x01[\x05刷特\x01] 已请求清空（只踢特感假人，真人不动）—— 结果见聊天/控制台");
			ShowAdminLive(client);
		}
		else if (StrEqual(s, "status"))
		{
			PrintAdminStatus(client);
			ShowAdminLive(client);
		}
		else if (StrEqual(s, "witch"))
			ShowAdminWitch(client);
		else if (StrEqual(s, "closevote"))
		{
			BroadcastVoteFail();
			g_bVoteActive = false;
			g_iPendKind = -1;
			g_iPendIdx  = -1;
			PrintToChatAll("\x01[\x05刷特\x01] 已广播 VoteFail，卡住的投票面板会关闭");
			LogMessage("[SIMenu] 管理员 %N 从菜单强制关闭投票面板", client);
			ShowAdminLive(client);
		}
		else if (StrEqual(s, "hint"))
		{
			PrintToChat(client, "\x01[\x05刷特\x01] 请在【自己控制台】执行（输出不会进聊天框）:");
			PrintToChat(client, "   sm_sispawn_status  —— 完整状态（含队列/缩放/槽位硬上限）");
			PrintToChat(client, "   sm_sispawn_slots   —— 逐槽位列出（谁占了哪个位置）");
			PrintToChat(client, "   sm_silite_info     —— 每只特感的距离/速度/停滞判定");
			PrintToChat(client, "   sm_framelog        —— 帧耗时统计（真实 tick）");
			ShowAdminLive(client);
		}
	}
	else if (action == MenuAction_Cancel)
	{
		if (item == MenuCancel_ExitBack)
			ShowAdminMain(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

/** 立刻刷 N 只：给几个预设档，避免还要打字（用刷特插件的 burst 命令） */
void ShowAdminBurst(int client)
{
	Menu menu = new Menu(MenuHandler_AdminBurst);
	menu.SetTitle("立刻刷特感\n（跳过 离开安全区 判断，走刷特插件的 sm_sispawn_burst）\n ");
	menu.AddItem("4",  "刷 4 只");
	menu.AddItem("8",  "刷 8 只");
	menu.AddItem("12", "刷 12 只");
	menu.AddItem("20", "刷 20 只");
	menu.AddItem("26", "刷 26 只（打满）");
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_AdminBurst(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char s[16];
		menu.GetItem(item, s, sizeof(s));
		ServerCommand("sm_sispawn_burst %s", s);
		PrintToChat(client, "\x01[\x05刷特\x01] 已请求立刻刷 \x04%s\x01 只（结果见聊天/控制台）", s);
		ShowAdminLive(client);
	}
	else if (action == MenuAction_Cancel)
	{
		if (item == MenuCancel_ExitBack)
			ShowAdminLive(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

/** 女巫控制（ltt_si_witch 是独立插件，可能没加载 → 全程判空） */
void ShowAdminWitch(int client)
{
	char sState[96];
	if (g_cWitchEnable == null)
		strcopy(sState, sizeof(sState), "女巫插件未加载（ltt_si_witch）");
	else if (!g_cWitchEnable.BoolValue)
		strcopy(sState, sizeof(sState), "当前：未接管（原版行为）");
	else
		Format(sState, sizeof(sState), "当前：已接管，上限 %d 只", g_cWitchMax != null ? g_cWitchMax.IntValue : 1);

	Menu menu = new Menu(MenuHandler_AdminWitch);
	menu.SetTitle("女巫控制\n%s\n ", sState);
	menu.AddItem("off",  "不干预（原版行为，默认）");
	menu.AddItem("m1",   "接管 · 全场最多 1 只");
	menu.AddItem("m2",   "接管 · 全场最多 2 只");
	menu.AddItem("m0",   "接管 · 一只都不刷");
	menu.AddItem("info", "查看女巫插件状态（控制台）");
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_AdminWitch(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char s[16];
		menu.GetItem(item, s, sizeof(s));

		if (g_cWitchEnable == null)
		{
			PrintToChat(client, "\x01[\x05刷特\x01] 女巫插件（ltt_si_witch）没加载，无法控制");
			ShowAdminLive(client);
			return 0;
		}

		// 【v1.2.14 · 2026-10-02 源码审核修复】"查看状态"是只读项，必须挡在下面"接管"分支【之前】。
		// 旧代码把 info 判断放在整个 if/else 之后 ⇒ 选它既不等于 "off" 也不等于 "m2"/"m0"，
		// 于是落进 else：g_cWitchMax 被设成 1、g_cWitchEnable 被设成 1，还广播"已接管"、
		// 记一条"管理员调整女巫控制"日志 —— 一次只读查询把设置改了。
		if (StrEqual(s, "info"))
		{
			PrintToChat(client, "\x01[\x05刷特\x01] 女巫控制：%s（上限 %d）",
				g_cWitchEnable.BoolValue ? "已接管" : "未接管",
				g_cWitchMax != null ? g_cWitchMax.IntValue : -1);
			ServerCommand("sm_siwitch");
			ShowAdminWitch(client);
			return 0;
		}

		if (StrEqual(s, "off"))
		{
			g_cWitchEnable.SetInt(0);
			PrintToChatAll("\x01[\x05刷特\x01] 女巫控制已\x04关闭\x01（回到原版行为）");
		}
		else
		{
			int mx = 1;
			if (StrEqual(s, "m2"))      mx = 2;
			else if (StrEqual(s, "m0")) mx = 0;

			if (g_cWitchMax != null)
				g_cWitchMax.SetInt(mx);
			g_cWitchEnable.SetInt(1);
			PrintToChatAll("\x01[\x05刷特\x01] 女巫控制已\x04接管\x01：全场最多 %d 只", mx);
		}
		LogMessage("[SIMenu] 管理员 %N 调整女巫控制（enable=%d max=%d）",
			client, g_cWitchEnable.IntValue, g_cWitchMax != null ? g_cWitchMax.IntValue : -1);

		ShowAdminWitch(client);
	}
	else if (action == MenuAction_Cancel)
	{
		if (item == MenuCancel_ExitBack)
			ShowAdminLive(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

// ---------------------------------------------------------- 维护

void ShowAdminMaint(int client)
{
	Menu menu = new Menu(MenuHandler_AdminMaint);
	menu.SetTitle("维护\n ");
	menu.AddItem("reset", "恢复日常档位（4特40秒/上限8）并清存档");
	menu.AddItem("reload", "重载目标配置（sm_to_reload）");
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_AdminMaint(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char s[16];
		menu.GetItem(item, s, sizeof(s));

		if (StrEqual(s, "reset"))
		{
			ResetToDefaults(client, true);
			ShowAdminMaint(client);
		}
		else if (StrEqual(s, "reload"))
		{
			ServerCommand("sm_to_reload");
			PrintToChat(client, "\x01[\x05刷特\x01] 已请求重载目标配置（Target Override）");
			LogMessage("[SIMenu] 管理员 %N 从菜单触发 sm_to_reload", client);
			ShowAdminMaint(client);
		}
	}
	else if (action == MenuAction_Cancel)
	{
		if (item == MenuCancel_ExitBack)
			ShowAdminMain(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}
