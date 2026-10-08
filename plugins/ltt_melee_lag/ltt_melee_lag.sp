/**
 *  ltt_melee_lag —— 「刀不掉飞扑」**只记账、不动作**探针（v1.2.0）
 *
 *  【为什么做】
 *  2026-10-03 服主转述群友反馈：「连服务器 20~30ms，刀飞扑 hunter 和起跳的 jockey 容易因延迟没刀掉反被控」。
 *  设计稿 §200 已查清根因优先是**客户端插值**（默认 cl_interp_ratio 2 ⇒ 20ms lerp ⇒ 世界滞后 40~50ms），
 *  但也留下了 §200.6② 这条：要不要做**服务器侧软补偿**（把"本该命中"的那些挥空替引擎补上）。
 *  服主 2026-10-05 定：**先做只记账不动作的版本跑一局，看如果真打断会误判多少**。
 *
 *  ================================ 版本变更 ================================
 *  【v1.2.2】2026-10-05 晚 —— ⚠⚠ 修一个**从头到尾让"★本该命中"永远为 0** 的致命 bug
 *   `GetEntPropVector(i, Prop_Send, "m_vecVelocity", ...)` 在 L4D2 会**抛异常**
 *   （`Property "m_vecVelocity" not found (entity N/player)`）——玩家的 m_vecVelocity 是 **datamap 属性**，
 *   必须用 `Prop_Data`（`ltt_skill_lite` 里就是这么写的）。异常发生在「已记录最近目标、还没设 ★ 候选」之间，
 *   于是：最近目标记下了、★ 候选永远 0、诊断行也没写成 —— 表现就是"明明扑到脸上了却从不判★"。
 *   证据：`addons/sourcemod/logs/errors_20261005.log` 里 17:45~17:49 连续多条
 *   `Line 629, SampleBestTarget` 的 GetEntPropVector 异常（★ 候选赋值就在它下一行）。
 *   ⇒ 教训：**日志要连 errors_*.log 一起看**；v1.0.0/v1.1.0 也是同一个错（只不过那时被定时器 bug 掩盖）。
 *   ➕ 调试用的「采样诊断」行改成 `ltt_meleelag_debug 1` 才开（默认关，不占日志预算）。
 * *  【v1.2.0】2026-10-05 晚（服主实战后发现的关键问题：**统计口径错了**）
 *   ⚠ 真凶：v1.1.0 只统计 `IN_ATTACK2`（**推/撞**），而服主是拿**近战武器用鼠标左键砍**
 *     （引擎日志实证：3 分钟内 20 条 `killed "Hunter/Jockey" with "melee"`），
 *     结果 挥刀 只有 2 次 —— 口径完全对不上他"刀了几只特感"的实际操作。
 *     现在两种都统计，并在日志里区分：`按键=推` / `按键=刀(weapon_melee)`。
 *     · 近战武器按住左键会**连续挥**，所以不能只看按键上升沿：改用
 *       `m_flNextPrimaryAttack`（下一次可攻击时间被推后 = 又挥出一刀）来识别每一刀。
 *     · 命中判定：推 → `player_shoved`；刀 → `player_hurt`（attacker = 本人）。
 *       ⚠ 已知局限：打**小僵尸**不触发 `player_hurt`（它们不是 client），所以在有僵尸的图上
 *         "砍中小僵尸"的那一刀会被算成挥空。tgxl 这类训练图没有小僵尸，不受影响。
 *   ➕ ★ 判定改用引擎精确标志（借 `ltt_skill_lite` 已经在服上跑通的写法）：
 *     Hunter = `m_isAttemptingToPounce`；Jockey = `IsJockeyLeaping()`（离地+非水+无受害者+`m_isLeaping`）。
 *     原来的"离地或速度≥150"降级成**可选补充判据**（`ltt_meleelag_speed` 默认改成 **0 = 关**）。
 *   ➕ 修 `换算lerp`：`cl_interp_ratio 0`（= 0 插值）原来被判成"未读到"，现在正确算成 0ms。
 *   ➕ `sm_meleelag lerp` 同时显示手上武器与"是否算近战"。
 *
 *  【v1.1.0】修 v1.0.0 的定时器 bug（换图后结算器永久停摆 ⇒ 挥空永远 0，实测 挥刀 20/命中 4/挥空 0）：
 *   结算定时器改成**每张图开图时重建**，并加**心跳计数**（status 第一行就打印；心跳 0 = 结算器没跑。
 *   以后一眼可辨，不靠推理）。⚠ `KillTimer(h, true)` 会抛 `TIMER_DATA_HNDL_CLOSE` 异常并打断 OnMapStart，
 *   必须用 `KillTimer(h)` + `CloseHandle(h)`。
 *   同日新增**玩家 lerp 记录**（服主点名要："100 lerp 就是 +100ms 延迟，自然难刀"）：
 *     引擎真值 `m_fLerpTime`（datamap）+ 客户端 `cl_interp`/`cl_interp_ratio`/`cl_updaterate`（异步查询）。
 *     估算世界滞后 = **lerp + ping/2**（估算不是测量，公式随日志打印，原始值同在一行）。
 *
 *  【v1.0.0】只统计推（IN_ATTACK2）。
 *
 *  【"本该命中"（★）的三个条件】
 *    ① 这一下**没有**命中（推没触发 `player_shoved`；刀没触发 `player_hurt`）；
 *    ② 那一刻前方 `cone` 度锥形内、`dist` 单位内有一只特感；
 *    ③ 那只特感**正在扑/正在跳**：Hunter `m_isAttemptingToPounce`；Jockey `IsJockeyLeaping()`
 *       （可选：`ltt_meleelag_speed` > 0 时，"离地或速度≥该值"也算）。
 *  —— 满足就记一条「本该命中」，**绝不造成任何伤害、不打断、不位移**。
 *
 *  【日志】每次挥空都写；★ 标记的才是"本该命中"；图末写 4 行汇总（心跳/总数/延迟分布/lerp 分布）。
 *  【命令】`sm_meleelag`（累计）｜`reset`（清零）｜`lerp`（重查在线玩家 lerp + 手上武器）
 *  【调参】`ltt_meleelag_cone` / `_dist` / `_speed` / `_window` / `_bots`；回滚 `ltt_meleelag_enable 0` 或卸插件（无副作用）。
 *
 *  ⚠ 与 `z_pounce_damage_interrupt 250` 的关系（§200.4 代价①）：真做"替引擎打断"时要给足伤害才能过这个阈值；
 *    本版**不打断**，所以现在不存在冲突。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.4.0"
#define SHOW_OR        "未读到"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define MAX_CLASS     6
#define CLASS_HUNTER  3
#define CLASS_JOCKEY  5

#define ATK_PUSH      1     // 推 / 撞（IN_ATTACK2）
#define ATK_MELEE     2     // 近战武器左键（IN_ATTACK + weapon_melee）

static const char g_sClassName[MAX_CLASS + 1][] =
{
	"", "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger"
};

// 异步查询 cl_* 时用来区分是哪一条
enum
{
	QI_INTERP = 1,
	QI_RATIO,
	QI_UPD
};

ConVar g_cEnable, g_cCone, g_cDist, g_cSpeed, g_cWindow, g_cLog, g_cBots, g_cDebug;
// 【v1.4.0】命中帧二次采样（只记账，不改原有口径）
ConVar g_cHitSample, g_cHitSampleDelay;
int    g_iHitSampleLines;                     // 本次运行写出的命中帧对比行数

Handle g_hSettle = null;

int    g_iLastButtons[MAXPLAYERS + 1];
float  g_flAttemptAt[MAXPLAYERS + 1];
float  g_flEyePos[MAXPLAYERS + 1][3];
float  g_flFwd[MAXPLAYERS + 1][3];
bool   g_bPending[MAXPLAYERS + 1];
bool   g_bHit[MAXPLAYERS + 1];
int    g_iAtkType[MAXPLAYERS + 1];
char   g_sAtkWeap[MAXPLAYERS + 1][64];
int    g_iLogLeft[MAXPLAYERS + 1];
int    g_iSeq[MAXPLAYERS + 1];          // 出手序号（把采样诊断行与结算行对上）
int    g_iLastWeapon[MAXPLAYERS + 1];
float  g_flLastNextPri[MAXPLAYERS + 1];

// 出手**瞬间**的采样结果（★判定与"为什么不算★"的解释都用它）
int    g_iBestTarget[MAXPLAYERS + 1];
float  g_flBestDist[MAXPLAYERS + 1];
float  g_flBestAng[MAXPLAYERS + 1];
int    g_iBestClass[MAXPLAYERS + 1];
float  g_flBestSpeed[MAXPLAYERS + 1];
float  g_flBestZDiff[MAXPLAYERS + 1];
int    g_iNearTarget[MAXPLAYERS + 1];
float  g_flNearDist[MAXPLAYERS + 1];
float  g_flNearAng[MAXPLAYERS + 1];
int    g_iNearClass[MAXPLAYERS + 1];

float  g_flPouncedAt[MAXPLAYERS + 1];   // 最近一次被 Hunter 扑中的时刻（lunge_pounce）

// 挥刀瞬间记下来的玩家状态（结算时用）
float  g_flPingMs[MAXPLAYERS + 1];
float  g_flLerpMs[MAXPLAYERS + 1];      // 引擎 m_fLerpTime（毫秒）；-1 = 没读到
int    g_iUpdEng[MAXPLAYERS + 1];       // 引擎 m_nUpdateRate；-1 = 没读到
char   g_sCliInterp[MAXPLAYERS + 1][24];// 客户端 cl_interp 原值（"" = 没读到）
char   g_sCliRatio[MAXPLAYERS + 1][24]; // 客户端 cl_interp_ratio 原值
char   g_sCliUpd[MAXPLAYERS + 1][24];   // 客户端 cl_updaterate 原值

int    g_iLerpOff = -1, g_iUpdOff = -1;
bool   g_bOffTried = false;

int g_iTry, g_iTryPush, g_iTryMelee;
int g_iHit, g_iHitPush, g_iHitMelee;
int g_iWhiff, g_iWhiffPin, g_iWhiffPinPush, g_iWhiffPinMelee;
int g_iPinHunter, g_iPinJockey;
int g_iPinRidden, g_iPinPounced, g_iPinFree;   // ★ 结算时：被Jockey骑 / 被Hunter扑 / 自由
int g_iPingLt20, g_iPing20to50, g_iPing50up;
int g_iLerpLt20, g_iLerp20to50, g_iLerp50to100, g_iLerp100up, g_iLerpUnknown;
float g_flLerpSum;
int g_iLerpN;
float g_flEstSum, g_flEstMax;
int g_iEstN;
int g_iLogBudget;
int g_iTicks;                            // 结算定时器心跳（0 = 结算器没跑 = 数据无效）

char g_sMapName[64];

public Plugin myinfo =
{
	name        = "[LTT] Melee Lag Probe",
	author      = "DeepSeek Harness",
	description = "只记账不动作：统计「推/近战刀 没命中，但正对着扑/跳中的 Hunter/Jockey」多少次 + 记录玩家 lerp/延迟（评估要不要做服务器侧软补偿）",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cEnable = CreateConVar("ltt_meleelag_enable", "1", "1=记账（只统计，不改任何行为）｜0=完全关掉", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cCone   = CreateConVar("ltt_meleelag_cone", "40.0", "判定「正对着」的锥角（度）。近战刀的实际判定是个宽扇形，想看宽一点就调大", FCVAR_NOTIFY, true, 5.0, true, 180.0);
	g_cDist   = CreateConVar("ltt_meleelag_dist", "110.0", "判定「够得着」的距离容差（单位）。近战 melee_range=70，给高延迟留余量", FCVAR_NOTIFY, true, 10.0, true, 500.0);
	g_cSpeed  = CreateConVar("ltt_meleelag_speed", "0.0", "可选补充判据：离地或速度≥该值（u/s）也算「正在扑/跳」。0=关（现在用引擎精确标志 m_isAttemptingToPounce / IsJockeyLeaping）", FCVAR_NOTIFY, true, 0.0, true, 2000.0);
	g_cWindow = CreateConVar("ltt_meleelag_window", "0.20", "出手后多久结算这一次（秒）。这段时间内收到命中事件就算命中", FCVAR_NOTIFY, true, 0.05, true, 1.0);
	g_cLog    = CreateConVar("ltt_meleelag_log", "1", "1=每次挥空都写明细｜0=只写图末汇总", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cBots   = CreateConVar("ltt_meleelag_bots", "0", "自测用：1=连 BOT 的出手也统计（验证出手→结算链路）｜0=只统计真人（正式数据）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cDebug  = CreateConVar("ltt_meleelag_debug", "0", "调试：1=每次出手都额外写一行「采样诊断」（默认 0，平时别开，会吃日志预算）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// =================================================================================
	// 【v1.4.0】命中帧二次采样 —— 车主 2026-10-07：让「★本该命中」这个指标可信
	//
	// 问题：原有口径是在**出手那一瞬间**采样判定（v1.2.1 起），因为 v1.2.0 在结算时(0.2s后)采样
	//   会系统性漏记 ★。但统计出来的 38.8% 空爆失败率里，成功组与失败组的延迟指标几乎完全重合
	//   （ping 均 46.9 vs 45.4ms），几何也几乎一样（距离 84 vs 82、夹角 19° vs 16°）——
	//   **说明失败不是网络造成的**，很可能是"出手瞬间"这个采样时机偏乐观：
	//   引擎的近战判定发生在挥击动画的**命中帧**（约 0.2 秒后），而 Hunter 扑击 ~600 u/s、
	//   Jockey ~400 u/s ⇒ 这 0.2 秒能位移 80~120 单位，足以滑出判定锥。
	//
	// 做法：**不动原有逻辑**，只在出手后 delay 秒再采一次同样的几何并单独记一行 `[命中帧]`，
	//   事后即可把「出手时够得着但命中帧够不着」（=差一点点/假失败）与「两边都够得着却失败」
	//   （=真·该命中却失败）分开。采样后**立即还原出手瞬间的全局量**，结算口径完全不受影响。
	// 日志量：只在"出手或命中帧任一侧扫到空中特感"时才记一行（约占挥击的 2.5%），不会刷爆。
	// =================================================================================
	g_cHitSample = CreateConVar("ltt_meleelag_hitsample", "1", "【v1.4.0】1=出手后 delay 秒再采一次「命中帧」几何并记一行 [命中帧]（只记账）｜0=关", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cHitSampleDelay = CreateConVar("ltt_meleelag_hitsample_delay", "0.20", "【v1.4.0】命中帧采样延迟（秒）。近战挥击从出手到命中判定约 0.15~0.25 秒", FCVAR_NOTIFY, true, 0.05, true, 1.0);

	AutoExecConfig(true, "ltt_melee_lag");

	HookEvent("player_shoved", Event_PlayerShoved, EventHookMode_Post);   // 推命中
	HookEvent("player_hurt",   Event_PlayerHurt,   EventHookMode_Post);
	HookEvent("lunge_pounce",  Event_LungePounce, EventHookMode_Post);   // Hunter 扑中人（判断★那次是否被控）   // 近战刀命中（砍到特感/生还者）

	RegAdminCmd("sm_meleelag", Cmd_MeleeLag, ADMFLAG_GENERIC, "【v1.2.0】只记账探针：sm_meleelag [status|reset|lerp]");

	for (int i = 1; i <= MaxClients; i++)
	{
		ResetClient(i);
		if (IsClientInGame(i) && !IsFakeClient(i))
			QueryInterp(i);          // 中途重载插件时，已在线玩家的 cl_* 缓存要重新拉一次
	}

	ResetStats();
	StartSettleTimer();
}

/** 结算定时器：每张图都要重建（v1.0.0 只建一次 + NO_MAPCHANGE ⇒ 换图后永久停摆）。
 *  ⚠ 不要用 KillTimer(h, true)：本插件定时器没有 data 句柄，那条路会抛 TIMER_DATA_HNDL_CLOSE 异常
 *    并打断 OnMapStart（v1.1.0 首次部署实测踩到，心跳 0）。 */
