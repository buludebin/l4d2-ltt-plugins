/**
 *  ltt_melee_onehit —— 近战武器对特感**一刀死**（可配置哪些特感；默认牛牛除外）
 *
 *  【服主要求，2026-10-05】
 *  「刀对特感伤害能不能设置一刀固定死这样，砍 250 血的特感砍到脚剩余 63 血真的很尴尬，牛牛除外」
 *
 *  【为什么会有"砍到脚剩 63 血"】
 *  L4D2 近战武器伤害按命中部位打折（头/躯干/四肢倍率不同），所以同一刀砍头能秒、砍脚就剩一口气。
 *  本插件不看部位：只要是**近战武器的挥砍**打到**名单内的特感**，就把伤害改成「它当前血量 + 1」
 *  ⇒ 一刀固定带走，砍到哪儿都一样。
 *
 *  【默认名单】1 烟鬼 / 2 胖子 / 3 猎人 / 4 毒妇 / 5 骑师  （**6 牛 / 7 女巫 / 8 坦克 不在名单**）
 *  想改：`ltt_meleeone_classes "1,2,3,4,5,6"`（也支持纯数字位掩码：63 = 全部六种）
 *
 *  【怎么区分"砍"和"推"】推（+attack2）对特感几乎不造成伤害，所以还加了一道
 *  `ltt_meleeone_min_dmg`（默认 20）门槛；再把武器类名限定为近战（`weapon_melee` / `weapon_chainsaw`）
 *  ⇒ 推、枪械、爆炸都不会被误判成一刀死。
 *
 *  【实现】SDKHooks 的 `OnTakeDamageAlive`（伤害真正生效前的最后一道，晚于 OnTakeDamage 的各种减免，
 *  所以服上那个 `Bot SI skeet/level damage fix` 的减免不会把这一刀又扣回去）。
 *
 *  【验证】`ltt_meleeone_log 1`（默认开）会为每次触发写一行日志：
 *    `[MeleeOne] 张三 用近战一刀带走 Jockey（血量 325，原始伤害 187 → 326）`
 *  关掉插件：`ltt_meleeone_enable 0`（或 `sm plugins unload ltt_melee_onehit`，无残留）。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.2"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

static const char g_sClass[9][12] =
{
	"", "Smoker", "Boomer", "Hunter", "Spitter", "Jockey", "Charger", "Witch", "Tank"
};

ConVar g_cEnable, g_cClasses, g_cMinDmg, g_cLog, g_cHumans;
bool   g_bHit[9];                 // 名单：按 z 职业号 1..8
int    g_iSaved;                  // 本图"本来砍不死、被抬成一刀死"的刀数
char   g_sMap[64];

public Plugin myinfo =
{
	name        = "[LTT] Melee One-Hit Specials",
	author      = "DeepSeek Harness",
	description = "近战武器对名单内的特感一刀固定死（默认牛牛/女巫/坦克除外），不看砍到哪个部位",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cEnable  = CreateConVar("ltt_meleeone_enable",  "1",        "1=近战武器对名单内特感一刀死（砍脚也死）｜0=关", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cClasses = CreateConVar("ltt_meleeone_classes", "1,2,3,4,5","哪些特感一刀死（职业号逗号分隔：1烟鬼 2胖子 3猎人 4毒妇 5骑师 6牛 7女巫 8坦克）", FCVAR_NOTIFY);
	g_cMinDmg  = CreateConVar("ltt_meleeone_min_dmg", "20.0",     "伤害门槛：只有≥这个值才算『砍』（推对特感几乎没伤害，用来排除推）", FCVAR_NOTIFY, true, 0.0, true, 2000.0);
	g_cLog     = CreateConVar("ltt_meleeone_log",     "1",        "1=每次触发写一行日志（验收用）｜0=不写", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cHumans  = CreateConVar("ltt_meleeone_humans_only", "1", "1=只对真人玩家生效（BOT 的近战照常）｜0=真人和 BOT 都一刀死", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "ltt_melee_onehit");

	g_cClasses.AddChangeHook(OnClassesChanged);
	ParseClasses();

	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			SDKHook(i, SDKHook_OnTakeDamageAlive, OnTakeDamageAlive);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamageAlive, OnTakeDamageAlive);
}

public void OnMapStart()
{
	GetCurrentMap(g_sMap, sizeof(g_sMap));
	g_iSaved = 0;
}

public void OnMapEnd()
{
	if (g_iSaved > 0)
		LogMessage("[MeleeOne] 地图=%s 本图被抬成一刀死的刀数：%d（这些本来会砍到脚/非致命部位而活下来）", g_sMap, g_iSaved);
	g_iSaved = 0;
}

public void OnConfigsExecuted()
{
	ParseClasses();          // cfg 里改完也能立刻生效
}

void OnClassesChanged(ConVar cvar, const char[] oldVal, const char[] newVal)
{
	ParseClasses();
}

/** 解析名单：支持 "1,2,3" 逗号列表，也支持纯数字位掩码（1烟|2胖|4猎|8毒|16骑|32牛|64女巫|128坦克） */
void ParseClasses()
{
	for (int i = 1; i <= 8; i++)
		g_bHit[i] = false;

	char buf[128];
	g_cClasses.GetString(buf, sizeof(buf));

	// 纯数字 ⇒ 当位掩码（并且必须是 2 的幂组合时才合理；这里按"整体是数字"处理）
	bool allDigits = (buf[0] != '\0');
	for (int i = 0; buf[i] != '\0'; i++)
	{
		if (buf[i] < '0' || buf[i] > '9')
		{
			allDigits = false;
			break;
		}
	}

	if (allDigits)
	{
		int mask = StringToInt(buf);
		for (int c = 1; c <= 8; c++)
			if ((mask & (1 << (c - 1))) != 0)
				g_bHit[c] = true;
	}
	else
	{
		char parts[16][8];
		int n = ExplodeString(buf, ",", parts, sizeof(parts), sizeof(parts[]));
		for (int i = 0; i < n; i++)
		{
			TrimString(parts[i]);
			int c = StringToInt(parts[i]);
			if (c >= 1 && c <= 8)
				g_bHit[c] = true;
		}
	}

	int cnt = 0;
	char list[128];
	list[0] = '\0';
	for (int c = 1; c <= 8; c++)
	{
		if (!g_bHit[c])
			continue;
		cnt++;
		Format(list, sizeof(list), "%s%s%d(%s)", list, (list[0] == '\0') ? "" : ",", c, g_sClass[c]);
	}

	if (cnt == 0)
	{
		LogError("[MeleeOne] ltt_meleeone_classes=\"%s\" 解析出 0 个特感 ⇒ 一刀死不会生效（检查是不是写了非法值）", buf);
	}
	else
	{
		LogMessage("[MeleeOne] v%s 名单：%s ｜ 伤害门槛 %.0f ｜ 开关=%d ｜ 仅真人=%d",
			PLUGIN_VERSION, list, g_cMinDmg.FloatValue, g_cEnable.BoolValue, g_cHumans.BoolValue);
	}
}

