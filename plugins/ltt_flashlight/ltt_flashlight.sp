/*
 *	[LTT] Server Flashlight — 服务端手电筒
 *
 *	思路（完全服务端，玩家零 mod，且不受客户端 cheat cvar 限制）：
 *	  1) 服务器把玩家实体的 EF_DIMLIGHT 位（m_fEffects 0x004）始终清掉
 *	     → 原版手电整体不出现（包括那束被人嫌弃的"跳跃光斑"），不需要玩家装透明贴图
 *	  2) 服务器自己挂一个 light_dynamic 当手电：颜色/亮度/光锥/距离/阴影全部 cvar 可调，
 *	     并用 SetTransmit 只让本人可见（不影响队友渲染）
 *	  3) 按 F 或聊天输入 !sd 切换；开关状态可用 cookie 记住，并可跨图保留
 *
 *	命令：!sd / !flash（所有人）切换手电
 *	调参：所有 ltt_fl_* cvar 都是即时生效的（改完按一下 F 重新生成光源即可看到新参数）
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <clientprefs>

#define PLUGIN_VERSION		"1.0.3"

#define TEAM_SURVIVOR		2
#define TEAM_INFECTED		3

#define IMPULS_FLASHLIGHT	100
#define EF_DIMLIGHT		0x004
#define DOUBLE_TAP_WINDOW	0.3

ConVar g_cEnable;
ConVar g_cReplace;
ConVar g_cBrightness;
ConVar g_cRadius;
ConVar g_cDistance;
ConVar g_cColor;
ConVar g_cSpawnFlags;
ConVar g_cOffsetZ;
ConVar g_cKeyMode;
ConVar g_cCooldown;
ConVar g_cKeepOnMap;
ConVar g_cCookie;
ConVar g_cVerbose;

bool   g_bEffectsOk;
Handle g_hCookieOn;

int    g_iLight[MAXPLAYERS + 1] = {-1, ...};
bool   g_bWantOn[MAXPLAYERS + 1];
float  g_fDoubleTap[MAXPLAYERS + 1];
float  g_fLastSwitch[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name        = "[LTT] Server Flashlight",
	author      = "DeepSeek Harness",
	description = "服务端手电筒：关闭原版手电并用服务端光源替代，玩家无需任何 mod",
	version     = PLUGIN_VERSION,
	url         = "N/A"
};

public void OnPluginStart()
{
	CreateConVar("ltt_fl_version", PLUGIN_VERSION, "服务端手电筒版本", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	g_cEnable     = CreateConVar("ltt_fl_enable",     "1",                "总开关: 1=启用服务端手电筒, 0=完全关闭（原版手电恢复）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cReplace    = CreateConVar("ltt_fl_replace",    "1",                "是否关闭原版手电(EF_DIMLIGHT): 1=关闭(推荐, 只用我们的光), 0=保留原版", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cKeyMode    = CreateConVar("ltt_fl_keymode",    "0",                "F键方案: 0=双方单击F, 1=幸存者双击F/感染者单击F, 2=禁用F键(只用 !sd)", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	g_cCooldown   = CreateConVar("ltt_fl_cooldown",   "0.25",             "开关冷却秒数", FCVAR_NOTIFY, true, 0.0, true, 5.0);
	g_cBrightness = CreateConVar("ltt_fl_brightness", "3",                "光源亮度(light_dynamic brightness)", FCVAR_NOTIFY, true, 0.1, true, 30.0);
	g_cRadius     = CreateConVar("ltt_fl_radius",     "45.0",             "光锥大小(spotlight_radius)", FCVAR_NOTIFY, true, 1.0, true, 180.0);
	g_cDistance   = CreateConVar("ltt_fl_distance",   "1200.0",           "照射距离(distance)", FCVAR_NOTIFY, true, 50.0, true, 5000.0);
	g_cColor      = CreateConVar("ltt_fl_color",      "255 245 220 255",  "光源颜色 R G B A（暖白）", FCVAR_NOTIFY);
	g_cSpawnFlags = CreateConVar("ltt_fl_spawnflags", "0",                "光源 spawnflags(0=不投影阴影, 1=投影阴影; 默认 0 更省玩家性能)", FCVAR_NOTIFY, true, 0.0, true, 255.0);
	g_cOffsetZ    = CreateConVar("ltt_fl_offsetz",    "24.0",             "光源相对玩家的高度偏移", FCVAR_NOTIFY, true, -50.0, true, 100.0);
	g_cKeepOnMap  = CreateConVar("ltt_fl_keep_on_map","1",                "过关/换图后是否保留玩家自己的开关", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cCookie     = CreateConVar("ltt_fl_cookie",     "1",                "是否用 cookie 记住玩家开关(clientprefs)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cVerbose    = CreateConVar("ltt_fl_verbose",    "0",                "1=写调试日志", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	AutoExecConfig(true, "ltt_flashlight");

	g_hCookieOn = RegClientCookie("ltt_fl_on", "服务端手电筒是否开启(1/0)", CookieAccess_Protected);

	// m_fEffects 可写性检查（不同版本属性名若有差异就不去写，避免刷错误日志）
	g_bEffectsOk = (FindSendPropInfo("CTerrorPlayer", "m_fEffects") > 0);
	LogMessage("[ServerFlash] v%s 已加载 | m_fEffects 可写: %s", PLUGIN_VERSION, g_bEffectsOk ? "是" : "否");

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("round_start",  Event_RoundStart,  EventHookMode_PostNoCopy);
	HookEvent("player_team",  Event_PlayerTeam,  EventHookMode_Post);

	RegConsoleCmd("sm_sd",    Cmd_Toggle, "开关服务端手电筒");
	RegAdminCmd("sm_flset", Cmd_Set, ADMFLAG_ROOT, "调手电筒参数");
	RegConsoleCmd("sm_flash", Cmd_Toggle, "开关服务端手电筒");

	// 安全网：每秒把原版手电再压一次（客户端可能自己又点亮了）
	CreateTimer(1.0, Timer_Suppress, _, TIMER_REPEAT);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && AreClientCookiesCached(i))
			LoadPrefs(i);
	}
}

/* ───────────────────────── 原版手电压制 ───────────────────────── */

