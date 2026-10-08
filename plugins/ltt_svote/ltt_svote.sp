/**
 *  LTT Server Vote v1.2.7
 *  服务器玩法统一设置菜单 + 每关开局播报当前设置
 *
 *  v1.2.8 追加「日志自检」命令 `sm_vtlogtest`（管理员）：往投票日志写一条带【日志自检】
 *    标记的记录，用来验证"日志到底写没写"。
 *    **为什么要它**：投票要真人才能触发，部署完没法立刻自测 ⇒ 只能靠"应该能写"，
 *    而我不能拿这种话交付。有了它，0 人在线也能证明整条链路（cvar 开关 / VFormat /
 *    LogToFile / 路径）是通的。
 *
 *  v1.2.7 【服主 2026-09-27】"投票我经常要用，做个日志功能"
 *    · 独立投票日志：`addons/sourcemod/logs/ltt_svote.log`（一行一次投票，用 LogToFile
 *      所以自带 `L 日期 - 时间: [ltt_svote.smx]` 前缀，直接 grep 就能查）
 *    · 记什么：发起人【名字 + SteamID】、类型、目标值、原值、结果（通过/未通过/直接生效）、
 *      票数（同意/反对/需几票）、以及最终生效值。
 *      为什么连 SteamID 一起记：`ltt_svote_minvoters=1` 时**一个人就能改难度/刷特间隔**，
 *      事后要能查出是谁。
 *    · 新增 `ltt_svote_log`（默认 1）开关；新增 `sm_vtlog [N]`（管理员，默认最近 15 条，
 *      最多 20 条）把日志打到**控制台**，省得为了看记录去 SSH。
 *    · 为什么不在聊天框播：日志行太长会刷屏，控制台才是看记录的地方。
 *
 *  v1.2.6 【服主 2026-09-27 要求：加三个投票 + 本局设置里也要能查】
 *    新增投票：① 游戏难度 ② 友伤倍率 ③ 火伤倍率（上限均 0.5），
 *    并且「查看本局设置」/ 每关开局播报里也带上这三项当前值。
 *
 *    ★ 关键实现决定（记下来免得以后被"优化"掉）
 *    1. **倍率用"十分位整数"编码**：本插件的投票框架全程是 int
 *       （GetChoiceValue/GetCurrentValue 都返回 int，档位表也是 int[]）。
 *       为了不把整套框架改成 float，倍率表存的是十分位：0/1/2/3/5 代表
 *       0.0/0.1/0.2/0.3/0.5；读的时候 ×10 取整，写的时候 ÷10。
 *       **上限 0.5 是服主定的**（`ltt_sispawn_*` 之外，这两项也封顶 0.5）。
 *    2. **友伤/火伤是"按难度分 4 个 cvar"**（`survivor_friendly_fire_factor_*` /
 *       `survivor_burn_factor_*` 各有 easy/normal/hard/expert）。
 *       玩家投的是"一个倍率"，所以投票通过时**四个难度档一起设**；
 *       读当前值时读**当前难度那一档**（`z_difficulty`），如实反映场上实际。
 *    3. **必须自己跨图重设**：`server.cfg` 每次换图都会重跑，里面把友伤/火伤
 *       四个档全设成 0 ⇒ 玩家刚投的 0.3 会被静默冲掉。
 *       所以在 `OnConfigsExecuted`（cfg 执行完之后）把"投过的值"再盖回去。
 *       ⚠ 这和刷特那三项的处理方式不同：刷特三项归 ltt_si_menu 管、本插件不碰
 *         （见 Timer_IdleCheck 里 v1.2.2 那段注释）；这三项是本插件新开的领地，
 *         没有别的插件管，所以本插件自己负责跨图重设 + 空服还原。
 *    4. **默认值只捕获一次**：在第一次 `OnConfigsExecuted` 里存下 cfg 给的值
 *       （不能在 OnPluginStart 存 —— 那时 server.cfg 还没跑），空服还原用它。
 *
 *  v1.2.5 【服主 2026-09-27 反馈两件事，一起修】
 *    ① 口径不一致：5 人进服时刷特播报"每波 6 只"，但 `!vt` 的「特感设置」标题
 *       仍写"每波 4 只"。根因：`ShowSIMenu()` 直接读了**设的值** `ltt_sispawn_wave`，
 *       而 spawner 实际跑的是"设的值 + 人数缩放"。
 *       同一个文件里的 `ShowSettings()` 早就读了镜像 cvar `ltt_sispawn_effwave/effcap`，
 *       只有这个子菜单漏了。⇒ 现在【全文件取数一律走镜像】，并同时显示
 *       "当前生效 X 只（设 Y）"，让玩家自己看出缩放加了多少。
 *    ② 接入 `!si`：`!vt` 的「特感设置」原来只内置"数量 / 间隔"两项投票，
 *       而 `ltt_si_menu`（`!si`，对所有人开放）已经有 6 项（数量/间隔/上限/距离/挡位/人数缩放）
 *       且自带投票。⇒ 新增 `ltt_svote_siforward`（默认 1）：
 *       **直接把玩家转到 `!si` 菜单**，不在本插件里再抄一份档位表 ——
 *       抄一份就变成"第三份必然漂的实现"（本文件 L303 那条注释骂的就是这个）。
 *       置 0 则退回内置的数量+间隔投票，随时可回滚。
 *
 *  v1.2.0: 新增「特感设置」投票（按服主要求只做数量与刷新间隔两项）
 *          · 把原来只服务杀特回血的投票流程泛化成支持三种目标：
 *              VOTE_HEAL / VOTE_SI_WAVE / VOTE_SI_TIME
 *            原生投票与 SM 回落两条路径都跟着泛化（回落菜单的选项表也按目标切换）
 *          · 数量投票会同时把 cap 设成 2×wave，保持刷特插件「cap ≈ 2×wave」的设计；
 *            只改 wave 不改 cap 的话，投"6 只"而上限还是 8，玩家会觉得没生效
 *          · 刷特 cvar 归 ltt_si_spawner 所有，一律现场 FindConVar，不缓存句柄
 *          · 空服还原（ltt_svote_idlereset）原来只还原杀特回血，现在把
 *            每波数量 / 存活上限 / 刷新间隔 三项一起还原
 *
 *          · 把原来只服务杀特回血的投票流程泛化成支持三种目标：
 *              VOTE_HEAL / VOTE_SI_WAVE / VOTE_SI_TIME
 *            原生投票与 SM 回落两条路径都跟着泛化（回落菜单的选项表也按目标切换）
 *          · 数量投票会同时把 cap 设成 2×wave，保持刷特插件「cap ≈ 2×wave」的设计；
 *            只改 wave 不改 cap 的话，投"6 只"而上限还是 8，玩家会觉得没生效
 *          · 刷特 cvar 归 ltt_si_spawner 所有，一律现场 FindConVar，不缓存句柄
 *          · 空服还原（ltt_svote_idlereset）原来只还原杀特回血，现在把
 *            每波数量 / 存活上限 / 刷新间隔 三项一起还原
 *
 *  v1.1.2: 解除对 Neko 的依赖（Neko 整套已从服务器卸载）
 *          · 菜单删掉「② 特感设置」（原来转发 sm_tgvote，NekoVote 没了 = 死按钮）
 *          · 开局播报原来读 Neko 的 Special_Num / Special_Spawn_Time /
 *            Special_Default_Mode，读不到就显示「特感=未知 0只/0秒」。
 *            改成读本服自己的 ltt_sispawn_enable/wave/time。
 *          · 刷特 cvar 由 ltt_si_spawner 插件创建，本插件不缓存其句柄
 *            （对方重载会让缓存句柄失效），改为播报时现场 FindConVar。
 *
 *  v1.1.1: 修 v1.1.0 的致命遗漏 —— 结算时必须调 vote.SetPass()/SetFail()。
 *          原生投票面板只认 VotePass/VoteFail 这条 usermessage 才会关闭，
 *          库里的 ResetVote()(复位 m_activeIssueIndex、解锁"投票进行中")
 *          也是挂在这两个 native 的 1 秒定时器上。不调 = 面板永久卡住，
 *          且 L4D2NativeVote_IsAllowNewVote() 恒为 false，连 Neko 投票也起不来。
 *          另加 sm_svoteclose 管理命令，用于强制关掉卡住的面板。
 *
 *  v1.1.0: 投票改用 L4D2 原生投票（L4D2NativeVote 封装，与 Neko 同一套）
 *          选档位(SM菜单) -> 原生 F1/F2 -> 按票数卡通过率
 *          通过率基准默认"在场生还者人数"（不投票视为反对）
 *          原生不可用时自动回落 SM 投票菜单
 *
 *  !set / !settings / !gvote / !vt / !v
 *    ① 杀特回血              -> 选档位 -> 原生投票
 *    ② 特感设置              -> 数量 / 刷新间隔 -> 选档位 -> 原生投票
 *    ③ 查看本局设置          -> 聊天框播报
 *
 *  v1.2.3 【旁观投票修复】服主 2026-09-24 实测「用旁观 !vt 投票出现了投票问题」。
 *         根因（与 ltt_si_menu v1.2.2 是同一个坑，那边已经修过并真人验证）：
 *           投票人名单只收 `GetClientTeam(i) == TEAM_SURVIVOR`，
 *           于是旁观者发起投票时 **他自己不在名单里**；如果场上生还者全是 bot
 *           （`!IsFakeClient` 又把他们排除了），名单就是空的 → `n == 0` →
 *           投票**根本发不出来**，只播一句「无法开始投票」，**一条日志都不留**。
 *         （2026-09-24 全天日志里 `[SVote]` 零条，正好印证"根本没开始"。）
 *
 *         修法（照抄 ltt_si_menu v1.2.2 已在真人局验证过的做法）：
 *           1. 投票人只算 **team 2(生还者) / team 3(感染者)**，旁观者必须排除。
 *              —— 旁观者会收下原生投票面板，但**引擎不把投票按键交给旁观者**，
 *                 那个投票就永远等不到结束 → **L4D2 引擎全局投票锁**一直挂着 →
 *                 之后连 `!chmap` 换图投票都发不出来，最后只能重启服务器。
 *                 参考实现（豆瓣酱 `l4d2_map_vote`）收人的条件也是 team 2 或 3。
 *           2. **发起人自己没有投票权（旁观）→ 直接生效**，不发起投票。
 *              他没有投票资格，起投票本来就没意义；这样服主旁观时菜单照样能用。
 *           3. 投票人数不足 `ltt_svote_minvoters` → 也直接生效。
 *           4. 上面每条分支都**必须打日志** —— 服主反馈「选了一档没反应」时，
 *              就是因为没有日志，只能靠翻别的日志间接推断，白绕一圈。
 *           5. 新增**投票锁看门狗** `ltt_svote_lockwatch`：本地没有投票在跑、
 *              而引擎锁连续挂住超过 `ltt_svote_locksecs` 秒（默认 30）时广播 VoteFail
 *              尽力顶掉（与 `sm_svoteclose` 同一手法）。已知局限：`l4d2_nativevote`
 *              没有任何"解锁/复位"原生，所以这只能算尽力而为；触发次数会记进日志，
 *              下次真出现死锁就能据此判断它管不管用。
 *
 *  作者: DeepSeek Harness
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <usermessages>

// 【编译环境说明 · 不是功能代码】
// 本插件依赖 `<multicolors>`，必须用 Multi-Colors 官方完整 include 目录编译：
//   -i "<SM 1.12.0.7253>\include"
//   -i "D:\#2\#2 jsmod\JS-MODS\Multi-Colors-master\addons\sourcemod\scripting\include"
//   -i "D:\#2\_工具\build\shim"          ← 只是为了 l4d2_nativevote.inc
// 【坑】不要用 `_工具\build\include` —— 那份 multicolors/colors.inc 是被裁剪过的
// （3714 字节），既没有 MAX_MESSAGE_LENGTH 也没有 C_ReplyToCommandEx 等函数，
// 会报 99 个 error。官方那份是 25956 字节、齐全。
#include <multicolors>
#include <l4d2_nativevote>

#define PLUGIN_VERSION   "1.2.11"
#define VOTE_OPTIONS     5
#define HP_MAX_OPTIONS   5
#define SI_WAVE_OPTIONS  5
#define SI_TIME_OPTIONS  5
#define DIFF_OPTIONS     4    // 简单/普通/困难/专家
#define MUL_OPTIONS      5    // 倍率档位：十分位 0/1/2/3/5 = 0.0/0.1/0.2/0.3/0.5
#define TEAM_SURVIVOR    2
#define TEAM_INFECTED    3

// 投票目标类型（用匿名枚举，常量即普通 int，避免与 int 参数混用时出现 tag 警告）
enum
{
	VOTE_HEAL = 0,     // 杀特回血数值
	VOTE_HP_MAX,       // 生还者血量上限
	VOTE_SI_WAVE,      // 特感每波数量
	VOTE_SI_TIME,      // 特感刷新间隔
	VOTE_DIFFICULTY,   // 【v1.2.6】游戏难度
	VOTE_FF,           // 【v1.2.6】友伤倍率（十分位）
	VOTE_FIRE          // 【v1.2.6】火伤倍率（十分位）
};

ConVar g_cEnable, g_cRatio, g_cCountBase, g_cDuration, g_cIdleReset, g_cIdleSeconds, g_cShowOnSpawn;
ConVar g_cHrValue, g_cMaxHpCvar, g_cSiMenu, g_cSiForward, g_cVoteLog, g_cExtra;
// 【v1.2.3】投票路径控制 + 投票锁看门狗
ConVar g_cVote, g_cMinVoters, g_cLockWatch, g_cLockSecs, g_cDbg;

static const int  g_iHealChoices[VOTE_OPTIONS]      = { 0, 5, 10, 15, 20 };
static const int  g_iHpMaxChoices[HP_MAX_OPTIONS]   = { 100, 200, 300, 500, 1000 };
static const int  g_iSiWaveChoices[SI_WAVE_OPTIONS] = { 2, 3, 4, 5, 6 };
static const int  g_iSiTimeChoices[SI_TIME_OPTIONS] = { 10, 20, 30, 40, 60 };

// 【v1.2.6】倍率档位（十分位）：0.0 / 0.1 / 0.2 / 0.3 / 0.5 —— 上限 0.5 是服主定的。
// 友伤与火伤共用同一张档位表。
static const int  g_iMulChoices[MUL_OPTIONS]        = { 0, 1, 2, 3, 5 };

// 难度：档位值就是下标；写 cvar 用 g_sDiffValue（引擎认的字符串），显示用 g_sDiffName。
static const char g_sDiffValue[DIFF_OPTIONS][12] = { "Easy", "Normal", "Hard", "Impossible" };
static const char g_sDiffName[DIFF_OPTIONS][12]  = { "简单", "普通", "困难", "专家" };

// 友伤/火伤：各难度一个 cvar（名字从服务器 server.cfg 抄的）
static const char g_sFfCvars[DIFF_OPTIONS][48] = {
	"survivor_friendly_fire_factor_easy",
	"survivor_friendly_fire_factor_normal",
	"survivor_friendly_fire_factor_hard",
	"survivor_friendly_fire_factor_expert"
};
static const char g_sFireCvars[DIFF_OPTIONS][48] = {
	"survivor_burn_factor_easy",
	"survivor_burn_factor_normal",
	"survivor_burn_factor_hard",
	"survivor_burn_factor_expert"
};

// 每个玩家当前打开的档位菜单属于哪个投票目标
int    g_iPickKind[MAXPLAYERS + 1];

bool   g_bVoteActive;
bool   g_bHasNative;
int    g_iPendingKind = -1;      // VoteKind
int    g_iPendingValue;
int    g_iHrDefault;
int    g_iHpDefault = -1;
char   g_sVoteLogFile[PLATFORM_MAX_PATH];   // 【v1.2.7】投票日志文件绝对路径
char   g_sVoterName[64];                   // 【v1.2.7】本次投票发起人（名字 + SteamID，写日志用）
char   g_sVoterAuth[40];
bool   g_bShownThisRound;
int    g_iIdleSince;

// 【v1.2.6】难度/友伤/火伤：默认值（第一次 OnConfigsExecuted 时从 cfg 捕获）+ 本次投过的值（-1=没投过）
int    g_iDiffDefault = -1, g_iFfDefault = -1, g_iFireDefault = -1;
int    g_iDiffVoted   = -1, g_iFfVoted   = -1, g_iFireVoted   = -1;
// 【v1.2.9】回血 / 血上限也要跨图重设。以前只有难度/友伤/火伤记了"投过"标记，
// 导致投完 +20 回血/1000 血上限，一换图就被各自的 cfg 冲回 5/100，玩家得重复投票。
int    g_iHrVoted = -1, g_iHpVoted = -1;
bool   g_bDefCaptured;

// 【v1.2.3】投票锁看门狗的状态
int    g_iLockSince;             // 引擎锁开始挂住的时间戳，0=没挂
int    g_iLockRecover;           // 看门狗累计强制解锁次数

// 回落路径
int    g_iVotes[MAXPLAYERS + 1];
int    g_iEligible, g_iVoted;
Menu   g_hMenu;
Handle g_hVoteTimer;

public Plugin myinfo =
{
	name        = "[LTT] Server Vote",
	author      = "DeepSeek Harness",
	description = "服务器玩法统一设置菜单 + 每关开局播报当前设置",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cEnable      = CreateConVar("ltt_svote_enable",      "1",   "1=开启统一设置菜单", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cRatio       = CreateConVar("ltt_svote_ratio",       "75",  "同意票需达到的百分比", FCVAR_NOTIFY, true, 1.0, true, 100.0);
	g_cCountBase   = CreateConVar("ltt_svote_countbase",   "0",   "通过率基准: 0=在场生还者人数(不投票视为反对) 1=实际投票人数", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cDuration    = CreateConVar("ltt_svote_duration",    "20",  "投票持续秒数", FCVAR_NOTIFY, true, 5.0, true, 120.0);
	g_cIdleReset   = CreateConVar("ltt_svote_idlereset",   "1",   "1=空服一段时间后还原本插件改过的设置", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cIdleSeconds = CreateConVar("ltt_svote_idleseconds", "300", "空服多少秒后还原", FCVAR_NOTIFY, true, 30.0, true, 7200.0);
	g_cShowOnSpawn = CreateConVar("ltt_svote_showonspawn", "1",   "1=每关开局在聊天框播报当前设置", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cSiMenu      = CreateConVar("ltt_svote_simenu",      "1",   "1=在设置菜单里显示「特感设置」入口（0=隐藏，只留杀特回血与血量上限）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cVoteLog     = CreateConVar("ltt_svote_log",        "1",   "1=把每次投票写进 logs/ltt_svote.log（发起人/类型/目标/结果/票数）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	// 【v1.2.7】服主 2026-09-27："难度、火伤、友伤暂时都不开放投票，先专注采集实验对照组数据"。
	// 做成开关而不是删代码：这三项是刚做好的功能，只是现在不能让人投票改（会污染 ABAB 的臂）。
	// 默认 0=不显示；想开放时把 ltt_svote_extra 设 1 即可，不用重新编译。
	g_cExtra       = CreateConVar("ltt_svote_extra",      "0",   "1=在菜单里开放「游戏难度/友伤倍率/火伤倍率」三项投票；0=暂时关闭（默认，避免污染实验）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cSiForward   = CreateConVar("ltt_svote_siforward",   "1",   "1=「特感设置」直接转到 !si 菜单（ltt_si_menu，6 项、自带投票）0=用本插件内置的数量+间隔投票", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 【v1.2.7】投票日志文件（绝对路径，省得依赖 LogToFile 的相对目录规则）
	BuildPath(Path_SM, g_sVoteLogFile, sizeof(g_sVoteLogFile), "logs/ltt_svote.log");

	// 【v1.2.3】旁观投票修复配套
	g_cVote        = CreateConVar("ltt_svote_vote",        "1",   "1=改动走原生投票 0=选了直接生效（调试用）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cMinVoters   = CreateConVar("ltt_svote_minvoters",   "1",   "有投票权的人数少于这个值就直接生效，不发起投票", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_cLockWatch   = CreateConVar("ltt_svote_lockwatch",   "1",   "1=开启投票锁看门狗（引擎投票锁挂住且本地无投票时自动广播 VoteFail 解锁）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cLockSecs    = CreateConVar("ltt_svote_locksecs",    "30",  "锁挂住多少秒才动手（要比任何合法投票都长）", FCVAR_NOTIFY, true, 10.0, true, 600.0);
	g_cDbg         = CreateConVar("ltt_svote_debug",       "1",   "1=把投票路径的关键决策写进日志（发起/直接生效/被拒的原因）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "ltt_svote");

	g_cHrValue   = FindConVar("l4d2_health_return_value");
	g_cMaxHpCvar = FindConVar("l4d2_survivor_health_max");
	// 注意：刷特相关 cvar 属于 ltt_si_spawner 插件，不在本插件里缓存句柄
	// （对方重载会让缓存的句柄变野指针），改成每次播报时现场 FindConVar。

	// l4d2_nativevote 库在不在：只认这个真正用到的 native
	g_bHasNative = (GetFeatureStatus(FeatureType_Native, "L4D2NativeVote_IsAllowNewVote") == FeatureStatus_Available);

	CreateTimer(3.0, Timer_Snapshot, _, TIMER_FLAG_NO_MAPCHANGE);

	RegConsoleCmd("sm_set",      Cmd_OpenMenu, "打开服务器设置菜单");
	RegConsoleCmd("sm_settings", Cmd_OpenMenu, "打开服务器设置菜单");
	RegConsoleCmd("sm_gvote",    Cmd_OpenMenu, "打开服务器设置菜单");
	RegConsoleCmd("sm_vt",       Cmd_OpenMenu, "打开服务器设置菜单");
	RegConsoleCmd("sm_v",        Cmd_OpenMenu, "打开服务器设置菜单");

	// 应急：投票面板卡住时用（控制台可直接执行 sm_svoteclose）
	RegAdminCmd("sm_svoteclose", Cmd_ForceCloseVote, ADMFLAG_GENERIC, "强制关掉卡住的投票面板");
	RegAdminCmd("sm_vtlog",       Cmd_VoteLog,        ADMFLAG_GENERIC, "查看最近的投票记录（输出到控制台，默认 15 条）");
	RegAdminCmd("sm_vtlogtest",   Cmd_VoteLogTest,    ADMFLAG_ROOT,    "往投票日志写一条自检记录（验证日志功能是否正常）");

	HookEvent("round_start",           Event_RoundStart,   EventHookMode_PostNoCopy);
	HookEvent("player_left_safe_area", Event_LeftSafeArea, EventHookMode_PostNoCopy);

	CreateTimer(30.0, Timer_IdleCheck, _, TIMER_REPEAT);

	// 【v1.2.3】投票锁看门狗：5 秒巡一次，够快也不会造成负担
	CreateTimer(5.0, Timer_VoteLockWatch, _, TIMER_REPEAT);

	LogMessage("[SVote] v%s 已加载 | 原生投票=%s | 回血cvar=%s | 基准=%s | 投票=%d 最少投票人=%d 看门狗=%d/%ds",
		PLUGIN_VERSION, g_bHasNative ? "可用" : "不可用(回落SM菜单)",
		g_cHrValue == null ? "无" : "有",
		g_cCountBase.IntValue == 0 ? "在场人数" : "投票人数",
		g_cVote.IntValue, g_cMinVoters.IntValue,
		g_cLockWatch.IntValue, g_cLockSecs.IntValue);
}

public Action Timer_Snapshot(Handle timer)
{
	g_iHrDefault = (g_cHrValue == null) ? -1 : g_cHrValue.IntValue;
	g_iHpDefault = (g_cMaxHpCvar == null) ? -1 : g_cMaxHpCvar.IntValue;

	// 【v1.2.2】不再给刷特三项做快照 —— 那三项已归 ltt_si_menu 独占管理
	LogMessage("[SVote] 启动快照: 杀特回血=%d 血上限=%d", g_iHrDefault, g_iHpDefault);
	return Plugin_Stop;
}

// ------------------------------------------------------------------ 应急：关掉卡住的投票面板

/** 【v1.2.3】把"广播 VoteFail 顶掉卡住的投票面板"抽成一个函数，
 *  给管理员命令 `sm_svoteclose` 和自动看门狗共用。
 *  已知局限：`l4d2_nativevote` 没有解锁原生，所以这是尽力而为。 */
