/**
 * ltt_autorelease —— 特感控人后自动解控（单人练习「防控」用）
 *
 * 作用：生还者被特感控制（扑/舌/骑/撞）后，过了 `ltt_autorel_delay` 秒自动解控。
 *       解控方式 = 杀掉控制者（这是 L4D2 里最可靠的解除途径：控制者一死，被控者立刻自由）。
 *
 * 为什么用"杀控制者"而不是别的：
 *   · 想"只解除不杀"在引擎层没有稳定接口 —— 舌头/骑乘/撞击的持有关系都在 SI 的 netprop 上，
 *     直接改它们属于"无文档的内部状态"，版本一变就会出怪事（甚至崩服）。
 *   · 练习服要的就是"每次被控 1 秒后重来"，杀掉控制者正好干净利落。
 *
 * 防误杀：每种控制都有对应的"结束事件"（pounce_stopped / tongue_release /
 *   jockey_ride_end / charger_pummel_end），收到就取消计时器 —— 所以某次控制提前结束时
 *   绝不会隔 1 秒再去杀一只已经没在控人的特感。
 *
 * 依赖：只有 sourcemod + sdktools（无 gamedata、无签名、无内存操作）⇒ 任何版本的服务端都能装。
 *
 * cvar：
 *   ltt_autorel_enable    1      总开关
 *   ltt_autorel_delay     0.75   被控后多少秒解控（0.1~30）
 *   ltt_autorel_notify    1      解控时给受害者屏幕提示
 *   ltt_autorel_humanonly 0      1=只对真人受害者生效（陪练 bot 被控时不管）
 *   ltt_autorel_chaptermsg 1     1=进新章节时全服播报"上一章节解控次数"
 *
 * 统计：本章节解控次数（章节边界 = player_left_start_area，与 ltt_kd「本章节计时」同源），
 *       聊天里打「解控」、或 sm_autorel / sm_jk 查当前数字；换图清零。
 *
 * 日志：每次解控写一行 `[AutoRel] 解控：受害者 #N 被控（事件首字母）→ 已杀控制者`
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.1.3"

ConVar g_cEnable;
ConVar g_cDelay;
ConVar g_cNotify;
ConVar g_cHumanOnly;
ConVar g_cDebug;
ConVar g_cChapterMsg;

Handle g_hTimer[MAXPLAYERS + 1];      // 每个受害者一个待解控计时器

// ===== 章节统计（v1.1.0 新增）=====
int g_iRelChapter;                     // 本章节已解控次数
int g_iRelTotal;                       // 本局（本次换图以来）已解控次数
int g_iKindChapter[4];                 // 本章节按类型：0=扑 1=舌 2=骑 3=撞
int g_iKindTotal[4];
int g_iChapterNo = 1;                  // 章节序号（日志用）

public Plugin myinfo =
{
	name        = "[LTT] Auto Release (自助解控)",
	author      = "ltt",
	description = "特感控人 N 秒后自动解控（单人练习防控用）",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cEnable    = CreateConVar("ltt_autorel_enable", "1", "1=开 ｜ 0=关", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cDelay     = CreateConVar("ltt_autorel_delay", "0.75", "被控后多少秒自动解控（默认 0.75 秒）", FCVAR_NOTIFY, true, 0.1, true, 30.0);
	g_cNotify    = CreateConVar("ltt_autorel_notify", "1", "1=解控时给受害者屏幕提示", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cDebug      = CreateConVar("ltt_autorel_debug",     "1",  "1=把每次被控事件写进日志（排查用）", 0, true, 0.0, true, 1.0);
	g_cChapterMsg = CreateConVar("ltt_autorel_chaptermsg", "1", "1=进新章节时全服播报上一章节解控次数", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cHumanOnly = CreateConVar("ltt_autorel_humanonly", "0", "1=只对真人受害者生效（陪练 bot 被控时不管）｜0=bot 也生效", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 四种"控制开始"
	HookEvent("lunge_pounce",         Ev_ControlStart, EventHookMode_Post);
	HookEvent("tongue_grab",          Ev_ControlStart, EventHookMode_Post);
	HookEvent("jockey_ride",          Ev_ControlStart, EventHookMode_Post);
	HookEvent("charger_pummel_start", Ev_ControlStart, EventHookMode_Post);

	// 四种"控制结束"（提前结束/被打断 → 取消待解控）
	HookEvent("pounce_stopped",       Ev_ControlEnd, EventHookMode_Post);
	HookEvent("tongue_release",       Ev_ControlEnd, EventHookMode_Post);
	HookEvent("jockey_ride_end",      Ev_ControlEnd, EventHookMode_Post);
	HookEvent("charger_pummel_end",   Ev_ControlEnd, EventHookMode_Post);

	// ===== v1.1.0：章节统计 =====
	HookEvent("player_left_start_area", Ev_ChapterStart);   // 章节边界（与 ltt_kd 的章节计时同一事件）
	RegConsoleCmd("sm_autorel", Cmd_Stats, "查看本章节/本局自动解控次数");
	RegConsoleCmd("sm_jk",      Cmd_Stats, "查看本章节/本局自动解控次数");
	AddCommandListener(OnSay, "say");                       // 聊天里直接打「解控」也能查

	AutoExecConfig(true, "ltt_autorelease");

	LogMessage("[AutoRel] v%s 就绪 | 延迟 %.1fs ｜ 只对真人=%d ｜ 提示=%d",
		PLUGIN_VERSION, g_cDelay.FloatValue, g_cHumanOnly.IntValue, g_cNotify.IntValue);
}

// 【v1.1.1】改成在 cfg 生效之后播报 —— 踩过的坑：`sm plugins reload` 时旧实例的 cvar
// 还没销毁，CreateConVar 会拿回旧句柄，OnPluginStart 里打印的"延迟"是旧值（1.0s），
// 曾让人误判 cfg 没生效。cfg 执行完再播报，打印的就是真正生效的值。
public void OnConfigsExecuted()
{
	LogMessage("[AutoRel] v%s 生效 | 延迟 %.2fs ｜ 只对真人=%d ｜ 提示=%d ｜ 章节播报=%d ｜ debug=%d",
		PLUGIN_VERSION, g_cDelay.FloatValue, g_cHumanOnly.IntValue, g_cNotify.IntValue,
		g_cChapterMsg.IntValue, g_cDebug.IntValue);
}

public void OnClientDisconnect(int client)
{
	CancelFor(client);
}

public void OnMapEnd()
{
	for (int i = 1; i <= MaxClients; i++)
		CancelFor(i);
}

void CancelFor(int victim)
{
	if (victim > 0 && victim <= MaxClients && g_hTimer[victim] != null)
	{
		// 【v1.1.3 · 2026-10-02 源码审核修复】第二个参数 true = 同时关闭计时器携带的 DataPack 句柄。
		// 旧代码只 KillTimer 不关数据 ⇒ 每次解控被提前取消就漏一个 DataPack。
		KillTimer(g_hTimer[victim], true);
		g_hTimer[victim] = null;
	}
}

// ===================== 章节统计（v1.1.0） =====================
// 「章节」边界与 ltt_kd 的「本章节计时」完全同源：player_left_start_area（生还者走出安全屋）。
// 换图（OnMapStart）时章节/本局计数全部清零。

void ResetChapterCounters()
{
	g_iRelChapter = 0;
	for (int i = 0; i < 4; i++)
		g_iKindChapter[i] = 0;
}

int KindIndex(int ch)
{
	switch (ch)
	{
		case 'l', 'p': return 0;   // lunge_pounce（扑）
		case 't':      return 1;   // tongue_grab（舌）
		case 'j':      return 2;   // jockey_ride（骑）
		case 'c':      return 3;   // charger_pummel_start（撞）
	}
	return -1;
}

public void OnMapStart()
{
	g_iChapterNo  = 1;
	g_iRelChapter = 0;
	g_iRelTotal   = 0;
	for (int i = 0; i < 4; i++)
	{
		g_iKindChapter[i] = 0;
		g_iKindTotal[i]   = 0;
	}
}

public void Ev_ChapterStart(Event event, const char[] name, bool dontBroadcast)
{
	if (g_cChapterMsg.BoolValue && g_iRelTotal > 0)
		PrintToChatAll("[解控] 新章节开始 ｜ 上一章节解控 %d 次 ｜ 本局累计 %d 次", g_iRelChapter, g_iRelTotal);

	LogMessage("[AutoRel] 章节 %d 结束：解控 %d 次（扑 %d ｜ 舌 %d ｜ 骑 %d ｜ 撞 %d）｜ 本局累计 %d 次",
		g_iChapterNo, g_iRelChapter,
		g_iKindChapter[0], g_iKindChapter[1], g_iKindChapter[2], g_iKindChapter[3], g_iRelTotal);

	ResetChapterCounters();
	g_iChapterNo++;
}

void ShowStats(int client)
{
	PrintToChat(client, "[解控] 本章节：%d 次（扑 %d ｜ 舌 %d ｜ 骑 %d ｜ 撞 %d）",
		g_iRelChapter, g_iKindChapter[0], g_iKindChapter[1], g_iKindChapter[2], g_iKindChapter[3]);
	PrintToChat(client, "[解控] 本局累计：%d 次（扑 %d ｜ 舌 %d ｜ 骑 %d ｜ 撞 %d）｜ 当前延迟 %.2f 秒",
		g_iRelTotal, g_iKindTotal[0], g_iKindTotal[1], g_iKindTotal[2], g_iKindTotal[3], g_cDelay.FloatValue);
}

public Action Cmd_Stats(int client, int args)
{
	if (client > 0 && IsClientInGame(client))
		ShowStats(client);
	return Plugin_Handled;
}

// 聊天里打「解控」也查（中文命令名 SourceMod 不认，所以监听 say）
public Action OnSay(int client, const char[] command, int argc)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
		return Plugin_Continue;

	char msg[64];
	GetCmdArgString(msg, sizeof(msg));
	StripQuotes(msg);
	TrimString(msg);

	if (StrEqual(msg, "解控") || StrEqual(msg, "!解控") || StrEqual(msg, "/解控") || StrEqual(msg, "解控次数"))
	{
		ShowStats(client);
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public void Ev_ControlStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cEnable.BoolValue)
		return;

	// 【v1.0.1 修正】L4D2 这几个事件里：`userid` 是**特感（控制者）**，`victim` 才是**被控的生还者**。
	// v1.0.0 我读反了（把 userid 当受害者）⇒ 计时器挂在特感身上、attacker 永远取到 0，
	// 于是"自动解控"根本不会发生（只会给特感发个提示）。
	int victim   = GetClientOfUserId(event.GetInt("victim"));
	int attacker = GetClientOfUserId(event.GetInt("userid"));
	if (victim <= 0)                       // 兜底：万一某个事件没有 victim 字段
	{
		victim   = attacker;
		attacker = 0;
	}

	if (g_cDebug.BoolValue)
		LogMessage("[AutoRel] 收到被控事件 %s：victim字段=%d→#%d ｜ userid字段=%d→#%d",
		           name, event.GetInt("victim"), victim, event.GetInt("userid"), attacker);

	if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim))
		return;
	if (g_cHumanOnly.BoolValue && IsFakeClient(victim))
		return;

	CancelFor(victim);                       // 同一人重复被控 → 只留最新那次

	DataPack dp = new DataPack();
	dp.WriteCell(GetClientUserId(victim));
	// 【v1.0.3 加固】attacker 可能是 0（事件缺字段/兜底路径），GetClientUserId(0) 会直接抛
	// "Client index 0 is invalid" 并中断整个处理 ⇒ 计时器根本建不起来（v1.0.0 就是这么废的）。
	dp.WriteCell(attacker > 0 ? GetClientUserId(attacker) : 0);
	dp.WriteCell(name[0]);                   // 事件首字母，仅用于日志区分
	dp.WriteCell(view_as<int>(GetGameTime())); // 【v1.1.2】被控时刻，用于核对真实延迟

	// 【v1.1.3 · 2026-10-02 源码审核修复】带 TIMER_DATA_HNDL_CLOSE：
	// DataPack 交给 CreateTimer 后，若计时器不是自然走完（被 KillTimer / 换图回收），
	// 句柄就没人关了 —— 每次"被控事件"漏一个。带这个标志后由框架在计时器结束时关闭。
	g_hTimer[victim] = CreateTimer(g_cDelay.FloatValue, Timer_Release, dp, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
}

public void Ev_ControlEnd(Event event, const char[] name, bool dontBroadcast)
{
	// 不同事件的受害者字段名不一样（userid 是特感、victim 是生还者；有的只有其中一个），两个都试
	if (g_cDebug.BoolValue)
		LogMessage("[AutoRel] 收到解控事件 %s：userid字段=%d victim字段=%d",
		           name, event.GetInt("userid"), event.GetInt("victim"));
	int v1 = GetClientOfUserId(event.GetInt("userid"));
	if (v1 > 0)
		CancelFor(v1);
	int v2 = GetClientOfUserId(event.GetInt("victim"));
	if (v2 > 0)
		CancelFor(v2);
}

public Action Timer_Release(Handle timer, DataPack dp)
{
	dp.Reset();
	int victim   = GetClientOfUserId(dp.ReadCell());
	int attacker = GetClientOfUserId(dp.ReadCell());
	int which    = dp.ReadCell();
	float fStart = view_as<float>(dp.ReadCell());
	float fReal  = GetGameTime() - fStart;   // 【v1.1.2】被控→解控的实际秒数

	if (victim > 0 && victim <= MaxClients)
		g_hTimer[victim] = null;

	if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim) || !IsPlayerAlive(victim))
		return Plugin_Stop;

	// ===== 计数（v1.1.0）=====
	int ki = KindIndex(which);
	if (ki >= 0)
	{
		g_iKindChapter[ki]++;
		g_iKindTotal[ki]++;
	}
	g_iRelChapter++;
	g_iRelTotal++;

	if (g_cNotify.BoolValue)
		PrintHintText(victim, "已自动解控（练习模式）｜ 本章节第 %d 次", g_iRelChapter);

	if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && IsPlayerAlive(attacker))
	{
		ForcePlayerSuicide(attacker);        // 控制者一死，被控者立刻自由
		LogMessage("[AutoRel] 解控：受害者 #%d 被控（%c）→ 已杀控制者 #%d ｜ 实际 %.2fs ｜ 本章节第 %d 次 ｜ 本局第 %d 次",
		           victim, which, attacker, fReal, g_iRelChapter, g_iRelTotal);
	}
	else
	{
		LogMessage("[AutoRel] 解控：受害者 #%d 被控（%c）→ 控制者已不在，仅提示 ｜ 实际 %.2fs ｜ 本章节第 %d 次",
		           victim, which, fReal, g_iRelChapter);
	}
	return Plugin_Stop;
}
