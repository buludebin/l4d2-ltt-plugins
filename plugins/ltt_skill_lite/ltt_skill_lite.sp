/**
 *  ltt_skill_lite
 *
 *  精简版技能播报: 只保留四项报告
 *    1) 枪空爆 / 刀空爆  -> REP_SKEET (1) / REP_HURTSKEET (2)
 *    2) 刀牛 / 残血刀牛  -> REP_LEVEL (4) / REP_HURTLEVEL (8)
 *    3) 断舌             -> REP_TONGUECUT (64)
 *
 *  移植自 l4d2_skill_detect (Tabun & zonde306, Harry)
 *  只依赖 sourcemod / sdkhooks / sdktools; 无翻译文件, 无定时器。
 *
 *  v1.1.0 起对外暴露一个全局 forward，供其它插件复用本插件的空爆判定，
 *  避免各自实现一套导致判定不一致：
 *
 *    forward void LTT_OnSkeet(int attacker, int victim, int isTeamSkeet);
 *
 *  只在**判定成立**时触发(与 sm_skill_report_enable / report_flags 无关，
 *  关掉播报不影响这个 forward)。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <colors>

#define PLUGIN_VERSION "1.2.1"

// ------------------------------------------------------------------ 报告位 (与原插件完全一致)
#define REP_SKEET       (1 << 0)    // 1   空爆 / 队伍空爆
#define REP_HURTSKEET   (1 << 1)    // 2   残血空爆 (chip skeet)
#define REP_LEVEL       (1 << 2)    // 4   刀牛
#define REP_HURTLEVEL   (1 << 3)    // 8   残血刀牛
#define REP_TONGUECUT   (1 << 6)    // 64  断舌
#define REP_DEFAULT     "79"        // 1|2|4|8|64

// ------------------------------------------------------------------ 常量
#define SHOTGUN_BLAST_TIME  0.1     // 一次霰弹的判定窗口

#define ZC_SMOKER           1
#define ZC_HUNTER           3
#define ZC_JOCKEY           5
#define ZC_CHARGER          6

#define CUT_SLASH           4       // tongue_pull_stopped: release_type

// ------------------------------------------------------------------ 宏
#define IS_VALID_CLIENT(%1)     (%1 > 0 && %1 <= MaxClients)
#define IS_SURVIVOR(%1)         (GetClientTeam(%1) == 2)
#define IS_INFECTED(%1)         (GetClientTeam(%1) == 3)
#define IS_VALID_INGAME(%1)     (IS_VALID_CLIENT(%1) && IsClientInGame(%1))
#define IS_VALID_SURVIVOR(%1)   (IS_VALID_INGAME(%1) && IS_SURVIVOR(%1))
#define IS_VALID_INFECTED(%1)   (IS_VALID_INGAME(%1) && IS_INFECTED(%1))

// ------------------------------------------------------------------ 枚举
enum strWeaponType
{
	WPTYPE_NONE,
	WPTYPE_MELEE,
	WPTYPE_SHOTGUN,
	WPTYPE_SNIPER,
	WPTYPE_MAGNUM,
	WPTYPE_GL
};

enum strAbility
{
	ABL_HUNTERLUNGE
};

// ------------------------------------------------------------------ 全局变量
Handle g_hTrieWeapons     = null;   // 武器 classname -> strWeaponType
Handle g_hTrieAbility     = null;   // 技能名 -> strAbility

// 猎人 / 骑师: 空爆相关累计
int   g_iHunterShotDmgTeam[MAXPLAYERS + 1];                 // [victim] 队伍对它的累计伤害
int   g_iHunterShotDmg[MAXPLAYERS + 1][MAXPLAYERS + 1];     // [victim][attacker]
float g_fHunterShotStart[MAXPLAYERS + 1][MAXPLAYERS + 1];    // [victim][attacker] 本次霰弹开始时间
int   g_iHunterShotCount[MAXPLAYERS + 1][MAXPLAYERS + 1];   // [victim][attacker] 命中次数
float g_fHunterTracePouncing[MAXPLAYERS + 1];                // traceattack 里最后一次确认扑击的时间
int   g_iHunterLastHealth[MAXPLAYERS + 1];                  // 上次受伤后剩余血量
int   g_iHunterOverkill[MAXPLAYERS + 1];                    // 溢出伤害
bool  g_bHunterKilledPouncing[MAXPLAYERS + 1];               // 是否在空中被打死

// 冲锋者 / 断舌
int   g_iChargerHealth[MAXPLAYERS + 1];                     // 冲锋者上次受伤后的血量
int   g_iSmokerVictim[MAXPLAYERS + 1];                      // [smoker] 正在拉的幸存者
bool  g_bSmokerShoved[MAXPLAYERS + 1];                       // [smoker] 拉人期间是否被推

// ------------------------------------------------------------------ cvar
ConVar g_hCvarReportEnable      = null;
ConVar g_hCvarReportFlags       = null;
ConVar g_hCvarHideFakeDamage    = null;
ConVar g_hCvarAllowShotgun      = null;
ConVar g_hCvarAllowMagnum       = null;
ConVar g_hCvarAllowMelee        = null;
ConVar g_hCvarAllowSniper       = null;
ConVar g_hCvarAllowGLSkeet      = null;
ConVar g_hCvarPounceInterrupt   = null;   // z_pounce_damage_interrupt
ConVar g_hCvarChargerHealth     = null;   // z_charger_health

int  g_iPounceInterrupt = 150;
int  g_iCvarReportFlags = 79;
bool g_bCvarReportEnable = true;

// 空爆广播 (LTT_OnSkeet)，供其它插件复用本插件的判定
Handle g_hFwdSkeet = null;

// 刀牛广播 (LTT_OnMeleeLevel)，供奖励类插件复用判定
Handle g_hFwdMeleeLevel = null;

public Plugin myinfo =
{
	name        = "LTT Skill Lite (skeet / melee skeet / level / tongue cut)",
	author      = "port of l4d2_skill_detect by Tabun & zonde306, Harry",
	description = "Reports gun/melee skeets, charger levels and smoker tongue cuts only.",
	version     = PLUGIN_VERSION,
	url         = ""
};

// ================================================================== 启动
public void OnPluginStart()
{
	// ---- 配置 cvar (沿用原插件名字, 服务器现有配置继续有效)
	g_hCvarReportEnable = CreateConVar("sm_skill_report_enable", "1",
		"是否在聊天框播报技能 (见 sm_skill_report_flags)。", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarReportFlags = CreateConVar("sm_skill_report_flags", REP_DEFAULT,
		"播报位标记, 可相加: 1=空爆/队伍空爆, 2=残血空爆, 4=刀牛, 8=残血刀牛, 64=断舌。", FCVAR_NOTIFY, true, 0.0);
	g_hCvarHideFakeDamage = CreateConVar("sm_skill_hidefakedamage", "1",
		"隐藏超出目标剩余血量的溢出伤害 (影响刀牛/残血刀牛判定)。", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_hCvarAllowShotgun = CreateConVar("sm_skill_skeet_shotgun", "1",
		"是否播报霰弹枪空爆。", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarAllowMagnum = CreateConVar("sm_skill_skeet_magnum", "1",
		"是否播报马格南空爆。", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarAllowMelee = CreateConVar("sm_skill_skeet_melee", "1",
		"是否播报近战(刀)空爆。", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarAllowSniper = CreateConVar("sm_skill_skeet_sniper", "1",
		"是否播报狙击枪空爆。", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarAllowGLSkeet = CreateConVar("sm_skill_skeet_grenade_launcher", "1",
		"是否播报榴弹发射器直击空爆。", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// ---- 游戏内置 cvar (缺失时自建, 保证代码不会空指针)
	g_hCvarPounceInterrupt = FindConVar("z_pounce_damage_interrupt");
	if (g_hCvarPounceInterrupt == null)
	{
		g_hCvarPounceInterrupt = CreateConVar("z_pounce_damage_interrupt", "150",
			"Not available on this server, added by ltt_skill_lite.", FCVAR_NONE, true, 0.0);
	}

	g_hCvarChargerHealth = FindConVar("z_charger_health");
	if (g_hCvarChargerHealth == null)
	{
		g_hCvarChargerHealth = CreateConVar("z_charger_health", "600",
			"Not available on this server, added by ltt_skill_lite.", FCVAR_NONE, true, 0.0);
	}

	// ---- 空爆广播 forward: 供其它插件复用本插件的空爆判定(如杀特回血)
	g_hFwdSkeet = CreateGlobalForward("LTT_OnSkeet", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);

	// ---- 刀牛广播 forward: 供奖励类插件复用本插件的刀牛判定
	g_hFwdMeleeLevel = CreateGlobalForward("LTT_OnMeleeLevel", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);

	GetCvars();
	g_hCvarPounceInterrupt.AddChangeHook(ConVarChanged_Cvars);	g_hCvarReportEnable.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarReportFlags.AddChangeHook(ConVarChanged_Cvars);

	// ---- 事件
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Pre);
	HookEvent("player_death", Event_PlayerDeath_Pre, EventHookMode_Pre);
	HookEvent("ability_use", Event_AbilityUse, EventHookMode_Post);
	HookEvent("lunge_pounce", Event_LungePounce, EventHookMode_Post);
	HookEvent("player_shoved", Event_PlayerShoved, EventHookMode_Post);
	HookEvent("tongue_grab", Event_TongueGrab, EventHookMode_Post);
	HookEvent("tongue_pull_stopped", Event_TonguePullStopped);

	// ---- 武器 trie (classname 列表与原插件逐条一致)
	g_hTrieWeapons = CreateTrie();
	SetTrieValue(g_hTrieWeapons, "hunting_rifle",                WPTYPE_SNIPER);
	SetTrieValue(g_hTrieWeapons, "sniper_military",              WPTYPE_SNIPER);
	SetTrieValue(g_hTrieWeapons, "sniper_awp",                   WPTYPE_SNIPER);
	SetTrieValue(g_hTrieWeapons, "sniper_scout",                 WPTYPE_SNIPER);
	SetTrieValue(g_hTrieWeapons, "pistol_magnum",                WPTYPE_MAGNUM);
	SetTrieValue(g_hTrieWeapons, "pumpshotgun",                  WPTYPE_SHOTGUN);
	SetTrieValue(g_hTrieWeapons, "shotgun_chrome",               WPTYPE_SHOTGUN);
	SetTrieValue(g_hTrieWeapons, "autoshotgun",                  WPTYPE_SHOTGUN);
	SetTrieValue(g_hTrieWeapons, "shotgun_spas",                 WPTYPE_SHOTGUN);
	SetTrieValue(g_hTrieWeapons, "grenade_launcher_projectile",  WPTYPE_GL);

	g_hTrieAbility = CreateTrie();
	SetTrieValue(g_hTrieAbility, "ability_lunge", ABL_HUNTERLUNGE);

	AutoExecConfig(true, "ltt_skill_lite");
}

void ConVarChanged_Cvars(ConVar hCvar, const char[] sOldVal, const char[] sNewVal)
{
	GetCvars();
}

void GetCvars()
{
	g_iPounceInterrupt  = g_hCvarPounceInterrupt.IntValue;
	g_bCvarReportEnable = g_hCvarReportEnable.BoolValue;
	g_iCvarReportFlags  = g_hCvarReportFlags.IntValue;
}

// 报告总开关 + 对应 bit, 在播报时检查
bool ReportWanted(int flag)
{
	return (g_bCvarReportEnable && (g_iCvarReportFlags & flag) != 0);
}

// ================================================================== 生成
public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IS_VALID_INFECTED(client))
	{
		return Plugin_Continue;
	}

	int zClass = GetEntProp(client, Prop_Send, "m_zombieClass");

	switch (zClass)
	{
		case ZC_SMOKER:
		{
			g_iSmokerVictim[client] = 0;
			g_bSmokerShoved[client] = false;
		}
		case ZC_HUNTER:
		{
			SDKUnhook(client, SDKHook_TraceAttack, TraceAttack_Hunter);
			SDKHook(client, SDKHook_TraceAttack, TraceAttack_Hunter);

			ResetHunter(client, true);
		}
		case ZC_JOCKEY:
		{
			SDKUnhook(client, SDKHook_TraceAttack, TraceAttack_Jockey);
			SDKHook(client, SDKHook_TraceAttack, TraceAttack_Jockey);

			ResetHunter(client, true);
		}
		case ZC_CHARGER:
		{
			g_iChargerHealth[client] = g_hCvarChargerHealth.IntValue;
		}
	}

	return Plugin_Continue;
}

public Action Event_AbilityUse(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IS_VALID_INGAME(client))
	{
		return Plugin_Continue;
	}

	char abilityName[64];
	event.GetString("ability", abilityName, sizeof(abilityName));

	strAbility ability;
	if (!GetTrieValue(g_hTrieAbility, abilityName, ability))
	{
		return Plugin_Continue;
	}

	if (ability == ABL_HUNTERLUNGE)
	{
		// 猎人起跳: 清空上一轮的空爆累计
		ResetHunter(client);
	}

	return Plugin_Continue;
}

public Action Event_LungePounce(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	// 扑中了: 之前累计的 (非空爆) 伤害作废
	ResetHunter(client);

	return Plugin_Continue;
}

// ================================================================== 受伤 (空爆 / 刀空爆 / 刀牛 的主判定点)
void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	int damage = event.GetInt("dmg_health");
	int damagetype = event.GetInt("type");

	if (!IS_VALID_INFECTED(victim))
	{
		return;
	}

	int zClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
	int health = event.GetInt("health");

	if (damage < 1)
	{
		return;
	}

	switch (zClass)
	{
		case ZC_HUNTER, ZC_JOCKEY:
		{
			// 不是幸存者打的: 只记录剩余血量
			if (!IS_VALID_SURVIVOR(attacker))
			{
				g_iHunterLastHealth[victim] = health;
				return;
			}

			// 溢出伤害折算 (与原插件保持一致)
			if (g_iHunterLastHealth[victim] > 0 && damage > g_iHunterLastHealth[victim])
			{
				// 【v1.2.1 · 2026-10-02 源码审核修复】顺序错了：旧代码先把 damage 夹到"剩余血量"，
				// 下一行再算 剩余血量 - damage ⇒ 恒等于 0。后果：溢出伤害永远是 0、
				// 依赖它的"残血空爆"判定成了死代码。必须先算溢出、再夹 damage。
				g_iHunterOverkill[victim] = damage - g_iHunterLastHealth[victim];
				damage = g_iHunterLastHealth[victim];
				g_iHunterLastHealth[victim] = 0;
			}

			// 上一次霰弹太久远了? 不算同一次
			if (g_iHunterShotDmg[victim][attacker] > 0 && (GetEngineTime() - g_fHunterShotStart[victim][attacker]) > SHOTGUN_BLAST_TIME)
			{
				g_fHunterShotStart[victim][attacker] = 0.0;
			}

			/*
				猎人被真空爆时 m_isAttemptingToPounce 已被清 0,
				所以用 traceattack 记录的时间戳 (必须紧贴本次伤害, 0.001s 内) 兜底。
			*/
			bool isPouncing = (GetEntProp(victim, Prop_Send, "m_isAttemptingToPounce") != 0
				|| (g_fHunterTracePouncing[victim] != 0.0 && (GetEngineTime() - g_fHunterTracePouncing[victim]) < 0.001));

			if (isPouncing || IsJockeyLeaping(victim))
			{
				if (damagetype & DMG_BUCKSHOT)
				{
					// 第一次命中 = 新一次霰弹
					if (g_fHunterShotStart[victim][attacker] == 0.0)
					{
						g_fHunterShotStart[victim][attacker] = GetEngineTime();
						g_iHunterShotCount[victim][attacker] += 1;
					}

					g_iHunterShotDmg[victim][attacker] += damage;
					g_iHunterShotDmgTeam[victim] += damage;

					if (health == 0)
					{
						g_bHunterKilledPouncing[victim] = true;
					}
				}
				else if (damagetype & (DMG_BLAST | DMG_PLASMA) && health == 0)
				{
					// 榴弹直击: DMG_BLAST | DMG_PLASMA (间接命中是 DMG_AIRBOAT)
					char weaponB[32];
					strWeaponType weaponTypeB;
					event.GetString("weapon", weaponB, sizeof(weaponB));
					if (GetTrieValue(g_hTrieWeapons, weaponB, weaponTypeB) && weaponTypeB == WPTYPE_GL)
					{
						if (g_hCvarAllowGLSkeet.BoolValue)
						{
							HandleSkeet(attacker, victim, WPTYPE_GL, false, zClass == ZC_HUNTER, 1);
						}
					}
				}
				else if (damagetype & DMG_BULLET)
				{
					g_iHunterShotCount[victim][attacker] += 1;

					char weaponA[32];
					strWeaponType weaponTypeA;
					event.GetString("weapon", weaponA, sizeof(weaponA));
					if (GetTrieValue(g_hTrieWeapons, weaponA, weaponTypeA))
					{
						if (weaponTypeA == WPTYPE_SNIPER)
						{
							if (health == 0)
							{
								if (damage >= g_iPounceInterrupt)
								{
									if (g_hCvarAllowSniper.BoolValue)
									{
										HandleSkeet(attacker, victim, WPTYPE_SNIPER, false, zClass == ZC_HUNTER, g_iHunterShotCount[victim][attacker]);
									}
								}
								else if (g_hCvarAllowSniper.BoolValue)
								{
									// 伤害不够 -> 残血空爆
									HandleNonSkeet(attacker, victim, damage, WPTYPE_SNIPER, zClass == ZC_HUNTER, g_iHunterShotCount[victim][attacker]);
								}

								ResetHunter(victim);
								g_iHunterLastHealth[victim] = 0;
								return;
							}
						}
						else if (weaponTypeA == WPTYPE_MAGNUM)
						{
							if (health == 0)
							{
								if (damage >= g_iPounceInterrupt)
								{
									if (g_hCvarAllowMagnum.BoolValue)
									{
										HandleSkeet(attacker, victim, WPTYPE_MAGNUM, false, zClass == ZC_HUNTER, g_iHunterShotCount[victim][attacker]);
									}
								}
								else if (g_hCvarAllowMagnum.BoolValue)
								{
									HandleNonSkeet(attacker, victim, damage, WPTYPE_MAGNUM, zClass == ZC_HUNTER, g_iHunterShotCount[victim][attacker]);
								}

								ResetHunter(victim);
								g_iHunterLastHealth[victim] = 0;
								return;
							}
						}
					}

					g_iHunterShotDmgTeam[victim] += damage;
					g_iHunterShotDmg[victim][attacker] += damage;
				}
				else if (damagetype & DMG_SLASH || damagetype & DMG_CLUB)
				{
					// 近战
					if (damage >= g_iPounceInterrupt)
					{
						if (g_hCvarAllowMelee.BoolValue && health == 0)
						{
							HandleSkeet(attacker, victim, WPTYPE_MELEE, false, zClass == ZC_HUNTER, 1);
						}
						// 注意: 近战分支不设置 g_bHunterKilledPouncing (与原插件一致)
					}
					else if (health == 0)
					{
						// 残血空爆 (必定是溢出伤害)
						if (g_hCvarAllowMelee.BoolValue)
						{
							HandleNonSkeet(attacker, victim, damage, WPTYPE_MELEE, zClass == ZC_HUNTER, 1);
						}
					}

					ResetHunter(victim);
					g_iHunterLastHealth[victim] = health;
					return;
				}
			}
			else if (health == 0)
			{
				// 非扑击状态死亡: 不要误判成"没空爆"
				g_bHunterKilledPouncing[victim] = false;
			}

			g_iHunterLastHealth[victim] = health;
		}

		case ZC_CHARGER:
		{
			if (IS_VALID_SURVIVOR(attacker))
			{
				// 刀牛: 近战打死且正在冲锋
				if (health == 0 && (damagetype & DMG_CLUB || damagetype & DMG_SLASH))
				{
					int iChargeHealth = g_hCvarChargerHealth.IntValue;
					int abilityEnt = GetEntPropEnt(victim, Prop_Send, "m_customAbility");
					if (IsValidEntity(abilityEnt) && GetEntProp(abilityEnt, Prop_Send, "m_isCharging"))
					{
						// 隐藏溢出伤害: 用已知血量代替本次伤害
						if (g_hCvarHideFakeDamage.BoolValue)
						{
							damage = g_iChargerHealth[victim];
						}

						if (damage >= RoundToNearest(iChargeHealth * 0.5))
						{
							HandleLevel(attacker, victim);
						}
						else
						{
							HandleLevelHurt(attacker, victim, damage);
						}
					}
				}
			}

			if (health > 0)
			{
				g_iChargerHealth[victim] = health;
			}
		}
	}
}