void StartSettleTimer()
{
	if (g_hSettle != null)
	{
		if (IsValidHandle(g_hSettle))
		{
			KillTimer(g_hSettle);
			if (IsValidHandle(g_hSettle))
				CloseHandle(g_hSettle);
		}
		g_hSettle = null;
	}
	g_hSettle = CreateTimer(0.1, Timer_Settle, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void ResetClient(int i)
{
	g_bPending[i]     = false;
	g_bHit[i]         = false;
	g_iLastButtons[i] = 0;
	g_iLogLeft[i]     = 300;
	g_flAttemptAt[i]  = 0.0;
	g_iAtkType[i]     = 0;
	g_sAtkWeap[i][0]  = '\0';
	g_iLastWeapon[i]  = 0;
	g_flLastNextPri[i]= 0.0;
	g_iBestTarget[i]  = 0;
	g_iNearTarget[i]  = 0;
	g_flBestDist[i]   = 99999.0;
	g_flNearDist[i]   = 99999.0;
	g_flPingMs[i]     = 0.0;
	g_flPouncedAt[i]  = 0.0;
	g_flLerpMs[i]     = -1.0;
	g_iUpdEng[i]      = -1;
	g_sCliInterp[i][0] = '\0';
	g_sCliRatio[i][0]  = '\0';
	g_sCliUpd[i][0]    = '\0';
}

void ResetStats()
{
	g_iTry = 0; g_iTryPush = 0; g_iTryMelee = 0;
	g_iHit = 0; g_iHitPush = 0; g_iHitMelee = 0;
	g_iWhiff = 0; g_iWhiffPin = 0; g_iWhiffPinPush = 0; g_iWhiffPinMelee = 0;
	g_iPinHunter = 0; g_iPinJockey = 0;
	g_iPinRidden = 0; g_iPinPounced = 0; g_iPinFree = 0;
	g_iPingLt20 = 0; g_iPing20to50 = 0; g_iPing50up = 0;
	g_iLerpLt20 = 0; g_iLerp20to50 = 0; g_iLerp50to100 = 0; g_iLerp100up = 0;
	g_iLerpUnknown = 0;
	g_flLerpSum = 0.0; g_iLerpN = 0;
	g_flEstSum = 0.0; g_flEstMax = 0.0; g_iEstN = 0;
	g_iLogBudget = 1500;
	g_iTicks = 0;
}

public void OnConfigsExecuted()
{
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
}

public void OnMapStart()
{
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	ResetStats();
	for (int i = 1; i <= MaxClients; i++)
		ResetClient(i);
	StartSettleTimer();                  // ← 关键：每张图都把结算器拉起来
}

public void OnMapEnd()
{
	LogMessage("[MeleeLag] 地图=%s 【心跳 %d 次（0=结算器没跑，本次数据无效）】本图出手 %d（推 %d / 刀 %d）/ 命中 %d（推 %d / 刀 %d）/ 挥空 %d；其中【★本该命中】%d（推 %d / 刀 %d ｜ Hunter %d / Jockey %d）",
		g_sMapName, g_iTicks, g_iTry, g_iTryPush, g_iTryMelee,
		g_iHit, g_iHitPush, g_iHitMelee, g_iWhiff,
		g_iWhiffPin, g_iWhiffPinPush, g_iWhiffPinMelee, g_iPinHunter, g_iPinJockey);
	LogMessage("[MeleeLag] 地图=%s 挥空者的 ping 分布：<20ms %d / 20~50ms %d / >=50ms %d",
		g_sMapName, g_iPingLt20, g_iPing20to50, g_iPing50up);
	LogMessage("[MeleeLag] 地图=%s 挥空者的 lerp 分布：<20ms %d / 20~50ms %d / 50~100ms %d / >=100ms %d / 没读到 %d ｜ 平均 lerp %.0fms（n=%d）",
		g_sMapName, g_iLerpLt20, g_iLerp20to50, g_iLerp50to100, g_iLerp100up, g_iLerpUnknown,
		(g_iLerpN > 0) ? (g_flLerpSum / float(g_iLerpN)) : 0.0, g_iLerpN);
	LogMessage("[MeleeLag] 地图=%s 估算世界滞后（lerp + ping/2）：平均 %.0fms / 最大 %.0fms（n=%d）",
		g_sMapName, (g_iEstN > 0) ? (g_flEstSum / float(g_iEstN)) : 0.0, g_flEstMax, g_iEstN);
}

// ------------------------------------------------------------------ 读玩家 lerp / 延迟

/** 引擎侧真值：datamap 的 m_fLerpTime（秒）→ 毫秒。返回 -1 表示这个字段读不到。 */
float ReadEngineLerpMs(int client, int &updRate)
{
	updRate = -1;
	if (!g_bOffTried)
	{
		g_bOffTried = true;
		g_iLerpOff  = FindDataMapInfo(client, "m_fLerpTime");
		g_iUpdOff   = FindDataMapInfo(client, "m_nUpdateRate");
	}
	if (g_iLerpOff == -1)
		return -1.0;

	if (g_iUpdOff != -1)
		updRate = GetEntData(client, g_iUpdOff);
	return GetEntDataFloat(client, g_iLerpOff) * 1000.0;
}

/** 客户端 cvar 换算出来的 lerp（毫秒）：cl_interp>0 用它，否则 cl_interp_ratio / cl_updaterate。
 *  ⚠ `cl_interp_ratio 0` 是**合法的 0 插值**（服主自己就是 ratio=0），v1.1.0 把它误判成"未读到"。 */
float DerivedLerpMs(int client)
{
	float ci = StringToFloat(g_sCliInterp[client]);
	if (ci > 0.0)
		return ci * 1000.0;

	float r = StringToFloat(g_sCliRatio[client]);
	float u = StringToFloat(g_sCliUpd[client]);
	if (u > 0.0 && r >= 0.0 && g_sCliUpd[client][0] != '\0')
		return (r / u) * 1000.0;

	return -1.0;
}

/** 两个来源里取能用的那个（引擎字段优先）。-1 = 这个玩家的 lerp 一点都读不到。 */
float BestLerpMs(int client)
{
	float e = g_flLerpMs[client];
	if (e >= 0.0)
		return e;
	return DerivedLerpMs(client);
}

void ShowText(const char[] s, char[] out, int maxlen)
{
	if (s[0] == '\0')
		strcopy(out, maxlen, SHOW_OR);
	else
		strcopy(out, maxlen, s);
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client))
		return;
	QueryInterp(client);
}

