/**
 * ===========================================================================
 *  LTT Long Ads  ——  长文案广告
 * ===========================================================================
 *
 *  为什么写这个：
 *      Source 引擎的用户消息缓冲约 255 字节，multicolors 的接收缓冲
 *      MAX_MESSAGE_LENGTH = 250，所以"把上限调大"没有意义——超出的部分只是
 *      把截断点从 multicolors 挪到引擎发送那一步。唯一办法是把一条长文案
 *      拆成多条聊天消息连着发出去。此插件即做这件事。
 *
 *  特点：
 *      - 文案长度基本不受限，超出阈值时按标点（。！？；，、…）在字符边界处
 *        自动切段，连发多条，视觉上就是一段完整的多行文案。
 *      - 颜色走 Multi-Colors：求生原生颜色码显示不出蓝色（SayText2 需要
 *        author 索引才能上色），Multi-Colors 的 MC_PrintToChat 带 author，
 *        所以 {blue} 能真正显示成蓝色。
 *      - 配置文件格式与原 advertisements.txt 完全兼容，可直接沿用。
 *
 *  配置(configs/advertisements.txt)：
 *      "Advertisements"
 *      {
 *          "1"
 *          {
 *              "chat"    "聊天框文案，长度不限"
 *              "center"  "屏幕中央文案(可选)"
 *              "hint"    "提示行文案(可选)"
 *          }
 *      }
 *
 *  变量占位符：{currentmap} {time} {time24} {date}
 *
 *  作者：DeepSeek Harness
 * ===========================================================================
 */

#include <sourcemod>
#include <multicolors>

#pragma newdecls required
#pragma semicolon 1

// 【2026-10-04 审计修复】原来叫 PL_VERSION，本项目构建脚本 build_plugin.ps1 只认
// PLUGIN_VERSION（找不到就拒绝构建）⇒ 统一改名。版本号不变。
#define PLUGIN_VERSION  "1.0.0"
#define MAX_AD_TEXT     4096
#define MAX_AD_ENTRIES  256
#define DEFAULT_CHUNK   220     // 单条聊天消息目标字节上限（multicolors 缓冲 250，留余量）

public Plugin myinfo =
{
	name        = "LTT Long Ads",
	author      = "DeepSeek Harness",
	description = "长文案广告：超出单条上限时按标点在字符边界自动分行连发",
	version     = PLUGIN_VERSION,
	url         = ""
};

ConVar  g_hEnabled;
ConVar  g_hFile;
ConVar  g_hInterval;
ConVar  g_hChunk;

Handle  g_hTimer;
int     g_iChunk = DEFAULT_CHUNK;
int     g_iIndex = 0;

ArrayList g_aChat;      // 聊天框文案
ArrayList g_aCenter;    // 屏幕中央文案
ArrayList g_aHint;      // 提示行文案

// 切分点。两级优先：先找句末标点，找不到再退到逗号/顿号，最后才硬切。
static const char g_sPunctStrong[][] = { "。", "！", "？", "；", "…" };
static const char g_sPunctWeak[][]   = { "，", "、" };


public void OnPluginStart()
{
	g_hEnabled  = CreateConVar("sm_ltt_ad_enabled",  "1",                  "开启长文案广告. 0=禁用, 1=启用.", FCVAR_NOTIFY);
	g_hFile     = CreateConVar("sm_ltt_ad_file",     "advertisements.txt", "广告文案文件名(位于 configs/ 下).", FCVAR_NOTIFY);
	g_hInterval = CreateConVar("sm_ltt_ad_interval", "180",                "两条广告之间的间隔/秒.", FCVAR_NOTIFY);
	g_hChunk    = CreateConVar("sm_ltt_ad_chunk",    "220",                "单条聊天消息的目标字节上限(100~240). <=0 表示不拆分.", FCVAR_NOTIFY);

	g_hFile.AddChangeHook(OnCvarChanged);
	g_hInterval.AddChangeHook(OnCvarChanged);
	g_hChunk.AddChangeHook(OnCvarChanged);
	g_hEnabled.AddChangeHook(OnCvarChanged);

	AutoExecConfig(true, "ltt_longad");

	RegAdminCmd("sm_ltt_ad_reload", Command_ReloadAds, ADMFLAG_GENERIC, "重载长文案广告配置文件");
	RegAdminCmd("sm_ltt_ad_next",   Command_NextAd,    ADMFLAG_GENERIC, "立刻播放下一广告");

	g_aChat   = new ArrayList(ByteCountToCells(MAX_AD_TEXT));
	g_aCenter = new ArrayList(ByteCountToCells(MAX_AD_TEXT));
	g_aHint   = new ArrayList(ByteCountToCells(MAX_AD_TEXT));

	LoadAds();
	RestartTimer();
}

public void OnMapStart()
{
	// 换图后重载，方便直接改文件生效
	LoadAds();
}


// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

void LoadAds()
{
	g_aChat.Clear();
	g_aCenter.Clear();
	g_aHint.Clear();
	g_iIndex = 0;

	char sPath[PLATFORM_MAX_PATH];
	char sFile[128];
	g_hFile.GetString(sFile, sizeof(sFile));
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/%s", sFile);

	if (!FileExists(sPath)) {
		LogError("[LTT Long Ads] 找不到文案文件: %s", sPath);
		return;
	}

	KeyValues kv = new KeyValues("Advertisements");
	if (!kv.ImportFromFile(sPath)) {
		LogError("[LTT Long Ads] 解析失败: %s", sPath);
		delete kv;
		return;
	}

	char sChat[MAX_AD_TEXT], sCenter[MAX_AD_TEXT], sHint[MAX_AD_TEXT];
	int  iCount = 0, iMaxLen = 0;

	if (kv.GotoFirstSubKey()) {
		do {
			if (iCount >= MAX_AD_ENTRIES) {
				break;
			}

			kv.GetString("chat",   sChat,   sizeof(sChat),   "");
			kv.GetString("center", sCenter, sizeof(sCenter), "");
			kv.GetString("hint",   sHint,   sizeof(sHint),   "");

			if (sChat[0]   || sCenter[0] || sHint[0]) {
				g_aChat.PushString(sChat);
				g_aCenter.PushString(sCenter);
				g_aHint.PushString(sHint);
				iCount++;

				int iLen = strlen(sChat);
				if (iLen > iMaxLen) {
					iMaxLen = iLen;
				}
			}
		} while (kv.GotoNextKey());
	}

	delete kv;
	LogMessage("[LTT Long Ads] 已载入 %d 条文案 (%s)，最长聊天文案 %d 字节，单条上限 %d 字节",
	           iCount, sFile, iMaxLen, g_iChunk);
}

void RestartTimer()
{
	delete g_hTimer;

	if (!g_hEnabled.BoolValue) {
		return;
	}

	int iInterval = g_hInterval.IntValue;
	if (iInterval < 5) {
		iInterval = 5;
	}

	g_hTimer = CreateTimer(float(iInterval), Timer_ShowAd, _, TIMER_REPEAT);
}


// ---------------------------------------------------------------------------
// 播放
// ---------------------------------------------------------------------------

public Action Timer_ShowAd(Handle timer)
{
	if (!g_hEnabled.BoolValue || g_aChat.Length == 0) {
		return Plugin_Continue;
	}

	if (g_iIndex >= g_aChat.Length) {
		g_iIndex = 0;
	}

	char sChat[MAX_AD_TEXT], sCenter[MAX_AD_TEXT], sHint[MAX_AD_TEXT];
	g_aChat.GetString(g_iIndex, sChat, sizeof(sChat));
	g_aCenter.GetString(g_iIndex, sCenter, sizeof(sCenter));
	g_aHint.GetString(g_iIndex, sHint, sizeof(sHint));
	g_iIndex++;

	ReplaceVars(sChat);
	ReplaceVars(sCenter);
	ReplaceVars(sHint);

	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}

		if (sChat[0]) {
			PrintChatChunked(i, sChat);
		}
		if (sHint[0]) {
			PrintHintText(i, "%s", sHint);
		}
		if (sCenter[0]) {
			PrintCenterText(i, "%s", sCenter);
		}
	}

	return Plugin_Continue;
}


// ---------------------------------------------------------------------------
// 长文案分行核心
// ---------------------------------------------------------------------------

/**
 * 把一条可能超过单条上限的聊天文案拆成若干段连着发出去。
 * 切分点优先取 [pos+chunk/2, pos+chunk] 区间内靠后的标点，
 * 且在 UTF-8 字符边界上切，绝不断开多字节汉字。
 */
