/**
 * ===========================================================================
 *  LTT Heal Amount Vote  ——  投票决定「击杀特感回复多少血量」
 * ===========================================================================
 *
 *  背景：
 *      l4d2_health_return 的回复量由 cvar l4d2_health_return_value 控制
 *      （默认 5）。这个数值该给多少，服务器上人各有爱，所以做成玩家投票。
 *
 *  用法：
 *      !hv / !healvote / !回血     任意玩家发起（有冷却）
 *      sm_healset <数值>           管理员直接设定，不走投票
 *
 *  规则：
 *      - 用 L4D2 原生投票样式展示（DisplayVoteToAll），票数实时可见
 *      - 每人一票，可以改票
 *      - 投票时长结束后统计，得票最高的生效；同票取较大值
 *      - 有效票数不足 ltt_healvote_minvotes 时投票作废，数值不变
 *      - 通过 SetConVarInt 写 l4d2_health_return_value，
 *        该插件挂了 HookConVarChange，会自己重读，不需要重启或换图
 *
 *  作者：DeepSeek Harness
 * ===========================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <multicolors>

#define PLUGIN_VERSION  "1.0.2"
#define MAX_OPTIONS     12
#define OPTION_LEN      16

ConVar g_cEnable;
ConVar g_cOptions;
ConVar g_cDuration;
ConVar g_cCooldown;
ConVar g_cMinVotes;
ConVar g_cValueCvar;

char   g_sOptions[MAX_OPTIONS][OPTION_LEN];
int    g_iOptionCount;
int    g_iVotes[MAXPLAYERS + 1];
bool   g_bVoteActive;
int    g_iEligible;
int    g_iVoted;
int    g_iLastVote;         // Unix 秒
Handle g_hTimer;
Menu   g_hMenu;

public Plugin myinfo =
{
	name        = "[LTT] Heal Amount Vote",
	author      = "DeepSeek Harness",
	description = "让玩家投票决定『击杀特感回复多少血量』",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	LoadTranslations("common.phrases");

	g_cEnable   = CreateConVar("ltt_healvote_enable",   "1",                 "1=允许玩家发起回血量投票, 0=关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cOptions  = CreateConVar("ltt_healvote_options",  "0;2;3;5;8;10;15;20", "可选的回复血量, 用分号分隔(最多 12 个)", FCVAR_NOTIFY);
	g_cDuration = CreateConVar("ltt_healvote_duration", "20",                "投票持续秒数", FCVAR_NOTIFY, true, 5.0, true, 120.0);
	g_cCooldown = CreateConVar("ltt_healvote_cooldown", "180",               "两次投票的最小间隔秒数", FCVAR_NOTIFY, true, 0.0, true, 3600.0);
	g_cMinVotes = CreateConVar("ltt_healvote_minvotes", "2",                 "有效票数低于这个值则投票作废", FCVAR_NOTIFY, true, 1.0, true, 32.0);

	g_cOptions.AddChangeHook(OnCvarChanged);
	g_cEnable.AddChangeHook(OnCvarChanged);
	ParseOptions();

	RegConsoleCmd("sm_hv",        Cmd_StartVote, "发起『击杀特感回复多少血量』投票");
	RegConsoleCmd("sm_healvote",  Cmd_StartVote, "发起『击杀特感回复多少血量』投票");
	RegAdminCmd("sm_healset",     Cmd_HealSet,   ADMFLAG_BAN, "直接设定击杀特感回复血量 (不走投票)");

	AutoExecConfig(true, "ltt_healvote");

	// l4d2_health_return 的回复量 cvar；插件不在位时投票会直接报错退出
	g_cValueCvar = FindConVar("l4d2_health_return_value");

	LogMessage("[HealVote] v%s 已加载 | 可选值 %d 个 | 目标 cvar: %s",
		PLUGIN_VERSION, g_iOptionCount, g_cValueCvar == null ? "未找到" : "l4d2_health_return_value");
}

/** 【v1.0.2 · 2026-10-02 源码审核修复】换图清投票状态。
 *  本插件原本只有 VoteAction_End 会清 g_bVoteActive：投票进行中换图、或引擎走了
 *  VoteCancel 分支时都不会触发它 ⇒ 标志卡在 true ⇒ :176 永久拒绝新的 !hv（要重载插件）。
 *  顺带把票箱清空（新图不该继承上一张图的票）。 */
public void OnMapStart()
{
	g_bVoteActive = false;
	for (int i = 0; i <= MaxClients; i++)
		g_iVotes[i] = -1;
}

public void OnConfigsExecuted()
{
	// cfg 载入后重新解析一次选项
	ParseOptions();
	g_cValueCvar = FindConVar("l4d2_health_return_value");
}

