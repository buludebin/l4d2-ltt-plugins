#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "1.7.0"
#define TEAM_SURVIVOR  2
#define HEAL_PASSES    5        // 回血轮数：覆盖"引擎恢复换图前状态"的时间窗
#define HEAL_INTERVAL  1.5      // 每轮间隔(秒)

// v1.4.0：换图后读图慢的人补血
#define GRACE_SECONDS  25.0     // 换图后多少秒内连进来的，也算"换图在场"，给补血资格
#define LATE_PASS_1    15.0     // 兜底轮次：没有安全区的地图收不到 player_left_safe_area
#define LATE_PASS_2    30.0

// 【v1.5.0 · 2026-10-03 服主实报】"过关回血不恢复黑白状态，有些人过关就是黑白的，回满血还是黑白的"
//
//  根因：**L4D2 的黑白不由血量决定**，而是由 `m_currentReviveCount`（被扶起过几次）决定 ——
//    倒地->被扶起一次之后这个值就 > 0，人就一直是黑白，**只有用急救包才能真正恢复**。
//    本插件 v1.4.0 的 RestoreFullHealth() 只写了 m_iMaxHealth / SetEntityHealth / 清 m_healthBuffer，
//    **从头到尾没碰 m_currentReviveCount** ⇒ 血补满了，人还是黑的。这就是那个 bug。
//  证据（同服已装的第三方插件就做对了这件事）：
//    `l4d2_survivor_transition.sp:277-279` 在换图时
//      SetEntProp(client, Prop_Send, "m_isGoingToDie", 0);
//      SetEntProp(client, Prop_Send, "m_currentReviveCount", 0);
//    —— 这两句才是"清黑白"。
//  修法：新增 `ltt_levelheal_clearbw`（默认 1），在每一轮回血里一起清
//    `m_currentReviveCount` 与 `m_isGoingToDie`（两者都会随换图被引擎恢复，所以要 5 轮都清）。
//    ⚠ 属性可写性先探测（FindSendPropInfo），属性不存在时不去写，避免刷错误日志。
ConVar g_cClearBW;
bool   g_bHasReviveCount;
bool   g_bHasGoingToDie;

ConVar g_cEnable;
ConVar g_cDelay;
ConVar g_cClearTemp;
ConVar g_cBots;
ConVar g_cRevive;
ConVar g_cEmergency;      // 【v1.6.0】团灭重开"0 秒团灭"修复开关
ConVar g_cWatch;          // 【v1.7.0】帧级看门狗开关
ConVar g_cWatchWindow;    // 【v1.7.0】看门狗窗口（秒）

// 【v1.7.0】帧级看门狗：引擎是在 round_start **之后**才把"死/濒死"状态塞回来的，
// 且同一秒就判全灭 ⇒ round_start 钩子必然抢不到，只能靠逐帧盯一小段时间。
float g_flWatchUntil;     // 窗口截止（GetGameTime）
int   g_iWatchFrames;     // 窗口已过帧数
bool  g_bWatchHit;        // 本窗口是否已经抢到过（只记一次日志）

// 【v1.6.0】紧急连发的间隔表（秒）。第 1 发在 round_start 当帧**同步**跑完，
// 这串是随后兜底用的 —— 因为 L4D_RespawnPlayer 复活可能要下一帧才真正落地。
#define EMERGENCY_COUNT 5
float g_flEmergencyDelay[EMERGENCY_COUNT] = {0.05, 0.15, 0.35, 0.70, 1.20};
int    g_iEmergency;
Handle g_hEmergencyTimer;

bool g_bHasHealthBuffer;
bool g_bHasRespawn;
bool g_bHasIncapProp;
int  g_iPass;
Handle g_hPassTimer;

// 本图"换图时在场、但还没补到血"的玩家。读图慢的人 round_start 那 5 轮跑完
// 都还没被分配到生还者队伍，会被整轮跳过，只能靠这个标记等他们真正出场时补。
bool  g_bPending[MAXPLAYERS + 1];
float g_flMapStart;
int   g_iLateHealed;