void BroadcastVoteFail()
{
	BfWrite bf = UserMessageToBfWrite(StartMessageAll("VoteFail", USERMSG_RELIABLE));
	bf.WriteByte(-1);
	EndMessage();
}

public Action Cmd_ForceCloseVote(int client, int args)
{
	BroadcastVoteFail();

	g_bVoteActive = false;
	ReplyToCommand(client, "[服务器设置] 已广播 VoteFail，卡住的投票面板会关闭");
	LogMessage("[SVote] 管理员强制关闭投票面板 (admin=%d)", client);
	return Plugin_Handled;
}

// ------------------------------------------------------------------ 投票锁看门狗

/** 【v1.2.3 新增】投票锁看门狗。
 *
 *  病症（ltt_si_menu 2026-09-23 实测过同一个病）：本插件并没有投票在跑，但引擎的
 *  全局投票锁一直挂着（`L4D2NativeVote_IsAllowNewVote() == false`），
 *  之后连 `!chmap` 换图投票都发不出来，最后只能重启服务器。
 *
 *  真正的根治手段是 StartVote 里那条"投票人只算 team 2/3"的修复；
 *  这个看门狗是兜底，防的是"别的插件/别的路径又把锁挂住"。
 *
 *  保守设计，避免误杀正常投票：
 *    · 只在"本地没有投票在跑"时才计时；
 *    · 连续挂住超过 ltt_svote_locksecs 秒（默认 30，比任何合法投票都长）才动手；
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
			if (g_cDbg.BoolValue)
				LogMessage("[SVote] 投票锁看门狗：锁已自行恢复（曾挂住 %d 秒，未干预）", now - g_iLockSince);
			g_iLockSince = 0;
		}
		return Plugin_Continue;
	}

	if (g_iLockSince == 0)
	{
		g_iLockSince = now;
		if (g_cDbg.BoolValue)
			LogMessage("[SVote] 投票锁看门狗：IsAllowNewVote=0 且本地无投票，开始计时（%d 秒后强制解锁）",
				g_cLockSecs.IntValue);
		return Plugin_Continue;
	}

	if (now - g_iLockSince < g_cLockSecs.IntValue)
		return Plugin_Continue;

	int hung = now - g_iLockSince;
	g_iLockSince = 0;
	g_iLockRecover++;

	BroadcastVoteFail();

	LogMessage("[SVote] 投票锁看门狗：引擎投票锁被挂住 %d 秒且本地无投票 → 已广播 VoteFail 强制解锁（累计第 %d 次）",
		hung, g_iLockRecover);
	CPrintToChatAll("{olive}[服务器设置]{default} 检测到投票锁卡住 %d 秒，已自动解锁", hung);
	return Plugin_Continue;
}

// ------------------------------------------------------------------ 播报

void ShowSettings(bool toAll, int client = 0)
{
	// 现场查（不缓存），对方插件重载也不会拿到失效句柄
	ConVar cOn   = FindConVar("ltt_sispawn_enable");
	ConVar cWave = FindConVar("ltt_sispawn_wave");
	ConVar cTime = FindConVar("ltt_sispawn_time");
	ConVar cCap  = FindConVar("ltt_sispawn_cap");

	bool bOn   = (cOn   == null) ? false : cOn.BoolValue;
	int  iWave = (cWave == null) ? 0     : cWave.IntValue;
	int  iSecs = (cTime == null) ? 0     : RoundToNearest(cTime.FloatValue);
	int  iCap  = (cCap  == null) ? 0     : cCap.IntValue;

	// 【v1.2.4】生效值。`ltt_si_spawner` v1.18.2 起把"设的值 + 人数缩放"的结果
	// 发布成只读镜像 cvar；这里优先读镜像，拿不到（旧版 spawner）才退回设的值。
	// **不自己复制缩放公式** —— 那会变成第三份必然漂的实现。
	ConVar cEffW = FindConVar("ltt_sispawn_effwave");
	ConVar cEffC = FindConVar("ltt_sispawn_effcap");
	int  iEffW  = (cEffW == null || cEffW.IntValue <= 0) ? iWave : cEffW.IntValue;
	int  iEffC  = (cEffC == null || cEffC.IntValue <= 0) ? iCap  : cEffC.IntValue;

	char sSI[64];
	if (!bOn)
		strcopy(sSI, sizeof(sSI), "原版导演");
	else if (iWave <= 0 || iSecs <= 0)
		strcopy(sSI, sizeof(sSI), "未知");
	else if (iEffW != iWave)
		// 生效值和设的值不一样时【两个都报】—— 这正是玩家最容易困惑的地方
		Format(sSI, sizeof(sSI), "%d只(设%d)/%d秒 (上限%d)", iEffW, iWave, iSecs, iEffC);
	else if (iEffC > 0)
		Format(sSI, sizeof(sSI), "%d只/%d秒 (上限%d)", iWave, iSecs, iEffC);
	else
		Format(sSI, sizeof(sSI), "%d只/%d秒", iWave, iSecs);

	char sLine[288];

	// 【v1.2.6】把难度/友伤/火伤也报出来（服主要求「查看本局设置」能查这三项）。
	// 友伤/火伤读的是【当前难度那一档】—— 这才是场上实际生效的值。
	// 倍率显示成一位小数；读不到就写"未知"，不编数。
	char sFf[8], sFire[8];
	MulText(ReadMulTenths(false), sFf,   sizeof(sFf));
	MulText(ReadMulTenths(true),  sFire, sizeof(sFire));
	int  iDiff = CurrentDifficulty();

	Format(sLine, sizeof(sLine), "难度=%s ｜ 友伤倍率=%s ｜ 火伤倍率=%s ｜ 特感=%s ｜ 杀特回血=+%d ｜ 血上限=%d",
		g_sDiffName[iDiff], sFf, sFire,
		sSI,
		g_cHrValue   == null ? 0 : g_cHrValue.IntValue,
		g_cMaxHpCvar == null ? 0 : g_cMaxHpCvar.IntValue);

	if (toAll)
		CPrintToChatAll("{olive}[本局设置]{default} %s", sLine);
	else if (client > 0)
		CPrintToChat(client, "{olive}[本局设置]{default} %s", sLine);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bShownThisRound = false;
}

/** 【v1.2.6】cfg 执行完之后跑。
 *  两件事，顺序不能颠倒：
 *   ① 第一次进来时【捕获默认值】—— 必须是这里而不是 OnPluginStart，
 *      因为插件加载时 server.cfg 还没执行，那时读到的是引擎原始值。
 *   ② 把【投过的值】盖回去 —— server.cfg 每次换图都会重跑，里面把友伤/火伤
 *      四个难度档全设成 0（见 cfg 第 187~205 行），不盖回去玩家投的 0.3
 *      会在换图时被静默冲掉。难度同理：L4D2 每张图会按战役难度重设 z_difficulty。
 *  只为"投过票"的设置这么做；没投过就完全不干预，免得和 cfg 的日常值打架。 */
