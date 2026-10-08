#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

/**
 *  ltt_boss v1.1.0 —— 坦克（Tank）管理：数量上限 / 本图不刷 / 一键处死 / 出场播报
 *
 *  ================== v1.1.0 为什么改成"事件驱动" ==================
 *  v1.0.0 用 left4dhooks 的 `L4D_OnSpawnTank` forward 来"拦生成"，实测在咱服**不可靠**：
 *    · `GetFeatureStatus(FeatureType_Native, ...)` **检测不了 forward**（那是 native 的接口），
 *      所以 v1.0.0 启动日志里的"拦生成=0 出场回调=0"是**假阴性**，不能当依据；
 *    · 而且编译用的 include（320071 B）比线上 left4dhooks 1.168 新，
 *      `L4D2_IsTankInPlay` 这类**新 native** 运行时不保证存在（实测报不可用）。
 *  现在改成**只用两样一定有的东西**：
 *    ① 引擎事件 `tank_spawn`（L4D2 原生事件，带 userid）—— 坦克一出现就能拿到它；
 *    ② `L4D_CullZombie`（咱服实测**可用**）—— 引擎自己的剔除。
 *  ⇒ "本图不刷" = 一出现就立刻剔除；"上限 N" = 第 N+1 只立刻剔除。
 *    语义与"直接不生成"对玩家完全等价，且**不依赖任何内存补丁与新版原生**。
 *
 *  ================== 命令（ADMFLAG_GENERIC）==================
 *    sm_tank            查看状态（接管/本图不刷/上限/已出现几只/场上几只）
 *    sm_tank spawn      【测试用】立刻放一只坦克（需要 L4D2_SpawnTank）
 *    sm_tank kill       处死场上坦克（L4D_CullZombie，真人控制的坦克不动）
 *    sm_tank off / on   本图不刷 / 恢复（换图自动回到 cfg 默认 0）
 *    sm_tank max <n>    本图最多允许出现几只（0=不限）
 *
 *  ================== cvar ==================
 *    ltt_boss_tank_enable    1=允许接管（0=完全不管坦克）
 *    ltt_boss_tank_off       1=本图不刷坦克
 *    ltt_boss_tank_max       本图最多允许出现几只（0=不限）
 *    ltt_boss_tank_announce  1=坦克出现时聊天播报"离最近生还者多远 + 前方/后方"
 *    ltt_boss_debug          1=写日志
 */

#define PLUGIN_VERSION "1.2.0"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define ZC_TANK       8
#define UNITS_PER_METER 52.49

ConVar g_cEnable, g_cTankOff, g_cTankMax, g_cAnnounce, g_cDebug;

bool g_bHasCull;    // L4D_CullZombie 可用？（咱服实测可用）
bool g_bHasFlow;    // L4D2Direct_GetFlowDistance 可用？（用来判断坦克在队伍前方还是后方）
bool g_bHasSpawn;   // 【v1.2.0】L4D2_SpawnTank 可用？（sm_tank spawn 测试用）

int  g_iSeen;       // 本图坦克"出现"次数（含被立刻剔除的）

