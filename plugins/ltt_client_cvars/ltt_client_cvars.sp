/*
 *	[LTT] Client Cvar Pusher — 服务器下发客户端参数
 *
 *	用途：把一组"客户端 cvar"（r_flashlight* / cl_crosshair* / cl_max_shadow_renderable_dist 等）
 *	      在玩家进服、出生、以及周期性地下发给客户端控制台执行 —— 玩家不需要安装任何 mod。
 *
 *	必须知道的边界（都是这类方案的固有特性）：
 *	  1) 服务器自己并不注册这些 cvar（服务器上 cvarlist 查不到），所以只能"转发命令"，无法校验是否生效
 *	  2) cheat 保护的 cvar（mat_wireframe / nav_edit 等）下发无效
 *	  3) 玩家本地 config / 控制台手动改会覆盖 → 所以本插件在"每次出生 + 每 N 秒"重复下发
 *	  4) FCVAR_ARCHIVE 的 cvar 会被写进玩家自己的 config（等于替玩家永久改了设置），请谨慎选择
 *
 *	配置：addons/sourcemod/configs/ltt_client_cvars.txt（一行一条：<cvar> <值>，支持 // 注释）
 *	命令：sm_ccpush（root 立即重发）、sm_ccreload（root 重新读配置并重发）
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"
#define MAX_ENTRIES    128
#define CONFIG_FILE    "configs/ltt_client_cvars.txt"

ConVar g_cEnable;
ConVar g_cInterval;
ConVar g_cDelay;
ConVar g_cVerbose;

char g_sName[MAX_ENTRIES][64];
char g_sValue[MAX_ENTRIES][128];
int  g_iCount;

Handle g_hTimer;

public Plugin myinfo =
{
	name        = "[LTT] Client Cvar Pusher",
	author      = "DeepSeek Harness",
	description = "向客户端下发参数（手电筒/准星/HUD），玩家无需装 mod",
	version     = PLUGIN_VERSION,
	url         = "N/A"
};

public void OnPluginStart()
{
	CreateConVar("ltt_cc_version", PLUGIN_VERSION, "客户端参数下发插件版本", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	g_cEnable   = CreateConVar("ltt_cc_enable",   "1",    "总开关: 1=下发, 0=关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cInterval = CreateConVar("ltt_cc_interval", "30.0", "周期性重发间隔秒数(0=只在出生时发一次)", FCVAR_NOTIFY, true, 0.0, true, 600.0);
	g_cDelay    = CreateConVar("ltt_cc_delay",    "2.0",  "进入服务器/出生后延迟多少秒下发", FCVAR_NOTIFY, true, 0.0, true, 30.0);
	g_cVerbose  = CreateConVar("ltt_cc_verbose",  "0",    "1=每次下发都写日志(调试用)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	AutoExecConfig(true, "ltt_client_cvars");

	g_cEnable.AddChangeHook(OnCvarChanged);
	g_cInterval.AddChangeHook(OnCvarChanged);

	RegAdminCmd("sm_ccpush",   Cmd_Push,   ADMFLAG_ROOT, "立即向所有玩家重新下发客户端参数");
	RegAdminCmd("sm_ccreload", Cmd_Reload, ADMFLAG_ROOT, "重新读取客户端参数配置并下发");

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);

	LoadConfig();
	StartTimer();
}

void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	StartTimer();
}

void StartTimer()
{
	if (g_hTimer != null)
	{
		delete g_hTimer;
		g_hTimer = null;
	}

	if (g_cInterval.FloatValue <= 0.0)
		return;

	g_hTimer = CreateTimer(g_cInterval.FloatValue, Timer_PushAll, _, TIMER_REPEAT);
}

public Action Timer_PushAll(Handle timer)
{
	if (!g_cEnable.BoolValue || g_iCount == 0)
		return Plugin_Continue;

	int n = PushToAll();
	if (g_cVerbose.BoolValue && n > 0)
		LogMessage("[ClientCvar] 周期下发: %d 名玩家 × %d 条参数", n, g_iCount);

	return Plugin_Continue;
}

void LoadConfig()
{
	g_iCount = 0;

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof path, CONFIG_FILE);

	if (!FileExists(path))
	{
		LogError("[ClientCvar] 找不到配置文件: %s", path);
		return;
	}

	File f = OpenFile(path, "r");
	if (f == null)
	{
		LogError("[ClientCvar] 无法打开配置文件: %s", path);
		return;
	}

	char line[256];
	while (!f.EndOfFile() && f.ReadLine(line, sizeof line))
	{
		TrimString(line);
		if (line[0] == '\0')
			continue;

		// 去掉行尾注释
		int cut = StrContains(line, "//");
		if (cut >= 0)
		{
			line[cut] = '\0';
			TrimString(line);
		}
		if (line[0] == '\0' || (line[0] == '/' && line[1] == '/'))
			continue;

		// 以第一个空白分割出 cvar 名与值
		int sp = -1;
		for (int i = 0; line[i] != '\0'; i++)
		{
			if (line[i] == ' ' || line[i] == '\t')
			{
				sp = i;
				break;
			}
		}
		if (sp <= 0)
			continue;

		char name[64], value[128];
		strcopy(name, sizeof name, line);
		name[sp] = '\0';
		strcopy(value, sizeof value, line[sp + 1]);
		TrimString(value);

		if (name[0] == '\0' || value[0] == '\0')
			continue;

		strcopy(g_sName[g_iCount], sizeof g_sName[], name);
		strcopy(g_sValue[g_iCount], sizeof g_sValue[], value);
		g_iCount++;

		if (g_iCount >= MAX_ENTRIES)
		{
			LogError("[ClientCvar] 配置条目超过上限 %d，后面的被忽略", MAX_ENTRIES);
			break;
		}
	}

	delete f;
	LogMessage("[ClientCvar] 配置已加载：%d 条参数", g_iCount);
}

bool PushToClient(int client)
{
	if (!g_cEnable.BoolValue || g_iCount == 0)
		return false;

	if (!IsClientInGame(client) || IsFakeClient(client))
		return false;

	for (int i = 0; i < g_iCount; i++)
		ClientCommand(client, "%s %s", g_sName[i], g_sValue[i]);

	return true;
}

int PushToAll()
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (PushToClient(i))
			n++;
	}
	return n;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || IsFakeClient(client))
		return;

	CreateTimer(g_cDelay.FloatValue, Timer_PushOne, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientPutInServer(int client)
{
	if (IsFakeClient(client))
		return;

	CreateTimer(g_cDelay.FloatValue + 3.0, Timer_PushOne, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_PushOne(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Stop;

	if (PushToClient(client) && g_cVerbose.BoolValue)
		LogMessage("[ClientCvar] 已向 %L 下发 %d 条参数", client, g_iCount);

	return Plugin_Stop;
}

Action Cmd_Push(int client, int args)
{
	int n = PushToAll();
	ReplyToCommand(client, "[客户端参数] 已向 %d 名玩家下发 %d 条参数", n, g_iCount);
	return Plugin_Handled;
}

Action Cmd_Reload(int client, int args)
{
	LoadConfig();
	int n = PushToAll();
	ReplyToCommand(client, "[客户端参数] 重新读取完成：%d 条参数，已下发给 %d 名玩家", g_iCount, n);
	return Plugin_Handled;
}