// ================================================================== 死亡 (霰弹空爆 / 队伍空爆 的判定点)
void Event_PlayerDeath_Pre(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (!IS_VALID_INFECTED(victim))
	{
		return;
	}

	int zClass = GetEntProp(victim, Prop_Send, "m_zombieClass");

	switch (zClass)
	{
		case ZC_HUNTER, ZC_JOCKEY:
		{
			if (!IS_VALID_SURVIVOR(attacker))
			{
				return;
			}

			char weapon_type[64];
			event.GetString("weapon", weapon_type, sizeof(weapon_type));
			strWeaponType weaponType = WPTYPE_NONE;
			GetTrieValue(g_hTrieWeapons, weapon_type, weaponType);

			if (weaponType == WPTYPE_SHOTGUN && !g_hCvarAllowShotgun.BoolValue)
			{
				ResetHunter(victim, true);
			}

			if (g_iHunterShotDmgTeam[victim] > 0 && g_bHunterKilledPouncing[victim])
			{
				if (g_iHunterShotDmgTeam[victim] > g_iHunterShotDmg[victim][attacker]
					&& g_iHunterShotDmgTeam[victim] >= g_iPounceInterrupt)
				{
					// 队伍空爆
					HandleSkeet(attacker, victim, weaponType, true, zClass == ZC_HUNTER, g_iHunterShotCount[victim][attacker]);
				}
				else if (g_iHunterShotDmg[victim][attacker] >= g_iPounceInterrupt)
				{
					// 单人空爆
					HandleSkeet(attacker, victim, weaponType, false, zClass == ZC_HUNTER, g_iHunterShotCount[victim][attacker]);
				}
				else if (g_iHunterOverkill[victim] > 0)
				{
					HandleNonSkeet(attacker, victim, g_iHunterShotDmgTeam[victim], weaponType, zClass == ZC_HUNTER, g_iHunterShotCount[victim][attacker]);
				}
				else
				{
					HandleNonSkeet(attacker, victim, g_iHunterShotDmg[victim][attacker], weaponType, zClass == ZC_HUNTER, g_iHunterShotCount[victim][attacker]);
				}
			}

			ResetHunter(victim, true);
		}
	}
}

