/**
 * [LTT] Bile Retarget —— 特感目标接管（取代 [L4D & L4D2] Target Override）
 *
 * 需求来源：玩家在胆汁窗口里"贴脸"站在特感旁边，特感却无视他去追吃了胆汁的人。
 * 原因：Target Override 的 type 1(Nearest visible) 在搜索失败时会退回游戏原生方法，
 *       而胆汁窗口里原生方法给所有特感的答案就是"吃胆汁的那个人"。
 *
 * 本插件规则（自己 detour BossZombiePlayerBot::ChooseVictim）：
 *   - 非胆汁时间：只选"最近的、看得见的"生还者；没人看得见就交给引擎（不强行改写）
 *   - 胆汁窗口内：只选"最近的、没吃胆汁的"生还者，可见的优先；
 *                 距离超过 ltt_bileret_maxdist 的不选；
 *                 所有人都吃了胆汁时才交回引擎
 *
 * 依赖：dhooks 扩展 + gamedata/ltt_bile_retarget.txt（签名与 Target Override 同源，已在本机验证可加载）
 *
 * v1.0.0  2026-10-06  首版
 * v1.0.1  2026-10-06  加 ltt_bileret_bots（默认 0 = 只盯真人，与 SilverShot team 2 行为一致）
 * v1.0.2  2026-10-06  试过"看得见优先"评分（可见非胆汁 3 > 可见胆汁 2 > 不可见非胆汁 1）——车主实战否决
 * v1.0.3  2026-10-06  退回 v1.0.1 规则：胆汁窗口内只要有非胆汁生还者就一律改追他（不要求看得见），maxdist 回 1400
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define PLUGIN_VERSION "1.0.4"
#define GAMEDATA "ltt_bile_retarget"

// 视线遮挡掩码（本机 sdktools 未定义 MASK_LTT_LOS，手动拼）
#define MASK_LTT_LOS (CONTENTS_SOLID|CONTENTS_MOVEABLE|CONTENTS_WINDOW|CONTENTS_GRATE|CONTENTS_OPAQUE)

ConVar g_cEnable;
ConVar g_cClasses;
ConVar g_cMaxDist;
ConVar g_cNeedVis;
ConVar g_cBileTime;
ConVar g_cLog;
ConVar g_cBots;

Handle g_hGameData = null;
Handle g_hDetour = null;
Handle g_hTimer = null;

bool g_bClassOn[9];
bool g_bBiled[MAXPLAYERS + 1];
float g_fBileUntil[MAXPLAYERS + 1];
int g_iLastPick[MAXPLAYERS + 1];

int g_iBiledNow = 0;        // 当前吃胆汁人数
int g_iBileEvents = 0;      // 本图胆汁次数
int g_iOverride = 0;        // 本图胆汁窗口内改写目标次数
int g_iOverrideByClass[9];
int g_iNoChoice = 0;        // 窗口内没有任何"非胆汁"可选，交回引擎的次数
int g_iCalls = 0;           // 本图 ChooseVictim 被调用次数（存活自检）
char g_sMap[64];

public Plugin myinfo =
{
	name = "[LTT] Bile Retarget",
	author = "LTT",
	description = "胆汁窗口接管特感目标：不追吃胆汁的人，改追最近的可见生还者",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_cEnable   = CreateConVar("ltt_bileret_enable",   "1",      "0=关闭 1=打开", FCVAR_NOTIFY);
	g_cClasses  = CreateConVar("ltt_bileret_classes",  "1,2,3,4,5,6", "接管哪些特感 1=Smoker 2=Boomer 3=Hunter 4=Spitter 5=Jockey 6=Charger（不支持 7=Witch 8=Tank）", FCVAR_NOTIFY);
	g_cMaxDist  = CreateConVar("ltt_bileret_maxdist",  "1400.0", "胆汁窗口内只选这个距离内的非胆汁生还者（不看可见性），0=不限", FCVAR_NOTIFY);
	g_cNeedVis  = CreateConVar("ltt_bileret_needvis",  "1",      "非胆汁时间只选看得见的生还者，0=不看视野", FCVAR_NOTIFY);
	g_cBileTime = CreateConVar("ltt_bileret_biletime", "15.0",   "事件没给时长时，胆汁窗口按多少秒算", FCVAR_NOTIFY);
	g_cLog      = CreateConVar("ltt_bileret_log",      "1",      "是否记录改写日志", FCVAR_NOTIFY);
	g_cBots     = CreateConVar("ltt_bileret_bots",     "0",      "1=也把电脑队友(bot)当目标 0=只盯真人（与 SilverShot team 2 一致）", FCVAR_NOTIFY);
	AutoExecConfig(true, "ltt_bile_retarget");

	g_cClasses.AddChangeHook(OnCvarChanged);
	ParseClasses();

	HookEvent("player_now_it",      Event_NowIt);
	HookEvent("player_no_longer_it", Event_NoLongerIt);
	HookEvent("player_death",       Event_PlayerDeath);
	HookEvent("player_team",        Event_PlayerTeam);

	RegAdminCmd("sm_bileret", Cmd_Status, ADMFLAG_ROOT, "查看胆汁目标接管状态");

	LoadDHook();
	StartSweepTimer();
}

public void OnPluginEnd()
{
	if (g_hDetour != null) { DHookDisableDetour(g_hDetour, false, ChooseVictim); g_hDetour = null; }
	if (g_hGameData != null) { CloseHandle(g_hGameData); g_hGameData = null; }
	if (g_hTimer != null) { KillTimer(g_hTimer); g_hTimer = null; }
}

void LoadDHook()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "gamedata/%s.txt", GAMEDATA);
	if (!FileExists(sPath))
		SetFailState("缺少签名文件: %s", sPath);

	g_hGameData = LoadGameConfigFile(GAMEDATA);
	if (g_hGameData == null)
		SetFailState("无法加载 gamedata/%s.txt", GAMEDATA);

	g_hDetour = DHookCreateFromConf(g_hGameData, "BossZombiePlayerBot::ChooseVictim");
	if (g_hDetour == null)
		SetFailState("gamedata 里找不到 \"BossZombiePlayerBot::ChooseVictim\"");

	if (!DHookEnableDetour(g_hDetour, false, ChooseVictim))
		SetFailState("DHookEnableDetour 失败");

	LogMessage("[BileRet] v%s 挂钩成功（自建 detour，取代 Target Override）", PLUGIN_VERSION);
}

void StartSweepTimer()
{
	if (g_hTimer != null) { KillTimer(g_hTimer); g_hTimer = null; }
	g_hTimer = CreateTimer(0.5, Timer_Sweep, _, TIMER_REPEAT);
}

public void OnMapStart()
{
	GetCurrentMap(g_sMap, sizeof(g_sMap));
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bBiled[i] = false;
		g_fBileUntil[i] = 0.0;
		g_iLastPick[i] = 0;
	}
	g_iBiledNow = 0;
	g_iBileEvents = 0;
	g_iOverride = 0;
	g_iNoChoice = 0;
	for (int i = 0; i < 9; i++) g_iOverrideByClass[i] = 0;
	StartSweepTimer();
}

public void OnMapEnd()
{
	if (g_cLog.BoolValue)
	{
		LogMessage("[BileRet] 地图=%s 调用 %d 次 ｜ 胆汁 %d 次 ｜ 胆汁窗口内改写目标 %d 次（Smoker %d / Boomer %d / Hunter %d / Spitter %d / Jockey %d / Charger %d）｜ 窗口内没有非胆汁可选 %d 次",
			g_sMap, g_iCalls, g_iBileEvents, g_iOverride,
			g_iOverrideByClass[1], g_iOverrideByClass[2], g_iOverrideByClass[3],
			g_iOverrideByClass[4], g_iOverrideByClass[5], g_iOverrideByClass[6], g_iNoChoice);
	}
	if (g_hTimer != null) { KillTimer(g_hTimer); g_hTimer = null; }
}

public void OnClientDisconnect(int client)
{
	if (client > 0 && client <= MaxClients)
	{
		SetBiled(client, false);
		g_iLastPick[client] = 0;
	}
}

// =========================================================
// 目标改写（核心）
// =========================================================
public MRESReturn ChooseVictim(int iSI, Handle hReturn)
{
	g_iCalls++;
	if (g_iCalls == 1 && g_cLog.BoolValue) LogMessage("[BileRet] 存活自检：ChooseVictim 已被调用（detour 生效）");

	if (!g_cEnable.BoolValue) return MRES_Ignored;
	if (iSI <= 0 || iSI > MaxClients) return MRES_Ignored;
	if (!IsClientInGame(iSI) || !IsFakeClient(iSI) || !IsPlayerAlive(iSI)) return MRES_Ignored;
	if (GetClientTeam(iSI) != 3) return MRES_Ignored;

	int cls = GetEntProp(iSI, Prop_Send, "m_zombieClass");
	if (cls < 1 || cls > 6 || !g_bClassOn[cls]) return MRES_Ignored;

	bool bBile = (g_iBiledNow > 0);
	float fSI[3], fEye[3], fP[3], fT[3];
	GetClientAbsOrigin(iSI, fSI);
	GetClientEyePosition(iSI, fEye);

	int iBest = 0, iBestScore = -1;
	float fBestDist = 0.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == iSI) continue;
		if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;
		if (GetClientTeam(i) != 2) continue;
		if (!g_cBots.BoolValue && IsFakeClient(i)) continue;

		// 【v1.0.4 · 车主 2026-10-07】倒地/挂边的生还者直接不做目标：
		// 一律追距离自己最近且站着的人；场上没有站着的则交回引擎（iBest==0 → MRES_Ignored）。
		if (GetEntProp(i, Prop_Send, "m_isIncapacitated") || GetEntProp(i, Prop_Send, "m_isHangingFromLedge"))
			continue;

		GetClientAbsOrigin(i, fP);
		float d = GetVectorDistance(fSI, fP);

		fT = fP;
		fT[2] += 45.0;
		bool vis = TraceVisible(fEye, fT, iSI);

		int score;
		if (bBile)
		{
			// 胆汁窗口（车主 2026-10-06 实战确认的设计意图）：绝不选吃胆汁的人——只要场上有
			// 非胆汁生还者，特感一律改追他；"特感当时看不看得见"不作限制（特感看不见是特感自己的问题）。
			// 距离上限 maxdist 依然生效，防止跨图拉人。
			if (g_cMaxDist.FloatValue > 0.0 && d > g_cMaxDist.FloatValue) continue;
			if (g_bBiled[i]) continue;
			score = (vis ? 2 : 0) + (g_bBiled[i] ? 0 : 1);
			if (score == 0) continue;
		}
		else
		{
			if (g_cNeedVis.BoolValue && !vis) continue;
			score = vis ? 1 : 0;
		}
		if (score > iBestScore || (score == iBestScore && (iBest == 0 || d < fBestDist)))
		{
			iBest = i;
			iBestScore = score;
			fBestDist = d;
		}
	}

	if (iBest == 0)
	{
		if (bBile) g_iNoChoice++;
		return MRES_Ignored;   // 交给引擎（例如全队都吃了胆汁）
	}

	if (bBile)
	{
		g_iOverride++;
		g_iOverrideByClass[cls]++;
		if (g_cLog.BoolValue && g_iLastPick[iSI] != iBest)
		{
			g_iLastPick[iSI] = iBest;
			LogMessage("[BileRet] 胆汁窗口：%N(类%d) 目标→%N（距 %.0f，可见=%s）｜场上吃胆汁 %d 人",
				iSI, cls, iBest, fBestDist, iBestScore == 1 ? "是" : "否", g_iBiledNow);
		}
	}
	else if (g_iLastPick[iSI] != iBest)
	{
		g_iLastPick[iSI] = iBest;
	}

	DHookSetReturn(hReturn, iBest);
	return MRES_Supercede;
}

public bool TraceFilter_World(int entity, int contentsMask, any data)
{
	return (entity == 0 || entity > MaxClients);   // 只让世界挡住视线，玩家/特感不算遮挡
}

bool TraceVisible(float fStart[3], float fEnd[3], int iSelf)
{
	Handle hTrace = TR_TraceRayFilterEx(fStart, fEnd, MASK_LTT_LOS, RayType_EndPoint, TraceFilter_World, iSelf);
	bool bVis = (TR_GetFraction(hTrace) >= 1.0);
	CloseHandle(hTrace);
	return bVis;
}

// =========================================================
// 胆汁窗口状态
// =========================================================
void SetBiled(int client, bool bOn)
{
	if (bOn == g_bBiled[client]) return;
	g_bBiled[client] = bOn;
	if (bOn)
	{
		g_iBiledNow++;
		g_iBileEvents++;
	}
	else
	{
		g_iBiledNow--;
		if (g_iBiledNow < 0) g_iBiledNow = 0;
	}
}

public Action Timer_Sweep(Handle hTimer)
{
	if (g_iBiledNow <= 0) return Plugin_Continue;
	float now = GetGameTime();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bBiled[i] && g_fBileUntil[i] > 0.0 && now > g_fBileUntil[i])
			SetBiled(i, false);
	}
	return Plugin_Continue;
}

public void Event_NowIt(Event hEvent, const char[] sName, bool bDontBroadcast)
{
	int i = GetClientOfUserId(hEvent.GetInt("userid"));
	if (i <= 0 || !IsClientInGame(i)) return;
	float dur = hEvent.GetFloat("duration");
	if (dur <= 0.5) dur = g_cBileTime.FloatValue;
	SetBiled(i, true);
	g_fBileUntil[i] = GetGameTime() + dur;
	g_iLastPick[i] = 0;
}

public void Event_NoLongerIt(Event hEvent, const char[] sName, bool bDontBroadcast)
{
	int i = GetClientOfUserId(hEvent.GetInt("userid"));
	if (i > 0) SetBiled(i, false);
}

public void Event_PlayerDeath(Event hEvent, const char[] sName, bool bDontBroadcast)
{
	int i = GetClientOfUserId(hEvent.GetInt("userid"));
	if (i > 0) SetBiled(i, false);
}

public void Event_PlayerTeam(Event hEvent, const char[] sName, bool bDontBroadcast)
{
	int i = GetClientOfUserId(hEvent.GetInt("userid"));
	if (i > 0 && GetClientTeam(i) != 2) SetBiled(i, false);
}

// =========================================================
// cvar / 命令
// =========================================================
void ParseClasses()
{
	for (int i = 0; i < 9; i++) g_bClassOn[i] = false;
	char sBuf[64];
	g_cClasses.GetString(sBuf, sizeof(sBuf));
	char sParts[16][8];
	int n = ExplodeString(sBuf, ",", sParts, sizeof(sParts), sizeof(sParts[]));
	for (int i = 0; i < n; i++)
	{
		TrimString(sParts[i]);
		int c = StringToInt(sParts[i]);
		if (c >= 1 && c <= 8) g_bClassOn[c] = true;
	}
}

public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ParseClasses();
}

public Action Cmd_Status(int client, int args)
{
	char sCls[64];
	g_cClasses.GetString(sCls, sizeof(sCls));
	ReplyToCommand(client, "[BileRet] enable=%d classes=%s maxdist=%.0f needvis=%d bots=%d ｜ 当前吃胆汁 %d 人 / 本图胆汁 %d 次 / 窗口内改写 %d 次 / 无可选 %d 次",
		g_cEnable.BoolValue, sCls, g_cMaxDist.FloatValue, g_cNeedVis.BoolValue, g_cBots.BoolValue,
		g_iBiledNow, g_iBileEvents, g_iOverride, g_iNoChoice);
	return Plugin_Handled;
}
