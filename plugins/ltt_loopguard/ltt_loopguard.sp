#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define TEAM_SURVIVOR 2
#define PLUGIN_VERSION "1.1.1"

ConVar g_cEnable, g_cThreshold, g_cWindow, g_cCooldown, g_cVerbose;

int   g_iFirstLoss;         // Unix 秒(跨地图单调递增)
int   g_iLastFix;           // Unix 秒, 跨地图保留冷却
int   g_iLossCount;
char  g_sWindowMap[64];     // 统计窗口所属的地图名

public Plugin myinfo =
{
	name        = "[LTT] Wipe Loop Guard",
	author      = "DeepSeek Harness",
	description = "检测『灭团→重开关卡』死循环并自动重载地图(2026-09-20 c2m2 事件)",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cEnable    = CreateConVar("ltt_loopguard_enable",    "1",     "1=开启灭团循环自愈", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cThreshold = CreateConVar("ltt_loopguard_threshold", "6",     "窗口内累计这么多次灭团就判定为卡死循环", FCVAR_NOTIFY, true, 2.0, true, 50.0);
	g_cWindow    = CreateConVar("ltt_loopguard_window",    "120.0", "统计窗口(秒)", FCVAR_NOTIFY, true, 10.0, true, 600.0);
	g_cCooldown  = CreateConVar("ltt_loopguard_cooldown",  "300.0", "两次自动重载的最小间隔(秒)", FCVAR_NOTIFY, true, 30.0, true, 3600.0);
	g_cVerbose   = CreateConVar("ltt_loopguard_verbose",   "0",     "1=额外记录回合开始和生还者死亡(排查用)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	HookEvent("mission_lost", Event_MissionLost, EventHookMode_PostNoCopy);
	HookEvent("round_start",  Event_RoundStart,  EventHookMode_PostNoCopy);
	HookEvent("player_death", Event_Death,       EventHookMode_Post);

	RegAdminCmd("sm_loopguard", Cmd_Status, ADMFLAG_ROOT, "查看并重置灭团循环统计");

	AutoExecConfig(true, "ltt_loopguard");
	LogMessage("[LoopGuard] v%s 已加载 (窗口 %.0fs 内 %d 次灭团 -> 自动重载地图)",
		PLUGIN_VERSION, g_cWindow.FloatValue, g_cThreshold.IntValue);
}

int CountAlive()
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
		{
			n++;
		}
	}
	return n;
}

public Action Cmd_Status(int client, int args)
{
	ReplyToCommand(client, "[LoopGuard] 当前窗口内灭团次数 %d / 阈值 %d，窗口地图 %s，存活生还者 %d",
		g_iLossCount, g_cThreshold.IntValue, g_sWindowMap, CountAlive());
	g_iLossCount = 0;
	g_iFirstLoss = 0;
	g_sWindowMap[0] = '\0';
	return Plugin_Handled;
}

/**
 * 判断是否要开一个新窗口。
 *
 * 修 v1.0.0 的 bug：原来用 GetGameTime() 做时间基准，而它**换图就归零**，
 * 导致 现在-首次 变成负数、窗口永不重置，灭团次数跨地图一直累加，
 * 攒够阈值就误判死循环并重载地图。
 * 现在改用 Unix 时间(GetTime, 跨地图单调)，并额外用地图名区分：
 *   真死循环 = 同一张图反复重开，地图名不变 -> 继续累计(必须保留)
 *   真实推进 = 换到新地图          -> 重开窗口
 */
bool NeedNewWindow(const char[] currentMap, int now)
{
	if (g_iLossCount == 0)
	{
		return true;
	}

	int elapsed = now - g_iFirstLoss;

	// 负数(时间被倒拨/异常)或超出窗口都重开
	if (elapsed < 0 || elapsed > g_cWindow.IntValue)
	{
		return true;
	}

	// 换了地图就重开窗口
	if (!StrEqual(g_sWindowMap, currentMap, false))
	{
		return true;
	}

	return false;
}

public void Event_MissionLost(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cEnable.BoolValue)
	{
		return;
	}

	int now          = GetTime();
	int windowSecs   = g_cWindow.IntValue;
	char currentMap[64];
	GetCurrentMap(currentMap, sizeof(currentMap));

	if (NeedNewWindow(currentMap, now))
	{
		g_iLossCount = 0;
		g_iFirstLoss = now;
		strcopy(g_sWindowMap, sizeof(g_sWindowMap), currentMap);
	}

	g_iLossCount++;
	int elapsed = now - g_iFirstLoss;

	int alive = CountAlive();
	LogMessage("[LoopGuard] 灭团计数 %d/%d（窗口已过 %d/%d 秒，地图 %s，当前存活生还者 %d）",
		g_iLossCount, g_cThreshold.IntValue, elapsed, windowSecs, currentMap, alive);

	if (g_iLossCount < g_cThreshold.IntValue)
	{
		return;
	}

	if (now - g_iLastFix < g_cCooldown.IntValue)
	{
		// 【v1.1.1 · 2026-10-02 源码审核修复】冷却期内不再把统计窗口一起清零。
		// 旧代码在这里同时清 g_iLossCount / g_iFirstLoss / g_sWindowMap ⇒ 限流形同虚设：
		// 冷却一过，只要【任意时间】再凑够 threshold 次灭团就会再换一次图，
		// 而"这些灭团发生在同一个窗口内"这个前提被抹掉了（跨几小时的 6 次也算"循环"）。
		// 新行为：保留计数与窗口，冷却期内只是不动手；窗口本身仍由 NeedNewWindow
		// （超过 window 秒或换图）自然重开 ⇒ 既不无限累积、也不会重复换图。
		LogMessage("[LoopGuard] 判定为循环，但距上次自动重载不足 %.0f 秒，本次不动手（保留计数 %d/%d，窗口 %d/%d 秒；窗口内再灭团才会重新判定）",
			g_cCooldown.FloatValue, g_iLossCount, g_cThreshold.IntValue, elapsed, windowSecs);
		return;
	}

	LogMessage("[LoopGuard] **检测到灭团死循环**：%d 秒内 %d 次灭团(地图 %s)，存活生还者 %d → 自动重载地图",
		elapsed, g_iLossCount, currentMap, alive);
	PrintToChatAll("\x04[LoopGuard] \x01检测到关卡卡死循环，正在重新载入本章节...");

	g_iLastFix = now;
	g_iLossCount = 0;
	g_iFirstLoss = 0;
	g_sWindowMap[0] = '\0';

	ServerCommand("changelevel %s", currentMap);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (g_cVerbose.BoolValue)
	{
		LogMessage("[LoopGuard] round_start 存活生还者=%d", CountAlive());
	}
}

public void Event_Death(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cVerbose.BoolValue)
	{
		return;
	}
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim <= 0 || GetClientTeam(victim) != TEAM_SURVIVOR)
	{
		return;
	}
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	char weapon[64];
	event.GetString("weapon", weapon, sizeof(weapon));
	float p[3];
	GetClientAbsOrigin(victim, p);
	LogMessage("[LoopGuard] 生还者死亡 %N <- %N 武器=%s 类型=%d 坐标 %.0f %.0f %.0f",
		victim, attacker, weapon, event.GetInt("damage_type"), p[0], p[1], p[2]);
}