void QueryInterp(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return;
	QueryClientConVar(client, "cl_interp",       OnConVarQueried, QI_INTERP);
	QueryClientConVar(client, "cl_interp_ratio", OnConVarQueried, QI_RATIO);
	QueryClientConVar(client, "cl_updaterate",   OnConVarQueried, QI_UPD);
}

public void OnConVarQueried(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, any value)
{
	if (client < 1 || client > MaxClients)
		return;

	int which = value;
	char buf[24];
	if (result != ConVarQuery_Okay)
		buf[0] = '\0';          // 查不到就留空（日志写「未读到」），绝不编一个数
	else
		strcopy(buf, sizeof(buf), cvarValue);

	switch (which)
	{
		case QI_INTERP: strcopy(g_sCliInterp[client], sizeof(g_sCliInterp[]), buf);
		case QI_RATIO:  strcopy(g_sCliRatio[client],  sizeof(g_sCliRatio[]),  buf);
		case QI_UPD:    strcopy(g_sCliUpd[client],    sizeof(g_sCliUpd[]),    buf);
	}
}

// ------------------------------------------------------------------ 武器 / 姿态判定

/** L4D2 所有近战武器共用一个类名 `weapon_melee`（引擎 dump：CTerrorMeleeWeapon - weapon_melee），
 *  电锯是 `weapon_chainsaw`；自定义近战模型偶尔带后缀，所以用包含匹配。 */