// ================================================================== 推人 / 断舌
public Action Event_PlayerShoved(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (!IS_VALID_SURVIVOR(attacker) || !IS_VALID_INFECTED(victim))
	{
		return Plugin_Continue;
	}

	// 记录 smoker 在拉人期间是否被推 (被推过 -> 之后的断舌不播报)
	if (g_iSmokerVictim[victim] == attacker ||
		GetEntPropEnt(attacker, Prop_Send, "m_tongueVictim") == victim ||
		GetEntPropEnt(victim, Prop_Send, "m_tongueOwner") == attacker)
	{
		g_bSmokerShoved[victim] = true;
	}

	return Plugin_Continue;
}

public Action Event_TongueGrab(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = GetClientOfUserId(event.GetInt("userid"));
	int victim = GetClientOfUserId(event.GetInt("victim"));

	if (IS_VALID_INFECTED(attacker) && IS_VALID_SURVIVOR(victim))
	{
		// 新的一次拉人: 清空状态
		g_bSmokerShoved[attacker] = false;
		g_iSmokerVictim[attacker] = victim;
	}

	return Plugin_Continue;
}

public Action Event_TonguePullStopped(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = GetClientOfUserId(event.GetInt("userid"));
	int victim = GetClientOfUserId(event.GetInt("victim"));
	int smoker = GetClientOfUserId(event.GetInt("smoker"));
	int reason = event.GetInt("release_type");

	if (!IS_VALID_SURVIVOR(attacker) || !IS_VALID_INFECTED(smoker))
	{
		return Plugin_Continue;
	}

	/*
		断舌: 只有被拉的幸存者自己挣脱 (attacker == victim),
		release_type == CUT_SLASH, 拉人期间 smoker 没被推过,
		且幸存者当前拿的是近战武器。
	*/
	if (attacker == victim && reason == CUT_SLASH && !g_bSmokerShoved[smoker])
	{
		char weapon[32];
		GetClientWeapon(attacker, weapon, sizeof(weapon));
		if (StrEqual(weapon, "weapon_melee", false))
		{
			HandleTongueCut(attacker, smoker);
		}
	}

	g_iSmokerVictim[smoker] = 0;

	return Plugin_Continue;
}