public Plugin myinfo =
{
	name        = "[LTT] Level Full Heal",
	author      = "DeepSeek Harness",
	description = "过关(进入下一章节)后所有生还者回满血，并可复活阵亡队友；v1.6.0 修团灭重开「0 秒团灭」",
	version     = PLUGIN_VERSION,
	url         = "N/A"
};

public void OnPluginStart()
{
	CreateConVar("ltt_levelheal_version", PLUGIN_VERSION, "过关回满血插件版本", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	g_cEnable    = CreateConVar("ltt_levelheal_enable",    "1",   "总开关: 1=过关回满血, 0=关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cDelay     = CreateConVar("ltt_levelheal_delay",     "2.5", "新关卡开始后第一次回血的延迟(秒)。太早会被引擎恢复的换图前状态覆盖。", FCVAR_NOTIFY, true, 0.0, true, 10.0);
	g_cClearTemp = CreateConVar("ltt_levelheal_cleartemp", "1",   "是否同时清除虚血(临时血量)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	// 【v1.5.0】清黑白：黑白由 m_currentReviveCount 决定，只补血**不会**清掉它
	g_cClearBW   = CreateConVar("ltt_levelheal_clearbw",   "1",   "【v1.5.0】是否同时清除【黑白状态】：清 m_currentReviveCount 与 m_isGoingToDie（补满血不会自动清黑白，必须清这两个属性）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cBots      = CreateConVar("ltt_levelheal_bots",      "1",   "是否也给 BOT 回血", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cRevive    = CreateConVar("ltt_levelheal_revive",    "1",   "是否复活阵亡的生还者(过关后自动归队并满血)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	// 【v1.6.0】c2m2「重开就 0 秒团灭」修复：round_start 当帧抢在导演判死之前把人救活
	// 【v1.7.0】帧级看门狗
	g_cWatch       = CreateConVar("ltt_levelheal_watch",        "1",   "【v1.7.0】帧级看门狗：round_start 后开一个时间窗，每游戏帧检查一次「有人死了/濒死」并当场救回（0=关）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cWatchWindow = CreateConVar("ltt_levelheal_watch_window", "2.0", "【v1.7.0】看门狗窗口长度（秒）。引擎是在 round_start 之后才恢复坏状态，窗口要盖住那一下", FCVAR_NOTIFY, true, 0.0, true, 10.0);
	g_cEmergency = CreateConVar("ltt_levelheal_emergency", "1",   "【v1.6.0】团灭重开「0 秒团灭」修复：round_start 当帧检测到有人不是活的就立即复活/补血，并追加 5 发紧急连发（0=关，恢复 v1.5.0 行为）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	AutoExecConfig(true, "ltt_levelheal");

	// 虚血属性可写性检查（属性不存在时不去写，避免刷错误日志）
	g_bHasHealthBuffer = (FindSendPropInfo("CTerrorPlayer", "m_healthBuffer") > 0
	                   && FindSendPropInfo("CTerrorPlayer", "m_healthBufferTime") > 0);
	// 复活依赖 left4dhooks（L4D_RespawnPlayer），不可用时自动跳过复活、只做回血
	g_bHasRespawn = (GetFeatureStatus(FeatureType_Native, "L4D_RespawnPlayer") == FeatureStatus_Available);
	// 倒地保护用：倒地的人 IsPlayerAlive 仍为真，补血会把他从倒地状态拉起来
	g_bHasIncapProp = (FindSendPropInfo("CTerrorPlayer", "m_isIncapacitated") > 0);
	// 【v1.5.0】黑白状态的两个属性（可写性先探测）
	g_bHasReviveCount = (FindSendPropInfo("CTerrorPlayer", "m_currentReviveCount") > 0);
	g_bHasGoingToDie  = (FindSendPropInfo("CTerrorPlayer", "m_isGoingToDie") > 0);
	LogMessage("[LevelHeal] v%s 已加载 | 虚血属性可写: %s | 复活可用: %s | 黑白属性可写: 倒地次数=%s 濒死=%s | 清黑白=%d",
		PLUGIN_VERSION, g_bHasHealthBuffer ? "是" : "否", g_bHasRespawn ? "是" : "否",
		g_bHasReviveCount ? "是" : "否", g_bHasGoingToDie ? "是" : "否", g_cClearBW.IntValue);

	// 只在"新关卡已经开局"之后回血。
	//
	// 为什么不用 map_transition：那个事件触发在**旧地图**上，此时加的血会在换图时
	// 被引擎"按换图前存档恢复生还者状态"覆盖掉 —— v1.2.0 的现象就是过关一瞬间
	// 加了血、载完图又退回去。
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	// v1.4.0：读图慢的人 —— 等他们真正出生/出安全区时再补
	HookEvent("player_spawn",           Event_PlayerSpawn,    EventHookMode_Post);
	// 必须用 Post：PostNoCopy 下事件数据不可读，event.GetInt() 会抛
	// "Invalid game event handle 0" 异常
	HookEvent("player_left_safe_area",  Event_LeftSafeArea,   EventHookMode_Post);

	RegAdminCmd("sm_lheal", Cmd_HealAll, ADMFLAG_ROOT, "立即给所有生还者回满血(含复活阵亡者)");
	RegAdminCmd("sm_lhealstatus", Cmd_Status, ADMFLAG_ROOT, "查看各生还者血量/队伍/待补血状态");
	// 【v1.5.0】只清黑白：不动血量、不复活 —— 用来当场验证"回满血还是黑白"那个修复
	RegAdminCmd("sm_bwclear", Cmd_BWClear, ADMFLAG_ROOT, "立即清除所有生还者的黑白状态(不改血量、不复活)");
	RegAdminCmd("sm_bwtest",  Cmd_BWTest,  ADMFLAG_ROOT, "黑白读写自检：在 BOT 上造黑白再清掉，验证写路径");
}

/**
 * 换图：给所有还连着的玩家打上"待补血"标记。
 * 换图时客户端不会断开（只是还在读图），所以这里能把慢的人全圈进来。
 */
public void OnMapStart()
{
	g_flMapStart = GetGameTime();
	g_iLateHealed = 0;

	for (int i = 1; i <= MaxClients; i++)
		g_bPending[i] = false;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
			g_bPending[i] = true;
	}

	// 兜底：没安全区的地图收不到 player_left_safe_area
	CreateTimer(LATE_PASS_1, Timer_LatePass, _, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(LATE_PASS_2, Timer_LatePass, _, TIMER_FLAG_NO_MAPCHANGE);
}

/** 换图后短时间内进来的（含重连回来的）也算换图在场 */
public void OnClientPutInServer(int client)
{
	if (IsFakeClient(client))
		return;
	if (GetGameTime() - g_flMapStart <= GRACE_SECONDS)
		g_bPending[client] = true;
}

/** 读图慢的人一出生就开始盯 */
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || client > MaxClients || !g_bPending[client])
		return;

	// 出生瞬间引擎可能还在写换图前的血量，等一下再补
	CreateTimer(1.5, Timer_LateHeal, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

/** 走出安全区 = 已经彻底载入完毕，这时候的血量才是最终值 */
public void Event_LeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || client > MaxClients || !g_bPending[client])
		return;

	LateHeal(client, "出安全区");
}

public Action Timer_LateHeal(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client < 1 || client > MaxClients)
		return Plugin_Stop;

	LateHeal(client, "出生后补");
	return Plugin_Stop;
}

public Action Timer_LatePass(Handle timer)
{
	int n = HealPending();

	// 兜底轮也补到人了，说明确实有慢的；没补到就算了
	if (n > 0)
		LogMessage("[LevelHeal] 兜底轮补血 %d 人", n);

	return Plugin_Stop;
}

/** 倒地的人 IsPlayerAlive 依然为真，这时候补血相当于把他从地上拉起来，跳过 */
bool IsDown(int client)
{
	return (g_bHasIncapProp && GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0);
}

void LateHeal(int client, const char[] why)
{
	if (!g_cEnable.BoolValue || !g_bPending[client])
		return;
	if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR)
		return;
	if (!IsPlayerAlive(client) || IsDown(client))
		return;
	if (IsFakeClient(client) && !g_cBots.BoolValue)
		return;

	g_bPending[client] = false;
	RestoreFullHealth(client);
	g_iLateHealed++;

	char map[64];
	GetCurrentMap(map, sizeof(map));
	LogMessage("[LevelHeal] 迟到的 %N 补满血 (%s, 地图 %s, 已补 %d 人)",
		client, why, map, g_iLateHealed);
}

/** 只处理还没补到的待补血玩家 */
int HealPending()
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bPending[i])
			continue;
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
			continue;
		if (IsDown(i))   // 倒地中的先放过，等他被扶起来/重新出场再补
			continue;
		if (IsFakeClient(i) && !g_cBots.BoolValue)
			continue;

		g_bPending[i] = false;
		RestoreFullHealth(i);
		g_iLateHealed++;
		n++;
	}
	return n;
}

