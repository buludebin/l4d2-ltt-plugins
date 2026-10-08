/**
 * ===========================================================================
 *  ltt_laugh  v1.2.0  ——  玩家"笑声/嘲讽"→ 全服广播 + 惩罚（三种方式 + 按重开次数升级）
 * ===========================================================================
 *
 *  【需求演变】
 *      v1.0.0（服主 2026-10-03）：最简单版——聊天框提示。实测可用。
 *      v1.1.0（服主朋友建议）：广播给全部人，写成"谁谁谁发送了嘲笑"，并扣 10 血惩罚。
 *      v1.2.0（服主 2026-10-03）：
 *        ① 惩罚方式做成旋钮：1=扣血 / 2=直接倒地 / 3=直接处死；
 *        ② 可按【本章节重开次数】自动升级惩罚方式。
 *
 *  【触发机制（不是猜的）】
 *      Z 键声音轮盘每项都让客户端发 `vocalize <概念名>`，用 AddCommandListener 监听 "vocalize" 即可
 *      （"标记"插件 l4d2_item_hint 就是这么绑"看"的）。
 *      笑声/嘲讽概念名：引擎服务端字符串 dump 里有 `PlayerTaunt`、没有 `PlayerLaugh`；
 *      参考插件 tls_restore_vocalize.sp 把两者当两个概念 ⇒ 本插件两个都认。
 *      实测（2026-10-03 17:00:54 / 17:05:xx）服主按轮盘笑声 → 本插件触发并广播成功 ✓
 *
 *  【"重开次数"怎么来的】
 *      HookEvent("mission_lost")（团灭）计数，OnMapStart 归零 ⇒ 语义 = "本次这张图重开了几次"。
 *      实测依据：2026-10-03 zc1_m4 那一小时内 8 次团灭，日志里"本图开始 地图=zc1_m4"只出现 **1 次**
 *      ⇒ **团灭不会重载地图**，所以按图实例计数就是准的，不需要写文件持久化。
 *
 *  【惩罚方式实现取舍】
 *      · 方式 1 扣血：SDKHooks_TakeDamage(client, 0, 0, dmg) —— 走正常伤害流程。
 *      · 方式 2 倒地：伤害 = 当前血 + 5 ⇒ 血量打到 0 以下，引擎自己判倒地
 *        （倒地后血量会被引擎设成 survivor_incap_health = 300，这是正常现象，不是被治疗）。
 *      · 方式 3 处死：ForcePlayerSuicide（等价 sm_slay）；**不去"打 9999 伤害"**——
 *        那样健康的人只会被判定倒地，达不到"直接处死"。
 *      · 三种都用 attacker=0 ⇒ 不计友伤（黑枪）统计、不误触发反伤类插件。
 *      · 已经倒地的人按轮盘：**跳过惩罚只记录**（倒地状态下再"处死"会变成补刀，语义不清）。
 *
 *  作者：DeepSeek Harness
 * ===========================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.2.1"

#define TEAM_SURVIVOR 2

#define MODE_DAMAGE 1     // 扣血
#define MODE_INCAP  2     // 直接倒地
#define MODE_KILL   3     // 直接处死

/** 认哪些概念名当"笑声/嘲讽"（大小写不敏感的子串匹配）。
 *  【2026-10-03 实测定论】Z 轮盘的"笑声"发的就是 **`PlayerLaugh #<目标>`** ——
 *  debug 日志实证：`vocalize: client=… 参数="PlayerLaugh #8730"`。
 *  `PlayerTaunt` 是引擎字符串里也存在的另一个概念（名字直译就是"嘲讽"），目前没见轮盘发它，
 *  但保留匹配：哪天真发了也算"嘲笑"，语义一致。 */
static const char g_sConcepts[][] =
{
	"PlayerLaugh",   // ← 实测确认（Z 轮盘"笑声"）
	"PlayerTaunt"    // ← 引擎里有这个字符串，一并认（备用）
};

ConVar g_cEnable, g_cText, g_cDebug, g_cCooldown, g_cPenalty, g_cMode, g_cAutoInc;
float  g_fNext[MAXPLAYERS + 1];
int    g_iRestarts;      // 本章节（本图实例）团灭重开次数

