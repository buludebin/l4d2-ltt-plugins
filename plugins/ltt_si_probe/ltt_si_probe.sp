/**
 *  ltt_si_probe  ——  临时探针，用完即删
 *
 *  两个用途：
 *   1) sm_simax [n]  —— 测 BinHooks 的 SetSpecialMax() 能否突破引擎"最多 9 只特感"上限
 *   2) sm_moveout    —— 把生还者 bot 挪出安全区
 *      为什么需要它：Neko / specialspawner 这类刷特插件都挂在
 *      "首个生还者离开安全区" 这个 forward 上才启动。空服时 bot 不会自己
 *      出安全区（试过 sb_all_bot_game 1 + 换图都无效），所以只能主动挪人。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

// BinHooks 提供的原生（自行声明，避免依赖 Neko 的 include）
native int  GetSpecialMax();
native void SetSpecialMax(int num);

#define TEAM_SURVIVOR 2

public Plugin myinfo =
{
	name        = "[LTT] SI Max Probe",
	author      = "DeepSeek Harness",
	description = "临时探针：测 SetSpecialMax + 把生还者挪出安全区（便于空服测试刷特）",
	version     = "1.1.1",
	url         = ""
};

public void OnPluginStart()
{
	MarkNativeAsOptional("GetSpecialMax");
	MarkNativeAsOptional("SetSpecialMax");

	RegAdminCmd("sm_simax",    Cmd_Set,     ADMFLAG_ROOT, "sm_simax [n] 查看/设置 SetSpecialMax");
	// 【2026-10-02 审核修复】原名 sm_moveout，与另外两个探针插件重名（SM 里后注册的会失败）
	RegAdminCmd("sm_moveout_si",  Cmd_MoveOut, ADMFLAG_ROOT, "把所有生还者 bot 挪出安全区（解锁刷特插件）");
	RegAdminCmd("sm_simaxinfo", Cmd_Info,   ADMFLAG_ROOT, "查看 native 可用状态");

	CreateTimer(2.0, Timer_Init);
}

public Action Timer_Init(Handle timer)
{
	LogMessage("[SIMax] native 状态: SetSpecialMax=%d GetSpecialMax=%d (0=可用)",
		view_as<int>(GetFeatureStatus(FeatureType_Native, "SetSpecialMax")),
		view_as<int>(GetFeatureStatus(FeatureType_Native, "GetSpecialMax")));
	return Plugin_Stop;
}

public Action Cmd_Info(int client, int args)
{
	ReplyToCommand(client, "[SIMax] SetSpecialMax=%d GetSpecialMax=%d (0=可用)",
		view_as<int>(GetFeatureStatus(FeatureType_Native, "SetSpecialMax")),
		view_as<int>(GetFeatureStatus(FeatureType_Native, "GetSpecialMax")));
	return Plugin_Handled;
}

public Action Cmd_Set(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SIMax] GetSpecialMax() = %d", GetSpecialMax());
		return Plugin_Handled;
	}

	int n = GetCmdArgInt(1);
	SetSpecialMax(n);
	ReplyToCommand(client, "[SIMax] SetSpecialMax(%d) → GetSpecialMax() = %d", n, GetSpecialMax());
	LogMessage("[SIMax] SetSpecialMax(%d) → GetSpecialMax()=%d", n, GetSpecialMax());
	return Plugin_Handled;
}

/** 把每个活着的生还者传送到引擎给的一个合法导航点上（远离安全区） */
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
		{
			LogMessage("[MoveOut] %N 找不到合法落点", i);
			continue;
		}

		TeleportEntity(i, pos, ang, NULL_VECTOR);
		moved++;
	}

	ReplyToCommand(client, "[MoveOut] 已挪出 %d 个生还者", moved);
	LogMessage("[MoveOut] 已挪出 %d 个生还者 | HasAnySurvivorLeftSafeArea=%d",
		moved, L4D_HasAnySurvivorLeftSafeArea() ? 1 : 0);

	// 再查一次，确认引擎是否已经认为"有人离开安全区"
	CreateTimer(1.0, Timer_CheckSafeArea);
	return Plugin_Handled;
}

public Action Timer_CheckSafeArea(Handle timer)
{
	LogMessage("[MoveOut] 1 秒后复查 HasAnySurvivorLeftSafeArea=%d",
		L4D_HasAnySurvivorLeftSafeArea() ? 1 : 0);
	return Plugin_Stop;
}