public Action Cmd_Status(int client, int args)
{
	char map[64];
	GetCurrentMap(map, sizeof(map));
	ReplyToCommand(client, "[过关回满血] 地图 %s | 开局 %.1f 秒前 | 已补迟到者 %d 人",
		map, GetGameTime() - g_flMapStart, g_iLateHealed);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		// 【v1.5.0】把两个"黑白"属性的**原始值**都打出来 —— 现场就能确认到底哪个才是黑白标志
		int iRev = g_bHasReviveCount ? GetEntProp(i, Prop_Send, "m_currentReviveCount") : -1;
		int iDie = g_bHasGoingToDie  ? GetEntProp(i, Prop_Send, "m_isGoingToDie")        : -1;
		ReplyToCommand(client, "  %-4d %-24N 队伍=%d 存活=%s 血=%d/%d 虚血=%.0f 倒地次数=%d 濒死=%d 黑白=%s 待补=%s",
			i, i,
			GetClientTeam(i),
			IsPlayerAlive(i) ? "是" : "否",
			IsPlayerAlive(i) ? GetClientHealth(i) : 0,
			GetEntProp(i, Prop_Send, "m_iMaxHealth"),
			g_bHasHealthBuffer ? GetEntPropFloat(i, Prop_Send, "m_healthBuffer") : 0.0,
			iRev, iDie,
			(iRev > 0 || iDie > 0) ? "是" : "否",
			g_bPending[i] ? "是" : "否");
	}
	return Plugin_Handled;
}

