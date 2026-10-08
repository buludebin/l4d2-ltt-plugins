/**
 *  ltt_stagger_damage  v1.0.0 —— 硬直追击伤害（Boomer 爆炸 / Hunter 扑 / Jockey 骑）
 *
 *  【这个插件干什么】
 *  被 Boomer 爆炸、Hunter 扑倒震人、Jockey 骑乘震下来之后，延迟一小段时间（默认 0.2 秒）
 *  给那个生还者补一笔小伤害（默认 Boomer 4 / Hunter 2 / Jockey 2）。
 *  它不改变硬直本身，只是在"被震了"这件事上再加一点代价。
 *
 *  【为什么要自己写一版（原版：R7WS 包里 l4d2_stagger_damage，作者 77）】
 *  原版源码我逐行读过（_分析\R7WS_审核报告_2026-10-02.md 第 9 节），功能方向没问题，四个点值得改：
 *    ① `90: SDKHooks_TakeDamage(client, 0, 0, float(Damage))` —— attacker/inflictor 全是 0
 *       ⇒ 这笔伤害**没有来源**：如果它把人打死了，死亡归属也是空的（特感拿不到击杀，
 *       击杀播报/统计类插件看到的是一次"无主死亡"）。本插件默认把伤害算在**造成硬直的那只特感**头上。
 *    ② `bypassHooks` 在 SourceMod 里的默认值是 **true**（见 sdkhooks.inc 签名）
 *       ⇒ 原版这笔伤害会**绕过**其它插件的 `OnTakeDamage`（比如"救助中不挨打"这类逻辑看不到它）。
 *       本插件默认 `bypasshooks 0`（让其它插件也看得见），想要原版行为就设 1。
 *    ③ `95: IsValidSurvivor()` 里带 `(GetEntityFlags & FL_ONGROUND)`，而且这个检查在
 *       **Post 回调的同一帧**和 **0.2 秒后的定时器里各做一次** ⇒ 只要那一下的瞬间"人不在空中"才补伤害。
 *       是不是符合预期取决于你打不打算让"被炸飞在空中"也吃这一下 —— 这里做成开关：
 *       `needground 0`（默认，不管在不在空中都补）/ `1`（= 原版口径，只在落地时才补）。
 *    ④ `42/62/74: CreateTimer(…, TIMER_FLAG_NO_MAPCHANGE)` + 回调里 `85: delete data`：
 *       如果这 0.2 秒里正好换图，定时器被 SM 回收、回调不执行 ⇒ 那个 DataPack **没人释放**（漏一个句柄）。
 *       本插件改用 `TIMER_DATA_HNDL_CLOSE`（由框架在计时器结束时关闭数据句柄）。
 *  另外原版的 cvar 名与本插件不同名（`l4d2_stagger_damage_*` vs `ltt_staggerdamage_*`），
 *  两者可以同时装做 A/B 对比；默认数值与原版一致（4/2/2）。
 *
 *  【依赖】
 *  · 需要服务端装 **left4dhooks**（本插件用它的两个 forward：
 *    `L4D2_OnStagger_Post` / `L4D2_OnPounceOrLeapStumble_Post`）。
 *    没有 left4dhooks 时本插件**不会报错也不会崩**，只是这两个回调永远不触发（等于没装）。
 *  · 其它依赖：无（只要 SourceMod 自带）。
 *
 *  【开关】
 *    ltt_staggerdamage_boomer      4      Boomer 爆炸后补的伤害（0=关闭这类）
 *    ltt_staggerdamage_hunter      2      Hunter 扑/跃震人后补的伤害（0=关闭）
 *    ltt_staggerdamage_jockey      2      Jockey 骑乘震下后补的伤害（0=关闭）
 *    ltt_staggerdamage_delay       0.2    延迟秒数
 *    ltt_staggerdamage_needground  0      1=只在受害者"落地"时才补（= 原版口径）
 *    ltt_staggerdamage_credit      1      1=伤害算在造成硬直的特感头上（击杀归因正常）；0=无来源（= 原版）
 *    ltt_staggerdamage_bypasshooks 0      1=绕过其它插件的 OnTakeDamage（= 原版默认行为）
 *    ltt_staggerdamage_log         1      1=每图写一条汇总（含各类型次数与跳过原因）
 *
 *  【日志】每图一条：
 *    [StaggerDmg] 地图=… 本图：Boomer 补 12 次 / Hunter 补 8 次 / Jockey 补 3 次 ｜
 *                 跳过（人已死/已倒地/已在挂边）5 次 ｜ 跳过（当时在空中，needground=1）7 次
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

#define ZC_SMOKER   1
#define ZC_BOOMER   2
#define ZC_HUNTER   3
#define ZC_JOCKEY   5

ConVar g_cBoomer, g_cHunter, g_cJockey, g_cDelay, g_cNeedGround, g_cCredit, g_cBypass, g_cLog;

int g_iBoomerDone, g_iHunterDone, g_iJockeyDone;
int g_iSkipBad, g_iSkipAir;

public Plugin myinfo =
{
	name        = "[LTT] Stagger Bonus Damage (硬直追击伤害)",
	author      = "DeepSeek Harness",
	description = "被 Boomer/Hunter/Jockey 震硬直后延迟补一笔小伤害；伤害归属与 hooks 口径可配",
	version     = PLUGIN_VERSION,
	url         = ""
}

public void OnPluginStart()
{
	g_cBoomer     = CreateConVar("ltt_staggerdamage_boomer", "4", "【v1.0.0】Boomer 爆炸硬直后补的伤害（0=关闭）", FCVAR_NOTIFY, true, 0.0);
	g_cHunter     = CreateConVar("ltt_staggerdamage_hunter", "2", "【v1.0.0】Hunter 扑/跃震人后补的伤害（0=关闭）", FCVAR_NOTIFY, true, 0.0);
	g_cJockey     = CreateConVar("ltt_staggerdamage_jockey", "2", "【v1.0.0】Jockey 骑乘震下后补的伤害（0=关闭）", FCVAR_NOTIFY, true, 0.0);
	g_cDelay      = CreateConVar("ltt_staggerdamage_delay", "0.2", "【v1.0.0】延迟秒数（原版 0.2）", FCVAR_NOTIFY, true, 0.0, true, 3.0);
	g_cNeedGround = CreateConVar("ltt_staggerdamage_needground", "0", "【v1.0.0】1=只在受害者落地时才补（= 原版口径）；0=不管在不在空中都补（默认）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cCredit     = CreateConVar("ltt_staggerdamage_credit", "1", "【v1.0.0】1=把伤害算在造成硬直的特感头上（击杀归因正常，默认）；0=无来源（= 原版行为）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cBypass     = CreateConVar("ltt_staggerdamage_bypasshooks", "0", "【v1.0.0】1=绕过其它插件的 OnTakeDamage（= 原版默认）；0=让其它插件也看得见这笔伤害（默认）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cLog        = CreateConVar("ltt_staggerdamage_log", "1", "【v1.0.0】1=每图写一条汇总日志", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "ltt_stagger_damage");

	LogMessage("[StaggerDmg] v%s 已加载 ｜ Boomer=%d Hunter=%d Jockey=%d 延迟=%.2fs 需落地=%d 伤害归属=%d 绕过hooks=%d",
		PLUGIN_VERSION, g_cBoomer.IntValue, g_cHunter.IntValue, g_cJockey.IntValue,
		g_cDelay.FloatValue, g_cNeedGround.IntValue, g_cCredit.IntValue, g_cBypass.IntValue);
}

public void OnMapStart()
{
	g_iBoomerDone = g_iHunterDone = g_iJockeyDone = 0;
	g_iSkipBad = g_iSkipAir = 0;
}

public void OnMapEnd()
{
	if (!g_cLog.BoolValue)
		return;
	if (g_iBoomerDone + g_iHunterDone + g_iJockeyDone + g_iSkipBad + g_iSkipAir <= 0)
		return;

	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
	LogMessage("[StaggerDmg] 地图=%s 本图：Boomer 补 %d 次 / Hunter 补 %d 次 / Jockey 补 %d 次 ｜ 跳过（人已死/已倒地/已挂边）%d 次 ｜ 跳过（当时在空中，needground=1）%d 次",
		sMap, g_iBoomerDone, g_iHunterDone, g_iJockeyDone, g_iSkipBad, g_iSkipAir);
}

/** Boomer 爆炸把生还者震硬直：source 是那只 Boomer（= 客户端，team 3，class 2） */
public void L4D2_OnStagger_Post(int target, int source)
{
	if (g_cBoomer.IntValue <= 0)
		return;
	if (!IsInfectedClient(source) || GetEntProp(source, Prop_Send, "m_zombieClass") != ZC_BOOMER)
		return;

	ScheduleStaggerDamage(target, source, g_cBoomer.IntValue, 1);
}

