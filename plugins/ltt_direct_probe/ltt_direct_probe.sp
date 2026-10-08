/**
 *  ltt_direct_probe —— 突破特感上限实验，用完即删
 *
 *  背景：rygive（管理员娱乐菜单 v1.2.3b, sorallll）用 ProdigySim 的
 *        "DirectInfectedSpawn" 技术刷特感 —— 完全不经过 ZombieManager::SpawnSpecial，
 *        而是直接 NextBotCreatePlayerBot<T>("Hunter") 造一个新 bot，
 *        再手工 InitializeSpecial 把它设成感染者。
 *
 *  与 v1.0.0 的差别（v1.0.0 测失败了，原因是探针自己的判定写错）：
 *    1) 返回类型照抄 rygive：SDKType_CBasePlayer（不是 CBaseEntity）
 *    2) 不再在 InitializeSpecial 之前判定队伍/存活 —— 此时 bot 还没被设成感染者，
 *       GetClientTeam 必然不等于 3，v1.0.0 就是卡在这里把成功的 bot 判成了失败
 *    3) 每一步都记录：返回号、在服、队伍、存活、当前存活特感数、客户端占用
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

Handle g_hBot[6];
Handle g_hTimer;
int    g_iLeft;
int    g_iOk;
int    g_iFail;
int    g_iStreak;
int    g_iTarget;
int    g_iPeakAlive;

static const char g_sKeys[6][]  = {
	"NextBotCreatePlayerBot<Smoker>", "NextBotCreatePlayerBot<Boomer>",
	"NextBotCreatePlayerBot<Hunter>", "NextBotCreatePlayerBot<Spitter>",
	"NextBotCreatePlayerBot<Jockey>", "NextBotCreatePlayerBot<Charger>"
};
static const char g_sNames[6][] = { "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger" };

public Plugin myinfo =
{
	name        = "[LTT] Direct Infected Probe",
	author      = "DeepSeek Harness",
	description = "用 NextBotCreatePlayerBot 直连刷特感，测真实天花板",
	version     = "1.1.1",
	url         = ""
};

public void OnPluginStart()
{
	RegAdminCmd("sm_directfill", Cmd_Fill,    ADMFLAG_ROOT, "sm_directfill [n] 用 NextBotCreatePlayerBot 连刷 n 只");
	RegAdminCmd("sm_directinfo", Cmd_Info,    ADMFLAG_ROOT, "查看 SDKCall 状态");
	// 【2026-10-02 审核修复】原名 sm_moveout，与另外两个探针插件重名（SM 里后注册的会失败）
	RegAdminCmd("sm_moveout_direct",    Cmd_MoveOut, ADMFLAG_ROOT, "把生还者挪出安全区");
	RegAdminCmd("sm_sidump",     Cmd_SIDump,  ADMFLAG_ROOT, "列出所有客户端槽位");
	RegAdminCmd("sm_sikickdead", Cmd_KickDead, ADMFLAG_ROOT, "踢掉死亡的特感假人，腾出槽位");

	GameData gd = LoadGameConfigFile("rygive");
	if (gd == null)
	{
		LogError("[Direct] 载入 gamedata rygive.txt 失败（确认文件已放到 gamedata/）");
		return;
	}

	for (int i = 0; i < 6; i++)
	{
		StartPrepSDKCall(SDKCall_Static);
		if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, g_sKeys[i]))
		{
			LogError("[Direct] 找不到签名 %s", g_sKeys[i]);
			continue;
		}
		PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
		PrepSDKCall_SetReturnInfo(SDKType_CBasePlayer, SDKPass_Pointer);
		g_hBot[i] = EndPrepSDKCall();
	}
	delete gd;

	CreateTimer(2.0, Timer_Init);
}

public Action Timer_Init(Handle timer)
{
	int ready = 0;
	for (int i = 0; i < 6; i++)
		if (g_hBot[i] != null) ready++;

	LogMessage("[Direct] SDKCall 就绪 %d/6", ready);
	return Plugin_Stop;
}

public Action Cmd_Info(int client, int args)
{
	int ready = 0;
	for (int i = 0; i < 6; i++)
		if (g_hBot[i] != null) ready++;

	ReplyToCommand(client, "[Direct] SDKCall 就绪 %d/6", ready);
	return Plugin_Handled;
}

/** 照抄 rygive 的 InitializeSpecial */
void InitSpecial(int ent, const float vPos[3], const float vAng[3])
{
	ChangeClientTeam(ent, TEAM_INFECTED);
	SetEntProp(ent, Prop_Send, "m_usSolidFlags", 16);
	SetEntProp(ent, Prop_Send, "movetype", 2);
	SetEntProp(ent, Prop_Send, "deadflag", 0);
	SetEntProp(ent, Prop_Send, "m_lifeState", 0);
	SetEntProp(ent, Prop_Send, "m_iObserverMode", 0);
	SetEntProp(ent, Prop_Send, "m_iPlayerState", 0);
	SetEntProp(ent, Prop_Send, "m_zombieState", 0);
	DispatchSpawn(ent);
	TeleportEntity(ent, vPos, vAng, NULL_VECTOR);
}

