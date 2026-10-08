/**
 *  ltt_no_interrupt  v1.1.0  —— 小丧尸不能打断救助
 *
 *  【v1.1.0 的重要更正 · 服主 2026-10-02 指出】
 *  我 v1.0.0 的说明写"L4D2 的打断机制是救助者挨打 ⇒ 打断"，服主当场纠正了游戏内实际现象：
 *    **倒地生还者正在被拉起（进度条在读）时，只要有伤害落到"被救的那个人"身上，进度条就重置**
 *    —— 所以倒地者周围围一圈小丧尸时根本拉不起来人。
 *  这条纠正改变了结论：R7WS 那个插件把判据放在"被救者"身上**方向是对的**；
 *  它每次返回 `Plugin_Handled`（伤害不进引擎管线）⇒ 按上面的机制，它**确实**能挡住
 *  "被救者挨打导致进度重置"。我先前的说法（"完全没做这件事"）是错的，一并更正。
 *  它真正的问题变成：① 冷却期内所有小丧尸伤害被全吞、冷却外只写一个固定伤害，而且是
 *  `SetEntProp(m_iHealth)` **直写血量** ⇒ 没有命中音效/击退/`player_hurt` 事件；
 *  ② `bool CanHurt[32]` + 我们 `MaxClients=32` ⇒ client 32 读/写越界（`round_start` 的
 *  `for(i=0;i<32;i++)` 也漏了 32 号槽）；③ 冷却计时器传 client 索引不是 userid ⇒ 退服后槽位
 *  复用会给别人开门；④ 只保护"被救者"一侧，救助者一侧没覆盖。
 *
 *  【本插件的口径：只在"救助进行中"挡，不把倒地者变成无敌】
 *    · 被救者一侧：`m_reviveOwner > 0`（有人正在拉他）→ 挡伤害 ⇒ 进度条不会被小丧尸重置；
 *      （判据先例：l4d_gear_transfer.sp:2451 用 m_reviveOwner 判"正在被救"）
 *    · 救助者一侧：`m_reviveTarget > 0`（他正在救人）→ 挡伤害 ⇒ 覆盖"救助者被打也断"的情形；
 *      （判据先例：l4d_target_override.sp:1999、l4d_selfhelp_en.sp:964-965）
 *    · 没人拉的时候，小丧尸打倒地/挂边者**照常掉血**（多特压力不变）；
 *      想要"倒地期间一直不被小丧尸打"这种更强的手感，用 `ltt_nointerrupt_victim_always 1`。
 *    · 挡 = 返回 `Plugin_Handled`，伤害不进引擎管线 ⇒ 既不重置进度也不掉血
 *      （"不打断"必须这样：只把伤害改小没用，引擎照样判定重置）。
 *
 *  【开关】
 *    ltt_nointerrupt_enable          1    总开关
 *    ltt_nointerrupt_src             1    1=只挡小丧尸(infected) 2=小丧尸+特感(含 Tank/Witch) 3=所有伤害
 *    ltt_nointerrupt_sides           3    1=只保护被救者 2=只保护救助者 3=两边都保护
 *    ltt_nointerrupt_victim_always   0    1=倒地/挂边期间"一直"挡小丧尸（不只在被拉的时候）
 *    ltt_nointerrupt_victim_throttle 0    1=同时开启原插件那套"倒地/挂边者挨小丧尸伤害节流"
 *                                         （做对的版本：冷却外 Plugin_Changed 改数值，引擎正常结算）
 *    ltt_nointerrupt_dmg             0    节流固定伤害；0=按难度表 1/2/5/20
 *    ltt_nointerrupt_cd              0.0  节流冷却秒；0=按难度表 0.50/0.33/0.50/1.00
 *    ltt_nointerrupt_log             1    1=每次挡下都写日志（长期跑图统计用）
 *
 *  【日志口径】每图一条汇总：
 *    [NoInterrupt] 地图=… 本图：为被救者挡下 N 次（其中挂边 M 次）｜为救助者挡下 K 次｜节流 X 次
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>

#define PLUGIN_VERSION "1.1.0"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

static const int   g_iDmgByDiff[4] = { 1, 2, 5, 20 };
static const float g_flCdByDiff[4] = { 0.50, 0.33, 0.50, 1.00 };

ConVar g_cEnable, g_cSrc, g_cSides, g_cVictimAlways, g_cVictimThrottle, g_cDmg, g_cCd, g_cLog;

bool g_bCanHurt[MAXPLAYERS + 1];       // 节流用（用 MAXPLAYERS+1，不重犯 [32] 越界）

int g_iBlockedRevivee;                 // 本图：为"被救者"挡下几次
int g_iBlockedReviveeHang;             // 其中"挂边"状态几次
int g_iBlockedReviver;                 // 本图：为"救助者"挡下几次
int g_iThrottled;                      // 本图：改成固定伤害几次

public Plugin myinfo =
{
	name        = "[LTT] No Interrupt (小丧尸不打断救助)",
	author      = "DeepSeek Harness",
	description = "救助进行中：小丧尸打被救者/救助者都不会重置救援进度条",
	version     = PLUGIN_VERSION,
	url         = ""
}

public void OnPluginStart()
{
	g_cEnable         = CreateConVar("ltt_nointerrupt_enable", "1", "【v1.1.0】1=开启：救助进行中，小丧尸打被救者/救助者都不会打断进度条", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cSrc            = CreateConVar("ltt_nointerrupt_src", "1", "【v1.1.0】挡哪些来源：1=只挡小丧尸(infected)｜2=小丧尸+特感(含 Tank/Witch)｜3=所有伤害", FCVAR_NOTIFY, true, 1.0, true, 3.0);
	g_cSides          = CreateConVar("ltt_nointerrupt_sides", "3", "【v1.1.0】保护哪一侧：1=只保护被救者 2=只保护救助者 3=两边都保护", FCVAR_NOTIFY, true, 1.0, true, 3.0);
	g_cVictimAlways   = CreateConVar("ltt_nointerrupt_victim_always", "0", "【v1.1.0】1=倒地/挂边期间『一直』挡（不只在有人正在拉的时候）——更强的手感", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cVictimThrottle = CreateConVar("ltt_nointerrupt_victim_throttle", "0", "【v1.1.0】1=同时开启原插件那套『倒地/挂边者挨小丧尸伤害节流』（做对的版本）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cDmg            = CreateConVar("ltt_nointerrupt_dmg", "0", "【v1.1.0】节流固定伤害；0=按难度表 1/2/5/20", FCVAR_NOTIFY, true, 0.0);
	g_cCd             = CreateConVar("ltt_nointerrupt_cd", "0.0", "【v1.1.0】节流冷却秒；0=按难度表 0.50/0.33/0.50/1.00", FCVAR_NOTIFY, true, 0.0);
	g_cLog            = CreateConVar("ltt_nointerrupt_log", "1", "【v1.1.0】1=每次挡下/节流都写日志", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "ltt_no_interrupt");

	HookEvent("round_start", Event_RoundStart);
	HookEvent("player_spawn", Event_PlayerSpawn);

	LogMessage("[NoInterrupt] v%s 已加载 ｜ 开关=%d 来源=%d 保护侧=%d 倒地一直挡=%d 节流=%d ｜ 判据=m_reviveOwner(被救者)/m_reviveTarget(救助者)",
		PLUGIN_VERSION, g_cEnable.IntValue, g_cSrc.IntValue, g_cSides.IntValue,
		g_cVictimAlways.IntValue, g_cVictimThrottle.IntValue);
}

public void OnClientPutInServer(int client)
{
	if (client > 0 && client <= MaxClients)
		g_bCanHurt[client] = true;

	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnMapStart()
{
	ResetMapState();
}

public void OnMapEnd()
{
	if (g_iBlockedRevivee > 0 || g_iBlockedReviver > 0 || g_iThrottled > 0)
	{
		char sMap[64];
		GetCurrentMap(sMap, sizeof(sMap));
		LogMessage("[NoInterrupt] 地图=%s 本图：为被救者挡下 %d 次（其中挂边 %d 次）｜为救助者挡下 %d 次｜节流改为固定伤害 %d 次",
			sMap, g_iBlockedRevivee, g_iBlockedReviveeHang, g_iBlockedReviver, g_iThrottled);
	}
}

void ResetMapState()
{
	for (int i = 0; i <= MaxClients; i++)
		g_bCanHurt[i] = true;

	g_iBlockedRevivee     = 0;
	g_iBlockedReviveeHang = 0;
	g_iBlockedReviver     = 0;
	g_iThrottled          = 0;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ResetMapState();
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && client <= MaxClients)
		g_bCanHurt[client] = true;
}

public Action OnTakeDamage(int client, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
	if (!g_cEnable.BoolValue)
		return Plugin_Continue;

	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_SURVIVOR)
		return Plugin_Continue;

	int  iSrc     = g_cSrc.IntValue;
	int  iSides   = g_cSides.IntValue;
	bool bCommon  = IsCommonInfected(attacker);
	bool bSpecial = IsSpecialInfected(attacker);

	bool bBlockSrc = false;
	if (iSrc == 1)      bBlockSrc = bCommon;
	else if (iSrc == 2) bBlockSrc = (bCommon || bSpecial);
	else                bBlockSrc = true;

	bool bIncap = view_as<bool>(GetEntProp(client, Prop_Send, "m_isIncapacitated"));
	bool bHang  = view_as<bool>(GetEntProp(client, Prop_Send, "m_isHangingFromLedge"));

	// ---- ① 被救者一侧：有人正在拉他（m_reviveOwner = 正在救我的那个人）----
	// 服主实测机制：进度条读取期间，伤害落到"被救者"身上会重置进度 ⇒ 这里必须整条挡掉。
	if ((iSides == 1 || iSides == 3) && bBlockSrc && (bIncap || bHang))
	{
		int  revOwner      = GetEntPropEnt(client, Prop_Send, "m_reviveOwner");
		bool bBeingRevived = (revOwner > 0 && revOwner <= MaxClients);

		if (bBeingRevived || g_cVictimAlways.BoolValue)
		{
			g_iBlockedRevivee++;
			if (bHang)
				g_iBlockedReviveeHang++;

			if (g_cLog.BoolValue)
			{
				char sMap[64];
				GetCurrentMap(sMap, sizeof(sMap));
				LogMessage("[NoInterrupt] 地图=%s 挡下打断（被救者）：#%d 状态=%s 正在被 %s 救 ｜ 来源=%s 原伤害=%.1f（本图第 %d 次）",
					sMap, client, bHang ? "挂边" : "倒地",
					bBeingRevived ? "队友" : "无人",
					bCommon ? "小丧尸" : (bSpecial ? "特感" : "其它"),
					damage, g_iBlockedRevivee);
			}
			return Plugin_Handled;
		}
	}

	// ---- ② 救助者一侧：他正在救别人（m_reviveTarget = 我正在救的那个人）----
	if ((iSides == 2 || iSides == 3) && bBlockSrc)
	{
		int revTarget = GetEntPropEnt(client, Prop_Send, "m_reviveTarget");
		if (revTarget > 0 && revTarget <= MaxClients)
		{
			g_iBlockedReviver++;
			if (g_cLog.BoolValue)
			{
				char sMap[64];
				GetCurrentMap(sMap, sizeof(sMap));
				LogMessage("[NoInterrupt] 地图=%s 挡下打断（救助者）：#%d 正在救 #%d ｜ 来源=%s 原伤害=%.1f（本图第 %d 次）",
					sMap, client, revTarget, bCommon ? "小丧尸" : (bSpecial ? "特感" : "其它"),
					damage, g_iBlockedReviver);
			}
			return Plugin_Handled;
		}
	}

	// ---- ③ 可选：原插件那套"倒地/挂边者挨小丧尸伤害节流"（做对的版本）----
	if (g_cVictimThrottle.BoolValue && bCommon && (bIncap || bHang))
	{
		if (!g_bCanHurt[client])
		{
			g_iThrottled++;
			return Plugin_Handled;                 // 冷却期内全挡（与原插件一致）
		}

		int   iDiff = GetDifficultyIndex();
		int   iHurt = g_cDmg.IntValue > 0 ? g_cDmg.IntValue : g_iDmgByDiff[iDiff];
		float flCd  = g_cCd.FloatValue > 0.0 ? g_cCd.FloatValue : g_flCdByDiff[iDiff];

		g_bCanHurt[client] = false;
		CreateTimer(flCd, Timer_Cold, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

		if (iHurt > 0)
		{
			// 只改数值、让引擎正常结算：有音效/击退/player_hurt，Kill Report 也看得见（原插件是直写 m_iHealth）
			damage = float(iHurt);
			g_iThrottled++;
			return Plugin_Changed;
		}
	}

	return Plugin_Continue;
}

public Action Timer_Cold(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && client <= MaxClients)
		g_bCanHurt[client] = true;

	return Plugin_Stop;
}

bool IsCommonInfected(int entity)
{
	if (entity <= 0 || entity <= MaxClients)
		return false;                          // 客户端/世界不是"小丧尸实体"
	if (!IsValidEdict(entity))
		return false;

	char cls[32];
	GetEdictClassname(entity, cls, sizeof(cls));
	return StrEqual(cls, "infected");
}

bool IsSpecialInfected(int entity)
{
	if (entity > 0 && entity <= MaxClients)
		return IsClientInGame(entity) && GetClientTeam(entity) == TEAM_INFECTED;

	if (entity <= 0 || !IsValidEdict(entity))
		return false;

	char cls[32];
	GetEdictClassname(entity, cls, sizeof(cls));
	return StrEqual(cls, "witch");
}

int GetDifficultyIndex()
{
	char diff[32];
	GetConVarString(FindConVar("z_difficulty"), diff, sizeof(diff));

	if (StrEqual(diff, "Easy", false))   return 0;
	if (StrEqual(diff, "Normal", false)) return 1;
	if (StrEqual(diff, "Hard", false))   return 2;
	return 3;
}