public void OnConfigsExecuted()
{
	if (!g_bDefCaptured)
	{
		g_bDefCaptured = true;
		g_iDiffDefault = CurrentDifficulty();
		g_iFfDefault   = ReadMulTenths(false);
		g_iFireDefault = ReadMulTenths(true);
		LogMessage("[SVote] 捕获默认值：难度=%s 友伤=%d.%d 火伤=%d.%d",
			g_sDiffName[g_iDiffDefault],
			g_iFfDefault / 10,   g_iFfDefault % 10,
			g_iFireDefault / 10, g_iFireDefault % 10);
	}

	if (g_iDiffVoted >= 0)
	{
		ConVar c = FindConVar("z_difficulty");
		if (c != null)
			c.SetString(g_sDiffValue[g_iDiffVoted]);
		LogMessage("[SVote] 换图/换 cfg 后重设难度 -> %s", g_sDiffValue[g_iDiffVoted]);
	}
	if (g_iFfVoted >= 0)
	{
		ApplyMul(false, g_iFfVoted);
		LogMessage("[SVote] 换图/换 cfg 后重设友伤倍率 -> %d.%d", g_iFfVoted / 10, g_iFfVoted % 10);
	}
	if (g_iFireVoted >= 0)
	{
		ApplyMul(true, g_iFireVoted);
		LogMessage("[SVote] 换图/换 cfg 后重设火伤倍率 -> %d.%d", g_iFireVoted / 10, g_iFireVoted % 10);
	}

	// 【v1.2.9】回血 / 血上限：同样在 cfg 之后盖回去（服主实测换图后会掉回 +5/100）
	if (g_iHrVoted >= 0 && g_cHrValue != null && g_cHrValue.IntValue != g_iHrVoted)
	{
		g_cHrValue.SetInt(g_iHrVoted);
		LogMessage("[SVote] 换图/换 cfg 后重设杀特回血 -> +%d", g_iHrVoted);
	}
	if (g_iHpVoted >= 0 && g_cMaxHpCvar != null && g_cMaxHpCvar.IntValue != g_iHpVoted)
	{
		g_cMaxHpCvar.SetInt(g_iHpVoted);
		LogMessage("[SVote] 换图/换 cfg 后重设血上限 -> %d", g_iHpVoted);
	}
}