// ================================================================== TraceAttack (记录扑击时间戳)
public Action TraceAttack_Hunter(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
	if (!IS_VALID_SURVIVOR(attacker) || !IsValidEdict(inflictor))
	{
		return Plugin_Continue;
	}

	// 记录最后一次确认还在扑击的时间
	if (GetEntProp(victim, Prop_Send, "m_isAttemptingToPounce"))
	{
		g_fHunterTracePouncing[victim] = GetEngineTime();
	}
	else
	{
		g_fHunterTracePouncing[victim] = 0.0;
	}

	return Plugin_Continue;
}

public Action TraceAttack_Jockey(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
	if (!IS_VALID_SURVIVOR(attacker) || !IsValidEdict(inflictor))
	{
		return Plugin_Continue;
	}

	if (IsJockeyLeaping(victim))
	{
		g_fHunterTracePouncing[victim] = GetEngineTime();
	}
	else
	{
		g_fHunterTracePouncing[victim] = 0.0;
	}

	return Plugin_Continue;
}

// 骑师是否在跳跃 (与原插件逐行一致, 未使用 left4dhooks)
bool IsJockeyLeaping(int jockey)
{
	if (GetEntProp(jockey, Prop_Send, "m_zombieClass") != ZC_JOCKEY ||
		GetEntPropEnt(jockey, Prop_Send, "m_hGroundEntity") > -1 ||
		GetEntityMoveType(jockey) != MOVETYPE_WALK ||
		GetEntProp(jockey, Prop_Send, "m_nWaterLevel") >= 3 ||	// 0: 无水, 1: 一点, 2: 半身, 3: 全身
		GetEntPropEnt(jockey, Prop_Send, "m_jockeyVictim") > -1)
	{
		return false;
	}

	int abilityEnt = GetEntPropEnt(jockey, Prop_Send, "m_customAbility");
	if (IsValidEntity(abilityEnt) && HasEntProp(abilityEnt, Prop_Send, "m_isLeaping") &&
		GetEntProp(abilityEnt, Prop_Send, "m_isLeaping"))
	{
		return true;
	}

	float vel[3];
	GetEntPropVector(jockey, Prop_Data, "m_vecVelocity", vel);
	vel[2] = 0.0;

	if (GetVectorLength(vel) >= 15.0 && GetEntPropEnt(jockey, Prop_Send, "m_hGroundEntity") == -1)
	{
		return true;
	}

	return false;
}