void SuppressVanilla(int client)
{
	if (!g_bEffectsOk || !g_cReplace.BoolValue || !g_cEnable.BoolValue)
		return;

	if (!IsClientInGame(client) || IsFakeClient(client))
		return;

	// 只处理生还者（感染者没有手电）
	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return;

	int fx = GetEntProp(client, Prop_Send, "m_fEffects");
	if (fx & EF_DIMLIGHT)
		SetEntProp(client, Prop_Send, "m_fEffects", fx & ~EF_DIMLIGHT);
}

public Action Timer_Suppress(Handle timer)
{
	if (!g_bEffectsOk || !g_cReplace.BoolValue || !g_cEnable.BoolValue)
		return Plugin_Continue;

	for (int i = 1; i <= MaxClients; i++)
		SuppressVanilla(i);

	return Plugin_Continue;
}

/* ───────────────────────── 光源 ───────────────────────── */

Action Hook_SetTransmit(int entity, int client)
{
	int ref = EntIndexToEntRef(entity);

	if (g_iLight[client] == ref)
		return Plugin_Continue;	// 只让本人看见

	return Plugin_Handled;
}

void RemoveRef(int& ref)
{
	int entity = EntRefToEntIndex(ref);
	if (entity != -1)
	{
		// 【v1.0.3 修复 · 2026-09-25 深夜事故】这里原来是 `RemoveEdict(entity)`。
		//
		// RemoveEdict 是【直接拆 edict】，不走实体的 Kill / OnRemove 清理路径。
		// 而本插件的这个光源是被 `AcceptEntityInput(light, "SetParent", client)`
		// 挂到【玩家实体】身上的 —— 对"已经设了父"的实体这么删，父实体的
		// m_Children 子链会留下【悬空项】。玩家实体的子链每帧都会被引擎遍历，
		// 于是每次开关手电都往那条链上压一个已释放的节点。
		//
		// 当天的观测（形状与"引擎侧链表条目泄漏"一致）：
		//   · 帧时间在 13 分钟内从 30ms 单调涨到 167ms（渐进，不是突变）
		//   · CPU 单核 100%（2 核机器，引擎单线程）
		//   · GetEntityCount() 全程不变（edict 确实释放了，漏的是引擎侧链表）
		//   · 重启立刻恢复；卸载刷特插件、关掉刷特都不影响它
		//   · 恶化起始那几分钟，日志里唯一在动的是本插件在反复生成光源
		//   !! 但当天只生成了 90 次光源，对 150ms/帧 来说数量偏少，
		//      所以这只是【最高嫌疑】，不是已证实的结论。看门狗会继续抓。
		//
		// 正确顺序：先解 SDKHook → 再解父 → 最后走 Kill 让引擎自己清理。
		SDKUnhook(entity, SDKHook_SetTransmit, Hook_SetTransmit);
		AcceptEntityInput(entity, "ClearParent");
		AcceptEntityInput(entity, "Kill");
	}
	ref = -1;
}