public void Event_LeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cShowOnSpawn.BoolValue || g_bShownThisRound)
		return;
	g_bShownThisRound = true;
	ShowSettings(true);
}

// ------------------------------------------------------------------ 主菜单

public Action Cmd_OpenMenu(int client, int args)
{
	if (!g_cEnable.BoolValue)
	{
		ReplyToCommand(client, "[服务器设置] 已关闭");
		return Plugin_Handled;
	}
	if (client == 0)
	{
		ReplyToCommand(client, "[服务器设置] 请在游戏内使用");
		return Plugin_Handled;
	}
	if (g_bVoteActive)
	{
		ReplyToCommand(client, "[服务器设置] 已有一个投票在进行");
		return Plugin_Handled;
	}

	Menu menu = new Menu(MenuHandler_Main);
	menu.SetTitle("服务器设置\n ");

	// 不用前导圈码：菜单里本来就会显示按哪个数字键选
	menu.AddItem("heal", "杀特回血数值");

	if (g_cMaxHpCvar != null)
		menu.AddItem("hpmax", "血量上限");

	if (g_cSiMenu.BoolValue)
	{
		// 【v1.2.5】标签跟着转发开关走，别让玩家看到一个和实际不符的入口名
		// 【v1.2.11】标签补全：v1.2.18 加了「救援关不刷特」、v1.2.19 加了「距离偏好」，
		//   标签不跟着更新就又是一处"名字与实际不符"。
		if (g_cSiForward.BoolValue)
			menu.AddItem("si", "特感设置（数量/间隔/上限/距离/挡位/人数缩放/救援关/距离偏好）");
		else
			menu.AddItem("si", "特感设置（数量 / 刷新间隔）");
	}

	menu.AddItem("show", "查看本局设置");

	// 【v1.2.6】三项新投票。顺序按服主要的：难度 -> 友伤 -> 火伤。
	// 【v1.2.7】服主 2026-09-27："难度、火伤、友伤暂时都不开放投票，先专注采集实验对照组数据"
	// ⇒ 用 `ltt_svote_extra` 关掉（默认 0）。**不删代码**：功能已做好，只是现在不能让人投票改
	//   （一改难度/友伤/火伤，ABAB 的两组臂就不是同一个条件了）。想开放时把该 cvar 设 1。
	if (g_cExtra.BoolValue)
	{
		menu.AddItem("diff", "游戏难度");
		menu.AddItem("ff",   "友伤倍率（上限 0.5）");
		menu.AddItem("fire", "火伤倍率（上限 0.5）");
	}

	// 【v1.2.6】主菜单从 4 项涨到 7 项 ⇒ 必须显式放开每页上限。
	// 依据：ltt_si_menu 的 7 项页也是这么写的（`menu.Pagination = 8`，
	// SM 内部会夹到它允许的最大值 7）。不写的话第 7 项可能被挤到第二页，
	// 玩家会以为"没有这一项"。
	menu.Pagination = 7;

	menu.ExitButton = true;
	menu.Display(client, 30);
	return Plugin_Handled;
}

public int MenuHandler_Main(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char sInfo[16];
		menu.GetItem(item, sInfo, sizeof(sInfo));
		if (StrEqual(sInfo, "heal"))
			ShowPickMenu(client, VOTE_HEAL);
		else if (StrEqual(sInfo, "hpmax"))
			ShowPickMenu(client, VOTE_HP_MAX);
		else if (StrEqual(sInfo, "si"))
		{
			// 【v1.2.5】转发到 ltt_si_menu 的 !si 菜单。
			// 为什么转发而不是把 6 项都抄进来：抄进来就是"第三份必然漂的实现"
			// （档位表、权限、投票路径都要抄），而 !si 那边已经成熟且对所有人开放。
			// ⚠ 这条路径我没法在 0 人时自测（菜单要真人客户端），
			//   若转发无效，把 ltt_svote_siforward 设 0 即回到内置子菜单。
			if (g_cSiForward.BoolValue)
				FakeClientCommandEx(client, "sm_si");
			else
				ShowSIMenu(client);
		}
		else if (StrEqual(sInfo, "show"))
			ShowSettings(false, client);
		// 【v1.2.6】三项新投票（【v1.2.7】由 ltt_svote_extra 控制是否开放；默认关闭）
		else if (g_cExtra.BoolValue && StrEqual(sInfo, "diff"))
			ShowPickMenu(client, VOTE_DIFFICULTY);
		else if (g_cExtra.BoolValue && StrEqual(sInfo, "ff"))
			ShowPickMenu(client, VOTE_FF);
		else if (g_cExtra.BoolValue && StrEqual(sInfo, "fire"))
			ShowPickMenu(client, VOTE_FIRE);
	}
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

// ------------------------------------------------------------------ 选档位

// ------------------------------------------------------------------ 通用档位菜单

/** 四个投票目标共用同一个档位菜单（杀特回血 / 血量上限 / 特感数量 / 特感间隔） */
void ShowPickMenu(int client, int kind)
{
	int iCur = GetCurrentValue(kind);
	if (iCur < 0)
	{
		CPrintToChat(client, "{olive}[服务器设置]{default} 读不到当前值（对应 cvar 不存在？）");
		return;
	}

	g_iPickKind[client] = kind;

	char sTitle[160];
	GetPickTitle(kind, iCur, sTitle, sizeof(sTitle));

	Menu menu = new Menu(MenuHandler_ValuePick);
	menu.SetTitle(sTitle);

	char sVal[8], sLabel[64];
	int  iCount = GetChoiceCount(kind);
	for (int i = 0; i < iCount; i++)
	{
		int v = GetChoiceValue(kind, i);
		Format(sVal, sizeof(sVal), "%d", v);
		GetChoiceLabel(kind, v, v == iCur, sLabel, sizeof(sLabel));
		menu.AddItem(sVal, sLabel);
	}

	menu.ExitBackButton = true;
	menu.Display(client, 30);
}

void GetPickTitle(int kind, int iCur, char[] buf, int maxlen)
{
	switch (kind)
	{
		case VOTE_HP_MAX:
			Format(buf, maxlen, "生还者血量上限设为多少？\n当前: %d\n选完进入投票\n ", iCur);
		case VOTE_SI_WAVE:
			Format(buf, maxlen, "每波特感刷几只？\n当前: %d 只（存活上限 %d）\n选完进入投票\n ", iCur, iCur * 2);
		case VOTE_SI_TIME:
			Format(buf, maxlen, "特感刷新间隔设为多少秒？\n当前: %d 秒\n选完进入投票\n ", iCur);
		case VOTE_DIFFICULTY:
			Format(buf, maxlen, "游戏难度设为？\n当前: %s\n选完进入投票\n ",
				(iCur >= 0 && iCur < DIFF_OPTIONS) ? g_sDiffName[iCur] : "?");
		case VOTE_FF:
		{
			char s[8]; MulText(iCur, s, sizeof(s));
			Format(buf, maxlen, "友伤倍率设为？\n当前: %s（上限 0.5，四个难度档一起改）\n选完进入投票\n ", s);
		}
		case VOTE_FIRE:
		{
			char s[8]; MulText(iCur, s, sizeof(s));
			Format(buf, maxlen, "火伤倍率设为？\n当前: %s（上限 0.5，四个难度档一起改）\n选完进入投票\n ", s);
		}
		default:
			Format(buf, maxlen, "杀特回血设为多少？\n当前: +%d\n选完进入投票\n ", iCur);
	}
}