public void OnMapEnd()
{
	// 换图时清掉未跑完的轮次，避免跨图残留
	delete g_hPassTimer;
	g_iPass = 0;
	// 【v1.6.0】紧急连发也要一起清
	delete g_hEmergencyTimer;
	g_iEmergency = 0;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cEnable.BoolValue)
		return;

	// 【v1.6.0 · 2026-10-08 车主实报 c2m2「重开就 0 秒团灭」修复】
	// 引擎日志铁证：wipe 重开的回合里引擎会走
	//   spawned as … → Round_Start → "Restoring player … after changelevel"
	//   → Round_Start(第2次) → L4D_Scenario_Survivors_Dead → Round_End
	// 也就是把生还者**恢复成"已死"状态**，导演在同一秒判全灭（本局计时 0:00，且与 bot 数量无关）。
	// 旧版第一轮回血在 g_cDelay(2.5) 秒后 ⇒ 回合早已结束，那几轮全落在"两局之间"。
	// 这里在 round_start **当帧同步**先救一次 —— 日志顺序显示第 2 次 Round_Start 正好夹在
	// "引擎恢复存档"与"导演判死"之间，那就是唯一的窗口。
	// 【v1.6.1】每次 round_start 打一行状态快照 —— 复现时这行就是铁证
	LogRoundStartSnapshot();

	// 【v1.7.0】开窗：接下来 watch_window 秒内逐帧盯"死/濒死"
	if (g_cWatch.BoolValue && g_cWatchWindow.FloatValue > 0.0)
	{
		g_flWatchUntil  = GetGameTime() + g_cWatchWindow.FloatValue;
		g_iWatchFrames  = 0;
		g_bWatchHit     = false;
	}

	if (g_cEmergency.BoolValue && HasUncleanSurvivor())
	{
		char map[64];
		GetCurrentMap(map, sizeof(map));
		LogMessage("[LevelHeal] v1.6.1 重开检测到有人**不是干净的活人**（濒死标志/血量/存活任一异常，疑似「死着回来」）→ round_start 当帧立即补一轮 + 紧急连发 %d 发（地图 %s）",
			EMERGENCY_COUNT, map);

		HealAll(true);                 // 当帧同步：复活 + 清濒死/黑白 + 给血
		g_iEmergency = 0;
		delete g_hEmergencyTimer;
		g_hEmergencyTimer = CreateTimer(g_flEmergencyDelay[0], Timer_EmergencyPass, _, TIMER_FLAG_NO_MAPCHANGE);
	}

	StartHealPasses(g_cDelay.FloatValue);
}