public Plugin myinfo =
{
	name        = "[LTT] Boss Control (Tank)",
	author      = "DeepSeek Harness",
	description = "坦克管理：本图不刷 / 数量上限 / 一键处死 / 出场播报（事件驱动，零内存补丁）",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cEnable   = CreateConVar("ltt_boss_tank_enable",   "1", "1=允许本插件接管坦克（0=完全不管坦克）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cTankOff  = CreateConVar("ltt_boss_tank_off",      "0", "1=本图不刷坦克（0=正常）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cTankMax  = CreateConVar("ltt_boss_tank_max",      "0", "本图最多允许出现几只坦克（0=不限）", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	g_cAnnounce = CreateConVar("ltt_boss_tank_announce", "1", "1=坦克出现时聊天播报位置", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cDebug    = CreateConVar("ltt_boss_debug",         "0", "1=写日志", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "ltt_boss");

	RegAdminCmd("sm_tank", Cmd_Tank, ADMFLAG_GENERIC, "坦克管理：查看状态 / kill 处死 / off|on 本图开关 / max <n> 上限");

	// 只探测 native（forward 用 GetFeatureStatus 检测不了，别写进日志免得又出现假信息）
	g_bHasCull  = (GetFeatureStatus(FeatureType_Native, "L4D_CullZombie") == FeatureStatus_Available);
	g_bHasFlow  = (GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetFlowDistance") == FeatureStatus_Available);
	g_bHasSpawn = (GetFeatureStatus(FeatureType_Native, "L4D2_SpawnTank") == FeatureStatus_Available);

	HookEvent("tank_spawn", Event_TankSpawn, EventHookMode_Post);

	LogMessage("[Boss] v%s 就绪（引擎剔除=%s 流量距离=%s 手动放坦克=%s；拦截走 tank_spawn 事件，不依赖新原生）",
		PLUGIN_VERSION, g_bHasCull ? "可用" : "不可用", g_bHasFlow ? "可用" : "不可用",
		g_bHasSpawn ? "可用" : "不可用");
}

public void OnMapStart()
{
	g_iSeen = 0;
}

// ------------------------------------------------------------------ 坦克出现

public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int tank = GetClientOfUserId(event.GetInt("userid"));
	if (tank <= 0 || !IsClientInGame(tank))
		return;

	g_iSeen++;

	bool blocked = false;

	if (g_cEnable.BoolValue)
	{
		int maxTanks = g_cTankMax.IntValue;

		if (g_cTankOff.BoolValue)
			blocked = true;
		else if (maxTanks > 0 && g_iSeen > maxTanks)
			blocked = true;
	}

	if (blocked)
	{
		if (g_bHasCull)
		{
			L4D_CullZombie(tank);

			if (g_cDebug.BoolValue)
				LogMessage("[Boss] 第 %d 只坦克已按设置立即剔除（本图不刷=%d 上限=%d）",
					g_iSeen, g_cTankOff.IntValue, g_cTankMax.IntValue);
			if (g_cAnnounce.BoolValue)
				PrintToChatAll("\x01[\x05坦克\x01] 本图按设置不刷坦克，已移除");
		}
		else
		{
			LogError("[Boss] 需要 L4D_CullZombie 才能移除坦克，但服务器不可用；本图不刷/上限设置无法生效");
		}
		return;
	}

	if (g_cDebug.BoolValue)
		LogMessage("[Boss] 坦克出现 #%d（客户端 %d）", g_iSeen, tank);

	AnnounceTank(tank);
}

/** 播报：离最近生还者多远 + 在队伍前方还是后方（拿不到 flow 原生时只报距离） */
void AnnounceTank(int tank)
{
	if (!g_cAnnounce.BoolValue)
		return;

	float pos[3];
	GetClientAbsOrigin(tank, pos);

	int   near = -1;
	float best = 999999.0;
	float spos[3];

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		GetClientAbsOrigin(i, spos);
		float d = GetVectorDistance(spos, pos, false);
		if (d < best)
		{
			best = d;
			near = i;
		}
	}

	if (near <= 0)
	{
		PrintToChatAll("\x01[\x05坦克\x01] 出现了！");
		return;
	}

	char sWhere[16];
	strcopy(sWhere, sizeof(sWhere), "附近");

	if (g_bHasFlow)
	{
		float fTank = L4D2Direct_GetFlowDistance(tank);
		float fNear = L4D2Direct_GetFlowDistance(near);

		if (fTank > fNear + 50.0)
			strcopy(sWhere, sizeof(sWhere), "前方");
		else if (fTank < fNear - 50.0)
			strcopy(sWhere, sizeof(sWhere), "后方");
	}

	PrintToChatAll("\x01[\x05坦克\x01] 出现了！在\x05%s\x01（离最近的生还者约 \x05%.0f\x01 米）",
		sWhere, best / UNITS_PER_METER);
}

// ------------------------------------------------------------------ 命令

int CountTanks()
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_INFECTED)
			continue;
		if (GetEntProp(i, Prop_Send, "m_zombieClass") == ZC_TANK)
			n++;
	}
	return n;
}