public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar == g_cOptions)
	{
		ParseOptions();
	}
}

/** 解析 ltt_healvote_options 里的候选值 */
void ParseOptions()
{
	g_iOptionCount = 0;

	char sRaw[256];
	g_cOptions.GetString(sRaw, sizeof(sRaw));

	char sParts[MAX_OPTIONS][OPTION_LEN];
	int n = ExplodeString(sRaw, ";", sParts, MAX_OPTIONS, OPTION_LEN);

	for (int i = 0; i < n; i++)
	{
		TrimString(sParts[i]);
		if (sParts[i][0] == '\0')
		{
			continue;
		}
		// 只接受数字，避免 cfg 填错导致运行时炸掉
		if (!IsNumericString(sParts[i]))
		{
			LogError("[HealVote] 忽略非法选项 \"%s\" (必须是非负整数)", sParts[i]);
			continue;
		}
		strcopy(g_sOptions[g_iOptionCount], OPTION_LEN, sParts[i]);
		g_iOptionCount++;
	}

	if (g_iOptionCount == 0)
	{
		// 兜底：至少留一个能用的选项
		strcopy(g_sOptions[0], OPTION_LEN, "5");
		g_iOptionCount = 1;
		LogError("[HealVote] ltt_healvote_options 里没有合法数值，已回退为 \"5\"");
	}
}

bool IsNumericString(const char[] s)
{
	for (int i = 0; s[i] != '\0'; i++)
	{
		if (s[i] < '0' || s[i] > '9')
		{
			return false;
		}
	}
	return true;
}

int GetTargetValue()
{
	return g_cValueCvar == null ? -1 : g_cValueCvar.IntValue;
}

// ---------------------------------------------------------------------------
// 发起投票
// ---------------------------------------------------------------------------

public Action Cmd_StartVote(int client, int args)
{
	if (!g_cEnable.BoolValue)
	{
		ReplyToCommand(client, "[回血投票] 该功能已关闭");
		return Plugin_Handled;
	}

	if (g_cValueCvar == null)
	{
		ReplyToCommand(client, "[回血投票] 找不到插件 l4d2_health_return（cvar l4d2_health_return_value 不存在）");
		return Plugin_Handled;
	}

	if (g_bVoteActive)
	{
		ReplyToCommand(client, "[回血投票] 已经有一个投票在进行中");
		return Plugin_Handled;
	}

	int iCooldown = g_cCooldown.IntValue;
	if (g_iLastVote > 0 && (GetTime() - g_iLastVote) < iCooldown)
	{
		ReplyToCommand(client, "[回血投票] 距离上次投票不足 %d 秒，请稍候", iCooldown);
		return Plugin_Handled;
	}

	StartVote(client);
	return Plugin_Handled;
}

void StartVote(int starter)
{
	g_bVoteActive = true;
	g_iVoted = 0;
	g_iEligible = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		g_iVotes[i] = -1;
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			g_iEligible++;
		}
	}

	if (g_hMenu != null)
	{
		delete g_hMenu;
	}
	g_hMenu = new Menu(MenuHandler_Vote);
	g_hMenu.SetTitle("击杀特感回复多少血量？\n当前: %d\n ", GetTargetValue());

	char sLabel[32];
	for (int i = 0; i < g_iOptionCount; i++)
	{
		Format(sLabel, sizeof(sLabel), "%s 点", g_sOptions[i]);
		g_hMenu.AddItem(g_sOptions[i], sLabel);
	}

	int iDuration = g_cDuration.IntValue;
	g_hMenu.DisplayVoteToAll(iDuration);

	if (starter > 0)
	{
		CPrintToChatAll("{olive}[回血投票]{default} {green}%N{default} 发起了投票，{green}%d{default} 秒内按数字键选择", starter, iDuration);
	}
	else
	{
		CPrintToChatAll("{olive}[回血投票]{default} 投票开始，{green}%d{default} 秒内按数字键选择", iDuration);
	}

	delete g_hTimer;
	g_hTimer = CreateTimer(float(iDuration), Timer_FinishVote);
}

public int MenuHandler_Vote(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		if (client < 1 || client > MaxClients)
		{
			return 0;
		}

		if (g_iVotes[client] == -1)
		{
			g_iVoted++;
		}
		g_iVotes[client] = item;

		// 所有人都投完了就立刻结束，不用干等
		if (g_iVoted >= g_iEligible)
		{
			FinishVote();
		}
	}
	else if (action == MenuAction_End)
	{
		// 菜单对象由 g_hMenu 持有，这里不要按 menu 参数删
	}

	return 0;
}

public Action Timer_FinishVote(Handle timer)
{
	g_hTimer = null;
	FinishVote();
	return Plugin_Stop;
}