void KillLight(int client)
{
	if (g_iLight[client] != -1)
		RemoveRef(g_iLight[client]);
}

void CreateLight(int client)
{
	// 【v1.0.3 · 保险】所有调用点本来都判了 `g_iLight[client] == -1`，
	// 但万一以后有人漏判，这里就会把旧实体变成永远删不掉的孤儿
	// （引用被覆盖，再也找不到它）。加这道守卫让"漏判"不再致命。
	if (g_iLight[client] != -1)
		KillLight(client);

	int light = CreateEntityByName("light_dynamic");
	if (!IsValidEntity(light))
		return;

	g_iLight[client] = EntIndexToEntRef(light);

	char buf[64];
	g_cColor.GetString(buf, sizeof buf);
	DispatchKeyValue(light, "_light", buf);

	IntToString(g_cBrightness.IntValue, buf, sizeof buf);
	DispatchKeyValue(light, "brightness", buf);

	DispatchKeyValueFloat(light, "spotlight_radius", g_cRadius.FloatValue);
	DispatchKeyValueFloat(light, "distance",         g_cDistance.FloatValue);
	DispatchKeyValue(light, "style", "0");

	int flags = g_cSpawnFlags.IntValue;
	if (flags > 0)
	{
		IntToString(flags, buf, sizeof buf);
		DispatchKeyValue(light, "spawnflags", buf);
	}

	DispatchSpawn(light);
	AcceptEntityInput(light, "TurnOn");

	SetVariantString("!activator");
	AcceptEntityInput(light, "SetParent", client);

	float pos[3];
	pos[0] = 0.0;
	pos[1] = 0.0;
	pos[2] = g_cOffsetZ.FloatValue;
	TeleportEntity(light, pos, view_as<float>({0.0, 0.0, 0.0}), NULL_VECTOR);

	SDKHook(light, SDKHook_SetTransmit, Hook_SetTransmit);

	if (g_cVerbose.BoolValue)
		LogMessage("[ServerFlash] 已为 %L 生成光源 (亮度 %d, 光锥 %.0f, 距离 %.0f)",
			client, g_cBrightness.IntValue, g_cRadius.FloatValue, g_cDistance.FloatValue);
}

/* ───────── v1.0.2 新增：!flset 实时调参（只加命令，其余代码不动）───────── */