// ================================================================== 状态清理
void ResetHunter(int client, bool death = false)
{
	g_iHunterShotDmgTeam[client] = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		g_iHunterShotDmg[client][i] = 0;
		g_fHunterShotStart[client][i] = 0.0;

		if (death)
		{
			g_iHunterShotCount[client][i] = 0;
		}
	}

	g_iHunterOverkill[client] = 0;
}

// ================================================================== 播报
// 真空爆 / 队伍空爆
void HandleSkeet(int attacker, int victim, strWeaponType eWeaponType, bool isTeamSkeet, bool isHunter, int shots)
{
	if (!IS_VALID_INGAME(attacker))
	{
		return;
	}

	// 先广播"这是一次真空爆/队伍空爆"。必须放在 ReportWanted 之前 ——
	// 否则关掉播报时，依赖它的插件(杀特回血)会跟着失效。
	Call_StartForward(g_hFwdSkeet);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_PushCell(isTeamSkeet ? 1 : 0);
	Call_Finish();

	if (!ReportWanted(REP_SKEET))
	{
		return;
	}

	if (isTeamSkeet)
	{
		CPrintToChatAll("{blue} {green}%N{blue} 被 {green}%N{blue} 和队伍合力空爆了", victim, attacker);
		return;
	}

	switch (eWeaponType)
	{
		case WPTYPE_MELEE:
		{
			if (isHunter)
			{
				CPrintToChatAll("{olive} 有点强，，， {green}%N{blue} 近战秒杀了飞扑的 {green}%N{blue}", attacker, victim);
			}
			else
			{
				CPrintToChatAll("{olive} 这么强？！ {green}%N{blue} 近战秒杀了空中的 {green}%N{blue}", attacker, victim);
			}
		}
		case WPTYPE_SNIPER:
		{
			CPrintToChatAll("{olive}(≧∇≦)是打靶高手！{green}%N{blue} 狙击空爆了  {green}%N{blue}", attacker, victim);
		}
		case WPTYPE_MAGNUM:
		{
			CPrintToChatAll("{olive}(≧∇≦)是打靶高手！{green}%N{blue} 马格南空爆了 {green}%N{blue}", attacker, victim);
		}
		case WPTYPE_SHOTGUN:
		{
			CPrintToChatAll("{olive}(≧∇≦)是打靶高手！{green}%N{blue} 使用喷子空爆了 {green}%N{blue}", attacker, victim);
		}
		case WPTYPE_GL:
		{
			if (isHunter)
			{
				CPrintToChatAll("{olive}(≧∇≦)是打靶高手！{green}%N{blue} 榴弹击中了飞扑的 {green}%N{blue}", attacker, victim);
			}
			else
			{
				CPrintToChatAll("{olive}(≧∇≦)是打靶高手！{green}%N{blue} 榴弹击中了空中的 {green}%N{blue}", attacker, victim);
			}
		}
		default:
		{
			// 其他子弹
			if (shots > 1)
			{
				CPrintToChatAll("{olive}(≧∇≦)是打靶高手！{green}%N{blue} 空爆了 {green}%N{blue} ( {green}%d{blue} 次射击)", attacker, victim, shots);
			}
			else
			{
				CPrintToChatAll("{olive}(≧∇≦)是打靶高手！{green}%N{blue} 空爆了 {green}%N{blue}", attacker, victim);
			}
		}
	}
}