bool IsMeleeClass(const char[] cls)
{
	if (cls[0] == '\0')
		return false;
	return (StrContains(cls, "melee", false) != -1) || (StrEqual(cls, "weapon_chainsaw", false));
}

bool IsHoldingMelee(int client)
{
	char w[64];
	GetClientWeapon(client, w, sizeof(w));
	return IsMeleeClass(w);
}

/** 猎人是否正在扑（引擎标志；被打真空爆时会被清 0，那一瞬靠速度补也够用）。 */
bool IsHunterPouncing(int hunter)
{
	return GetEntProp(hunter, Prop_Send, "m_isAttemptingToPounce") != 0;
}

/** 骑师是否在跳（与 ltt_skill_lite 在服上跑通的写法逐行一致）。 */
bool IsJockeyLeaping(int jockey)
{
	if (GetEntProp(jockey, Prop_Send, "m_zombieClass") != CLASS_JOCKEY ||
		GetEntPropEnt(jockey, Prop_Send, "m_hGroundEntity") > -1 ||
		GetEntityMoveType(jockey) != MOVETYPE_WALK ||
		GetEntProp(jockey, Prop_Send, "m_nWaterLevel") >= 3 ||
		GetEntPropEnt(jockey, Prop_Send, "m_jockeyVictim") > -1)
	{
		return false;
	}

	int abilityEnt = GetEntPropEnt(jockey, Prop_Send, "m_customAbility");
	if (IsValidEntity(abilityEnt) && HasEntProp(abilityEnt, Prop_Send, "m_isLeaping") &&
		GetEntProp(abilityEnt, Prop_Send, "m_isLeaping"))
	{
		return true;
	}

	float vel[3];
	GetEntPropVector(jockey, Prop_Data, "m_vecVelocity", vel);
	vel[2] = 0.0;

	return (GetVectorLength(vel) >= 15.0 && GetEntPropEnt(jockey, Prop_Send, "m_hGroundEntity") == -1);
}

