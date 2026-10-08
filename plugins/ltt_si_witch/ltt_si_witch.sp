/**
 *  ltt_si_witch  v1.0.0  —— 女巫（Witch）控制：总开关 + 数量上限
 *
 *  ================== 为什么单独一个插件 ==================
 *  服主 2026-09-23 决定："只做总开关 + 数量上限，位置不动。"
 *
 *  · 女巫在 coop 里是【环境陷阱】性质（玩家绕开或打死），和多特压力不是一回事；
 *    原版的女巫落点逻辑（走廊、拐角）本来就不差，所以【不做】位置控制。
 *  · **`z_*` 系列没有任何 cvar 能关女巫**（实测 `director_no_witch` /
 *    `z_witch_spawn_distance` 在 L4D2 里都不存在），只能靠插件钩子，
 *    所以才要单独写一个。
 *  · **独立成一个插件而不是塞进 ltt_si_spawner**，因为服主明确要求
 *    "有些人觉得没必要控制 witch 就不控制了" —— 独立插件可以
 *    整个 `sm plugins unload ltt_si_witch`，也可以只把 enable 设 0，
 *    两种方式都不影响刷特核心。
 *
 *  ================== 行为 ==================
 *  `ltt_siwitch_enable 0`（默认）= **完全不干预**，原版行为，一行日志都不写。
 *  `ltt_siwitch_enable 1`         = 接管：全场女巫数达到 `ltt_siwitch_max` 时
 *                                   拦掉导演后续的女巫生成。
 *
 *  拦截点用 left4dhooks 的 `L4D_OnSpawnWitch`（返回 Plugin_Handled 即阻止生成），
 *  计数用 `L4D2_GetWitchCount()`。婚礼女巫（Witch Bride）走另一个 forward，
 *  但共用同一个上限计数器 —— 不然婚礼关会漏。
 *
 *  ================== 已知局限（诚实记录）==================
 *  · **只拦"生成"，不管"已存在的"**。enable 从 0 改成 1 的那一刻，场上已有的女巫
 *    不会被移除（服主没要求杀女巫，而且杀女巫会有"凭空消失"的观感问题）。
 *  · 拦掉之后**导演可能隔一会儿再试一次**。所以日志里会看到同一个上限被反复命中 ——
 *    这是正常的，不是 bug。计数只在真正创建成功时才涨。
 *  · `L4D2_GetWitchCount()` 是可选原生（inc 里 MarkNativeAsOptional）。
 *    取不到时本插件自动降级为"扫实体 classname=witch"计数，功能不受影响。
 *
 *  依赖：sourcemod + left4dhooks（和刷特核心同一套，无新依赖、无内存补丁）
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0.0"

ConVar g_cEnable, g_cMax, g_cDebug;

bool g_bHasCountNative;
int  g_iBlocked;        // 统计：拦掉了多少次

public Plugin myinfo =
{
	name        = "[LTT] SI Witch Control",
	author      = "DeepSeek Harness",
	description = "女巫控制：总开关 + 全场数量上限（只拦生成，不动原版落点）",
	version     = PLUGIN_VERSION,
	url         = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "本插件只支持 Left 4 Dead 2");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cEnable = CreateConVar("ltt_siwitch_enable", "0",
		"0=完全不干预女巫（默认，原版行为）1=接管：全场女巫数达到 ltt_siwitch_max 时拦掉后续生成",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cMax = CreateConVar("ltt_siwitch_max", "1",
		"全场同时存在的女巫上限（仅在 enable=1 时生效）。0=一只都不许刷出来",
		FCVAR_NOTIFY, true, 0.0, true, 16.0);
	g_cDebug = CreateConVar("ltt_siwitch_debug", "1",
		"1=输出女巫拦截日志（默认开，方便确认它到底有没有在工作）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	CreateConVar("ltt_siwitch_version", PLUGIN_VERSION, "女巫控制插件版本", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	RegAdminCmd("sm_siwitch", Cmd_Witch, ADMFLAG_GENERIC, "查看/设置女巫控制状态");

	// L4D2_GetWitchCount 是可选原生：取不到就用实体扫描降级
	g_bHasCountNative = (GetFeatureStatus(FeatureType_Native, "L4D2_GetWitchCount") == FeatureStatus_Available);

	AutoExecConfig(true, "ltt_si_witch");

	LogMessage("[SIWitch] v%s 就绪 | 开关=%d 上限=%d | 计数方式=%s",
		PLUGIN_VERSION, g_cEnable.IntValue, g_cMax.IntValue,
		g_bHasCountNative ? "L4D2_GetWitchCount" : "实体扫描(降级)");
}

/** 当前场上的女巫数量 */
int CountWitches()
{
	if (g_bHasCountNative)
		return L4D2_GetWitchCount();

	// 降级：扫实体。找 m_iClassname 等于 witch 的 NPC
	int n = 0;
	int max = GetMaxEntities();
	char cls[64];
	for (int i = MaxClients + 1; i <= max; i++)
	{
		if (!IsValidEntity(i))
			continue;
		if (!GetEntityClassname(i, cls, sizeof(cls)))
			continue;
		if (StrEqual(cls, "witch"))
			n++;
	}
	return n;
}

/** 返回 true = 拦掉这次生成 */
bool ShouldBlock(const char[] src)
{
	if (!g_cEnable.BoolValue)
		return false;              // 不干预：一行日志都不写，零副作用

	int cur = CountWitches();
	int max = g_cMax.IntValue;
	if (cur < max)
		return false;

	g_iBlocked++;
	if (g_cDebug.BoolValue)
	{
		LogMessage("[SIWitch] 拦掉一只是女巫生成（%s）：场上 %d 只，上限 %d（累计拦截 %d 次）",
			src, cur, max, g_iBlocked);
	}
	return true;
}

/** 导演生成普通女巫时触发（ZombieManager::SpawnWitch） */
public Action L4D_OnSpawnWitch(const float vecPos[3], const float vecAng[3])
{
	if (ShouldBlock("导演"))
		return Plugin_Handled;
	return Plugin_Continue;
}

/** 婚礼女巫（The Passing 那关）走另一个 forward，共用同一个上限 */
public Action L4D2_OnSpawnWitchBride(const float vecPos[3], const float vecAng[3])
{
	if (ShouldBlock("婚礼女巫"))
		return Plugin_Handled;
	return Plugin_Continue;
}

public Action Cmd_Witch(int client, int args)
{
	if (!g_cEnable.BoolValue)
	{
		ReplyToCommand(client, "[女巫] 当前【未接管】（ltt_siwitch_enable 0）—— 完全是原版行为");
		ReplyToCommand(client, "[女巫] 要接管：ltt_siwitch_enable 1（再用 ltt_siwitch_max 设上限）");
		return Plugin_Handled;
	}

	ReplyToCommand(client, "[女巫] 已接管：场上 %d 只 / 上限 %d ｜ 计数方式=%s ｜ 累计拦截 %d 次",
		CountWitches(), g_cMax.IntValue,
		g_bHasCountNative ? "原生" : "实体扫描", g_iBlocked);
	return Plugin_Handled;
}