void GetChoiceLabel(int kind, int v, bool bCurrent, char[] buf, int maxlen)
{
	switch (kind)
	{
		case VOTE_SI_WAVE:
			Format(buf, maxlen, "%d 只（上限 %d）%s", v, v * 2, bCurrent ? "  ← 当前" : "");
		case VOTE_SI_TIME:
			Format(buf, maxlen, "%d 秒%s", v, bCurrent ? "  ← 当前" : "");
		case VOTE_HP_MAX:
			Format(buf, maxlen, "%d 点%s", v, bCurrent ? "  ← 当前" : "");
		case VOTE_DIFFICULTY:
			Format(buf, maxlen, "%s%s",
				(v >= 0 && v < DIFF_OPTIONS) ? g_sDiffName[v] : "?", bCurrent ? "  ← 当前" : "");
		case VOTE_FF:
		{
			// 【踩坑记录】SourcePawn **不支持** C 那种"两个 case 标签叠在一起"
			// （`case A: case B: ...`）—— 会报 error 014 invalid statement; not in switch。
			// 所以这里两个 case 各写一份 body。别为了省几行又叠回去。
			char sFf[8]; MulText(v, sFf, sizeof(sFf));
			Format(buf, maxlen, "%s 倍%s", sFf, bCurrent ? "  ← 当前" : "");
		}
		case VOTE_FIRE:
		{
			char sFire[8]; MulText(v, sFire, sizeof(sFire));
			Format(buf, maxlen, "%s 倍%s", sFire, bCurrent ? "  ← 当前" : "");
		}
		default:
			Format(buf, maxlen, "+%d 点%s", v, bCurrent ? "  ← 当前" : "");
	}
}

public int MenuHandler_ValuePick(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char sVal[8];
		menu.GetItem(item, sVal, sizeof(sVal));
		StartVote(client, g_iPickKind[client], StringToInt(sVal));
	}
	else if (action == MenuAction_Cancel)
	{
		if (item == MenuCancel_ExitBack)
		{
			int kind = g_iPickKind[client];
			if (kind == VOTE_SI_WAVE || kind == VOTE_SI_TIME)
				ShowSIMenu(client);        // 特感的两项回上一级
			else
				Cmd_OpenMenu(client, 0);   // 其它回主菜单
		}
	}
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

// ------------------------------------------------------------------ 特感设置子菜单

void ShowSIMenu(int client)
{
	ConVar cw = FindConVar("ltt_sispawn_wave");
	ConVar ct = FindConVar("ltt_sispawn_time");
	ConVar cc = FindConVar("ltt_sispawn_cap");

	if (cw == null || ct == null)
	{
		CPrintToChat(client, "{olive}[服务器设置]{default} 找不到刷特插件的 cvar（ltt_si_spawner 是否在运行？）");
		return;
	}

	// 【v1.2.5 修「口径对不上」—— 服主 2026-09-27 报的那个 bug】
	// 原来这里写的是 `cw.IntValue`，即【设的值】。5 人时 spawner 每波实际刷 6 只
	// （4 + 人数缩放 2），而本标题还写"每波 4 只" ⇒ 玩家以为设置没生效。
	// ⇒ 取数一律走镜像 cvar `ltt_sispawn_effwave/effcap`（spawner v1.18.2+ 每 0.1 秒维护），
	//   并且**两个值都显示**，让玩家直接看出缩放加了多少。
	//   ⚠ 不在这里自己算缩放公式 —— 同一份文件 L303 那条注释已经骂过这件事。
	int  iWave = cw.IntValue;
	int  iCap  = (cc == null) ? 0 : cc.IntValue;
	ConVar cEffW = FindConVar("ltt_sispawn_effwave");
	ConVar cEffC = FindConVar("ltt_sispawn_effcap");
	int  iEffW  = (cEffW == null || cEffW.IntValue <= 0) ? iWave : cEffW.IntValue;
	int  iEffC  = (cEffC == null || cEffC.IntValue <= 0) ? iCap  : cEffC.IntValue;

	char sTitle[192];
	if (iEffW != iWave || iEffC != iCap)
		Format(sTitle, sizeof(sTitle),
			"特感设置\n当前生效: 每波 %d 只（设 %d） / 间隔 %d 秒 / 上限 %d（设 %d）\n ",
			iEffW, iWave, RoundToNearest(ct.FloatValue), iEffC, iCap);
	else
		Format(sTitle, sizeof(sTitle),
			"特感设置\n当前: 每波 %d 只 / 间隔 %d 秒 / 上限 %d\n ",
			iWave, RoundToNearest(ct.FloatValue), iCap);

	Menu menu = new Menu(MenuHandler_SIMenu);
	menu.SetTitle("%s", sTitle);
	menu.AddItem("wave", "每波特感数量");
	menu.AddItem("time", "特感刷新间隔");
	menu.ExitBackButton = true;
	menu.Display(client, 30);
}

public int MenuHandler_SIMenu(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char sInfo[16];
		menu.GetItem(item, sInfo, sizeof(sInfo));
		if (StrEqual(sInfo, "wave"))
			ShowPickMenu(client, VOTE_SI_WAVE);
		else if (StrEqual(sInfo, "time"))
			ShowPickMenu(client, VOTE_SI_TIME);
	}
	else if (action == MenuAction_Cancel)
	{
		if (item == MenuCancel_ExitBack)
			Cmd_OpenMenu(client, 0);
	}
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

// 特感的两项档位菜单复用上面的通用 ShowPickMenu / MenuHandler_ValuePick，
// 通过 g_iPickKind[client] 区分目标，不再各写一套 handler。

// ------------------------------------------------------------------ 投票目标辅助

// ------------------------------------------------------------------ 【v1.2.6】难度 / 友伤 / 火伤 的取值与写入

/** 当前难度下标（对不上就按"普通"算）。z_difficulty 的合法值是 Easy/Normal/Hard/Impossible */
int CurrentDifficulty()
{
	ConVar c = FindConVar("z_difficulty");
	if (c == null)
		return 1;

	char s[32];
	c.GetString(s, sizeof(s));
	for (int i = 0; i < DIFF_OPTIONS; i++)
		if (StrEqual(s, g_sDiffValue[i], false))
			return i;

	// 引擎/别的插件可能写成小写或中文；对不上时**不猜**，回退到"普通"并在日志里留痕
	LogMessage("[SVote] z_difficulty = \"%s\" 不在已知档位里，按\"普通\"处理", s);
	return 1;
}

/** 取某个倍率的 cvar 名：bFire=false 友伤 / true 火伤；diff=难度下标 */
void MulCvarName(bool bFire, int diff, char[] out, int maxlen)
{
	if (diff < 0 || diff >= DIFF_OPTIONS)
		diff = 1;
	if (bFire)
		strcopy(out, maxlen, g_sFireCvars[diff]);
	else
		strcopy(out, maxlen, g_sFfCvars[diff]);
}

/** 读【当前难度那一档】的倍率，返回十分位整数；读不到返回 -1 */
int ReadMulTenths(bool bFire)
{
	char sName[48];
	MulCvarName(bFire, CurrentDifficulty(), sName, sizeof(sName));

	ConVar c = FindConVar(sName);
	if (c == null)
		return -1;

	return RoundToNearest(c.FloatValue * 10.0);
}

/** 四个难度档【一起】设成同一个倍率，这样换难度也不会变。
 *  为什么必须四档一起：玩家投的是"一个倍率"，如果只设当前难度那一档，
 *  下一张图难度一变（或别人改难度）这个设置就"失效"了，玩家会以为没生效。 */
void ApplyMul(bool bFire, int tenths)
{
	char sName[48];
	for (int d = 0; d < DIFF_OPTIONS; d++)
	{
		MulCvarName(bFire, d, sName, sizeof(sName));
		ConVar c = FindConVar(sName);
		if (c != null)
			c.SetFloat(float(tenths) / 10.0);
	}
}

/** 倍率的显示文本："0.3"（十分位整数 -> 一位小数） */
void MulText(int tenths, char[] buf, int maxlen)
{
	if (tenths < 0)
		strcopy(buf, maxlen, "未知");
	else
		Format(buf, maxlen, "%d.%d", tenths / 10, tenths % 10);
}

// ------------------------------------------------------------------ 【v1.2.7】投票日志

/** 投票类型的短名（写日志用；比 GetKindText 那种"把X设为Y"更适合一行日志） */
void KindLogName(int kind, char[] buf, int maxlen)
{
	switch (kind)
	{
		case VOTE_HEAL:       strcopy(buf, maxlen, "杀特回血");
		case VOTE_HP_MAX:     strcopy(buf, maxlen, "血量上限");
		case VOTE_SI_WAVE:    strcopy(buf, maxlen, "特感每波数量");
		case VOTE_SI_TIME:    strcopy(buf, maxlen, "特感刷新间隔");
		case VOTE_DIFFICULTY: strcopy(buf, maxlen, "游戏难度");
		case VOTE_FF:         strcopy(buf, maxlen, "友伤倍率");
		case VOTE_FIRE:       strcopy(buf, maxlen, "火伤倍率");
		default:              strcopy(buf, maxlen, "未知");
	}
}

/** 值 → 日志里好读的短文本：难度给"专家(3)"、倍率给"0.3"、其它给整数 */
void KindValueText(int kind, int value, char[] buf, int maxlen)
{
	switch (kind)
	{
		case VOTE_DIFFICULTY:
			Format(buf, maxlen, "%s(%d)",
				(value >= 0 && value < DIFF_OPTIONS) ? g_sDiffName[value] : "?", value);
		case VOTE_FF:
		{
			char s[8]; MulText(value, s, sizeof(s));
			strcopy(buf, maxlen, s);
		}
		case VOTE_FIRE:
		{
			char s[8]; MulText(value, s, sizeof(s));
			strcopy(buf, maxlen, s);
		}
		default:
			Format(buf, maxlen, "%d", value);
	}
}

/** 【v1.2.7】写一行投票日志。用 LogToFile ⇒ 自带 `L 日期 - 时间: [ltt_svote.smx]` 前缀。
 *  独立文件而不是只写 SM 主日志：主日志一天几千行、和刷特/性能混在一起，
 *  事后查"谁在什么时候把难度改成专家"要翻很久。这里一行一次投票，grep 就行。 */
void VoteLog(const char[] fmt, any ...)
{
	if (g_cVoteLog == null || !g_cVoteLog.BoolValue)
		return;

	char sMsg[320];
	VFormat(sMsg, sizeof(sMsg), fmt, 2);
	LogToFile(g_sVoteLogFile, "%s", sMsg);
}

int GetChoiceCount(int kind)
{
	switch (kind)
	{
		case VOTE_HP_MAX:     return HP_MAX_OPTIONS;
		case VOTE_SI_WAVE:    return SI_WAVE_OPTIONS;
		case VOTE_SI_TIME:    return SI_TIME_OPTIONS;
		case VOTE_DIFFICULTY: return DIFF_OPTIONS;
		case VOTE_FF:         return MUL_OPTIONS;
		case VOTE_FIRE:       return MUL_OPTIONS;
	}
	return VOTE_OPTIONS;
}