int CountAliveInfected()
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i))
			n++;

	return n;
}

/** 返回所有已连入客户端的快照字符串 */
void BuildSlotDump(char[] out, int maxlen)
{
	out[0] = '\0';
	int used = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		used++;
		char piece[48];
		Format(piece, sizeof piece, "#%d/%s%d%s", i, IsFakeClient(i) ? "BOT" : "HUM",
			GetClientTeam(i), IsPlayerAlive(i) ? "活" : "死");
		StrCat(out, maxlen, piece);
		if (used < MaxClients) StrCat(out, maxlen, " ");
	}
}

public Action Cmd_SIDump(int client, int args)
{
	char s[1024];
	BuildSlotDump(s, sizeof s);

	ReplyToCommand(client, "[Direct] 存活特感=%d 客户端=%d/%d", CountAliveInfected(), GetClientCount(false), MaxClients);
	ReplyToCommand(client, "[Direct] 槽位: %s", s);
	LogMessage("[Direct] 槽位快照 存活特感=%d 客户端=%d/%d | %s",
		CountAliveInfected(), GetClientCount(false), MaxClients, s);
	return Plugin_Handled;
}

public Action Cmd_KickDead(int client, int args)
{
	int kicked = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_INFECTED || !IsFakeClient(i) || IsPlayerAlive(i))
			continue;

		KickClient(i);
		kicked++;
	}

	ReplyToCommand(client, "[Direct] 踢掉死亡特感假人 %d 个", kicked);
	LogMessage("[Direct] 踢掉死亡特感假人 %d 个（踢后客户端=%d/%d）", kicked, GetClientCount(false), MaxClients);
	return Plugin_Handled;
}

public Action Cmd_Fill(int client, int args)
{
	int n = (args >= 1) ? GetCmdArgInt(1) : 24;
	if (n < 1)  n = 1;
	if (n > 40) n = 40;

	g_iTarget = L4D_GetHighestFlowSurvivor();
	if (g_iTarget <= 0 || !IsClientInGame(g_iTarget) || !IsPlayerAlive(g_iTarget) || GetClientTeam(g_iTarget) != TEAM_SURVIVOR)
	{
		g_iTarget = 0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == TEAM_SURVIVOR)
			{
				g_iTarget = i;
				break;
			}
		}
	}
	if (g_iTarget <= 0)
	{
		ReplyToCommand(client, "[Direct] 没有可用的生还者目标");
		LogMessage("[Direct] 中止：没有可用的生还者目标（客户端=%d/%d）", GetClientCount(false), MaxClients);
		return Plugin_Handled;
	}

	g_iLeft      = n;
	g_iOk        = 0;
	g_iFail      = 0;
	g_iStreak    = 0;
	g_iPeakAlive = CountAliveInfected();

	delete g_hTimer;
	g_hTimer = CreateTimer(0.15, Timer_SpawnOne, _, TIMER_REPEAT);

	ReplyToCommand(client, "[Direct] 开始连刷 %d 只（每 0.15 秒 1 只）", n);
	LogMessage("[Direct] === 开始：目标 %d 只，基准目标生还者=#%d，起始存活特感=%d，客户端=%d/%d ===",
		n, g_iTarget, g_iPeakAlive, GetClientCount(false), MaxClients);
	return Plugin_Handled;
}