// ------------------------------------------------------------------ 出手检测

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (g_cEnable == null || !g_cEnable.BoolValue)
		return Plugin_Continue;
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return Plugin_Continue;
	if (!g_cBots.BoolValue && IsFakeClient(client))
		return Plugin_Continue;
	if (!IsPlayerAlive(client) || GetClientTeam(client) != TEAM_SURVIVOR)
	{
		g_iLastButtons[client] = buttons;
		return Plugin_Continue;
	}

	// ---- 这一 tick 手上是什么武器
	int wep = weapon;
	if (wep <= 0 || !IsValidEdict(wep))
		wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");

	char sWeap[64];
	sWeap[0] = '\0';
	if (wep > 0 && IsValidEdict(wep))
		GetEdictClassname(wep, sWeap, sizeof(sWeap));

	// ---- ① 推 / 撞：按键上升沿
	bool bPush = ((buttons & IN_ATTACK2) != 0) && ((g_iLastButtons[client] & IN_ATTACK2) == 0);

	// ---- ② 近战刀：按住左键会连续挥，所以看「下一次可攻击时间被推后」= 又挥出一刀
	bool bMelee = false;
	if (wep > 0 && IsValidEdict(wep))
	{
		float nextPri = GetEntPropFloat(wep, Prop_Send, "m_flNextPrimaryAttack");
		if (g_iLastWeapon[client] != wep)
		{
			g_iLastWeapon[client] = wep;        // 换武器不算出手
			g_flLastNextPri[client] = nextPri;
		}
		else
		{
			if ((buttons & IN_ATTACK) != 0 && IsMeleeClass(sWeap) &&
				nextPri > g_flLastNextPri[client] + 0.001)
			{
				bMelee = true;
			}
			g_flLastNextPri[client] = nextPri;
		}
	}

	g_iLastButtons[client] = buttons;

	if (!bPush && !bMelee)
		return Plugin_Continue;

	int atk = bPush ? ATK_PUSH : ATK_MELEE;

	float now = GetGameTime();
	float win = g_cWindow.FloatValue;
	if (g_bPending[client] && (now - g_flAttemptAt[client]) < win)
		return Plugin_Continue;                 // 上一刀还没结算完就不记新的

		g_iSeq[client]++;
	g_iTry++;
	if (atk == ATK_PUSH) g_iTryPush++;
	else                 g_iTryMelee++;

	g_bPending[client] = true;
	g_bHit[client]     = false;
	g_iAtkType[client] = atk;
	strcopy(g_sAtkWeap[client], sizeof(g_sAtkWeap[]), sWeap);
	g_flAttemptAt[client] = now;

	// 出手瞬间的玩家状态（延迟 / 插值）
	// ⚠ GetClientLatency 对 BOT 会抛异常（"Client N is a bot"），自测模式必须挡住
	g_flPingMs[client] = IsFakeClient(client) ? 0.0 : (GetClientLatency(client, NetFlow_Both) * 1000.0);
	int updRate = -1;
	g_flLerpMs[client] = ReadEngineLerpMs(client, updRate);
	g_iUpdEng[client]  = updRate;

	GetClientEyePosition(client, g_flEyePos[client]);
	float ang[3];
	GetClientEyeAngles(client, ang);
	GetAngleVectors(ang, g_flFwd[client], NULL_VECTOR, NULL_VECTOR);

	SampleBestTarget(client);        // ← 关键：就在出手这一刻采样，别等 0.2 秒后（结算口径依赖它，不动）

	// 【v1.4.0】再挂一个「命中帧二次采样」（只记账、会还原全局量，见 Timer_HitFrameSample）
	if (g_cHitSample.BoolValue)
		CreateTimer(g_cHitSampleDelay.FloatValue, Timer_HitFrameSample, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Continue;
}

void MarkHit(int client, int type)
{
	if (client < 1 || client > MaxClients)
		return;
	if (!g_bPending[client] || g_bHit[client])
		return;
	if (g_iAtkType[client] != type)
		return;

	g_bHit[client] = true;
	g_bPending[client] = false;
	g_iHit++;
	if (type == ATK_MELEE) g_iHitMelee++;
	else                   g_iHitPush++;

	// 命中同样写一行明细（与 ★ 完全同口径 ⇒ 可以直接对比"成功的刀"和"该中没中的刀"）
	char sExtra[192];
	if (g_iBestTarget[client] > 0)
	{
		Format(sExtra, sizeof(sExtra), "✔命中（出手瞬间采样）职业=%s 距离=%.0f 夹角=%.0f° 高差=%.0f 速度=%.0f",
			g_sClassName[g_iBestClass[client]], g_flBestDist[client], g_flBestAng[client],
			g_flBestZDiff[client], g_flBestSpeed[client]);
	}
	else
	{
		strcopy(sExtra, sizeof(sExtra), "✔命中（出手时附近没有扑/跳中的特感 → 砍的是小僵尸/落地特感）");
	}
	LogAttempt(client, sExtra);
}

// 推命中（引擎判定推到了东西）
public void Event_PlayerShoved(Event event, const char[] name, bool dontBroadcast)
{
	MarkHit(GetClientOfUserId(event.GetInt("attacker")), ATK_PUSH);
}

// 近战刀命中（砍到特感/生还者；⚠ 砍小僵尸不会触发这个事件——它们不是 client）
public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	MarkHit(GetClientOfUserId(event.GetInt("attacker")), ATK_MELEE);
}

// ------------------------------------------------------------------ 结算

public Action Timer_Settle(Handle timer)
{
	g_iTicks++;

	if (g_cEnable == null || !g_cEnable.BoolValue)
		return Plugin_Continue;

	float now = GetGameTime();
	float win = g_cWindow.FloatValue;

	for (int c = 1; c <= MaxClients; c++)
	{
		if (!g_bPending[c])
			continue;

		if (g_bHit[c])
		{
			g_bPending[c] = false;
			continue;
		}

		if ((now - g_flAttemptAt[c]) < win)
			continue;                            // 还在窗口内，再等等

		g_bPending[c] = false;
		g_iWhiff++;
		SettleWhiff(c);
	}
	return Plugin_Continue;
}

/** 出手**瞬间**采样（v1.2.1 关键修正）：找出「正在扑/跳」的特感里落在判定范围内、最近的那只（★候选），
 *  另外记下全场最近的扑/跳中特感（不论距离），用来解释某次挥空"为什么不算★"。
 *  ⚠ v1.2.0 是**结算时**（出手后 0.2 秒）才扫描的 —— 扑击速度 600+ u/s，0.2 秒能挪 120+ 单位，
 *    那一刻标志/位置早就变了，★ 会被系统性漏记。现在改成出手那一刻采样，结算只用采样值。 */
/**
 * 【v1.4.0】命中帧二次采样（只记账，绝不改原有结算口径）。
 *   · 先快照「出手瞬间」的全部采样字段 → 重新采样 → 记一行对比 → **全部还原**；
 *   · 只在"出手或命中帧任一侧扫到空中特感"时才记（否则多数挥击根本没在打空爆，记了是噪音）。
 * 判读：`出手时=★候选` 且 `命中帧=无候选` ⇒ 那 0.2 秒里特感滑出了判定范围（差一点点，假失败）；
 *       两边都有候选却没砍中 ⇒ 真·该命中却失败（这才值得深挖）。
 */