int GetChoiceValue(int kind, int idx)
{
	if (idx < 0)
		return -1;

	switch (kind)
	{
		case VOTE_HP_MAX:
			return (idx < HP_MAX_OPTIONS) ? g_iHpMaxChoices[idx] : -1;
		case VOTE_SI_WAVE:
			return (idx < SI_WAVE_OPTIONS) ? g_iSiWaveChoices[idx] : -1;
		case VOTE_SI_TIME:
			return (idx < SI_TIME_OPTIONS) ? g_iSiTimeChoices[idx] : -1;
		case VOTE_DIFFICULTY:
			// 难度的"值"就是档位下标，写 cvar 时再映射成字符串
			return (idx < DIFF_OPTIONS) ? idx : -1;
		case VOTE_FF:
			return (idx < MUL_OPTIONS) ? g_iMulChoices[idx] : -1;
		case VOTE_FIRE:
			return (idx < MUL_OPTIONS) ? g_iMulChoices[idx] : -1;
	}
	return (idx < VOTE_OPTIONS) ? g_iHealChoices[idx] : -1;
}

/** 当前值。刷特的两个 cvar 归 ltt_si_spawner 所有，现场 FindConVar，不缓存句柄 */
int GetCurrentValue(int kind)
{
	switch (kind)
	{
		case VOTE_HP_MAX:
			return (g_cMaxHpCvar == null) ? -1 : g_cMaxHpCvar.IntValue;
		case VOTE_SI_WAVE:
		{
			ConVar c = FindConVar("ltt_sispawn_wave");
			return (c == null) ? -1 : c.IntValue;
		}
		case VOTE_SI_TIME:
		{
			ConVar c = FindConVar("ltt_sispawn_time");
			return (c == null) ? -1 : RoundToNearest(c.FloatValue);
		}
		case VOTE_DIFFICULTY:
			return CurrentDifficulty();
		case VOTE_FF:
			return ReadMulTenths(false);
		case VOTE_FIRE:
			return ReadMulTenths(true);
	}
	return (g_cHrValue == null) ? -1 : g_cHrValue.IntValue;
}

/** 把投票结果写进 cvar。注意这里也会同步 cap，保持 cap = 2×wave 的设计 */
void ApplyVote(int kind, int value)
{
	switch (kind)
	{
		case VOTE_HP_MAX:
		{
			if (g_cMaxHpCvar != null)
				g_cMaxHpCvar.SetInt(value);
			g_iHpVoted = value;          // 【v1.2.9】记下来：换图后要重设
			LogMessage("[SVote] 生还者血量上限 -> %d", value);
		}
		case VOTE_SI_WAVE:
		{
			// 【v1.2.10 · 写入权整改】刷特设置（数量/上限/间隔/距离/挡位）的权威是 ltt_si_menu 的存档。
			// 装了菜单插件时这条直投路径不该再写 cvar —— 写了也会在下次开图被菜单存档盖回，
			// 玩家看到"投了没生效"。此时只在日志留痕，提示走菜单投票。
			if (g_cSiMenu.BoolValue && FindPluginByFile("ltt_si_menu.smx") != INVALID_HANDLE)
			{
				LogMessage("[SVote] 特感数量投票被忽略：刷特设置归 ltt_si_menu 管（避免两边互相覆盖）");
				return;   // SourcePawn 的 switch 不穿透，用 return 直接结束本次施加
			}
			ConVar cw = FindConVar("ltt_sispawn_wave");
			ConVar cc = FindConVar("ltt_sispawn_cap");
			if (cw != null)
				cw.SetInt(value);
			// 只改 wave 不改 cap 的话，投"6 只"而上限还是 8，实际最多只出 8 只，玩家会觉得没生效
			if (cc != null)
				cc.SetInt(value * 2);
			LogMessage("[SVote] 特感数量 -> 每波 %d 只 / 存活上限 %d", value, value * 2);
		}
		case VOTE_SI_TIME:
		{
			// 【v1.2.10】同上：刷新间隔也归 ltt_si_menu 管
			if (g_cSiMenu.BoolValue && FindPluginByFile("ltt_si_menu.smx") != INVALID_HANDLE)
			{
				LogMessage("[SVote] 特感间隔投票被忽略：刷特设置归 ltt_si_menu 管（避免两边互相覆盖）");
				return;
			}
			ConVar ct = FindConVar("ltt_sispawn_time");
			if (ct != null)
				ct.SetFloat(float(value));
			LogMessage("[SVote] 特感刷新间隔 -> %d 秒", value);
		}
		case VOTE_DIFFICULTY:
		{
			if (value < 0 || value >= DIFF_OPTIONS)
				return;
			ConVar c = FindConVar("z_difficulty");
			if (c != null)
				c.SetString(g_sDiffValue[value]);
			g_iDiffVoted = value;      // 记下来：换图后要重设（server.cfg / 导演会冲掉）
			LogMessage("[SVote] 游戏难度 -> %s", g_sDiffValue[value]);
		}
		case VOTE_FF:
		{
			ApplyMul(false, value);     // 四个难度档一起设
			g_iFfVoted = value;
			LogMessage("[SVote] 友伤倍率 -> %d.%d（四个难度档一起设）", value / 10, value % 10);
		}
		case VOTE_FIRE:
		{
			ApplyMul(true, value);
			g_iFireVoted = value;
			LogMessage("[SVote] 火伤倍率 -> %d.%d（四个难度档一起设）", value / 10, value % 10);
		}
		default:
		{
			if (g_cHrValue != null)
				g_cHrValue.SetInt(value);
			g_iHrVoted = value;          // 【v1.2.9】记下来：换图后要重设
			LogMessage("[SVote] 杀特回血 -> +%d", value);
		}
	}
}

void GetKindText(int kind, int value, char[] buf, int maxlen)
{
	switch (kind)
	{
		case VOTE_HP_MAX:  Format(buf, maxlen, "把生还者血量上限设为 %d", value);
		case VOTE_SI_WAVE: Format(buf, maxlen, "把每波特感数量设为 %d 只（存活上限 %d）", value, value * 2);
		case VOTE_SI_TIME: Format(buf, maxlen, "把特感刷新间隔设为 %d 秒", value);
		case VOTE_DIFFICULTY:
			Format(buf, maxlen, "把游戏难度设为 %s",
				(value >= 0 && value < DIFF_OPTIONS) ? g_sDiffName[value] : "?");
		case VOTE_FF:
		{
			char s[8]; MulText(value, s, sizeof(s));
			Format(buf, maxlen, "把友伤倍率设为 %s（四个难度档一起）", s);
		}
		case VOTE_FIRE:
		{
			char s[8]; MulText(value, s, sizeof(s));
			Format(buf, maxlen, "把火伤倍率设为 %s（四个难度档一起）", s);
		}
		default:           Format(buf, maxlen, "把杀特回血设为 +%d", value);
	}
}

// ------------------------------------------------------------------ 投票