public Action Timer_SpawnOne(Handle timer)
{
	if (g_iLeft <= 0 || g_iStreak >= 3)
	{
		char s[1024];
		BuildSlotDump(s, sizeof s);
		LogMessage("[Direct] === 汇总：成功 %d 失败 %d 存活特感峰值 %d 最终存活特感 %d 客户端=%d/%d ===",
			g_iOk, g_iFail, g_iPeakAlive, CountAliveInfected(), GetClientCount(false), MaxClients);
		LogMessage("[Direct] 最终槽位: %s", s);
		g_hTimer = null;
		return Plugin_Stop;
	}

	g_iLeft--;

	int idx = GetRandomInt(0, 5);
	if (g_hBot[idx] == null)
	{
		g_iFail++;
		g_iStreak++;
		return Plugin_Continue;
	}

	float pos[3], ang[3] = { 0.0, 0.0, 0.0 };
	if (!L4D_GetRandomPZSpawnPosition(g_iTarget, idx + 1, 10, pos))
	{
		g_iFail++;
		g_iStreak++;
		LogMessage("[Direct] %s：找不到落点", g_sNames[idx]);
		return Plugin_Continue;
	}

	int ent = SDKCall(g_hBot[idx], g_sNames[idx]);

	if (ent <= 0 || ent > MaxClients)
	{
		g_iFail++;
		g_iStreak++;
		LogMessage("[Direct] %s：SDKCall 返回无效 #%d（客户端=%d/%d 存活特感=%d）",
			g_sNames[idx], ent, GetClientCount(false), MaxClients, CountAliveInfected());
		return Plugin_Continue;
	}

	bool bInGameBefore = IsClientInGame(ent);
	int  iTeamBefore   = bInGameBefore ? GetClientTeam(ent) : -1;

	InitSpecial(ent, pos, ang);

	int alive = CountAliveInfected();
	if (alive > g_iPeakAlive) g_iPeakAlive = alive;

	if (IsClientInGame(ent) && GetClientTeam(ent) == TEAM_INFECTED && IsPlayerAlive(ent))
	{
		g_iOk++;
		g_iStreak = 0;
		LogMessage("[Direct] %s：成功 → 槽位 #%d | 初始化前(在服=%d 队伍=%d) 初始化后(在服=%d 队伍=%d 存活=%d) | 存活特感=%d 客户端=%d/%d",
			g_sNames[idx], ent, bInGameBefore, iTeamBefore,
			IsClientInGame(ent), GetClientTeam(ent), IsPlayerAlive(ent),
			alive, GetClientCount(false), MaxClients);
	}
	else
	{
		g_iFail++;
		g_iStreak++;
		LogMessage("[Direct] %s：初始化后无效 #%d | 在服=%d 队伍=%d 存活=%d | 存活特感=%d 客户端=%d/%d",
			g_sNames[idx], ent, IsClientInGame(ent), GetClientTeam(ent), IsPlayerAlive(ent),
			alive, GetClientCount(false), MaxClients);
	}

	return Plugin_Continue;
}

public Action Cmd_MoveOut(int client, int args)
{
	int moved = 0;
	float ang[3] = { 0.0, 0.0, 0.0 };

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		float pos[3];
		if (!L4D_GetRandomPZSpawnPosition(i, 3, 30, pos))
			continue;

		TeleportEntity(i, pos, ang, NULL_VECTOR);
		moved++;
	}

	ReplyToCommand(client, "[Direct] 已挪出 %d 个生还者", moved);
	LogMessage("[Direct] 挪人：%d 个", moved);
	return Plugin_Handled;
}