public Action Timer_HitFrameSample(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client <= 0 || !IsClientInGame(client) || !g_cHitSample.BoolValue)
		return Plugin_Stop;

	// —— 快照出手瞬间的采样结果（SettleWhiff 依赖这些全局量，采完必须还原）——
	int   sBest  = g_iBestTarget[client], sBestCls = g_iBestClass[client];
	float sDist  = g_flBestDist[client],  sAng = g_flBestAng[client];
	float sSpd   = g_flBestSpeed[client], sZ   = g_flBestZDiff[client];
	int   sNear  = g_iNearTarget[client], sNearCls = g_iNearClass[client];
	float sNDist = g_flNearDist[client],  sNAng = g_flNearAng[client];

	SampleBestTarget(client);        // 覆盖成"命中帧"的采样

	int   hBest  = g_iBestTarget[client], hBestCls = g_iBestClass[client];
	float hDist  = g_flBestDist[client],  hAng = g_flBestAng[client];
	float hSpd   = g_flBestSpeed[client], hZ   = g_flBestZDiff[client];

	// —— 还原成出手瞬间的，原有结算口径完全不受影响 ——
	g_iBestTarget[client] = sBest;  g_iBestClass[client] = sBestCls;
	g_flBestDist[client]  = sDist;  g_flBestAng[client]  = sAng;
	g_flBestSpeed[client] = sSpd;   g_flBestZDiff[client] = sZ;
	g_iNearTarget[client] = sNear;  g_iNearClass[client] = sNearCls;
	g_flNearDist[client]  = sNDist; g_flNearAng[client]  = sNAng;

	if (!g_cLog.BoolValue || (sBest == 0 && hBest == 0))
		return Plugin_Stop;          // 两侧都没扫到空中特感 ⇒ 没在打空爆，不记

	char sName[MAX_NAME_LENGTH];
	GetClientName(client, sName, sizeof(sName));

	float est = -1.0, lp = BestLerpMs(client);
	if (lp >= 0.0)
		est = lp + (g_flPingMs[client] / 2.0);

	char sSwing[96], sHit[96];
	if (sBest > 0)
		Format(sSwing, sizeof(sSwing), "%s d=%.0f ang=%.0f dz=%.0f v=%.0f",
			(sBestCls == CLASS_HUNTER) ? "Hunter" : "Jockey", sDist, sAng, sZ, sSpd);
	else
		strcopy(sSwing, sizeof(sSwing), "无候选");
	if (hBest > 0)
		Format(sHit, sizeof(sHit), "%s d=%.0f ang=%.0f dz=%.0f v=%.0f",
			(hBestCls == CLASS_HUNTER) ? "Hunter" : "Jockey", hDist, hAng, hZ, hSpd);
	else
		strcopy(sHit, sizeof(sHit), "无候选");

	char sVerdict[48];
	if (sBest > 0 && hBest == 0)
		strcopy(sVerdict, sizeof(sVerdict), "★滑出判定（差一点点）");
	else if (sBest > 0 && hBest > 0)
		strcopy(sVerdict, sizeof(sVerdict), "★两侧都够得着（真失败）");
	else
		strcopy(sVerdict, sizeof(sVerdict), "出手无、命中帧有");

	LogMessage("[MeleeLag][命中帧] 图=%s 玩家=%s 出手#%d 按键=%s ping=%.0fms 估算滞后=%.0fms 采样延迟=%.2fs ｜ 出手时=%s ｜ 命中帧=%s ⇒ %s",
		g_sMapName, sName, g_iSeq[client], (g_iAtkType[client] == ATK_PUSH) ? "推" : "刀",
		g_flPingMs[client], est, g_cHitSampleDelay.FloatValue, sSwing, sHit, sVerdict);
	g_iHitSampleLines++;
	return Plugin_Stop;
}

void SampleBestTarget(int client)
{
	float cone = g_cCone.FloatValue;
	float maxD = g_cDist.FloatValue;
	int   nActive = 0;
	float minV = g_cSpeed.FloatValue;

	g_iBestTarget[client] = 0;
	g_flBestDist[client] = 99999.0;
	g_flBestAng[client]  = 999.0;
	g_iBestClass[client] = 0;
	g_flBestSpeed[client] = 0.0;
	g_flBestZDiff[client] = 0.0;

	g_iNearTarget[client] = 0;
	g_flNearDist[client]  = 99999.0;
	g_flNearAng[client]   = 999.0;
	g_iNearClass[client]  = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_INFECTED)
			continue;

		int cls = GetEntProp(i, Prop_Send, "m_zombieClass");
		if (cls != CLASS_HUNTER && cls != CLASS_JOCKEY)
			continue;

		// ③ 正在扑 / 正在跳（引擎精确标志）
		bool bActive;
		if (cls == CLASS_HUNTER)
			bActive = IsHunterPouncing(i);
		else
			bActive = IsJockeyLeaping(i);

		// 可选补充判据（默认关）：离地或速度够快也算
		if (!bActive && minV > 0.0)
		{
			float v[3];
			GetEntPropVector(i, Prop_Data, "m_vecVelocity", v);
			if ((GetEntityFlags(i) & FL_ONGROUND) == 0 || GetVectorLength(v) >= minV)
				bActive = true;
		}
		if (!bActive)
			continue;
		nActive++;

		float pos[3];
		GetClientAbsOrigin(i, pos);
		float d = GetVectorDistance(g_flEyePos[client], pos);

		float dir[3];
		SubtractVectors(pos, g_flEyePos[client], dir);
		if (GetVectorLength(dir) < 1.0)
			continue;
		NormalizeVector(dir, dir);
		float dot = GetVectorDotProduct(g_flFwd[client], dir);
		if (dot > 1.0)  dot = 1.0;
		if (dot < -1.0) dot = -1.0;
		float angDeg = RadToDeg(ArcCosine(dot));

		if (d < g_flNearDist[client])
		{
			g_iNearTarget[client] = i;
			g_flNearDist[client]  = d;
			g_flNearAng[client]   = angDeg;
			g_iNearClass[client]  = cls;
		}

		if (d > maxD || angDeg > cone)
			continue;

		if (d < g_flBestDist[client])
		{
			float v2[3];
			GetEntPropVector(i, Prop_Data, "m_vecVelocity", v2);
			g_iBestTarget[client] = i;
			g_flBestDist[client]  = d;
			g_flBestAng[client]   = angDeg;
			g_iBestClass[client]  = cls;
			g_flBestSpeed[client] = GetVectorLength(v2);
			g_flBestZDiff[client] = pos[2] - g_flEyePos[client][2];
		}
	}

	// ---- 采样即时诊断（临时，用来查"为什么明明够得着却不算★"）
	if (g_cDebug.BoolValue && g_cLog.BoolValue && g_iLogBudget > 0 && g_iLogLeft[client] > 0)
	{
		g_iLogBudget--;
		g_iLogLeft[client]--;

		char sName[MAX_NAME_LENGTH];
		GetClientName(client, sName, sizeof(sName));

		LogMessage("[MeleeLag][采样] 玩家=%s 出手#%d 手=%s maxD=%.0f cone=%.0f ｜ 扫到扑/跳特感 %d 只 ｜ ★候选=%d(d=%.0f ang=%.0f) ｜ 最近=%d(d=%.0f ang=%.0f)",
			sName, g_iSeq[client], g_sAtkWeap[client], maxD, cone, nActive,
			g_iBestTarget[client], g_flBestDist[client], g_flBestAng[client],
			g_iNearTarget[client], g_flNearDist[client], g_flNearAng[client]);
	}
}

