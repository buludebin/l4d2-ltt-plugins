#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define TEAM_SURVIVOR 2

public Plugin myinfo =
{
	name        = "LTT Diag",
	author      = "DeepSeek Harness",
	description = "临时诊断: 记录生还者死亡原因 / 回合重启",
	version     = "1.0.0",
	url         = ""
};

public void OnPluginStart()
{
	HookEvent("player_death",   Event_Death,       EventHookMode_Post);
	HookEvent("player_hurt",    Event_Hurt,        EventHookMode_Post);
	HookEvent("player_spawn",   Event_Spawn,       EventHookMode_Post);
	HookEvent("round_start",    Event_RoundStart,  EventHookMode_PostNoCopy);
	HookEvent("round_end",      Event_RoundEnd,    EventHookMode_PostNoCopy);
	HookEvent("mission_lost",   Event_MissionLost, EventHookMode_PostNoCopy);
	HookEvent("finale_win",     Event_FinaleWin,   EventHookMode_PostNoCopy);
	HookEvent("map_transition", Event_MapTrans,    EventHookMode_PostNoCopy);
	HookEvent("player_team",    Event_Team,        EventHookMode_Post);
	RegAdminCmd("sm_diag", Cmd_Diag, ADMFLAG_ROOT, "立刻打印一次生还者状态");
	LogMessage("[DIAG] 诊断插件已加载");
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

public Action Cmd_Diag(int client, int args)
{
	char map[64];
	GetCurrentMap(map, sizeof(map));
	ReplyToCommand(client, "[DIAG] map=%s 存活生还者=%d", map, CountAlive());
	DumpAll(client);
	return Plugin_Handled;
}

void DumpAll(int replyTo)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i))
		{
			continue;
		}
		if (!IsClientInGame(i))
		{
			LogMessage("[DIAG]   slot=%d 已连接但不在游戏 (name=%N)", i, i);
			continue;
		}
		float p[3];
		GetClientAbsOrigin(i, p);
		LogMessage("[DIAG]   slot=%d %N 队伍=%d BOT=%d 存活=%d lifeState=%d HP=%d 坐标 %.0f %.0f %.0f",
			i, i, GetClientTeam(i), IsFakeClient(i), IsPlayerAlive(i),
			GetEntProp(i, Prop_Send, "m_lifeState"), GetClientHealth(i), p[0], p[1], p[2]);
	}
}

public void Event_Team(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int isBot = (client > 0 && IsFakeClient(client)) ? 1 : 0;
	LogMessage("[DIAG] player_team %N 队伍 %d -> %d 主动退出=%d BOT=%d",
		client, event.GetInt("oldteam"), event.GetInt("team"),
		event.GetInt("disconnect"), isBot);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	LogMessage("[DIAG] == round_start == 存活生还者=%d", CountAlive());
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR)
		{
			continue;
		}
		float p[3];
		GetClientAbsOrigin(i, p);
		LogMessage("[DIAG]   %N 存活=%d HP=%d 坐标 %.0f %.0f %.0f",
			i, IsPlayerAlive(i), GetClientHealth(i), p[0], p[1], p[2]);
	}
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	LogMessage("[DIAG] == round_end == reason=%d 存活生还者=%d", event.GetInt("reason"), CountAlive());
}

public void Event_MissionLost(Event event, const char[] name, bool dontBroadcast)
{
	LogMessage("[DIAG] == MISSION_LOST == 存活生还者=%d", CountAlive());
	DumpAll(0);
}

public void Event_FinaleWin(Event event, const char[] name, bool dontBroadcast)
{
	LogMessage("[DIAG] == finale_win ==");
}

public void Event_MapTrans(Event event, const char[] name, bool dontBroadcast)
{
	LogMessage("[DIAG] == map_transition ==");
}

public void Event_Spawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || GetClientTeam(client) != TEAM_SURVIVOR)
	{
		return;
	}
	float p[3];
	GetClientAbsOrigin(client, p);
	LogMessage("[DIAG] spawn %N HP=%d 坐标 %.0f %.0f %.0f", client, GetClientHealth(client), p[0], p[1], p[2]);
}

public void Event_Hurt(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim <= 0 || GetClientTeam(victim) != TEAM_SURVIVOR)
	{
		return;
	}
	// 只记录"致命/濒死"的那一下，避免刷屏
	if (event.GetInt("health") > 0 && event.GetInt("dmg_health") < 40)
	{
		return;
	}
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	char weapon[64];
	event.GetString("weapon", weapon, sizeof(weapon));
	float p[3];
	GetClientAbsOrigin(victim, p);
	LogMessage("[DIAG] hurt %N <- %N 武器=%s 伤害=%d 剩余=%d 类型=%d 坐标 %.0f %.0f %.0f",
		victim, attacker, weapon, event.GetInt("dmg_health"), event.GetInt("health"),
		event.GetInt("type"), p[0], p[1], p[2]);
}

public void Event_Death(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	char weapon[64];
	event.GetString("weapon", weapon, sizeof(weapon));
	float p[3];
	if (victim > 0)
	{
		GetClientAbsOrigin(victim, p);
	}
	LogMessage("[DIAG] death %N (队伍=%d) 凶手=%N 武器=%s 伤害类型=%d 坐标 %.0f %.0f %.0f",
		victim, victim > 0 ? GetClientTeam(victim) : -1, attacker, weapon,
		event.GetInt("damage_type"), p[0], p[1], p[2]);
}