void StartVote(int client, int kind, int value)
{
	int iOld = GetCurrentValue(kind);
	if (iOld < 0)
	{
		CPrintToChat(client, "{olive}[服务器设置]{default} 读不到当前值，无法发起投票");
		return;
	}

	char sText[96], sTitle[128];
	GetKindText(kind, value, sText, sizeof(sText));

	// 【v1.2.7】记下发起人（名字 + SteamID）——投票结束时也要写进日志，
	// 而那时 client 可能已经退服，所以在这里先存下来。
	g_sVoterName[0] = '\0';
	g_sVoterAuth[0] = '\0';
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		GetClientName(client, g_sVoterName, sizeof(g_sVoterName));
		if (!GetClientAuthId(client, AuthId_Steam2, g_sVoterAuth, sizeof(g_sVoterAuth)))
			strcopy(g_sVoterAuth, sizeof(g_sVoterAuth), "未知");
	}
	else
	{
		strcopy(g_sVoterName, sizeof(g_sVoterName), "控制台");
		strcopy(g_sVoterAuth, sizeof(g_sVoterAuth), "-");
	}

	g_iPendingKind  = kind;
	g_iPendingValue = value;

	int iDuration = g_cDuration.IntValue;

	// ---- 【v1.2.3 旁观投票修复】先决定"谁有投票权" ----
	//
	// v1.2.2 及以前只收 `GetClientTeam(i) == TEAM_SURVIVOR`，两个后果：
	//   · 旁观者发起投票时他自己不在名单里 → 他收不到面板、也投不了自己的票；
	//   · 场上生还者全是 bot 时（`!IsFakeClient` 把他们排除了）名单为空 →
	//     投票根本发不出来，只播一句「无法开始投票」，而且**一条日志都不留**。
	//
	// 现在照 ltt_si_menu v1.2.2 的做法：投票人只算 team 2/3（旁观必须排除，
	// 否则引擎不把投票按键交给旁观者 → 投票永远不结束 → 全服投票锁死），
	// 发起人自己没有投票权时走"直接生效"。
	int iClients[MAXPLAYERS + 1];
	int n     = 0;
	int nSpec = 0;                 // 旁观/未选择的人数，只用于日志排查
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		int team = GetClientTeam(i);
		if (team == TEAM_SURVIVOR || team == TEAM_INFECTED)
			iClients[n++] = i;
		else
			nSpec++;               // team 1 = 旁观/未选择 → 不给投票权
	}

	bool byIsVoter = false;
	for (int i = 0; i < n; i++)
	{
		if (iClients[i] == client)
		{
			byIsVoter = true;
			break;
		}
	}

	// 不需要投票的情形：关掉了 / 原生不可用 / 有投票权的人太少 / 【发起人自己没有投票权】
	// 【重要】这条分支必须打日志 —— 服主反馈"选了一档没反应"时，
	// 就是因为这里没日志，只能靠翻别的日志间接推断，白白绕了一圈。
	if (!g_cVote.BoolValue || !g_bHasNative || n < g_cMinVoters.IntValue || !byIsVoter)
	{
		if (g_cDbg.BoolValue)
			LogMessage("[SVote] 直接生效（没走投票）：走投票=%d 原生可用=%d 投票人=%d 旁观=%d 发起人有投票权=%d 门槛=%d kind=%d %d->%d",
				g_cVote.IntValue, g_bHasNative ? 1 : 0, n, nSpec,
				byIsVoter ? 1 : 0, g_cMinVoters.IntValue, kind, iOld, value);

		ApplyVote(kind, value);

		// 【v1.2.7】投票日志：直接生效也要记（这是"没人投票就改了设置"的唯一痕迹）
		{
			char sKind[24], sOld[24], sNew[24], sWhy[32];
			KindLogName(kind, sKind, sizeof(sKind));
			KindValueText(kind, iOld, sOld, sizeof(sOld));
			KindValueText(kind, GetCurrentValue(kind), sNew, sizeof(sNew));
			if (!g_cVote.BoolValue)         strcopy(sWhy, sizeof(sWhy), "投票功能已关");
			else if (!g_bHasNative)         strcopy(sWhy, sizeof(sWhy), "原生投票不可用");
			else if (!byIsVoter)            strcopy(sWhy, sizeof(sWhy), "发起人是旁观");
			else                            strcopy(sWhy, sizeof(sWhy), "在场投票人不足");
			VoteLog("[直接生效] 发起=%s(%s) 类型=%s 原值=%s -> 新值=%s 原因=%s(投票人%d/门槛%d)",
				g_sVoterName, g_sVoterAuth, sKind, sOld, sNew, sWhy, n, g_cMinVoters.IntValue);
		}

		if (g_cVote.BoolValue && !byIsVoter && client > 0)
			CPrintToChat(client, "{olive}[服务器设置]{default} 你在旁观（没有投票权），本次直接生效：%s", sText);
		else if (g_cVote.BoolValue && !g_bHasNative)
			CPrintToChatAll("{olive}[服务器设置]{default} 原生投票不可用，本次直接生效：%s", sText);
		else if (g_cVote.BoolValue && n < g_cMinVoters.IntValue)
			CPrintToChatAll("{olive}[服务器设置]{default} 在场投票人只有 %d 人（需 %d 人才投票），本次直接生效：%s",
				n, g_cMinVoters.IntValue, sText);
		else
			CPrintToChatAll("{olive}[服务器设置]{default} %s（%d → %d）", sText, iOld, value);

		g_iPendingKind = -1;
		return;
	}

	if (g_bHasNative)
	{
		if (g_bVoteActive || !L4D2NativeVote_IsAllowNewVote())
		{
			CPrintToChat(client, "{olive}[服务器设置]{default} 当前已有别的投票在进行，请稍后再试");
			if (g_cDbg.BoolValue)
				LogMessage("[SVote] 投票被拒：本地进行中=%d IsAllowNewVote=%d",
					g_bVoteActive ? 1 : 0, L4D2NativeVote_IsAllowNewVote() ? 1 : 0);
			g_iPendingKind = -1;
			return;
		}

		L4D2NativeVote vote = L4D2NativeVote(Handler_NativeVote);
		vote.Initiator = client;
		vote.SetDisplayText("%s ?[当前 %d]", sText, iOld);

		if (!vote.DisplayVote(iClients, n, iDuration))
		{
			CPrintToChatAll("{olive}[服务器设置]{default} 投票发起失败，请稍后再试");
			if (g_cDbg.BoolValue)
				LogMessage("[SVote] DisplayVote 返回 false（投票人=%d 时长=%d）", n, iDuration);
			g_iPendingKind = -1;
			return;
		}

		g_bVoteActive = true;

		char sWho[MAX_NAME_LENGTH];
		GetClientName(client, sWho, sizeof(sWho));
		CPrintToChatAll("{olive}[服务器设置]{default} {green}%s{default} 提议%s（当前 %d），%d 秒内 {green}F1 同意{default} / {green}F2 反对{default}",
			sWho, sText, iOld, iDuration);

		if (g_cDbg.BoolValue)
			LogMessage("[SVote] 已发起投票：%s kind=%d %d->%d（投票人 %d 人，旁观 %d 人不计）",
				sWho, kind, iOld, value, n, nSpec);

		// 【v1.2.7】投票日志：发起
		{
			char sKind[24], sOld[24], sNew[24];
			KindLogName(kind, sKind, sizeof(sKind));
			KindValueText(kind, iOld,  sOld, sizeof(sOld));
			KindValueText(kind, value, sNew, sizeof(sNew));
			VoteLog("[发起投票] 发起=%s(%s) 类型=%s 原值=%s 目标=%s 投票人=%d 旁观=%d 时长=%ds",
				g_sVoterName, g_sVoterAuth, sKind, sOld, sNew, n, nSpec, iDuration);
		}
	}
	else
	{
		// 回落：SM 投票菜单（原生不可用才会走到这里；本服原生可用）
		for (int i = 1; i <= MaxClients; i++)
			g_iVotes[i] = -1;
		g_iVoted = 0;
		g_iEligible = 0;
		for (int i = 1; i <= MaxClients; i++)
			if (IsClientInGame(i) && !IsFakeClient(i))
				g_iEligible++;

		if (g_hMenu != null)
			delete g_hMenu;
		g_hMenu = new Menu(MenuHandler_VoteFallback);
		Format(sTitle, sizeof(sTitle), "%s 吗？\n当前: %d\n ", sText, iOld);
		g_hMenu.SetTitle(sTitle);

		int iCount = GetChoiceCount(kind);
		char sVal[8], sLabel[32];
		for (int i = 0; i < iCount; i++)
		{
			int v = GetChoiceValue(kind, i);
			Format(sVal, sizeof(sVal), "%d", v);
			Format(sLabel, sizeof(sLabel), "%d%s", v, v == value ? "  ← 提议" : "");
			g_hMenu.AddItem(sVal, sLabel);
		}
		g_hMenu.DisplayVoteToAll(iDuration);

		g_bVoteActive = true;

		CPrintToChatAll("{olive}[服务器设置]{default} 提议%s（当前 %d），%d 秒内按数字键投票", sText, iOld, iDuration);
		if (g_cDbg.BoolValue)
			LogMessage("[SVote] 已发起回落到 SM 菜单的投票：kind=%d %d->%d（在场真人 %d）",
				kind, iOld, value, g_iEligible);

		delete g_hVoteTimer;
		g_hVoteTimer = CreateTimer(float(iDuration), Timer_FinishVote);
	}
}

/** 通过所需同意票数：基准 = 在场生还者人数(默认) 或 实际投票人数 */
int GetVoteNeedCount(int iPlayerCount, int iYes, int iNo)
{
	int iBase = (g_cCountBase.IntValue == 0) ? iPlayerCount : (iYes + iNo);
	if (iBase < 1)
		iBase = 1;

	int iNeed = RoundToCeil(float(iBase) * g_cRatio.FloatValue / 100.0);
	if (iNeed < 1)
		iNeed = 1;
	return iNeed;
}

// ---- 原生投票回调 ----
public void Handler_NativeVote(L4D2NativeVote vote, VoteAction action, int param1, int param2)
{
	switch (action)
	{
		case VoteAction_Start:
		{
			int iNeed = GetVoteNeedCount(vote.PlayerCount, vote.YesCount, vote.NoCount);
			CPrintToChatAll("{olive}[服务器设置]{default} 通过条件：在场 {green}%d{default} 人中需 {green}%d{default} 票同意（不投票视为反对）",
				vote.PlayerCount, iNeed);
		}
		case VoteAction_End:
		{
			g_bVoteActive = false;

			int iNeed = GetVoteNeedCount(vote.PlayerCount, vote.YesCount, vote.NoCount);
			int iOld  = GetCurrentValue(g_iPendingKind);

			char sText[96];
			GetKindText(g_iPendingKind, g_iPendingValue, sText, sizeof(sText));

			if (vote.YesCount >= iNeed && vote.YesCount > vote.NoCount)
			{
				ApplyVote(g_iPendingKind, g_iPendingValue);
				// 必须先发 VotePass 面板才会关、库里的 ResetVote 才会跑
				vote.SetPass("%s 通过", sText);
				CPrintToChatAll("{olive}[服务器设置]{default} 通过！{green}%s{default}（%d → %d）（同意 %d / 反对 %d，需 %d）",
					sText, iOld, g_iPendingValue, vote.YesCount, vote.NoCount, iNeed);
				LogMessage("[SVote] 原生投票通过: kind=%d %d -> %d (同意%d 反对%d 需%d)",
					g_iPendingKind, iOld, g_iPendingValue, vote.YesCount, vote.NoCount, iNeed);
				// 【v1.2.7】投票日志：通过（含谁发起的、最终生效值）
				{
					char sKind[24], sNew[24];
					KindLogName(g_iPendingKind, sKind, sizeof(sKind));
					KindValueText(g_iPendingKind, GetCurrentValue(g_iPendingKind), sNew, sizeof(sNew));
					VoteLog("[通过] 发起=%s(%s) 类型=%s 原值=%s -> 新值=%s 票=同意%d/反对%d 需%d 在场%d",
						g_sVoterName, g_sVoterAuth, sKind, sText, sNew,
						vote.YesCount, vote.NoCount, iNeed, vote.PlayerCount);
				}
			}
			else
			{
				// 不通过也必须发 VoteFail，否则面板卡住 + 投票锁死
				vote.SetFail();
				CPrintToChatAll("{olive}[服务器设置]{default} 未通过，维持 {green}%d{default}（同意 %d / 反对 %d，需 %d）",
					iOld, vote.YesCount, vote.NoCount, iNeed);
				LogMessage("[SVote] 原生投票未通过: kind=%d 同意%d 反对%d 需%d",
					g_iPendingKind, vote.YesCount, vote.NoCount, iNeed);
				// 【v1.2.7】投票日志：未通过
				{
					char sKind[24], sOld[24];
					KindLogName(g_iPendingKind, sKind, sizeof(sKind));
					KindValueText(g_iPendingKind, iOld, sOld, sizeof(sOld));
					VoteLog("[未通过] 发起=%s(%s) 类型=%s 维持=%s 票=同意%d/反对%d 需%d 在场%d",
						g_sVoterName, g_sVoterAuth, sKind, sOld,
						vote.YesCount, vote.NoCount, iNeed, vote.PlayerCount);
				}
			}

			g_iPendingKind = -1;
		}
		default:
		{
			// 其它状态（有人投票等）不需要处理
		}
	}
}

// ---- 回落路径 ----
public int MenuHandler_VoteFallback(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		if (client < 1 || client > MaxClients)
			return 0;
		if (g_iVotes[client] == -1)
			g_iVoted++;
		g_iVotes[client] = item;
		if (g_iVoted >= g_iEligible)
			FinishVoteFallback();
	}
	return 0;
}