void SaveConfigV102()
{
	char path[PLATFORM_MAX_PATH], color[64];
	g_cColor.GetString(color, sizeof color);

	BuildPath(Path_SM, path, sizeof path, "../../cfg/sourcemod/ltt_flashlight.cfg");

	File f = OpenFile(path, "w");
	if (f == null)
		return;

	f.WriteLine("// [LTT] 服务端手电筒 v1.0.2 配置（由 !flset 保存，换图自动执行）");
	f.WriteLine("ltt_fl_enable \"%d\"", g_cEnable.IntValue);
	f.WriteLine("ltt_fl_replace \"%d\"", g_cReplace.IntValue);
	f.WriteLine("ltt_fl_brightness \"%d\"", g_cBrightness.IntValue);
	f.WriteLine("ltt_fl_radius \"%.1f\"", g_cRadius.FloatValue);
	f.WriteLine("ltt_fl_distance \"%.1f\"", g_cDistance.FloatValue);
	f.WriteLine("ltt_fl_color \"%s\"", color);
	f.WriteLine("ltt_fl_spawnflags \"%d\"", g_cSpawnFlags.IntValue);
	f.WriteLine("ltt_fl_offsetz \"%.1f\"", g_cOffsetZ.FloatValue);
	f.WriteLine("ltt_fl_keymode \"%d\"", g_cKeyMode.IntValue);
	f.WriteLine("ltt_fl_cooldown \"%.2f\"", g_cCooldown.FloatValue);
	f.WriteLine("ltt_fl_keep_on_map \"%d\"", g_cKeepOnMap.IntValue);
	f.WriteLine("ltt_fl_cookie \"%d\"", g_cCookie.IntValue);
	f.WriteLine("ltt_fl_verbose \"%d\"", g_cVerbose.IntValue);

	delete f;
}

Action Cmd_Set(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "[手电筒] 用法: !flset <brightness|radius|distance|offsetz|color|enable> <值>");
		ReplyToCommand(client, "   brightness 亮度 1~6   例: !flset brightness 3");
		ReplyToCommand(client, "   radius 张角 30聚/60散  例: !flset radius 30");
		ReplyToCommand(client, "   distance 距离         例: !flset distance 800");
		ReplyToCommand(client, "   offsetz 高度(离地)     例: !flset offsetz 60");
		ReplyToCommand(client, "   color 颜色+强度        例: !flset color 255 245 220 255");
		ReplyToCommand(client, "   enable 0=整套关掉(恢复原版手电) / 1=开启");
		return Plugin_Handled;
	}

	char key[32], val[160], argstr[224];
	GetCmdArg(1, key, sizeof key);
	GetCmdArgString(argstr, sizeof argstr);
	TrimString(argstr);

	int sp = StrContains(argstr, " ");
	if (sp > 0)
	{
		strcopy(val, sizeof val, argstr[sp + 1]);
		TrimString(val);
	}
	else
	{
		GetCmdArg(2, val, sizeof val);
	}

	if (StrEqual(key, "brightness", false) || StrEqual(key, "b", false))
		g_cBrightness.SetInt(StringToInt(val));
	else if (StrEqual(key, "radius", false) || StrEqual(key, "r", false))
		g_cRadius.SetFloat(StringToFloat(val));
	else if (StrEqual(key, "distance", false) || StrEqual(key, "d", false))
		g_cDistance.SetFloat(StringToFloat(val));
	else if (StrEqual(key, "offsetz", false) || StrEqual(key, "z", false))
		g_cOffsetZ.SetFloat(StringToFloat(val));
	else if (StrEqual(key, "color", false) || StrEqual(key, "c", false))
		g_cColor.SetString(val);
	else if (StrEqual(key, "enable", false))
		g_cEnable.SetInt(StringToInt(val));
	else
	{
		ReplyToCommand(client, "[手电筒] 未知参数: %s", key);
		return Plugin_Handled;
	}

	SaveConfigV102();

	ReplyToCommand(client, "[手电筒] %s = %s | 亮度=%d 张角=%.0f 距离=%.0f 高度=%.0f 开关=%d",
		key, val, g_cBrightness.IntValue, g_cRadius.FloatValue, g_cDistance.FloatValue, g_cOffsetZ.FloatValue, g_cEnable.IntValue);

	// 开着的话立刻用新参数重建（不然要手动重开才看到）
	if (client && IsClientInGame(client) && !IsFakeClient(client) && g_iLight[client] != -1)
	{
		KillLight(client);
		CreateLight(client);
	}

	return Plugin_Handled;
}

