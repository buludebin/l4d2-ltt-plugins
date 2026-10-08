#pragma semicolon 1
#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.1.10-Optimized"

// 玩家音效选择状态
#define SOUND_DEFAULT 0   // 使用游戏内原有音效
#define SOUND_NONE 1      // 无击中音效（默认）
#define SOUND_CUSTOM 2    // 使用自定义音效（路径由 cvar 配置）

// 游戏自带音效（默认值）
#define DEF_KILL_SOUND     "level/timer_bell.wav"
#define DEF_HEADSHOT_SOUND "level/bell_impact.wav"
#define DEF_HIT_SOUND      "buttons/arena_switch_press_02.wav"

// 全局变量
int   g_iSoundSelect[MAXPLAYERS + 1];
float g_fLastPlay[MAXPLAYERS + 1];

ConVar g_cKillSound;
ConVar g_cHeadshotSound;
ConVar g_cHitSound;
ConVar g_cThrottle;

public Plugin myinfo =
{
	name        = "击中反馈的分支版本",
	author      = "TsukasaSato ,Hesh233(分支) - Rebuild；优化：DeepSeek Harness",
	description = "支持对玩家及小怪的击中反馈（音效预缓存 + 播放节流；自定义音效路径可配置）",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	// 音效路径改为 cvar，配合菜单里的"自定义音效"选项真正生效
	g_cKillSound     = CreateConVar("hitsound_snd_kill",     DEF_KILL_SOUND,     "击杀音效路径（选\"自定义音效\"时播放）", FCVAR_NOTIFY);
	g_cHeadshotSound = CreateConVar("hitsound_snd_headshot", DEF_HEADSHOT_SOUND, "爆头音效路径（同上）", FCVAR_NOTIFY);
	g_cHitSound      = CreateConVar("hitsound_snd_hit",      DEF_HIT_SOUND,      "命中音效路径（同上）", FCVAR_NOTIFY);
	g_cThrottle      = CreateConVar("hitsound_throttle",     "0.05",             "同一玩家两次音效的最小间隔（秒）。0=不限制；0.05 可压掉散弹/连发造成的音效轰炸", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	AutoExecConfig(true, "l4d2_hitsound");

	// 注册命令
	RegConsoleCmd("sm_snd", Command_HitsoundMenu, "设置音效类型");

	// 挂钩玩家受到伤害/死亡事件
	HookEvent("player_hurt",    Event_PlayerHurt,    EventHookMode_Pre);
	HookEvent("player_death",   Event_PlayerDeath,   EventHookMode_Pre);

	// 挂钩小怪受到伤害/死亡事件 (L4D2专属)
	HookEvent("infected_hurt",  Event_InfectedHurt,  EventHookMode_Pre);
	HookEvent("infected_death", Event_InfectedDeath, EventHookMode_Pre);
}

// 【优化点 1】音效只在换图时预缓存一次（原版是每次命中都调用 PrecacheSound）
public void OnMapStart()
{
	// 【1.1.10 · 2026-10-02 源码审核修复】换图必须清"上次播放时刻"。
	// GetGameTime() 换图会归零，而 g_fLastPlay 只在 OnClientPutInServer 里清过
	// （换图不会触发它）⇒ now - 旧值 为负 ⇒ 节流判定 now-g_fLastPlay < interval 恒真
	// ⇒ 已经开了击中音效的玩家，换图后会静音"上一张图已运行时长"那么久（可长达几十分钟）。
	for (int i = 1; i <= MaxClients; i++)
		g_fLastPlay[i] = 0.0;

	PrecacheSound(DEF_KILL_SOUND, true);
	PrecacheSound(DEF_HEADSHOT_SOUND, true);
	PrecacheSound(DEF_HIT_SOUND, true);

	char buf[PLATFORM_MAX_PATH];
	g_cKillSound.GetString(buf, sizeof(buf));
	if (buf[0] != '\0') PrecacheSound(buf, true);
	g_cHeadshotSound.GetString(buf, sizeof(buf));
	if (buf[0] != '\0') PrecacheSound(buf, true);
	g_cHitSound.GetString(buf, sizeof(buf));
	if (buf[0] != '\0') PrecacheSound(buf, true);
}

// 玩家进入游戏时，默认设置为无击中音效（按 072Bi 要求保持默认无声）
public void OnClientPutInServer(int client)
{
	g_iSoundSelect[client] = SOUND_NONE;
	g_fLastPlay[client]    = 0.0;
}

// 打开菜单命令
public Action Command_HitsoundMenu(int client, int args)
{
	if (!IsValidClient(client))
	{
		return Plugin_Handled;
	}
	OpenHitsoundMenu(client);
	return Plugin_Handled;
}

// 构建并显示菜单
void OpenHitsoundMenu(int client)
{
	Menu menu = new Menu(MenuHandler_SoundSelect);

	char sTitle[128];
	char sCurrentOption[64];

	switch (g_iSoundSelect[client])
	{
		case SOUND_DEFAULT: strcopy(sCurrentOption, sizeof(sCurrentOption), "游戏内原有音效");
		case SOUND_NONE:    strcopy(sCurrentOption, sizeof(sCurrentOption), "无击中音效");
		case SOUND_CUSTOM:  strcopy(sCurrentOption, sizeof(sCurrentOption), "使用自定义音效");
	}

	Format(sTitle, sizeof(sTitle), "当前状态: %s", sCurrentOption);
	menu.SetTitle(sTitle);

	menu.AddItem("default", "游戏内原有音效");
	menu.AddItem("none", "无击中音效");
	menu.AddItem("custom", "使用自定义音效（服务器配置的路径）");

	menu.Display(client, MENU_TIME_FOREVER);
}

// 菜单处理回调
public int MenuHandler_SoundSelect(Menu menu, MenuAction action, int param1, int param2)
{
	int client = param1;

	if (action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));

		if (strcmp(sInfo, "default") == 0)
		{
			g_iSoundSelect[client] = SOUND_DEFAULT;
			PrintToChat(client, "已设置为：游戏内原有音效");
		}
		else if (strcmp(sInfo, "none") == 0)
		{
			g_iSoundSelect[client] = SOUND_NONE;
			PrintToChat(client, "已设置为：无击中音效");
		}
		else if (strcmp(sInfo, "custom") == 0)
		{
			g_iSoundSelect[client] = SOUND_CUSTOM;
			PrintToChat(client, "已设置为：使用自定义音效");
		}

		OpenHitsoundMenu(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

// --- 核心音效播放逻辑 ---

void PlayHitSound(int client, bool isHeadshot, bool isKill)
{
	// 如果玩家选择了"无音效"，直接返回
	if (g_iSoundSelect[client] == SOUND_NONE)
	{
		return;
	}

	// 【优化点 2】节流：同一玩家在间隔内只播一次，压掉散弹/连发造成的音效轰炸
	float now      = GetGameTime();
	float interval = g_cThrottle.FloatValue;
	// 【1.1.10 · 审核修复】击杀音不参与节流：一次击杀通常紧跟一次命中（同一次攻击先算命中
	// 再算击杀），旧顺序会让命中音先把节流窗口占掉，击杀音永远播不出来。
	if (!isKill && interval > 0.0 && now - g_fLastPlay[client] < interval)
	{
		return;
	}
	g_fLastPlay[client] = now;

	char path[PLATFORM_MAX_PATH];

	if (g_iSoundSelect[client] == SOUND_CUSTOM)
	{
		if (isKill)          g_cKillSound.GetString(path, sizeof(path));
		else if (isHeadshot) g_cHeadshotSound.GetString(path, sizeof(path));
		else                 g_cHitSound.GetString(path, sizeof(path));
	}
	else
	{
		if (isKill)          strcopy(path, sizeof(path), DEF_KILL_SOUND);
		else if (isHeadshot) strcopy(path, sizeof(path), DEF_HEADSHOT_SOUND);
		else                 strcopy(path, sizeof(path), DEF_HIT_SOUND);
	}

	if (path[0] == '\0')
	{
		return;
	}

	// 音效已在 OnMapStart 预缓存，这里不再调用 PrecacheSound
	EmitSoundToClient(client, path, SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NORMAL, SND_NOFLAGS, SNDVOL_NORMAL, SNDPITCH_NORMAL);
}

// --- 事件处理 ---

// 玩家攻击玩家
public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int victim   = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (!IsValidClient(attacker) || !IsValidClient(victim) || IsFakeClient(attacker))
	{
		return Plugin_Continue;
	}

	bool is_headshot = event.GetBool("headshot");
	PlayHitSound(attacker, is_headshot, false);
	return Plugin_Continue;
}

// 玩家击杀玩家
public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim   = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (!IsValidClient(attacker) || !IsValidClient(victim) || IsFakeClient(attacker))
	{
		return Plugin_Continue;
	}

	PlayHitSound(attacker, false, true);
	return Plugin_Continue;
}

// 玩家命中小怪
public Action Event_InfectedHurt(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (!IsValidClient(attacker) || IsFakeClient(attacker))
	{
		return Plugin_Continue;
	}

	bool is_headshot = event.GetBool("headshot");
	PlayHitSound(attacker, is_headshot, false);
	return Plugin_Continue;
}

// 玩家击杀小怪
public Action Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (!IsValidClient(attacker) || IsFakeClient(attacker))
	{
		return Plugin_Continue;
	}

	PlayHitSound(attacker, false, true);
	return Plugin_Continue;
}

// 检查客户端是否有效
bool IsValidClient(int client)
{
	return (1 <= client <= MaxClients && IsClientInGame(client));
}