/** 【v1.6.0】紧急连发的一发。 */
public Action Timer_EmergencyPass(Handle timer)
{
	g_hEmergencyTimer = null;

	if (!g_cEnable.BoolValue || !g_cEmergency.BoolValue)
	{
		g_iEmergency = 0;
		return Plugin_Stop;
	}

	HealAll(true);

	if (++g_iEmergency < EMERGENCY_COUNT)
		g_hEmergencyTimer = CreateTimer(g_flEmergencyDelay[g_iEmergency], Timer_EmergencyPass, _, TIMER_FLAG_NO_MAPCHANGE);
	else
		g_iEmergency = 0;

	return Plugin_Stop;
}

/** 【v1.6.1】生还者里是否有人"**不是干净的活人**"。
 *
 *  为什么不能只看 IsPlayerAlive：2026-10-08 v1.6.0 实测（家里 c2m2）——
 *  引擎在 round_start 的同一秒先 `Restoring player … after changelevel`，
 *  那一刻人**还是 IsPlayerAlive 的**（所以 v1.6.0 一次都没触发），
 *  但引擎已经把"濒死/血量"这类状态恢复回来了，人随后（<2.5 秒）就真死。
 *  ⇒ 判据必须把"濒死标志"和"血量不满"也算进来，才能在"恢复存档"与"导演判死"之间拦住。
 *
 *  只在 round_start 调用，此时正常出生的人必然是满血、无濒死标志 ⇒ 正常回合不会误触发。
 *  与 HealAll 同一套过滤口径：只看生还者队伍；ltt_levelheal_bots=0 时忽略 BOT。 */
bool HasUncleanSurvivor()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		if (IsFakeClient(i) && !g_cBots.BoolValue)
			continue;

		if (!IsPlayerAlive(i))
			return true;
		if (g_bHasGoingToDie && GetEntProp(i, Prop_Send, "m_isGoingToDie") != 0)
			return true;
		if (GetClientHealth(i) < 100)
			return true;
	}
	return false;
}

/** 【v1.7.0】帧级看门狗。
 *  为什么必须逐帧：引擎是在 `round_start` **之后**打
 *  `Restoring player … after changelevel`，把"已死/濒死"塞回来，
 *  并在**同一秒**触发 `L4D_Scenario_Survivors_Dead` ⇒
 *  round_start 钩子（跑在恢复之前）无论如何判据都抢不到，只能逐帧抢在导演判死之前。
 *  判据只用最硬的两条（不碰血量，避免窗口内误补血影响手感）：
 *    · !IsPlayerAlive
 *    · m_isGoingToDie != 0（属性可写时）
 */
