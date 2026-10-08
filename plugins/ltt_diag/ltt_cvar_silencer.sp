#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

public Plugin myinfo =
{
	name        = "[LTT] Cvar Notify Silencer",
	author      = "DeepSeek Harness",
	description = "去掉指定 cvar 的 FCVAR_NOTIFY 标记，避免变更时向全体玩家刷屏（只改标记，不改值）",
	version     = "1.0.0",
	url         = ""
};

// 【为什么要这个】
// ABAB 配对实验每 10 分钟执行一次 `sm_cvar director_no_specials X`。
// 该 cvar 带 FCVAR_NOTIFY，SourceMod 对这类 cvar 的任何变更都会向全体玩家播报
//   [SM] Console: 更改 cvar "director_no_specials" 为 "1".
// 一局下来会刷十几次，干扰玩家。去掉 NOTIFY 标记即可静音，cvar 的值与行为不受影响。
//
// 【注意】只改【运行时标记掩码】，不改 cvar 的值、不改引擎注册。
// 插件卸载时会把原标记还回去（下面 OnPluginEnd）。

#define MAX_TARGETS 16

ConVar g_cList;
char   g_sTargets[MAX_TARGETS][64];
int    g_iOrigFlags[MAX_TARGETS];
bool   g_bStripped[MAX_TARGETS];
int    g_iTargets;

public void OnPluginStart()
{
	g_cList = CreateConVar("ltt_silentcvars", "director_no_specials",
		"要静音的 cvar 名，逗号分隔（去掉它们的 FCVAR_NOTIFY，变更时不再向玩家播报）。空=不静音任何东西",
		FCVAR_NOTIFY);
	RegAdminCmd("sm_silencecvars", Cmd_Silence, ADMFLAG_ROOT, "重新对 ltt_silentcvars 里的 cvar 去掉 NOTIFY 标记");

	ApplySilence();
	LogMessage("[Silencer] v1.0.0 已加载 | 目标=%s", g_cList != null ? "见 ltt_silentcvars" : "无");
}

public void OnConfigsExecuted()
{
	// 【为什么还要挂这里】换图/执行 cfg 时引擎可能重置标志位，重新压一遍。
	ApplySilence();
}

public void OnPluginEnd()
{
	for (int i = 0; i < g_iTargets; i++)
	{
		if (!g_bStripped[i])
		{
			continue;
		}
		ConVar cv = FindConVar(g_sTargets[i]);
		if (cv != null)
		{
			SetConVarFlags(cv, g_iOrigFlags[i]);
			LogMessage("[Silencer] 已还原 %s 的标记 = %d", g_sTargets[i], g_iOrigFlags[i]);
		}
	}
}

void ApplySilence()
{
	char list[256];
	g_cList.GetString(list, sizeof(list));
	TrimString(list);

	g_iTargets = 0;
	if (list[0] == '\0')
	{
		LogMessage("[Silencer] ltt_silentcvars 为空 → 不静音任何 cvar");
		return;
	}

	char parts[MAX_TARGETS][64];
	int n = ExplodeString(list, ",", parts, MAX_TARGETS, sizeof(parts[]));

	for (int i = 0; i < n && g_iTargets < MAX_TARGETS; i++)
	{
		TrimString(parts[i]);
		if (parts[i][0] == '\0')
		{
			continue;
		}

		ConVar cv = FindConVar(parts[i]);
		if (cv == null)
		{
			LogMessage("[Silencer] 找不到 cvar %s（跳过）", parts[i]);
			continue;
		}

		int idx = g_iTargets;
		strcopy(g_sTargets[idx], sizeof(g_sTargets[]), parts[i]);
		g_iOrigFlags[idx] = GetConVarFlags(cv);
		g_bStripped[idx]  = false;
		g_iTargets++;

		if (g_iOrigFlags[idx] & FCVAR_NOTIFY)
		{
			SetConVarFlags(cv, g_iOrigFlags[idx] & ~FCVAR_NOTIFY);
			g_bStripped[idx] = true;
			LogMessage("[Silencer] 已去掉 %s 的 FCVAR_NOTIFY（原 flags=%d，新 flags=%d）",
				g_sTargets[idx], g_iOrigFlags[idx], GetConVarFlags(cv));
		}
		else
		{
			LogMessage("[Silencer] %s 本来就没有 FCVAR_NOTIFY（flags=%d），无需处理",
				g_sTargets[idx], g_iOrigFlags[idx]);
		}
	}
}

public Action Cmd_Silence(int client, int args)
{
	ApplySilence();
	ReplyToCommand(client, "[Silencer] 已按 ltt_silentcvars 处理 %d 个 cvar（详见 SM 日志）", g_iTargets);
	return Plugin_Handled;
}
