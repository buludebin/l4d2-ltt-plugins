#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

/**
 *  ltt_firez v1.2.0 —— 只用于实测的一次性探针
 *
 *  2026-10-04 "终极特感训练"实测踩坑记录：
 *    v1.0.0 直接 AcceptEntityInput(e,"SpawnZombie")           → A/B 都 0（漏了职业参数）
 *    v1.1.0 带职业参数（SetVariantString）                     → A/B 仍 0（漏了 activator）
 *    v1.2.0 再带 activator（模拟"玩家按下按钮"）              ← 现在这版
 *  依据：地图按钮接线是 `"OnPressed" "SpawnSmoker1 SpawnZombie smoker 0 -1"`，
 *        按钮被玩家按下时 activation 是那个玩家；rcon 触发时 activator 是 0（世界），
 *        commentary_zombie_spawner 很可能就因此拒绝生成。
 *
 *  命令：
 *      sm_firez <靶名> [职业] [activator#]  默认职业 smoker，默认 activator=第一个存活生还者
 *      sm_zcount / sm_zlist [靶名] / sm_zclients
 */

#define PLUGIN_VERSION "1.2.0"

public Plugin myinfo =
{
	name        = "[LTT] SpawnZombie Probe",
	author      = "DeepSeek Harness",
	description = "诊断用：给刷点实体发 SpawnZombie（职业参数 + activator）并统计特感数",
	version     = PLUGIN_VERSION,
	url         = ""
};

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

public void OnPluginStart()
{
	RegAdminCmd("sm_firez",    Cmd_FireZ,    ADMFLAG_ROOT, "发 SpawnZombie：sm_firez <靶名> [职业] [activator#]");
	RegAdminCmd("sm_zcount",   Cmd_ZCount,   ADMFLAG_ROOT, "统计在场特感/真人/客户端数");
	RegAdminCmd("sm_zlist",    Cmd_ZList,    ADMFLAG_ROOT, "列出刷点实体");
	RegAdminCmd("sm_zclients", Cmd_ZClients, ADMFLAG_ROOT, "列出客户端（bot/队伍/存活/职业）");
}

int CountSI(int &tank)
{
	int n = 0;
	tank = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i))
			continue;
		if (GetClientTeam(i) != TEAM_INFECTED)
			continue;

		n++;
		if (GetEntProp(i, Prop_Send, "m_zombieClass") == 8)
			tank++;
	}
	return n;
}

int FirstSurvivor()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == TEAM_SURVIVOR)
			return i;
	}
	return 0;
}

public Action Cmd_ZClients(int client, int args)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		int team = GetClientTeam(i);
		char cls[24];
		strcopy(cls, sizeof(cls), "-");
		if (team == TEAM_INFECTED && IsPlayerAlive(i))
			IntToString(GetEntProp(i, Prop_Send, "m_zombieClass"), cls, sizeof(cls));

		ReplyToCommand(client, "[Probe] #%d %s team=%d alive=%d class=%s",
			i, IsFakeClient(i) ? "BOT" : "真人", team, IsPlayerAlive(i) ? 1 : 0, cls);
	}
	return Plugin_Handled;
}

public Action Cmd_ZCount(int client, int args)
{
	int tank = 0;
	int si = CountSI(tank);

	int surv = 0, realpl = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		if (!IsFakeClient(i))
			realpl++;
		if (GetClientTeam(i) == TEAM_SURVIVOR)
			surv++;
	}
	ReplyToCommand(client, "[Probe] 特感=%d（坦克 %d）｜生还者槽=%d｜真人=%d｜客户端总数=%d｜MaxClients=%d",
		si, tank, surv, realpl, GetClientCount(false), MaxClients);
	return Plugin_Handled;
}

bool IsSpawnerClass(const char[] cls)
{
	return (StrEqual(cls, "commentary_zombie_spawner", false)
		|| StrEqual(cls, "info_zombie_spawn", false)
		|| StrEqual(cls, "func_zombie_spawn", false));
}

public Action Cmd_ZList(int client, int args)
{
	char name[64];
	if (args >= 1)
		GetCmdArg(1, name, sizeof(name));
	else
		strcopy(name, sizeof(name), "z");

	int found = 0;
	int maxent = GetMaxEntities();
	char cls[64], tname[64];
	float pos[3];
	for (int e = MaxClients + 1; e < maxent; e++)
	{
		if (!IsValidEntity(e))
			continue;

		GetEntityClassname(e, cls, sizeof(cls));
		if (!IsSpawnerClass(cls))
			continue;

		GetEntPropString(e, Prop_Data, "m_iName", tname, sizeof(tname));
		if (name[0] != '\0' && !StrEqual(tname, name, false))
			continue;

		GetEntPropVector(e, Prop_Send, "m_vecOrigin", pos);
		ReplyToCommand(client, "[Probe] ent=%d %s name=%s pos=%.0f,%.0f,%.0f", e, cls, tname, pos[0], pos[1], pos[2]);
		found++;
		if (found >= 40)
		{
			ReplyToCommand(client, "[Probe] （只列前 40 个）");
			break;
		}
	}
	ReplyToCommand(client, "[Probe] 匹配 %d 个（靶名=%s）", found, name);
	return Plugin_Handled;
}

public Action Cmd_FireZ(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[Probe] 用法: sm_firez <靶名> [职业] [activator#]");
		return Plugin_Handled;
	}

	char name[64], zclass[32];
	GetCmdArg(1, name, sizeof(name));
	if (args >= 2)
		GetCmdArg(2, zclass, sizeof(zclass));
	else
		strcopy(zclass, sizeof(zclass), "smoker");

	int activator = 0;
	if (args >= 3)
		activator = GetCmdArgInt(3);
	if (activator <= 0)
		activator = FirstSurvivor();

	int tank = 0;
	int before = CountSI(tank);

	int fired = 0;
	int maxent = GetMaxEntities();
	char cls[64], tname[64];
	for (int e = MaxClients + 1; e < maxent; e++)
	{
		if (!IsValidEntity(e))
			continue;

		GetEntityClassname(e, cls, sizeof(cls));
		if (!IsSpawnerClass(cls))
			continue;

		GetEntPropString(e, Prop_Data, "m_iName", tname, sizeof(tname));
		if (!StrEqual(tname, name, false))
			continue;

		SetVariantString(zclass);
		AcceptEntityInput(e, "SpawnZombie", activator, e);
		fired++;
	}

	ReplyToCommand(client, "[Probe] 靶名=%s 职业=%s activator=#%d 触发 %d 个｜触发前特感=%d",
		name, zclass, activator, fired, before);
	CreateTimer(2.0, Timer_Report, _, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Handled;
}

public Action Timer_Report(Handle timer)
{
	int tank = 0;
	int si = CountSI(tank);
	PrintToServer("[Probe] 触发后 2 秒：在场特感=%d（坦克 %d）", si, tank);
	PrintToChatAll("\x01[\x05Probe\x01] 触发后 2 秒：在场特感=\x05%d\x01（坦克 %d）", si, tank);
	return Plugin_Stop;
}
