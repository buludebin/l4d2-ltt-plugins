#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "1.4.0"
#define TEAM_SURVIVOR  2
#define HEAL_PASSES    5        // 回血轮数：覆盖"引擎恢复换图前状态"的时间窗
#define HEAL_INTERVAL  1.5      // 每轮间隔(秒)

// v1.4.0：换图后读图慢的人补血
#define GRACE_SECONDS  25.0     // 换图后多少秒内连进来的，也算"换图在场"，给补血资格
#define LATE_PASS_1    15.0     // 兜底轮次：没有安全区的地图收不到 player_left_safe_area
#define LATE_PASS_2    30.0

ConVar g_cEnable;
ConVar g_cDelay;
ConVar g_cClearTemp;
ConVar g_cBots;
ConVar g_cRevive;

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
	description = "过关(进入下一章节)后所有生还者回满血，并可复活阵亡队友",
	version     = PLUGIN_VERSION,
	url         = "N/A"
};

public void OnPluginStart()
{
	CreateConVar("ltt_levelheal_version", PLUGIN_VERSION, "过关回满血插件版本", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	g_cEnable    = CreateConVar("ltt_levelheal_enable",    "1",   "总开关: 1=过关回满血, 0=关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cDelay     = CreateConVar("ltt_levelheal_delay",     "2.5", "新关卡开始后第一次回血的延迟(秒)。太早会被引擎恢复的换图前状态覆盖。", FCVAR_NOTIFY, true, 0.0, true, 10.0);
	g_cClearTemp = CreateConVar("ltt_levelheal_cleartemp", "1",   "是否同时清除虚血(临时血量)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cBots      = CreateConVar("ltt_levelheal_bots",      "1",   "是否也给 BOT 回血", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cRevive    = CreateConVar("ltt_levelheal_revive",    "1",   "是否复活阵亡的生还者(过关后自动归队并满血)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	AutoExecConfig(true, "ltt_levelheal");

	// 虚血属性可写性检查（属性不存在时不去写，避免刷错误日志）
	g_bHasHealthBuffer = (FindSendPropInfo("CTerrorPlayer", "m_healthBuffer") > 0
	                   && FindSendPropInfo("CTerrorPlayer", "m_healthBufferTime") > 0);
	// 复活依赖 left4dhooks（L4D_RespawnPlayer），不可用时自动跳过复活、只做回血
	g_bHasRespawn = (GetFeatureStatus(FeatureType_Native, "L4D_RespawnPlayer") == FeatureStatus_Available);
	// 倒地保护用：倒地的人 IsPlayerAlive 仍为真，补血会把他从倒地状态拉起来
	g_bHasIncapProp = (FindSendPropInfo("CTerrorPlayer", "m_isIncapacitated") > 0);
	LogMessage("[LevelHeal] v%s 已加载 | 虚血属性可写: %s | 复活可用: %s",
		PLUGIN_VERSION, g_bHasHealthBuffer ? "是" : "否", g_bHasRespawn ? "是" : "否");

	// 只在"新关卡已经开局"之后回血。
	//
	// 为什么不用 map_transition：那个事件触发在**旧地图**上，此时加的血会在换图时
	// 被引擎"按换图前存档恢复生还者状态"覆盖掉 —— v1.2.0 的现象就是过关一瞬间
	// 加了血、载完图又退回去。
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	// v1.4.0：读图慢的人 —— 等他们真正出生/出安全区时再补
	HookEvent("player_spawn",           Event_PlayerSpawn,    EventHookMode_Post);
	HookEvent("player_left_safe_area",  Event_LeftSafeArea,   EventHookMode_PostNoCopy);

	RegAdminCmd("sm_lheal", Cmd_HealAll, ADMFLAG_ROOT, "立即给所有生还者回满血(含复活阵亡者)");
	RegAdminCmd("sm_lhealstatus", Cmd_Status, ADMFLAG_ROOT, "查看各生还者血量/队伍/待补血状态");
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

		ReplyToCommand(client, "  %-4d %-24N 队伍=%d 存活=%s 血=%d/%d 虚血=%.0f 待补=%s",
			i, i,
			GetClientTeam(i),
			IsPlayerAlive(i) ? "是" : "否",
			IsPlayerAlive(i) ? GetClientHealth(i) : 0,
			GetEntProp(i, Prop_Send, "m_iMaxHealth"),
			g_bHasHealthBuffer ? GetEntPropFloat(i, Prop_Send, "m_healthBuffer") : 0.0,
			g_bPending[i] ? "是" : "否");
	}
	return Plugin_Handled;
}

public void OnMapEnd()
{
	// 换图时清掉未跑完的轮次，避免跨图残留
	delete g_hPassTimer;
	g_iPass = 0;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cEnable.BoolValue)
		return;
	StartHealPasses(g_cDelay.FloatValue);
}

void StartHealPasses(float delay)
{
	if (!g_cEnable.BoolValue)
		return;

	delete g_hPassTimer;
	g_iPass = 0;
	g_hPassTimer = CreateTimer(delay, Timer_HealPass, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Cmd_HealAll(int client, int args)
{
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
			continue;                 // ← 本轮不设血，交给后续轮次
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

	return true;
}
