/**
 *  ltt_sdk_probe  ——  最终对照实验，用完即删
 *
 *  目的：验证"用 SDK 刷能不能突破 9 只特感上限"。
 *
 *  做法：完全绕开 left4dhooks 的 L4D2_SpawnSpecial 封装，
 *        自己用 L4D_GetPointer(POINTER_ZOMBIEMANAGER) 拿 @TheZombieManager 指针，
 *        再用 SDKCall 直接调引擎的 ZombieManager::SpawnSpecial。
 *
 *  背景：left4dhooks 的 L4D2_SpawnSpecial 实现本身就是一句裸 SDKCall
 *        （见 l4dd_natives.sp:2975），没有任何额外限制。本实验排除
 *        "是不是封装层有限制" 这个可能性。
 *
 *  注意：必须先 ltt_sispawn_enable 0 —— 否则我方刷特插件的
 *        L4D_OnSpawnSpecial 拦截会把本探针的生成也挡掉（同一个底层函数）。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

Handle g_hSDK;
int    g_iClass = 3;      // 3 = Hunter

public Plugin myinfo =
{
	name        = "[LTT] SDK Spawn Probe",
	author      = "DeepSeek Harness",
	description = "绕过 left4dhooks，用 SDKCall 直连 ZombieManager::SpawnSpecial 测上限",
	version     = "1.0.1",
	url         = ""
};

public void OnPluginStart()
{
	RegAdminCmd("sm_sdkburst", Cmd_Burst, ADMFLAG_ROOT, "sm_sdkburst [n] 用 SDKCall 直连引擎连刷 n 只");
	RegAdminCmd("sm_sdkinfo",  Cmd_Info,  ADMFLAG_ROOT, "查看 SDKCall 准备状态");
	// 【2026-10-02 审核修复】原名 sm_moveout，与另外两个探针插件重名（SM 里后注册的会失败）
	RegAdminCmd("sm_moveout_sdk",  Cmd_MoveOut, ADMFLAG_ROOT, "把所有生还者挪出安全区");

	GameData gd = LoadGameConfigFile("left4dhooks.l4d2");
	if (gd == null)
	{
		LogError("[SDKProbe] 载入 gamedata left4dhooks.l4d2 失败");
		return;
	}

	StartPrepSDKCall(SDKCall_Raw);
	// 注意：key 要用【签名名】"ZombieManager::SpawnSpecial"，
	// 不是 gamedata 里那个 "L4DD::ZombieManager::SpawnSpecial" 函数块名。
	// （照抄 left4dhooks 自己的 l4dd_gamedata.sp:1648）
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "ZombieManager::SpawnSpecial"))
	{
		LogError("[SDKProbe] 找不到签名 ZombieManager::SpawnSpecial");
		delete gd;
		return;
	}

	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);   // a1 int      = 职业
	PrepSDKCall_AddParameter(SDKType_Vector,       SDKPass_ByRef);   // a2 vectorptr = 坐标
	PrepSDKCall_AddParameter(SDKType_QAngle,       SDKPass_ByRef);   // a3 vectorptr = 朝向（QAngle！）
	PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);

	g_hSDK = EndPrepSDKCall();
	delete gd;

	CreateTimer(2.0, Timer_Init);
}

public Action Timer_Init(Handle timer)
{
	LogMessage("[SDKProbe] SDKCall=%s  ZombieManager指针=%x  POINTER_ZOMBIEMANAGER=%d",
		g_hSDK != null ? "就绪" : "失败",
		view_as<int>(L4D_GetPointer(POINTER_ZOMBIEMANAGER)),
		view_as<int>(POINTER_ZOMBIEMANAGER));
	return Plugin_Stop;
}

public Action Cmd_Info(int client, int args)
{
	ReplyToCommand(client, "[SDKProbe] SDKCall=%s  指针=%x",
		g_hSDK != null ? "就绪" : "失败",
		view_as<int>(L4D_GetPointer(POINTER_ZOMBIEMANAGER)));
	return Plugin_Handled;
}

public Action Cmd_Burst(int client, int args)
{
	if (g_hSDK == null)
	{
		ReplyToCommand(client, "[SDKProbe] SDKCall 未就绪");
		return Plugin_Handled;
	}

	int n = (args >= 1) ? GetCmdArgInt(1) : 10;
	if (n < 1)  n = 1;
	if (n > 32) n = 32;

	Address pZM = L4D_GetPointer(POINTER_ZOMBIEMANAGER);
	if (pZM == Address_Null)
	{
		ReplyToCommand(client, "[SDKProbe] 拿不到 ZombieManager 指针");
		return Plugin_Handled;
	}

	// L4D_GetHighestFlowSurvivor() 在"没人在安全区外"时返回 0（所有人生还者 flow 都是 0），
	// 所以必须加兜底，否则空服测试会直接卡死在这一步。
	int target = L4D_GetHighestFlowSurvivor();
	if (target <= 0 || !IsClientInGame(target) || !IsPlayerAlive(target) || GetClientTeam(target) != 2)
	{
		target = 0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == 2)
			{
				target = i;
				break;
			}
		}
	}

	if (target <= 0)
	{
		ReplyToCommand(client, "[SDKProbe] 没有可用的生还者目标");
		return Plugin_Handled;
	}

	int ok = 0;
	int fail = 0;
	float ang[3] = { 0.0, 0.0, 0.0 };

	for (int i = 0; i < n; i++)
	{
		float pos[3];
		if (!L4D_GetRandomPZSpawnPosition(target, g_iClass, 10, pos))
		{
			fail++;
			LogMessage("[SDKProbe] 第 %d 次：找不到落点", i + 1);
			continue;
		}

		int ent = SDKCall(g_hSDK, pZM, g_iClass, pos, ang);

		bool good = (ent > 0 && ent <= MaxClients && IsClientInGame(ent)
		             && GetClientTeam(ent) == 3 && IsPlayerAlive(ent));
		if (good)
		{
			ok++;
			LogMessage("[SDKProbe] 第 %d 次：成功 → 槽位 #%d", i + 1, ent);
		}
		else
		{
			fail++;
			LogMessage("[SDKProbe] 第 %d 次：失败 → 返回 %d", i + 1, ent);
		}
	}

	ReplyToCommand(client, "[SDKProbe] SDKCall 直连结果：成功 %d / 失败 %d", ok, fail);
	LogMessage("[SDKProbe] === 汇总：成功 %d 失败 %d ===", ok, fail);
	return Plugin_Handled;
}

/** 把生还者挪出安全区 —— 引擎的找位函数在安全区内（以及服务器休眠时）会全部失败 */
public Action Cmd_MoveOut(int client, int args)
{
	int moved = 0;
	float ang[3] = { 0.0, 0.0, 0.0 };

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != 2)
			continue;

		float pos[3];
		if (!L4D_GetRandomPZSpawnPosition(i, 3, 30, pos))
		{
			LogMessage("[SDKProbe] 挪人：%N 找不到落点", i);
			continue;
		}

		TeleportEntity(i, pos, ang, NULL_VECTOR);
		moved++;
	}

	ReplyToCommand(client, "[SDKProbe] 已挪出 %d 个生还者", moved);
	LogMessage("[SDKProbe] 挪人：%d 个 | HasAnySurvivorLeftSafeArea=%d",
		moved, L4D_HasAnySurvivorLeftSafeArea() ? 1 : 0);
	return Plugin_Handled;
}