/** 结算一次"挥空"：记延迟/插值 + 报出手瞬间的采样结果。只记录，不改任何行为。 */
void SettleWhiff(int survivor)
{
	float ping = g_flPingMs[survivor];

	// ---- 延迟/插值分组（每一次挥空都记）
	float lerp = BestLerpMs(survivor);
	float est  = -1.0;
	if (lerp >= 0.0)
	{
		est = lerp + (ping / 2.0);
		g_flEstSum += est;
		if (est > g_flEstMax) g_flEstMax = est;
		g_iEstN++;
		g_flLerpSum += lerp;
		g_iLerpN++;

		if (lerp < 20.0)       g_iLerpLt20++;
		else if (lerp < 50.0)  g_iLerp20to50++;
		else if (lerp < 100.0) g_iLerp50to100++;
		else                   g_iLerp100up++;
	}
	else
	{
		g_iLerpUnknown++;
	}

	if (ping < 20.0)      g_iPingLt20++;
	else if (ping < 50.0) g_iPing20to50++;
	else                  g_iPing50up++;

	// ---- 明细日志（命中 / 普通挥空 / ★ 用同一个输出函数，口径完全一致）
	char sExtra[192];

	if (g_iBestTarget[survivor] <= 0)
	{
		// 解释"为什么不算★"：出手那一刻，全场最近的扑/跳中特感在哪、多远、多大夹角
		if (g_iNearTarget[survivor] > 0 && g_flNearDist[survivor] <= 500.0)
		{
			Format(sExtra, sizeof(sExtra), "普通挥空（出手时最近扑/跳中特感=%s 距离=%.0f 夹角=%.0f°，超出判定 距离%.0f/夹角%.0f°）",
				g_sClassName[g_iNearClass[survivor]], g_flNearDist[survivor], g_flNearAng[survivor],
				g_cDist.FloatValue, g_cCone.FloatValue);
		}
		else
		{
			strcopy(sExtra, sizeof(sExtra), "普通挥空（出手时附近没有扑/跳中的特感）");
		}
		LogAttempt(survivor, sExtra);
		return;
	}

	g_iWhiffPin++;
	if (g_iAtkType[survivor] == ATK_PUSH) g_iWhiffPinPush++;
	else                                  g_iWhiffPinMelee++;

	if (g_iBestClass[survivor] == CLASS_HUNTER) g_iPinHunter++;
	else if (g_iBestClass[survivor] == CLASS_JOCKEY) g_iPinJockey++;

	// ★ 结算时他有没有被控（验证"刀还没落就被扑/被骑"这条假设）
	char sState[28];
	if (IsRiddenByJockey(survivor))
	{
		g_iPinRidden++;
		strcopy(sState, sizeof(sState), "被Jockey骑");
	}
	else if (WasPouncedRecently(survivor))
	{
		g_iPinPounced++;
		strcopy(sState, sizeof(sState), "被Hunter扑");
	}
	else
	{
		g_iPinFree++;
		strcopy(sState, sizeof(sState), "自由（没被控）");
	}

	Format(sExtra, sizeof(sExtra), "★本该命中（出手瞬间采样）职业=%s 距离=%.0f 夹角=%.0f° 高差=%.0f 速度=%.0f ｜ 结算时=%s",
		g_sClassName[g_iBestClass[survivor]], g_flBestDist[survivor], g_flBestAng[survivor],
		g_flBestZDiff[survivor], g_flBestSpeed[survivor], sState);
	LogAttempt(survivor, sExtra);
}

/** 统一的明细行输出（命中 / 普通挥空 / ★ 都走这里，字段与口径完全一致）。 */
void LogAttempt(int client, const char[] sExtra)
{
	if (!g_cLog.BoolValue || g_iLogBudget <= 0 || g_iLogLeft[client] <= 0)
		return;

	g_iLogBudget--;
	g_iLogLeft[client]--;

	char sName[MAX_NAME_LENGTH];
	GetClientName(client, sName, sizeof(sName));

	char sWeap[64];
	ShowText(g_sAtkWeap[client], sWeap, sizeof(sWeap));

	char sInterp[24], sRatio[24], sUpd[24];
	ShowText(g_sCliInterp[client], sInterp, sizeof(sInterp));
	ShowText(g_sCliRatio[client],  sRatio,  sizeof(sRatio));
	ShowText(g_sCliUpd[client],    sUpd,    sizeof(sUpd));

	char sEngineLerp[16], sUpdEng[16], sEst[16], sDerived[16];
	if (g_flLerpMs[client] >= 0.0) Format(sEngineLerp, sizeof(sEngineLerp), "%.0f", g_flLerpMs[client]);
	else                           strcopy(sEngineLerp, sizeof(sEngineLerp), SHOW_OR);
	if (g_iUpdEng[client] >= 0)    Format(sUpdEng, sizeof(sUpdEng), "%d", g_iUpdEng[client]);
	else                           strcopy(sUpdEng, sizeof(sUpdEng), SHOW_OR);

	float der = DerivedLerpMs(client);
	if (der >= 0.0)                Format(sDerived, sizeof(sDerived), "%.0f", der);
	else                           strcopy(sDerived, sizeof(sDerived), SHOW_OR);

	float est = -1.0;
	float lp  = BestLerpMs(client);
	if (lp >= 0.0)
		est = lp + (g_flPingMs[client] / 2.0);
	if (est >= 0.0)                Format(sEst, sizeof(sEst), "%.0f", est);
	else                           strcopy(sEst, sizeof(sEst), SHOW_OR);

	char sAtkName[8];
	strcopy(sAtkName, sizeof(sAtkName), (g_iAtkType[client] == ATK_PUSH) ? "推" : "刀");

	LogMessage("[MeleeLag] 图=%s 玩家=%s 按键=%s(%s) ping=%.0fms 引擎lerp=%sms upd_eng=%s 客户端cl_interp=%s ratio=%s upd=%s 换算lerp=%sms 估算滞后=%sms %s",
		g_sMapName, sName, sAtkName, sWeap, g_flPingMs[client], sEngineLerp, sUpdEng,
		sInterp, sRatio, sUpd, sDerived, sEst, sExtra);
}