/** Hunter 扑/跃震人（class 3）与 Jockey 骑乘震下（class 5） */
public void L4D2_OnPounceOrLeapStumble_Post(int victim, int attacker)
{
	if (!IsInfectedClient(attacker))
		return;

	int zclass = GetEntProp(attacker, Prop_Send, "m_zombieClass");

	if (zclass == ZC_HUNTER)
	{
		if (g_cHunter.IntValue <= 0)
			return;

		ScheduleStaggerDamage(victim, attacker, g_cHunter.IntValue, 2);
	}
	else if (zclass == ZC_JOCKEY)
	{
		if (g_cJockey.IntValue <= 0)
			return;

		ScheduleStaggerDamage(victim, attacker, g_cJockey.IntValue, 3);
	}
}

/** kind: 1=Boomer 2=Hunter 3=Jockey */
void ScheduleStaggerDamage(int victim, int attackerEntity, int damage, int kind)
{
	if (!IsEligibleVictim(victim))
	{
		g_iSkipBad++;
		return;
	}

	if (g_cNeedGround.BoolValue && !(GetEntityFlags(victim) & FL_ONGROUND))
	{
		g_iSkipAir++;
		return;
	}

	DataPack dp = CreateDataPack();
	dp.WriteCell(GetClientUserId(victim));
	dp.WriteCell(g_cCredit.BoolValue ? GetClientUserId(attackerEntity) : 0);
	dp.WriteCell(damage);
	dp.WriteCell(kind);

	// 【与 @4 的差异】TIMER_DATA_HNDL_CLOSE：换图/被回收时由框架关闭数据句柄，不再漏 DataPack
	CreateTimer(g_cDelay.FloatValue, Timer_ApplyStaggerDamage, dp, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
}

public Action Timer_ApplyStaggerDamage(Handle timer, DataPack dp)
{
	dp.Reset();

	int victimUid   = dp.ReadCell();
	int attackerUid = dp.ReadCell();
	int damage      = dp.ReadCell();
	int kind        = dp.ReadCell();

	int victim = GetClientOfUserId(victimUid);
	if (!IsEligibleVictim(victim))
	{
		g_iSkipBad++;
		return Plugin_Stop;
	}

	// 延迟这 0.2 秒里可能已经落地了：needground=1 时按原版口径再判一次
	if (g_cNeedGround.BoolValue && !(GetEntityFlags(victim) & FL_ONGROUND))
	{
		g_iSkipAir++;
		return Plugin_Stop;
	}

	int attacker = attackerUid > 0 ? GetClientOfUserId(attackerUid) : 0;

	if (kind == 1)      g_iBoomerDone++;
	else if (kind == 2) g_iHunterDone++;
	else if (kind == 3) g_iJockeyDone++;

	if (g_cLog.BoolValue)
	{
		char sMap[64];
		GetCurrentMap(sMap, sizeof(sMap));
		LogMessage("[StaggerDmg] 地图=%s 补伤害：%s → #%d 共 %d 点（归属=%s）",
			sMap, kind == 1 ? "Boomer" : (kind == 2 ? "Hunter" : "Jockey"),
			victim, damage, attacker > 0 ? "特感" : "无来源");
	}

	// 归属：把造成硬直的那只特感当 attacker + inflictor（原版是 0/0，死亡归属为空）
	int iInflictor = attacker;
	int iAttacker  = attacker;
	SDKHooks_TakeDamage(victim, iInflictor, iAttacker, float(damage), DMG_GENERIC, -1,
		NULL_VECTOR, NULL_VECTOR, g_cBypass.BoolValue);

	return Plugin_Stop;
}

/** 能被补这一下的人：在游戏、生还者、活着、不在倒地、不在挂边（不含"是否在空中"，那由 needground 决定） */
bool IsEligibleVictim(int client)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
		return false;
	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return false;
	if (!IsPlayerAlive(client))
		return false;
	if (GetEntProp(client, Prop_Send, "m_isIncapacitated"))
		return false;
	if (GetEntProp(client, Prop_Send, "m_isHangingFromLedge"))
		return false;

	return true;
}

bool IsInfectedClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == TEAM_INFECTED;
}
