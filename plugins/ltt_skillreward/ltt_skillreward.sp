/**
 * ===========================================================================
 *  LTT Melee Skill Reward  ——  低难度下「刀空爆 / 刀牛」额外回血
 * ===========================================================================
 *
 *  设计意图（服务器主人定的）：
 *      玩专家的人空爆是顺手的事，不需要奖励；玩简单/普通的人只会拿枪打特感，
 *      所以只在这两个难度给近战技巧发血量奖励，鼓励他们用刀。
 *
 *  判定完全复用 ltt_skill_lite，不自己实现一套：
 *      LTT_OnSkeet(attacker, victim, isTeamSkeet)   ← v1.1.0 起
 *      LTT_OnMeleeLevel(attacker, victim, isHurt)   ← v1.2.0 起
 *
 *  刀空爆靠"攻击者当前手持武器"判断是不是刀，所以只认满伤害的空爆
 *  （残血刀空爆不在 LTT_OnSkeet 的广播范围内）。
 *
 *  作者：DeepSeek Harness
 * ===========================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <multicolors>

#define PLUGIN_VERSION "1.0.0"
#define TEAM_SURVIVOR  2

// 由 ltt_skill_lite 广播
forward void LTT_OnSkeet(int attacker, int victim, int isTeamSkeet);
forward void LTT_OnMeleeLevel(int attacker, int victim, int isHurt);

ConVar g_cEnable;
ConVar g_cOnlyLowDiff;
ConVar g_cSkeetHp;
ConVar g_cLevelHp;
ConVar g_cChipRatio;
ConVar g_cAnnounce;
ConVar g_cDebug;

bool g_bHasSkeet;
bool g_bHasLevel;

public Plugin myinfo =
{
	name        = "[LTT] Melee Skill Reward",
	author      = "DeepSeek Harness",
	description = "简单/普通难度下，刀空爆与刀牛额外回血",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cEnable      = CreateConVar("ltt_skillreward_enable",      "1",  "1=开启近战技巧回血奖励", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cOnlyLowDiff = CreateConVar("ltt_skillreward_only_lowdiff", "1",  "1=只有简单/普通难度才奖励（高级/专家不给）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cSkeetHp     = CreateConVar("ltt_skillreward_skeet_hp",    "25",  "刀空爆奖励血量", FCVAR_NOTIFY, true, 0.0);
	g_cLevelHp     = CreateConVar("ltt_skillreward_level_hp",    "25",  "刀牛奖励血量", FCVAR_NOTIFY, true, 0.0);
	g_cChipRatio   = CreateConVar("ltt_skillreward_chip_ratio",  "50",  "残血版（残血刀牛）的奖励百分比", FCVAR_NOTIFY, true, 0.0, true, 100.0);
	g_cAnnounce    = CreateConVar("ltt_skillreward_announce",    "1",  "1=回血时聊天框播报", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cDebug       = CreateConVar("ltt_skillreward_debug",       "0",  "1=输出判定日志（排查用）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "ltt_skillreward");

	// left4dhooks 那类"提供方检测"：skill_lite 在位才会创建这个 cvar
	g_bHasSkeet = (FindConVar("sm_skill_report_enable") != null);
	g_bHasLevel = g_bHasSkeet;

	LogMessage("[SkillReward] v%s 已加载 | skill_lite 在位: %s | 低难度限定: %s",
		PLUGIN_VERSION, g_bHasSkeet ? "是" : "否", g_cOnlyLowDiff.BoolValue ? "是" : "否");
}

/** 当前是不是"高级以下"（简单/普通） */
bool IsLowDifficulty()
{
	ConVar cvar = FindConVar("z_difficulty");
	if (cvar == null)
	{
		return false;                 // 读不到就当高难度，宁可不发奖励
	}

	char diff[16];
	cvar.GetString(diff, sizeof(diff));

	return (!StrEqual(diff, "Hard", false) && !StrEqual(diff, "Impossible", false));
}

bool RewardActive()
{
	if (!g_cEnable.BoolValue)
	{
		return false;
	}
	if (g_cOnlyLowDiff.BoolValue && !IsLowDifficulty())
	{
		return false;
	}
	return true;
}

/** 攻击者当前手持的是不是近战武器（刀） */
bool IsHoldingMelee(int client)
{
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon <= 0 || !IsValidEntity(weapon))
	{
		return false;
	}

	char cls[64];
	GetEdictClassname(weapon, cls, sizeof(cls));

	if (g_cDebug.BoolValue)
	{
		LogMessage("[SkillReward] 手持武器 classname = %s", cls);
	}

	return (StrEqual(cls, "weapon_melee", false) || StrContains(cls, "melee", false) != -1);
}

/** 加血，并播报 */
void GiveHealth(int client, int amount, const char[] label)
{
	if (amount <= 0 || client < 1 || client > MaxClients)
	{
		return;
	}
	if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client))
	{
		return;
	}

	int maxhp = GetEntProp(client, Prop_Send, "m_iMaxHealth");
	if (maxhp < 100)
	{
		maxhp = 100;
	}
	if (maxhp > 9999)
	{
		maxhp = 100;
	}

	int cur = GetClientHealth(client);
	if (cur >= maxhp)
	{
		return;                        // 已经满血，不浪费也不刷屏
	}

	int newhp = cur + amount;
	if (newhp > maxhp)
	{
		newhp = maxhp;
	}
	SetEntityHealth(client, newhp);

	if (g_cAnnounce.BoolValue)
	{
		CPrintToChatAll("{olive}[技巧奖励]{default} {green}%N{default} %s  +{green}%d{default} 血",
			client, label, newhp - cur);
	}

	LogMessage("[SkillReward] %N %s +%d (%d -> %d)", client, label, newhp - cur, cur, newhp);
}

/** 刀空爆（满伤害那次才会广播到这里） */
public void LTT_OnSkeet(int attacker, int victim, int isTeamSkeet)
{
	if (!RewardActive() || !g_bHasSkeet)
	{
		return;
	}
	if (!IsHoldingMelee(attacker))
	{
		return;                        // 枪空爆不给——那是专家的顺手活
	}
	GiveHealth(attacker, g_cSkeetHp.IntValue, "刀空爆");
}

/** 刀牛 / 残血刀牛 */
public void LTT_OnMeleeLevel(int attacker, int victim, int isHurt)
{
	if (!RewardActive() || !g_bHasLevel)
	{
		return;
	}

	int amount = g_cLevelHp.IntValue;
	if (isHurt != 0)
	{
		amount = amount * g_cChipRatio.IntValue / 100;
	}

	GiveHealth(attacker, amount, isHurt != 0 ? "残血刀牛" : "刀牛");
}