void PrintChatChunked(int client, const char[] sText)
{
	int len = strlen(sText);

	if (g_iChunk <= 0 || len <= g_iChunk) {
		// 未超限：没有显式换行就整条发出；有换行仍按行拆（作者意图优先）
		if (StrContains(sText, "\n") == -1) {
			CPrintToChat(client, "%s", sText);
			return;
		}
	}

	char sPart[MAX_AD_TEXT];
	int  pos = 0, guard = 0;

	while (pos < len && guard++ < 64)
	{
		int remain = len - pos;
		int cut    = -1;

		// 0) 作者在文件里写的显式换行优先级最高：窗口内第一个换行处断开
		int nlim = pos + g_iChunk;
		if (nlim > len - 1) {
			nlim = len - 1;
		}
		for (int k = pos + 1; k <= nlim; k++) {
			if (sText[k] == '\n') {
				cut = k;
				break;
			}
		}

		// 1) 没有显式换行，且剩余不超限 → 整段发出，结束
		if (cut == -1 && remain <= g_iChunk) {
			CPrintToChat(client, "%s", sText[pos]);
			break;
		}

		// 2) 两级标点：先句末标点，再逗号/顿号
		if (cut == -1) {
			for (int strong = 1; strong >= 0 && cut == -1; strong--) {
				for (int k = pos + g_iChunk; k > pos + g_iChunk / 2; k--) {
					if (!IsCharStart(sText[k])) {
						continue;
					}
					int pl = PunctLen(sText, k, strong == 1);
					if (pl > 0 && k + pl <= pos + g_iChunk) {
						cut = k + pl;
						break;
					}
				}
			}
		}

		// 3) 实在没有切分点就退到最近的安全字符边界，绝不断开多字节字符
		if (cut == -1) {
			cut = pos + g_iChunk;
			while (cut > pos && !IsCharStart(sText[cut])) {
				cut--;
			}
			if (cut <= pos) {
				cut = pos + g_iChunk;
			}
		}

		// 段尾的 \r 一并去掉，避免 Windows 换行残留
		int end = cut;
		while (end > pos && sText[end - 1] == '\r') {
			end--;
		}

		if (end > pos) {
			strcopy(sPart, sizeof(sPart), sText[pos]);
			sPart[end - pos] = '\0';
			CPrintToChat(client, "%s", sPart);
		}

		pos = cut;
		while (pos < len && (sText[pos] == '\n' || sText[pos] == '\r'
		                     || sText[pos] == ' '  || sText[pos] == '\t')) {
			pos++;
		}
	}
}

/** s[i] 处的标点占几个字节；不是切分点返回 0。strong=true 只认句末标点 */
int PunctLen(const char[] s, int i, bool strong)
{
	if (strong) {
		for (int p = 0; p < sizeof(g_sPunctStrong); p++) {
			int n = strlen(g_sPunctStrong[p]);
			if (strncmp(s[i], g_sPunctStrong[p], n, false) == 0) {
				return n;
			}
		}
		return 0;
	}

	for (int p = 0; p < sizeof(g_sPunctWeak); p++) {
		int n = strlen(g_sPunctWeak[p]);
		if (strncmp(s[i], g_sPunctWeak[p], n, false) == 0) {
			return n;
		}
	}
	return 0;
}

/** UTF-8 字符起始字节（续字节形如 10xxxxxx） */
bool IsCharStart(int b)
{
	return (b & 0xC0) != 0x80;
}


// ---------------------------------------------------------------------------
// 变量占位符
// ---------------------------------------------------------------------------

void ReplaceVars(char[] sText)
{
	char sMap[64], sBuf[64];

	if (StrContains(sText, "{currentmap}", false) != -1) {
		GetCurrentMap(sMap, sizeof(sMap));
		ReplaceString(sText, MAX_AD_TEXT, "{currentmap}", sMap, false);
	}
	if (StrContains(sText, "{time24}", false) != -1) {
		FormatTime(sBuf, sizeof(sBuf), "%H:%M");
		ReplaceString(sText, MAX_AD_TEXT, "{time24}", sBuf, false);
	}
	if (StrContains(sText, "{time}", false) != -1) {
		FormatTime(sBuf, sizeof(sBuf), "%I:%M %p");
		ReplaceString(sText, MAX_AD_TEXT, "{time}", sBuf, false);
	}
	if (StrContains(sText, "{date}", false) != -1) {
		FormatTime(sBuf, sizeof(sBuf), "%Y-%m-%d");
		ReplaceString(sText, MAX_AD_TEXT, "{date}", sBuf, false);
	}
}


// ---------------------------------------------------------------------------
// Cvar 变化
// ---------------------------------------------------------------------------

public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar == g_hEnabled || convar == g_hInterval) {
		RestartTimer();
	}

	if (convar == g_hFile) {
		LoadAds();
	}

	if (convar == g_hChunk) {
		g_iChunk = convar.IntValue;
		if (g_iChunk > 240) {
			g_iChunk = 240;
		}
		if (g_iChunk > 0 && g_iChunk < 100) {
			g_iChunk = 100;
		}
	}
}


// ---------------------------------------------------------------------------
// 命令
// ---------------------------------------------------------------------------

public void OnConfigsExecuted()
{
	// 让 cfg 里的 sm_ltt_ad_chunk 真正生效
	g_iChunk = g_hChunk.IntValue;
	if (g_iChunk > 240) {
		g_iChunk = 240;
	}
	if (g_iChunk > 0 && g_iChunk < 100) {
		g_iChunk = 100;
	}
}

public Action Command_ReloadAds(int client, int args)
{
	LoadAds();
	ReplyToCommand(client, "[LTT Long Ads] 文案已重载 (%d 条)", g_aChat.Length);
	return Plugin_Handled;
}

public Action Command_NextAd(int client, int args)
{
	Timer_ShowAd(null);
	return Plugin_Handled;
}