public void OnGameFrame()
{
	if (g_flWatchUntil <= 0.0)
		return;
	if (!g_cEnable.BoolValue)
	{
		g_flWatchUntil = 0.0;
		return;
	}
	if (GetGameTime() > g_flWatchUntil)
	{
		g_flWatchUntil = 0.0;
		return;
	}

	g_iWatchFrames++;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		if (IsFakeClient(i) && !g_cBots.BoolValue)
			continue;

		bool bBad = false;
		if (!IsPlayerAlive(i))
			bBad = true;
		else if (g_bHasGoingToDie && GetEntProp(i, Prop_Send, "m_isGoingToDie") != 0)
			bBad = true;

		if (!bBad)
			continue;

		// 当场救回：清濒死/黑白 + 复活 + 补满血（HealAll 内部会做全套）
		HealAll(true);
		if (!g_bWatchHit)
		{
			char map[64];
			GetCurrentMap(map, sizeof(map));
			LogMessage("[LevelHeal] v1.7.0 帧级看门狗**抢到了**：round_start 后第 %d 帧发现有人死/濒死 → 已当场救回（地图 %s，窗口 %.1fs）",
				g_iWatchFrames, map, g_cWatchWindow.FloatValue);
			g_bWatchHit = true;
		}
		break;
	}
}

/** 【v1.6.1】round_start 状态快照：把每个生还者的队伍/存活/血量/濒死/倒地次数据打成一行日志。
 *  用途：下一次「重开就 0 秒团灭」复现时，这行能直接告诉我们**引擎把哪个属性恢复成了什么**，
 *  不用再靠猜。 */
void LogRoundStartSnapshot()
{
	if (!g_cEnable.BoolValue)
		return;

	char map[64], line[512];
	GetCurrentMap(map, sizeof(map));
	Format(line, sizeof(line), "[LevelHeal] v1.6.1 round_start 快照 (地图 %s):", map);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		char one[128];
		Format(one, sizeof(one), " #%d(%N)%s 血=%d 濒死=%d 倒地次数=%d%s",
			i, i,
			IsFakeClient(i) ? "[BOT]" : "[人]",
			IsPlayerAlive(i) ? GetClientHealth(i) : 0,
			g_bHasGoingToDie  ? GetEntProp(i, Prop_Send, "m_isGoingToDie")        : -1,
			g_bHasReviveCount ? GetEntProp(i, Prop_Send, "m_currentReviveCount")  : -1,
			IsPlayerAlive(i) ? "" : "【已死】");
		StrCat(line, sizeof(line), one);
	}

	LogMessage("%s", line);
}

/** 【LTT 补丁 2026-10-06 c2m2 事件】复活后一帧补血。
 *  L4D_RespawnPlayer 当帧可能还没就绪，所以延后一帧（≈16ms）补满血 ——
 *  彻底消掉"复活后要等下一轮（1.5 秒）才有血"的 1 血窗口：bot 就是在这个窗口里被小僵尸啃死的。 */
public void Frame_RestoreAfterRespawn(any userid)
{
	int client = GetClientOfUserId(userid);
	if (client <= 0 || !IsClientInGame(client))
		return;
	if (GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client))
		return;
	RestoreFullHealth(client);
}
void StartHealPasses(float delay)
{
	if (!g_cEnable.BoolValue)
		return;

	delete g_hPassTimer;
	g_iPass = 0;
	g_hPassTimer = CreateTimer(delay, Timer_HealPass, _, TIMER_FLAG_NO_MAPCHANGE);
}

/** 【v1.5.0】sm_bwclear：只清黑白，不动血、不复活。
 *  为什么单独做一个：`sm_lheal` 会顺带复活阵亡队友（中途复活 = 不公平），
 *  而"验证黑白修复"只需要清属性这一件事。 */