// 残血空爆 (伤害低于 z_pounce_damage_interrupt)
void HandleNonSkeet(int attacker, int victim, int damage, strWeaponType eWeaponType, bool isHunter, int shots)
{
	if (!ReportWanted(REP_HURTSKEET) || !IS_VALID_INGAME(attacker))
	{
		return;
	}

	switch (eWeaponType)
	{
		case WPTYPE_MELEE:
		{
			if (isHunter)
			{
				CPrintToChatAll("{blue} {green}%N{blue} 砍死了飞扑的 {green}%N{blue} ( {green}%d{blue} 伤害)", attacker, victim, damage);
			}
			else
			{
				CPrintToChatAll("{blue} {green}%N{blue} 砍死了空中的 {green}%N{blue} ( {green}%d{blue} 伤害)", attacker, victim, damage);
			}
		}
		case WPTYPE_SNIPER:
		{
			CPrintToChatAll("{olive}(≧∇≦)是打靶高手！{green}%N{blue} 狙击空爆了  {green}%N{blue} ( {green}%d{blue} 伤害)", attacker, victim, damage);
		}
		case WPTYPE_MAGNUM:
		{
			CPrintToChatAll("{olive}(≧∇≦)是打靶高手！{green}%N{blue} 马格南空爆了 {green}%N{blue} ( {green}%d{blue} 伤害)", attacker, victim, damage);
		}
		case WPTYPE_SHOTGUN:
		{
			CPrintToChatAll("{olive}(≧∇≦)是打靶高手！{green}%N{blue} 使用喷子空爆了 {green}%N{blue} ( {green}%d{blue} 伤害)", attacker, victim, damage);
		}
		default:
		{
			if (shots > 1)
			{
				CPrintToChatAll("{olive}(≧∇≦)是打靶高手！{green}%N{blue} 空爆了 {green}%N{blue} ( {green}%d{blue} 次射击, {green}%d{blue} 伤害)", attacker, victim, shots, damage);
			}
			else
			{
				CPrintToChatAll("{olive}(≧∇≦)是打靶高手！{green}%N{blue} 空爆了 {green}%N{blue} ( {green}%d{blue} 伤害)", attacker, victim, damage);
			}
		}
	}
}