void ToggleLight(int client)
{
	if (g_iLight[client] == -1)
	{
		CreateLight(client);
		if (g_iLight[client] != -1)
		{
			g_bWantOn[client] = true;
			SavePrefs(client);
			SuppressVanilla(client);
			PrintHintText(client, "手电筒已开启（!sd 关闭）");
		}
	}
	else
	{
		KillLight(client);
		g_bWantOn[client] = false;
		SavePrefs(client);
		PrintHintText(client, "手电筒已关闭");
	}
}

bool CanUse(int client)
{
	int team = GetClientTeam(client);
	return (team == TEAM_SURVIVOR || team == TEAM_INFECTED);
}

void TryToggle(int client)
{
	if (!g_cEnable.BoolValue || !CanUse(client))
		return;

	float now = GetEngineTime();
	if (now - g_fLastSwitch[client] < g_cCooldown.FloatValue)
		return;

	g_fLastSwitch[client] = now;
	ToggleLight(client);
}

/* ───────────────────────── cookie 记忆 ───────────────────────── */

public void OnClientCookiesCached(int client)
{
	if (IsFakeClient(client))
		return;
	LoadPrefs(client);
}

void LoadPrefs(int client)
{
	if (!g_cCookie.BoolValue)
		return;

	char buf[8];
	GetClientCookie(client, g_hCookieOn, buf, sizeof buf);
	g_bWantOn[client] = (buf[0] != '\0' && StringToInt(buf) == 1);
}

void SavePrefs(int client)
{
	if (!g_cCookie.BoolValue || IsFakeClient(client) || !AreClientCookiesCached(client))
		return;

	SetClientCookie(client, g_hCookieOn, g_bWantOn[client] ? "1" : "0");
}

/* ───────────────────────── 事件 ───────────────────────── */

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || IsFakeClient(client))
		return;

	CreateTimer(1.0, Timer_AfterSpawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_AfterSpawn(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Stop;

	SuppressVanilla(client);

	if (g_bWantOn[client] && g_cKeepOnMap.BoolValue && g_iLight[client] == -1 && g_cEnable.BoolValue)
		CreateLight(client);

	return Plugin_Stop;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++)
		KillLight(i);
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	// v1.0.1：player_team 实测每 3 秒乱触发一次（阵营读数会闪），
	// 原来这里"收灯 + 清开关"→ 手电开一会儿就消失。现在不动光源。
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsClientInGame(client) || IsFakeClient(client))
		return;
}

public void OnClientDisconnect(int client)
{
	KillLight(client);
	g_bWantOn[client] = false;
	g_fDoubleTap[client] = 0.0;
	g_fLastSwitch[client] = 0.0;
}

/* ───────────────────────── 按键与命令 ───────────────────────── */

public void OnPlayerRunCmdPre(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	if (impulse != IMPULS_FLASHLIGHT)
		return;

	if (!IsClientInGame(client) || IsFakeClient(client))
		return;

	// 原版手电被我们关了，但客户端可能已经把这一下当成"开手电"，
	// 所以这里立刻再压一次，保证原版手电不会闪出来
	SuppressVanilla(client);

	int keymode = g_cKeyMode.IntValue;
	if (keymode == 2)
		return;

	int team = GetClientTeam(client);

	if (keymode == 0)
	{
		TryToggle(client);
	}
	else if (team == TEAM_SURVIVOR)
	{
		float now = GetEngineTime();
		if (now - g_fDoubleTap[client] < DOUBLE_TAP_WINDOW)
		{
			g_fDoubleTap[client] = 0.0;
			TryToggle(client);
		}
		else
			g_fDoubleTap[client] = now;
	}
	else if (team == TEAM_INFECTED)
	{
		TryToggle(client);
	}
}

Action Cmd_Toggle(int client, int args)
{
	if (!client || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Handled;

	if (!g_cEnable.BoolValue)
	{
		PrintToChat(client, "\x04[提示]\x05服务端手电筒未启用。");
		return Plugin_Handled;
	}

	if (!CanUse(client))
	{
		PrintToChat(client, "\x04[提示]\x05当前阵营无法使用手电筒。");
		return Plugin_Handled;
	}

	ToggleLight(client);
	return Plugin_Handled;
}