public Action Timer_FinishVote(Handle timer)
{
	g_hVoteTimer = null;
	FinishVoteFallback();
	return Plugin_Stop;
}

#define MAX_CHOICES 8

void FinishVoteFallback()
{
	if (!g_bVoteActive)
		return;
	g_bVoteActive = false;

	delete g_hVoteTimer;
	g_hVoteTimer = null;
	if (g_hMenu != null)
	{
		delete g_hMenu;
		g_hMenu = null;
	}

	int iKind  = g_iPendingKind;
	int iCount = GetChoiceCount(iKind);
	if (iKind < 0 || iCount <= 0 || iCount > MAX_CHOICES)
		return;

	int iTally[MAX_CHOICES];
	for (int i = 0; i < iCount; i++)
		iTally[i] = 0;

	int iTotal = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		int v = g_iVotes[i];
		if (IsClientInGame(i) && !IsFakeClient(i) && v >= 0 && v < iCount)
		{
			iTally[v]++;
			iTotal++;
		}
		g_iVotes[i] = -1;
	}

	if (iTotal < 1)
	{
		CPrintToChatAll("{olive}[服务器设置]{default} 无人投票，未生效");
		// 【v1.2.7】投票日志：无人投票（"发起了但没结果"也要留痕）
		{
			char sKind[24];
			KindLogName(iKind, sKind, sizeof(sKind));
			VoteLog("[无人投票] 发起=%s(%s) 类型=%s 未生效", g_sVoterName, g_sVoterAuth, sKind);
		}
		return;
	}

	// 取票数最高的一项；同票时取数值更大的那个（和原版行为一致）
	int iBest = 0;
	for (int i = 1; i < iCount; i++)
	{
		if (iTally[i] > iTally[iBest] ||
		    (iTally[i] == iTally[iBest] && GetChoiceValue(iKind, i) > GetChoiceValue(iKind, iBest)))
			iBest = i;
	}

	// 回落路径没有"在场人数"这个准确值，用投票人数作基准
	int iNeed = RoundToCeil(float(iTotal) * g_cRatio.FloatValue / 100.0);
	if (iNeed < 1)
		iNeed = 1;

	int iWin  = GetChoiceValue(iKind, iBest);
	int iOld  = GetCurrentValue(iKind);

	char sText[96];
	GetKindText(iKind, iWin, sText, sizeof(sText));

	if (iTally[iBest] < iNeed)
	{
		CPrintToChatAll("{olive}[服务器设置]{default} 最高票 %d 得 {green}%d{default} 票，未达 %d%%（需 %d），不改",
			iWin, iTally[iBest], g_cRatio.IntValue, iNeed);
		// 【v1.2.7】投票日志：票数不够
		{
			char sKind[24];
			KindLogName(iKind, sKind, sizeof(sKind));
			VoteLog("[未达标·回落] 发起=%s(%s) 类型=%s 最高票=%d 得%d票 需%d",
				g_sVoterName, g_sVoterAuth, sKind, iWin, iTally[iBest], iNeed);
		}
		return;
	}

	ApplyVote(iKind, iWin);
	CPrintToChatAll("{olive}[服务器设置]{default} 通过！{green}%s{default}（%d → %d）（%d/%d 票）",
		sText, iOld, iWin, iTally[iBest], iTotal);
	LogMessage("[SVote] 回落投票通过: kind=%d %d -> %d (%d/%d)", iKind, iOld, iWin, iTally[iBest], iTotal);

	// 【v1.2.7】投票日志：回落路径通过
	{
		char sKind[24], sNew[24];
		KindLogName(iKind, sKind, sizeof(sKind));
		KindValueText(iKind, GetCurrentValue(iKind), sNew, sizeof(sNew));
		VoteLog("[通过·回落] 发起=%s(%s) 类型=%s 原值=%s -> 新值=%s 票=%d/%d",
			g_sVoterName, g_sVoterAuth, sKind, sText, sNew, iTally[iBest], iTotal);
	}
}

// ------------------------------------------------------------------ 【v1.2.7】查看投票日志

#define VTLOG_MAX 15      // 一次最多打这么多行（还受栈大小限制：15 × 208 ≈ 3.1KB）
#define VTLOG_LEN 208

/** 【v1.2.8】日志自检：走的是和真实投票完全相同的 VoteLog() 路径，
 *  所以只要这条能落盘，就说明整条链路（cvar 开关 / VFormat / LogToFile / 路径）是通的。
 *  记录里带【日志自检】标记，不会被误当成真实投票。 */
public Action Cmd_VoteLogTest(int client, int args)
{
	char sWho[64];
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
		GetClientName(client, sWho, sizeof(sWho));
	else
		strcopy(sWho, sizeof(sWho), "控制台");

	VoteLog("[日志自检] 由 %s 触发（不是真实投票，可忽略）", sWho);
	ReplyToCommand(client, "[服务器设置] 已写入一条【日志自检】记录；用 sm_vtlog 1 或看 logs/ltt_svote.log 确认");
	return Plugin_Handled;
}

/** 管理员命令：把投票日志最后 N 条打到自己的控制台（默认 15，上限 15）。
 *  为什么打到控制台而不是聊天框：日志行很长，刷聊天框会把别人的对话顶掉。 */
public Action Cmd_VoteLog(int client, int args)
{
	if (client <= 0)
	{
		ReplyToCommand(client, "[服务器设置] 请在游戏内使用（或直接看 logs/ltt_svote.log）");
		return Plugin_Handled;
	}

	int want = VTLOG_MAX;
	if (args >= 1)
	{
		char sN[8];
		GetCmdArg(1, sN, sizeof(sN));
		want = StringToInt(sN);
		if (want < 1)        want = 1;
		if (want > VTLOG_MAX) want = VTLOG_MAX;
	}

	File f = OpenFile(g_sVoteLogFile, "r");
	if (f == null)
	{
		CPrintToChat(client, "{olive}[服务器设置]{default} 还没有投票日志（一次投票都还没发生？）");
		return Plugin_Handled;
	}

	char ring[VTLOG_MAX][VTLOG_LEN];
	char line[VTLOG_LEN];
	int  n = 0;
	while (!f.EndOfFile() && f.ReadLine(line, sizeof(line)))
	{
		strcopy(ring[n % VTLOG_MAX], VTLOG_LEN, line);
		n++;
	}
	delete f;

	if (n == 0)
	{
		CPrintToChat(client, "{olive}[服务器设置]{default} 投票日志是空的");
		return Plugin_Handled;
	}

	int show = (n < want) ? n : want;
	CPrintToChat(client, "{olive}[服务器设置]{default} 最近 {green}%d{default} 条投票记录已打到你的控制台（共 %d 条）", show, n);
	PrintToConsole(client, "===== 投票日志：最近 %d 条 / 共 %d 条 =====", show, n);
	for (int i = n - show; i < n; i++)
		PrintToConsole(client, "%s", ring[i % VTLOG_MAX]);
	return Plugin_Handled;
}

// ------------------------------------------------------------------ 空服恢复

public Action Timer_IdleCheck(Handle timer)
{
	int iHumans = 0;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && !IsFakeClient(i))
			iHumans++;

	if (iHumans > 0)
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
	if (!g_cIdleReset.BoolValue || (now - g_iIdleSince) < g_cIdleSeconds.IntValue)
		return Plugin_Continue;

	g_iIdleSince = 0;
	if (g_cHrValue != null && g_iHrDefault >= 0 && g_cHrValue.IntValue != g_iHrDefault)
	{
		LogMessage("[SVote] 空服还原: 杀特回血 %d -> %d", g_cHrValue.IntValue, g_iHrDefault);
		g_cHrValue.SetInt(g_iHrDefault);
	}
	if (g_cMaxHpCvar != null && g_iHpDefault >= 0 && g_cMaxHpCvar.IntValue != g_iHpDefault)
	{
		LogMessage("[SVote] 空服还原: 血上限 %d -> %d", g_cMaxHpCvar.IntValue, g_iHpDefault);
		g_cMaxHpCvar.SetInt(g_iHpDefault);
	}
	// 【v1.2.9】空服还原也要清掉"投过"的标记，否则下次换图又会被重新盖回去
	g_iHrVoted = -1;
	g_iHpVoted = -1;

	// 【v1.2.2 移除】这里原来还会还原"特感每波 / 上限 / 间隔"三项。
	// 现在刷特设置已经由独立的 ltt_si_menu 插件接管（它有自己的空服还原 +
	// 跨图存档），两边都管会互相打架：ltt_svote 空服把它改回默认，
	// ltt_si_menu 换图又按存档改回去，玩家会看到设置自己跳来跳去。
	// 所以刷特三项的还原权交给 ltt_si_menu，本插件只负责回血与血上限。

	// 【v1.2.6】难度/友伤/火伤是本插件新开的领地（没有别的插件管），所以也在这里还原，
	// 并把"投过"的标记清掉（否则下次换图又会被 OnConfigsExecuted 盖回来）。
	if (g_iDiffVoted >= 0)
	{
		ConVar c = FindConVar("z_difficulty");
		if (c != null && g_iDiffDefault >= 0)
		{
			LogMessage("[SVote] 空服还原: 难度 %s -> %s",
				g_sDiffName[CurrentDifficulty()], g_sDiffName[g_iDiffDefault]);
			c.SetString(g_sDiffValue[g_iDiffDefault]);
		}
		g_iDiffVoted = -1;
	}
	if (g_iFfVoted >= 0)
	{
		int iNow = ReadMulTenths(false);
		LogMessage("[SVote] 空服还原: 友伤倍率 %d.%d -> %d.%d",
			iNow / 10, iNow % 10, g_iFfDefault / 10, g_iFfDefault % 10);
		if (g_iFfDefault >= 0)
			ApplyMul(false, g_iFfDefault);
		g_iFfVoted = -1;
	}
	if (g_iFireVoted >= 0)
	{
		int iNow = ReadMulTenths(true);
		LogMessage("[SVote] 空服还原: 火伤倍率 %d.%d -> %d.%d",
			iNow / 10, iNow % 10, g_iFireDefault / 10, g_iFireDefault % 10);
		if (g_iFireDefault >= 0)
			ApplyMul(true, g_iFireDefault);
		g_iFireVoted = -1;
	}

	return Plugin_Continue;
}