public Action Cmd_BWClear(int client, int args)
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		// 【v1.5.0】打印"清前 → 清后"的原始值：这样**下一次真的有黑白的人时**，
		// 命令自己的输出就能当证据（不用再等一轮观察）。
		int a = g_bHasReviveCount ? GetEntProp(i, Prop_Send, "m_currentReviveCount") : -1;
		int b = g_bHasGoingToDie  ? GetEntProp(i, Prop_Send, "m_isGoingToDie")        : -1;
		bool ch = ClearBlackWhite(i);
		int c = g_bHasReviveCount ? GetEntProp(i, Prop_Send, "m_currentReviveCount") : -1;
		int d = g_bHasGoingToDie  ? GetEntProp(i, Prop_Send, "m_isGoingToDie")        : -1;
		if (ch)
		{
			n++;
			ReplyToCommand(client, "  %N：倒地次数 %d→%d，濒死 %d→%d", i, a, c, b, d);
			LogMessage("[LevelHeal] sm_bwclear 清了 %N：倒地次数 %d→%d，濒死 %d→%d", i, a, c, b, d);
		}
	}
	ReplyToCommand(client, "[过关回满血] 已清黑白 %d 人（未改血量、未复活）", n);
	return Plugin_Handled;
}

/** 【v1.5.0】sm_bwtest：黑白读写的**自检**。
 *  做法：在一只 **BOT** 身上先把 m_currentReviveCount / m_isGoingToDie 设成 1（模拟黑白），
 *  再调用 ClearBlackWhite()，把 设置前→设置后→清除后 三个值都打进日志。
 *  为什么必须自检：真人不可能随叫随到地变黑白，"等下次有人黑白"不是可复现的验证。
 *  ⚠ 只碰 BOT，绝不动真人。 */
public Action Cmd_BWTest(int client, int args)
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsFakeClient(i))
			continue;
		if (!g_bHasReviveCount || !g_bHasGoingToDie)
			break;

		int before = GetEntProp(i, Prop_Send, "m_currentReviveCount");
		SetEntProp(i, Prop_Send, "m_currentReviveCount", 1);
		SetEntProp(i, Prop_Send, "m_isGoingToDie", 1);
		int setr = GetEntProp(i, Prop_Send, "m_currentReviveCount");
		int setd = GetEntProp(i, Prop_Send, "m_isGoingToDie");
		ClearBlackWhite(i);
		int clrr = GetEntProp(i, Prop_Send, "m_currentReviveCount");
		int clrd = GetEntProp(i, Prop_Send, "m_isGoingToDie");

		LogMessage("[LevelHeal] 黑白自检 BOT #%d：原本 倒地次数=%d → 设成(%d/%d) → 清除后(%d/%d) %s",
			i, before, setr, setd, clrr, clrd, (clrr == 0 && clrd == 0) ? "【通过】" : "【失败】");
		n++;
	}
	if (n == 0)
		ReplyToCommand(client, "[过关回满血] 黑白自检：场上的生还者里没有 BOT，无法自检（全真人）");
	else
		ReplyToCommand(client, "[过关回满血] 黑白自检完成：%d 个 BOT，结果见日志（找「黑白自检」）", n);
	return Plugin_Handled;
}

public Action Cmd_HealAll(int client, int args){
	int n = HealAll(true);
	ReplyToCommand(client, "[过关回满血] 第一轮已处理 %d 名生还者，后续还会补 %d 轮", n, HEAL_PASSES - 1);
	StartHealPasses(1.5);
	return Plugin_Handled;
}