// 刀牛
void HandleLevel(int attacker, int victim)
{
	if (!IS_VALID_INGAME(attacker))
	{
		return;
	}

	// 先广播再判断播报 —— 否则关掉聊天播报时，依赖它的插件(刀牛奖励)会一起失效
	Call_StartForward(g_hFwdMeleeLevel);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_PushCell(0);              // 0 = 完整刀牛
	Call_Finish();

	if (!ReportWanted(REP_LEVEL))
	{
		return;
	}

	CPrintToChatAll("{olive} 到底有多强？！ {green}%N{blue} 近战秒杀了冲锋的 {green}%N{blue}", attacker, victim);
}

// 残血刀牛
void HandleLevelHurt(int attacker, int victim, int damage)
{
	if (!IS_VALID_INGAME(attacker))
	{
		return;
	}

	// 残血刀牛也广播（1 = 残血/未打满）
	Call_StartForward(g_hFwdMeleeLevel);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_PushCell(1);
	Call_Finish();

	if (!ReportWanted(REP_HURTLEVEL))
	{
		return;
	}

	CPrintToChatAll("{olive} ！？强强？！ {green}%N{blue} 近战砍死了冲锋的 {green}%N{blue} ( {green}%d{blue} 伤害)", attacker, victim, damage);
}

// 断舌
void HandleTongueCut(int attacker, int victim)
{
	if (!ReportWanted(REP_TONGUECUT) || !IS_VALID_INGAME(attacker))
	{
		return;
	}

	CPrintToChatAll("{olive} 到底有多强？！ {green}%N{blue} 近战砍断了 {green}%N{blue} 的舌头", attacker, victim);
}
