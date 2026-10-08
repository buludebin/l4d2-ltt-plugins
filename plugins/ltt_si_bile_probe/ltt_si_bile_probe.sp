/**
 *  ltt_si_bile_probe v1.0.1 —— 只在"有人被胆汁喷中"的窗口里记账（**零动作**）
 *
 *  v1.0.1 修两处：
 *   ①全队倒地/没人活着时直接跳过 —— v1.0.0 会在团灭后为每只特感狂刷 `[无]=99999`，吃掉日志预算；
 *   ②"在追谁"改成【窗口内各自最近距离】比较（谁更近=目标），并叠加两拍接近量作辅助 ——
 *     v1.0.0 只看相邻两拍缩短 5 单位，157/131 这种会来回翻。
 *
 *  读胆汁：事件 `player_now_it`（引擎二进制已确认），窗口长度读 `vomit_duration`（服务端读不到 ⇒ 15s）。
 *  判断追谁：不依赖目标 prop，用几何（距被喷者 vs 距最近的其他生还者）+ player_hurt 铁证。
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.2"
#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

static const char g_sClass[7][] = { "", "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger" };

ConVar g_cEnable, g_cSample, g_cWindow, g_cLog;
Handle g_hTimer = null;

bool  g_bBiled[MAXPLAYERS + 1];
float g_flBiledUntil[MAXPLAYERS + 1];
float g_flPrevBiled[MAXPLAYERS + 1];
float g_flPrevOther[MAXPLAYERS + 1];
float g_flMinBiled[MAXPLAYERS + 1];    // 本窗口内：距被喷者的最近值
float g_flMinOther[MAXPLAYERS + 1];    // 本窗口内：距其他人的最近值
int   g_iClassSeen[MAXPLAYERS + 1];

int g_iWindows, g_iSamples, g_iLogBudget;
int g_iCloserBiled[7], g_iCloserOther[7], g_iHitBiled[7], g_iHitOther[7];
char g_sMap[64];

public Plugin myinfo =
{
	name        = "[LTT] SI Bile Target Probe",
	author      = "DeepSeek Harness",
	description = "只记账：有人被胆汁喷中后，逐只特感追踪它更靠近被喷的人还是别人（评估要不要把胆汁纳入目标改写）",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cEnable = CreateConVar("ltt_bileprobe_enable", "1", "1=记账（只统计）｜0=关", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cSample = CreateConVar("ltt_bileprobe_sample", "0.5", "窗口内采样间隔（秒）", FCVAR_NOTIFY, true, 0.2, true, 3.0);
	g_cWindow = CreateConVar("ltt_bileprobe_window", "0", "窗口长度（秒）。0=读 vomit_duration（读不到用 15）", FCVAR_NOTIFY, true, 0.0, true, 60.0);
	g_cLog    = CreateConVar("ltt_bileprobe_log", "1", "1=每次采样写一行｜0=只写图末汇总", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	AutoExecConfig(true, "ltt_si_bile_probe");

	HookEvent("player_now_it", Event_NowIt, EventHookMode_Post);
	HookEvent("player_hurt",   Event_Hurt,  EventHookMode_Post);

	RegAdminCmd("sm_bileprobe", Cmd_Probe, ADMFLAG_GENERIC, "【v1.0.1】胆汁目标探针：sm_bileprobe [status|reset]");
	StartTimer();
}

void StartTimer()
{
	if (g_hTimer != null && IsValidHandle(g_hTimer))
	{
		KillTimer(g_hTimer);
		if (IsValidHandle(g_hTimer))
			CloseHandle(g_hTimer);
	}
	g_hTimer = CreateTimer(0.5, Timer_Sample, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapStart()
{
	GetCurrentMap(g_sMap, sizeof(g_sMap));
	ResetAll();
	StartTimer();
}

void ResetAll()
{
	g_iWindows = 0; g_iSamples = 0; g_iLogBudget = 500;
	for (int i = 0; i < 7; i++) { g_iCloserBiled[i] = 0; g_iCloserOther[i] = 0; g_iHitBiled[i] = 0; g_iHitOther[i] = 0; }
	for (int i = 1; i <= MaxClients; i++) ResetClient(i);
}

void ResetClient(int i)
{
	g_bBiled[i] = false; g_flBiledUntil[i] = 0.0;
	g_flPrevBiled[i] = 0.0; g_flPrevOther[i] = 0.0;
	g_flMinBiled[i] = 99999.0; g_flMinOther[i] = 99999.0;
	g_iClassSeen[i] = 0;
}

public void OnMapEnd()
{
	if (g_iWindows <= 0)
		return;
	char s[512];
	s[0] = '\0';
	for (int c = 1; c <= 6; c++)
	{
		if (g_iCloserBiled[c] + g_iCloserOther[c] + g_iHitBiled[c] + g_iHitOther[c] == 0)
			continue;
		Format(s, sizeof(s), "%s%s: 更近被喷 %d / 更近别人 %d ｜ 打被喷 %d / 打别人 %d；",
			s, g_sClass[c], g_iCloserBiled[c], g_iCloserOther[c], g_iHitBiled[c], g_iHitOther[c]);
	}
	LogMessage("[SIBile] 地图=%s 胆汁窗口 %d 次 ｜ 采样 %d 行 ｜ %s", g_sMap, g_iWindows, g_iSamples, s);
}

public void Event_NowIt(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cEnable.BoolValue)
		return;
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim < 1 || victim > MaxClients || GetClientTeam(victim) != TEAM_SURVIVOR)
		return;

	float win = g_cWindow.FloatValue;
	if (win <= 0.0)
	{
		ConVar c = FindConVar("vomit_duration");
		win = (c != null) ? c.FloatValue : 15.0;
		if (win <= 0.0) win = 15.0;
	}
	if (!g_bBiled[victim])          // 新窗口：把"最近距离"重置，重新量这一窗
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			g_flMinBiled[i] = 99999.0;
			g_flMinOther[i] = 99999.0;
		}
	}
	g_bBiled[victim] = true;
	g_flBiledUntil[victim] = GetGameTime() + win;
	g_iWindows++;
	g_iLogBudget = 80;   // 【v1.0.2】每个胆汁窗口各给一笔预算（原来每图 500 行，烧完就永远不写了）

	char n[MAX_NAME_LENGTH];
	GetClientName(victim, n, sizeof(n));
	LogMessage("[SIBile] 地图=%s ★胆汁窗口开始：%s 被喷（%.1f 秒）", g_sMap, n, win);
}

public void Event_Hurt(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cEnable.BoolValue)
		return;
	int a = GetClientOfUserId(event.GetInt("attacker"));
	int v = GetClientOfUserId(event.GetInt("userid"));
	if (a < 1 || a > MaxClients || GetClientTeam(a) != TEAM_INFECTED)
		return;
	if (v < 1 || v > MaxClients || GetClientTeam(v) != TEAM_SURVIVOR)
		return;
	int cls = GetEntProp(a, Prop_Send, "m_zombieClass");
	if (cls < 1 || cls > 6)
		return;
	if (g_bBiled[v] && GetGameTime() <= g_flBiledUntil[v])
		g_iHitBiled[cls]++;
	else
		g_iHitOther[cls]++;
}

public Action Timer_Sample(Handle timer)
{
	if (!g_cEnable.BoolValue)
		return Plugin_Continue;

	float now = GetGameTime();
	bool anyBiled = false, anyAlive = false;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bBiled[i] && now > g_flBiledUntil[i])
			g_bBiled[i] = false;
		if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == TEAM_SURVIVOR)
		{
			anyAlive = true;
			if (g_bBiled[i])
				anyBiled = true;
		}
	}
	// 【v1.0.1】有被喷的人 + 至少一个活着的生还者 才继续（否则团灭后会狂刷 99999）
	if (!anyBiled || !anyAlive)
		return Plugin_Continue;

	float pos[3], bp[3];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_INFECTED)
			continue;
		int cls = GetEntProp(i, Prop_Send, "m_zombieClass");
		if (cls < 1 || cls > 6)
			continue;
		if (g_iClassSeen[i] != cls)      // 槽位复用了别的职业：重置这一只的累计
		{
			g_iClassSeen[i] = cls;
			g_flMinBiled[i] = 99999.0;
			g_flMinOther[i] = 99999.0;
			g_flPrevBiled[i] = 0.0;
			g_flPrevOther[i] = 0.0;
		}
		GetClientAbsOrigin(i, pos);

		float dBiled = 99999.0, dOther = 99999.0;
		int biledTgt = 0;
		for (int j = 1; j <= MaxClients; j++)
		{
			if (!IsClientInGame(j) || !IsPlayerAlive(j) || GetClientTeam(j) != TEAM_SURVIVOR)
				continue;
			GetClientAbsOrigin(j, bp);
			float d = GetVectorDistance(pos, bp);
			if (g_bBiled[j]) { if (d < dBiled) dBiled = d; }
			else             { if (d < dOther) dOther = d; }
		}
		if (dBiled < g_flMinBiled[i]) g_flMinBiled[i] = dBiled;
		if (dOther < g_flMinOther[i]) g_flMinOther[i] = dOther;

		// 追谁：窗口内"更靠近谁"（10% 余量防抖）+ 两拍接近量辅助
		bool closerBiled = false, closerOther = false;
		if (g_flMinBiled[i] < 99999.0 && g_flMinBiled[i] < g_flMinOther[i] * 0.9)
			closerBiled = true;
		else if (g_flMinOther[i] < 99999.0 && g_flMinOther[i] < g_flMinBiled[i] * 0.9)
			closerOther = true;
		if (!closerBiled && !closerOther)
		{
			if (dBiled < dOther) closerBiled = true; else closerOther = true;   // 至少按当前谁更近
		}
		bool closing = false;
		if (g_flPrevBiled[i] > 0.0 && dBiled < g_flPrevBiled[i] - 5.0)  closing = true;

		if (closerBiled) g_iCloserBiled[cls]++; else g_iCloserOther[cls]++;
		g_flPrevBiled[i] = dBiled;
		g_flPrevOther[i] = dOther;

		if (!g_cLog.BoolValue || g_iLogBudget <= 0)
			continue;
		g_iLogBudget--; g_iSamples++;

		char bn[MAX_NAME_LENGTH];

		GetClientName(biledTgt, bn, sizeof(bn));
		LogMessage("[SIBile] 图=%s %s(#%d) 现在 距被喷=%.0f 距别人=%.0f ｜ 窗口内最近 被喷=%.0f 别人=%.0f → %s%s",
			g_sMap, g_sClass[cls], i, dBiled, dOther, g_flMinBiled[i], g_flMinOther[i],
			closerBiled ? "★更靠近被喷的" : "更靠近别人", closing ? "（正在接近被喷）" : "");
	}
	return Plugin_Continue;
}

public Action Cmd_Probe(int client, int args)
{
	char a[16];
	if (args >= 1) GetCmdArg(1, a, sizeof(a));
	if (StrEqual(a, "reset", false))
	{
		ResetAll();
		ReplyToCommand(client, "[SIBile] 统计已清零");
		return Plugin_Handled;
	}
	ReplyToCommand(client, "[SIBile] v%s 图=%s 胆汁窗口 %d 次 ｜ 采样行 %d ｜ 间隔 %.1fs ｜ 窗口 %s",
		PLUGIN_VERSION, g_sMap, g_iWindows, g_iSamples, g_cSample.FloatValue,
		(g_cWindow.FloatValue > 0.0) ? "自设" : "vomit_duration/15s");
	return Plugin_Handled;
}