bool IsMeleeClass(const char[] cls)
{
	if (cls[0] == '\0')
		return false;
	return (StrContains(cls, "melee", false) != -1) || (StrEqual(cls, "weapon_chainsaw", false));
}

bool IsMeleeHit(int weapon, int inflictor)
{
	char cls[64];
	if (weapon > 0 && IsValidEdict(weapon))
	{
		GetEdictClassname(weapon, cls, sizeof(cls));
		if (IsMeleeClass(cls))
			return true;
	}
	if (inflictor > 0 && IsValidEdict(inflictor))
	{
		GetEdictClassname(inflictor, cls, sizeof(cls));
		if (IsMeleeClass(cls))
			return true;
	}
	return false;
}

public Action OnTakeDamageAlive(int victim, int &attacker, int &inflictor, float &damage,
	int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
	if (g_cEnable == null || !g_cEnable.BoolValue)
		return Plugin_Continue;

	// 受害者必须是"活着的人类/机器人客户端的特感"（坦克/女巫不在名单里就不会进来）
	if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
		return Plugin_Continue;
	if (GetClientTeam(victim) != TEAM_INFECTED)
		return Plugin_Continue;

	int cls = GetEntProp(victim, Prop_Send, "m_zombieClass");
	if (cls < 1 || cls > 8 || !g_bHit[cls])
		return Plugin_Continue;

	// 攻击者必须是人类生还者
	if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
		return Plugin_Continue;
	if (GetClientTeam(attacker) != TEAM_SURVIVOR)
		return Plugin_Continue;
	if (g_cHumans.BoolValue && IsFakeClient(attacker))
		return Plugin_Continue;

	// 必须够疼（排除"推"）且确实来自近战武器
	if (damage < g_cMinDmg.FloatValue)
		return Plugin_Continue;
	if (!IsMeleeHit(weapon, inflictor))
		return Plugin_Continue;

	int hp = GetClientHealth(victim);
	if (hp <= 0)
		return Plugin_Continue;

	// 只救"本来砍不死"的那些刀（砍到脚/非致命部位）；本来就能秒的刀不碰，也不刷日志
	if (damage >= float(hp))
		return Plugin_Continue;

	float before = damage;
	damage = float(hp) + 1.0;            // 一刀固定死：不管砍到哪个部位
	g_iSaved++;

	if (g_cLog.BoolValue)
	{
		LogMessage("[MeleeOne] %N 用近战砍 %s：本来只砍掉 %.0f（它还剩 %d 血）→ 抬成一刀死",
			attacker, g_sClass[cls], before, hp);
	}

	return Plugin_Changed;
}