public Action Timer_HealPass(Handle timer)
{
	g_hPassTimer = null;

	HealAll(true);

	if (++g_iPass < HEAL_PASSES)
	{
		g_hPassTimer = CreateTimer(HEAL_INTERVAL, Timer_HealPass, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		g_iPass = 0;
	}

	return Plugin_Stop;
}

/**
 * 对全队做一轮处理。
 *
 * 复活的玩家本轮**只复活、不设血**，直接 continue 交给下一轮 ——
 * L4D_RespawnPlayer 要到引擎下一帧才真正落地，紧接着设的血会被覆盖。
 */
int HealAll(bool bAllowRevive)
{
	int healed, revived;
	char map[64];
	GetCurrentMap(map, sizeof(map));

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		if (GetClientTeam(i) != TEAM_SURVIVOR)
			continue;
		if (IsFakeClient(i) && !g_cBots.BoolValue)
			continue;

		if (!IsPlayerAlive(i))
		{
			if (!bAllowRevive || !g_cRevive.BoolValue || !g_bHasRespawn)
				continue;

			L4D_RespawnPlayer(i, true);
			revived++;
			RequestFrame(Frame_RestoreAfterRespawn, GetClientUserId(i));   // 【LTT 补丁】复活后当帧立刻补血，消掉"1 血窗口"
			continue;
		}

		if (RestoreFullHealth(i))
		{
			g_bPending[i] = false;   // 已经补到了，不用等他出生再补一次
			healed++;
		}
	}

	if (healed > 0 || revived > 0)
		LogMessage("[LevelHeal] 第 %d/%d 轮 (地图 %s): 回满血 %d 人，复活 %d 人",
			g_iPass + 1, HEAL_PASSES, map, healed, revived);

	return healed;
}

/**
 * 把单个生还者恢复成满血。
 * 生还者的 m_iMaxHealth 正常是 100；刚归队的阵亡者可能读到被压低的旧值，
 * 所以只在低于 100 时抬到 100（只抬不降，不影响任何调高血上限的插件）。
 */
bool RestoreFullHealth(int client)
{
	int maxhp = GetEntProp(client, Prop_Send, "m_iMaxHealth");

	if (maxhp < 100)
		maxhp = 100;
	if (maxhp > 9999)
		maxhp = 100;

	if (GetEntProp(client, Prop_Data, "m_iMaxHealth") < maxhp)
		SetEntProp(client, Prop_Data, "m_iMaxHealth", maxhp);
	if (GetEntProp(client, Prop_Send, "m_iMaxHealth") < maxhp)
		SetEntProp(client, Prop_Send, "m_iMaxHealth", maxhp);

	SetEntityHealth(client, maxhp);

	if (g_cClearTemp.BoolValue && g_bHasHealthBuffer)
	{
		SetEntPropFloat(client, Prop_Send, "m_healthBuffer", 0.0);
		SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", 0.0);
	}

	// 【v1.5.0】清黑白（服主 2026-10-03 实报"回满血还是黑白的"）。
	// 只补血不清这两个属性的结果是：血条满了、画面依旧是黑白、下一波倒地即死。
	//   · m_currentReviveCount > 0  ⇒ 被扶起过 ⇒ 黑白（只有急救包能清）——这是根因
	//   · m_isGoingToDie            ⇒ 濒死标志，与黑白一起出现
	// 两轮之间引擎可能又按"换图前存档"恢复，所以每一轮都清（本插件共 5 轮）。
	if (g_cClearBW.BoolValue)
		ClearBlackWhite(client);

	return true;
}

/** 【v1.5.0】只清黑白状态（不动血量、不复活）。
 *  单独拆出来是为了 `sm_bwclear` —— 服主报障时可以当场验证，且没有"中途复活队友"的副作用。
 *  @return 真的清掉了返回 true（本来就不黑白的返回 false） */
bool ClearBlackWhite(int client)
{
	bool bChanged = false;

	if (g_bHasReviveCount && GetEntProp(client, Prop_Send, "m_currentReviveCount") != 0)
	{
		SetEntProp(client, Prop_Send, "m_currentReviveCount", 0);
		bChanged = true;
	}
	if (g_bHasGoingToDie && GetEntProp(client, Prop_Send, "m_isGoingToDie") != 0)
	{
		SetEntProp(client, Prop_Send, "m_isGoingToDie", 0);
		bChanged = true;
	}
	return bChanged;
}