/** 统计并应用结果 */
void FinishVote()
{
	if (!g_bVoteActive)
	{
		return;
	}
	g_bVoteActive = false;

	delete g_hTimer;
	g_hTimer = null;

	if (g_hMenu != null)
	{
		delete g_hMenu;
		g_hMenu = null;
	}

	// 计票
	int iTally[MAX_OPTIONS];
	for (int i = 0; i < g_iOptionCount; i++)
	{
		iTally[i] = 0;
	}

	int iTotal = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		int v = g_iVotes[i];
		if (IsClientInGame(i) && !IsFakeClient(i) && v >= 0 && v < g_iOptionCount)
		{
			iTally[v]++;
			iTotal++;
		}
		g_iVotes[i] = -1;
	}

	if (iTotal < g_cMinVotes.IntValue)
	{
		CPrintToChatAll("{olive}[回血投票]{default} 只有 {green}%d{default} 票，不足 {green}%d{default} 票，本次投票作废，数值不变",
			iTotal, g_cMinVotes.IntValue);
		LogMessage("[HealVote] 投票作废: 有效票 %d < %d", iTotal, g_cMinVotes.IntValue);
		return;
	}

	// 最高票；同票取较大值（选项按 cfg 顺序，这里显式比数值）
	char sWin[OPTION_LEN];
	strcopy(sWin, sizeof(sWin), g_sOptions[0]);
	int iBestVotes = -1;
	int iBestValue = -1;

	for (int i = 0; i < g_iOptionCount; i++)
	{
		int iValue = StringToInt(g_sOptions[i]);
		if (iTally[i] > iBestVotes || (iTally[i] == iBestVotes && iValue > iBestValue))
		{
			iBestVotes = iTally[i];
			iBestValue = iValue;
			strcopy(sWin, sizeof(sWin), g_sOptions[i]);
		}
	}

	int iOld = GetTargetValue();

	// 【v1.0.1 · 2026-10-02 源码审核修复】句柄判空：起投票时 :170 已拦 null，
	// 但投票窗口（20 秒）内管理员卸载 l4d2_health_return 会让句柄失效，
	// 此时 SetInt 抛运行时错误并中断本次结算 ⇒ 投票结果白投、明细也不打。
	if (g_cValueCvar == null)
	{
		CPrintToChatAll("{olive}[回血投票]{default} 投票结束，但目标插件已卸载，本次结果未写入");
		LogMessage("[HealVote] 结算中止：g_cValueCvar 已失效（胜出 %s 值 %d）", sWin, iBestValue);
		return;
	}

	g_cValueCvar.SetInt(iBestValue);
	g_iLastVote = GetTime();

	// 明细，便于事后核对
	char sDetail[256];
	sDetail[0] = '\0';
	for (int i = 0; i < g_iOptionCount; i++)
	{
		if (iTally[i] > 0)
		{
			Format(sDetail, sizeof(sDetail), "%s%s:%d票 ", sDetail, g_sOptions[i], iTally[i]);
		}
	}

	CPrintToChatAll("{olive}[回血投票]{default} 结果：{green}%s 点{default}（%d 票 / 共 %d 票）  {olive}%s",
		sWin, iBestVotes, iTotal, sDetail);
	CPrintToChatAll("{olive}[回血投票]{default} 击杀特感回复血量：{green}%d{default} → {green}%d", iOld, iBestValue);

	LogMessage("[HealVote] 投票通过: %d -> %d (%d票/共%d票) 明细: %s", iOld, iBestValue, iBestVotes, iTotal, sDetail);
}

// ---------------------------------------------------------------------------
// 管理员直接设定
// ---------------------------------------------------------------------------

public Action Cmd_HealSet(int client, int args)
{
	if (g_cValueCvar == null)
	{
		ReplyToCommand(client, "[回血投票] 找不到 l4d2_health_return_value");
		return Plugin_Handled;
	}

	if (args < 1)
	{
		ReplyToCommand(client, "[回血投票] 用法: sm_healset <数值>   当前 = %d", GetTargetValue());
		return Plugin_Handled;
	}

	char sArg[16];
	GetCmdArg(1, sArg, sizeof(sArg));

	if (!IsNumericString(sArg))
	{
		ReplyToCommand(client, "[回血投票] 数值必须是非负整数");
		return Plugin_Handled;
	}

	int iValue = StringToInt(sArg);
	int iOld = GetTargetValue();
	g_cValueCvar.SetInt(iValue);
	g_iLastVote = GetTime();

	CPrintToChatAll("{olive}[回血投票]{default} 管理员把击杀特感回复血量设为 {green}%d{default}（原 %d）", iValue, iOld);
	LogMessage("[HealVote] 管理员设定: %d -> %d", iOld, iValue);
	return Plugin_Handled;
}