/** 他此刻是不是正被 Jockey 骑着（m_jockeyVictim 是 ltt_skill_lite 在服上跑通的写法）。 */
bool IsRiddenByJockey(int survivor)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == survivor || !IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED)
			continue;
		if (GetEntProp(i, Prop_Send, "m_zombieClass") != CLASS_JOCKEY)
			continue;
		if (GetEntPropEnt(i, Prop_Send, "m_jockeyVictim") == survivor)
			return true;
	}
	return false;
}

/** 1 秒内被 Hunter 扑中过（lunge_pounce 事件）。 */
bool WasPouncedRecently(int survivor)
{
	return (g_flPouncedAt[survivor] > 0.0 && (GetGameTime() - g_flPouncedAt[survivor]) < 1.0);
}

public void Event_LungePounce(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("victim"));
	if (victim >= 1 && victim <= MaxClients)
		g_flPouncedAt[victim] = GetGameTime();
}

// ------------------------------------------------------------------ 命令

public Action Cmd_MeleeLag(int client, int args)
{
	char a[16];
	if (args >= 1) GetCmdArg(1, a, sizeof(a));

	if (StrEqual(a, "reset", false))
	{
		ResetStats();
		for (int i = 1; i <= MaxClients; i++)
			ResetClient(i);
		ReplyToCommand(client, "[MeleeLag] 本图统计已清零");
		return Plugin_Handled;
	}

	if (StrEqual(a, "lerp", false))
	{
		ReplyToCommand(client, "[MeleeLag] ——— 在线玩家 lerp / 延迟 / 手上武器（已重新发起 cl_* 查询）———");
		int n = 0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i))
				continue;
			n++;

			int updRate = -1;
			float eng = ReadEngineLerpMs(i, updRate);
			float der = DerivedLerpMs(i);

			char sInterp[24], sRatio[24], sUpd[24], sName[MAX_NAME_LENGTH], sEng[16], sDer[16], sWeap[64];
			ShowText(g_sCliInterp[i], sInterp, sizeof(sInterp));
			ShowText(g_sCliRatio[i],  sRatio,  sizeof(sRatio));
			ShowText(g_sCliUpd[i],    sUpd,    sizeof(sUpd));
			GetClientName(i, sName, sizeof(sName));
			GetClientWeapon(i, sWeap, sizeof(sWeap));
			if (eng >= 0.0) Format(sEng, sizeof(sEng), "%.0fms", eng);
			else            strcopy(sEng, sizeof(sEng), SHOW_OR);
			if (der >= 0.0) Format(sDer, sizeof(sDer), "%.0fms", der);
			else            strcopy(sDer, sizeof(sDer), SHOW_OR);

			ReplyToCommand(client, "[MeleeLag] %s%s：ping=%.0fms ｜ 引擎lerp=%s（upd_eng=%d）｜ cl_interp=%s ratio=%s upd=%s → 换算lerp=%s ｜ 手上=%s（算近战=%s）",
				sName, IsFakeClient(i) ? "(BOT)" : "",
				IsFakeClient(i) ? 0.0 : (GetClientLatency(i, NetFlow_Both) * 1000.0),
				sEng, updRate, sInterp, sRatio, sUpd, sDer,
				sWeap, IsHoldingMelee(i) ? "是" : "否");

			if (!IsFakeClient(i))
				QueryInterp(i);              // 重新查（异步，下次看时刷新）
		}
		if (n == 0)
			ReplyToCommand(client, "[MeleeLag] （没有玩家在线）");
		ReplyToCommand(client, "[MeleeLag] 换算lerp = cl_interp>0 ? cl_interp : cl_interp_ratio/cl_updaterate｜「未读到」= 服务器拿不到，不作假｜cl_* 是异步查询，重启查询后稍等再看");
		return Plugin_Handled;
	}

	ReplyToCommand(client, "[MeleeLag] v%s 图=%s 【心跳 %d 次（0=结算器没跑）】出手 %d（推 %d / 刀 %d）/ 命中 %d（推 %d / 刀 %d）/ 挥空 %d ｜ ★本该命中 %d（推 %d / 刀 %d ｜ Hunter %d / Jockey %d）",
		PLUGIN_VERSION, g_sMapName, g_iTicks, g_iTry, g_iTryPush, g_iTryMelee,
		g_iHit, g_iHitPush, g_iHitMelee, g_iWhiff,
		g_iWhiffPin, g_iWhiffPinPush, g_iWhiffPinMelee, g_iPinHunter, g_iPinJockey);
	ReplyToCommand(client, "[MeleeLag] ★ 结算时状态：被Jockey骑 %d ｜ 被Hunter扑 %d ｜ 自由 %d", g_iPinRidden, g_iPinPounced, g_iPinFree);
	ReplyToCommand(client, "[MeleeLag] 挥空者 ping：<20ms %d / 20~50ms %d / >=50ms %d ｜ lerp：<20ms %d / 20~50 %d / 50~100 %d / >=100 %d / 没读到 %d ｜ 平均 lerp %.0fms（n=%d）",
		g_iPingLt20, g_iPing20to50, g_iPing50up,
		g_iLerpLt20, g_iLerp20to50, g_iLerp50to100, g_iLerp100up, g_iLerpUnknown,
		(g_iLerpN > 0) ? (g_flLerpSum / float(g_iLerpN)) : 0.0, g_iLerpN);
	ReplyToCommand(client, "[MeleeLag] 估算世界滞后（lerp + ping/2）：平均 %.0fms / 最大 %.0fms（n=%d）｜ 判定：锥角 %.0f° 距离 %.0f 补充速度 %.0f（0=关）窗口 %.2fs",
		(g_iEstN > 0) ? (g_flEstSum / float(g_iEstN)) : 0.0, g_flEstMax, g_iEstN,
		g_cCone.FloatValue, g_cDist.FloatValue, g_cSpeed.FloatValue, g_cWindow.FloatValue);
	ReplyToCommand(client, "[MeleeLag] sm_meleelag lerp = 查在线玩家 lerp+武器｜reset = 清零｜ltt_meleelag_bots 1 = 连 BOT 也统计（自测用）");
	return Plugin_Handled;
}