public Plugin myinfo =
{
	name        = "[LTT] Laugh Hint",
	author      = "DeepSeek Harness",
	description = "玩家按 Z 轮盘的笑声/嘲讽时：全服广播『X 发送了嘲笑』并惩罚（扣血/倒地/处死，可按重开次数升级）",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cEnable   = CreateConVar("ltt_laugh_enable",   "1",        "1=开启嘲笑惩罚 0=关闭（只监听不广播）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cText     = CreateConVar("ltt_laugh_text",     "发送了嘲笑", "广播里跟在玩家名后面的文字", FCVAR_NOTIFY);
	g_cMode     = CreateConVar("ltt_laugh_mode",     "1",        "惩罚方式：1=扣血 2=直接倒地 3=直接处死", FCVAR_NOTIFY, true, 1.0, true, 3.0);
	g_cPenalty  = CreateConVar("ltt_laugh_penalty",  "10.0",     "方式 1 的扣血量（0=不扣血，只广播）", FCVAR_NOTIFY, true, 0.0, true, 200.0);
	g_cAutoInc  = CreateConVar("ltt_laugh_auto_inc", "0",        "按本章节重开次数自动升级惩罚：每重开 N 次方式 +1 档（封顶 3）。0=不自动升级", FCVAR_NOTIFY, true, 0.0, true, 20.0);
	g_cCooldown = CreateConVar("ltt_laugh_cooldown", "0.5",      "同一玩家两次广播/惩罚的最小间隔（秒）", FCVAR_NOTIFY, true, 0.0, true, 10.0);
	g_cDebug    = CreateConVar("ltt_laugh_debug",    "0",        "1=把收到的每条 vocalize 参数打进日志（核对轮播各项概念名用；注意 cfg 会在换图时把它重置回这里的默认值）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "ltt_laugh");

	AddCommandListener(Cmd_Vocalize, "vocalize");
	HookEvent("mission_lost", Event_MissionLost, EventHookMode_PostNoCopy);

	RegAdminCmd("sm_laugh_test", Cmd_Test, ADMFLAG_GENERIC, "自测：sm_laugh_test <#userid|名字> [方式1/2/3] [扣血量]（不给方式=只广播不惩罚）");
	RegAdminCmd("sm_laugh_status", Cmd_Status, ADMFLAG_GENERIC, "查看当前惩罚方式与本图重开次数");

	LogMessage("[Laugh] v%s 已加载：概念=%s/%s｜方式=%d（1扣血/2倒地/3处死）扣血=%.0f｜自动升级=每 %d 次重开 +1 档（0=关）",
		PLUGIN_VERSION, g_sConcepts[0], g_sConcepts[1], g_cMode.IntValue, g_cPenalty.FloatValue, g_cAutoInc.IntValue);
}

public void OnMapStart()
{
	g_iRestarts = 0;   // 换图（或同图重开）⇒ 本章节重开次数归零
}

public void OnClientDisconnect(int client)
{
	g_fNext[client] = 0.0;
}

public void Event_MissionLost(Event event, const char[] name, bool dontBroadcast)
{
	g_iRestarts++;
	if (g_cDebug.BoolValue)
		LogMessage("[Laugh] 团灭 +1 ⇒ 本图重开次数=%d（当前惩罚方式=%d）", g_iRestarts, EffectiveMode());
}

/** 本次生效的惩罚方式（含"按重开次数自动升级"） */
int EffectiveMode()
{
	int mode = g_cMode.IntValue;
	int inc  = g_cAutoInc.IntValue;

	if (inc > 0)
	{
		mode += g_iRestarts / inc;      // 每 inc 次重开升一档
		if (mode > MODE_KILL)
			mode = MODE_KILL;
	}

	if (mode < MODE_DAMAGE)
		mode = MODE_DAMAGE;
	return mode;
}

public Action Cmd_Vocalize(int client, const char[] command, int argc)
{
	// 只要真人玩家：client 0 = 服务器控制台，IsFakeClient = 假人（特感/生还者 bot）
	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;

	char sArg[64];
	if (GetCmdArgString(sArg, sizeof(sArg)) < 2)
		return Plugin_Continue;

	if (g_cDebug.BoolValue)
		LogMessage("[Laugh] vocalize: client=%N 参数=\"%s\"", client, sArg);

	for (int i = 0; i < sizeof(g_sConcepts); i++)
	{
		if (StrContains(sArg, g_sConcepts[i], false) != -1)
		{
			NotifyLaugh(client, 0, -1.0);
			break;
		}
	}

	return Plugin_Continue;   // 不拦原命令：笑声照旧播
}

/** 真正广播 + 惩罚（测试命令走同一条路，保证行为一致）。
 *  参数：modeOverride 0 = 用当前生效方式（默认）；1/2/3 = 强制用这种方式
 *        dmgOverride < 0 = 用 cvar 的扣血量；>= 0 = 强制这个扣血量（0 = 不扣血） */
void NotifyLaugh(int client, int modeOverride = 0, float dmgOverride = -1.0)
{
	if (!g_cEnable.BoolValue)
		return;

	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
		return;

	// 只处理活着的生还者（被控/死亡时本来也发不出嘲笑）
	if (GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client))
		return;

	float now = GetEngineTime();     // 不能用 GetGameTime()：空服会冻住（本项目踩过）
	if (now < g_fNext[client])
		return;
	g_fNext[client] = now + g_cCooldown.FloatValue;

	char sText[64];
	g_cText.GetString(sText, sizeof(sText));

	bool  bIncapped = (GetEntProp(client, Prop_Send, "m_isIncapacitated") == 1);
	int   hpBefore  = GetEntProp(client, Prop_Send, "m_iHealth");
	int   mode      = (modeOverride >= MODE_DAMAGE && modeOverride <= MODE_KILL) ? modeOverride : EffectiveMode();
	float dmg       = (dmgOverride >= 0.0) ? dmgOverride : g_cPenalty.FloatValue;

	// 已经倒地的人：跳过惩罚（避免"补刀"语义不清），但仍广播 + 记日志
	if (bIncapped && mode != MODE_DAMAGE)
	{
		PrintToChatAll("\x01[\x04嘲笑\x01] \x05%N\x01 %s（\x02已倒地，不再追加惩罚\x01）", client, sText);
		LogMessage("[Laugh] %N 已倒地，跳过方式 %d 的惩罚（重开次数=%d）", client, mode, g_iRestarts);
		return;
	}

	char sPenalty[64];

	switch (mode)
	{
		case MODE_DAMAGE:
		{
			if (dmg > 0.0)
			{
				SDKHooks_TakeDamage(client, 0, 0, dmg);
				FormatEx(sPenalty, sizeof(sPenalty), "\x04惩罚：-%.0f\x01 血", dmg);
			}
			else
				strcopy(sPenalty, sizeof(sPenalty), "\x02无惩罚\x01");
		}
		case MODE_INCAP:
		{
			// 伤害 = 当前血 + 5 ⇒ 打到 0 以下，引擎自己判倒地（倒地后血量会被设成 300）
			float d = float(hpBefore) + 5.0;
			SDKHooks_TakeDamage(client, 0, 0, d);
			strcopy(sPenalty, sizeof(sPenalty), "\x04惩罚：直接倒地\x01");
		}
		case MODE_KILL:
		{
			ForcePlayerSuicide(client);   // 等价 sm_slay；打伤害只会倒地，达不到"处死"
			strcopy(sPenalty, sizeof(sPenalty), "\x04惩罚：直接处死\x01");
		}
	}

	int hpAfter = GetEntProp(client, Prop_Send, "m_iHealth");
	bool bIncapNow = (GetEntProp(client, Prop_Send, "m_isIncapacitated") == 1);

	PrintToChatAll("\x01[\x04嘲笑\x01] \x05%N\x01 %s（%s\x01）", client, sText, sPenalty);
	LogMessage("[Laugh] 已广播+惩罚: %N %s｜方式=%d（本图重开 %d 次）血 %d→%d%s",
		client, sText, mode, g_iRestarts, hpBefore, hpAfter,
		bIncapNow ? "【已倒地】" : ((hpAfter <= 0) ? "【已死亡】" : ""));
}

public Action Cmd_Status(int client, int args)
{
	char sText[64];
	g_cText.GetString(sText, sizeof(sText));

	ReplyToCommand(client, "[Laugh] 基础方式=%d（1扣血/2倒地/3处死）｜自动升级=%s（每 %d 次重开 +1 档）｜本图重开次数=%d｜当前生效方式=%d",
		g_cMode.IntValue,
		g_cAutoInc.IntValue > 0 ? "开" : "关",
		g_cAutoInc.IntValue, g_iRestarts, EffectiveMode());
	ReplyToCommand(client, "[Laugh] 扣血=%.0f｜冷却=%.1fs｜开关=%d｜文本=\"%s\"",
		g_cPenalty.FloatValue, g_cCooldown.FloatValue, g_cEnable.IntValue, sText);
	return Plugin_Handled;
}

public Action Cmd_Test(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[Laugh] 用法：sm_laugh_test <#userid|名字> [方式1/2/3] [扣血量]（不给方式=只广播不惩罚；方式 1 的扣血量不给就用 cvar 值）");
		return Plugin_Handled;
	}

	char sTarget[64];
	GetCmdArg(1, sTarget, sizeof(sTarget));

	int target = FindTarget(client, sTarget, true, false);
	if (target <= 0)
	{
		ReplyToCommand(client, "[Laugh] 找不到这个玩家");
		return Plugin_Handled;
	}

	int modeOverride = 0;
	float dmgOverride = -1.0;
	if (args >= 2)
	{
		char s2[16];
		GetCmdArg(2, s2, sizeof(s2));
		modeOverride = StringToInt(s2);
	}
	if (args >= 3)
	{
		char s3[16];
		GetCmdArg(3, s3, sizeof(s3));
		dmgOverride = float(StringToInt(s3));
	}

	g_fNext[target] = 0.0;    // 测试时不受冷却限制

	// 不给方式 ⇒ 只广播不惩罚：直接用 dmg=0 的"扣血方式"跑（最安全）
	if (modeOverride == 0)
		NotifyLaugh(target, MODE_DAMAGE, 0.0);
	else
		NotifyLaugh(target, modeOverride, dmgOverride);

	if (client > 0)
		ReplyToCommand(client, "[Laugh] 已用 %N 的名义广播（方式=%d，扣血=%.0f；同时写了日志）", target, modeOverride, dmgOverride);
	else
		PrintToServer("[Laugh] 已用 %N 的名义广播（方式=%d，扣血=%.0f；同时写了日志）", target, modeOverride, dmgOverride);

	return Plugin_Handled;
}