public Action Cmd_Tank(int client, int args)
{
	char arg[16];
	if (args >= 1)
		GetCmdArg(1, arg, sizeof(arg));

	if (StrEqual(arg, "spawn", false))
	{
		if (!g_bHasSpawn)
		{
			ReplyToCommand(client, "[Boss] 这个服务器的 left4dhooks 没有 L4D2_SpawnTank，无法手动放坦克");
			return Plugin_Handled;
		}

		// 位置：优先用发起者脚下，其次第一个存活生还者（都没有就报错）
		int anchor = (client > 0 && client <= MaxClients && IsClientInGame(client) && IsPlayerAlive(client)) ? client : 0;
		if (anchor == 0)
		{
			for (int i = 1; i <= MaxClients; i++)
			{
				if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == TEAM_SURVIVOR)
				{
					anchor = i;
					break;
				}
			}
		}

		if (anchor == 0)
		{
			ReplyToCommand(client, "[Boss] 场上没有存活生还者，放不了坦克（引擎需要一个落点）");
			return Plugin_Handled;
		}

		float pos[3], ang[3];
		GetClientAbsOrigin(anchor, pos);
		GetClientAbsAngles(anchor, ang);

		int tank = L4D2_SpawnTank(pos, ang);
		LogMessage("[Boss] 管理员 %d 手动放坦克（锚点客户端 %d）→ 返回 %d", client, anchor, tank);
		ReplyToCommand(client, "[Boss] 已尝试在客户端 %d 位置放一只坦克（返回 %d）", anchor, tank);
		return Plugin_Handled;
	}

	if (StrEqual(arg, "kill", false))
	{
		if (!g_bHasCull)
		{
			ReplyToCommand(client, "[Boss] 这个服务器的 left4dhooks 没有 L4D_CullZombie，无法处死坦克");
			return Plugin_Handled;
		}

		int killed = 0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_INFECTED)
				continue;
			if (GetEntProp(i, Prop_Send, "m_zombieClass") != ZC_TANK)
				continue;
			if (!IsFakeClient(i))
				continue;   // 真人控制的坦克不动

			L4D_CullZombie(i);
			killed++;
		}

		LogMessage("[Boss] 管理员 %d 处死坦克 %d 只", client, killed);
		ReplyToCommand(client, "[Boss] 已处死坦克 %d 只", killed);
		if (killed > 0)
			PrintToChatAll("\x01[\x05坦克\x01] 已被管理员处死");
		return Plugin_Handled;
	}

	if (StrEqual(arg, "off", false))
	{
		g_cTankOff.SetInt(1);
		LogMessage("[Boss] 管理员 %d 设置本图不刷坦克", client);
		ReplyToCommand(client, "[Boss] 本图不再刷坦克（换图自动恢复；sm_tank on 可立刻恢复）");
		return Plugin_Handled;
	}

	if (StrEqual(arg, "on", false))
	{
		g_cTankOff.SetInt(0);
		LogMessage("[Boss] 管理员 %d 恢复刷坦克", client);
		ReplyToCommand(client, "[Boss] 已恢复刷坦克");
		return Plugin_Handled;
	}

	if (StrEqual(arg, "max", false))
	{
		if (args < 2)
		{
			ReplyToCommand(client, "[Boss] 用法: sm_tank max <数字>（0=不限）");
			return Plugin_Handled;
		}

		int n = GetCmdArgInt(2);
		if (n < 0)
			n = 0;
		g_cTankMax.SetInt(n);
		ReplyToCommand(client, "[Boss] 本图坦克上限设为 %d（0=不限）", n);
		return Plugin_Handled;
	}

	ReplyToCommand(client, "[Boss] v%s 接管=%d 本图不刷=%d 上限=%d 播报=%d | 本图已出现 %d 只 | 场上坦克 %d 只｜引擎剔除=%s",
		PLUGIN_VERSION, g_cEnable.IntValue, g_cTankOff.IntValue, g_cTankMax.IntValue,
		g_cAnnounce.IntValue, g_iSeen, CountTanks(), g_bHasCull ? "可用" : "不可用");
	ReplyToCommand(client, "[Boss] 用法: sm_tank [spawn | kill | off | on | max <n>]");
	return Plugin_Handled;
}
