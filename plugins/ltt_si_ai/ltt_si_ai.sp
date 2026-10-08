/**
 * ===========================================================================
 *  ltt_si_ai  v1.0.0  ——  特感主动进攻修正（纯脚本，不依赖 BinHooks）
 * ===========================================================================
 *
 *  【为什么需要这个插件】
 *      Neko 时代特感很凶，是因为 Neko 的 SetAISpawnInit() 里一直在调
 *      BinHooks 的 SetSpecialAssault(Special_Fast_Response = 1)。
 *      把 Neko 整套卸载后，再没人调这个 native，特感就退回"被动模式"——
 *      表现就是「Hunter 被人机打一枪就往后退，跑过来当活靶子」。
 *
 *  【引擎里到底是谁在管这件事】
 *      两个 CDirectorChallengeMode 的成员函数，内部各读一个导演脚本值：
 *
 *        CDirectorChallengeMode::AggresiveSpecials()
 *            -> CDirector::GetScriptValue("cm_AggressiveSpecials", 0) != 0
 *            -> 决定 BossZombiePlayerBot::ShouldAdvanceOnSurvivors()（往前进还是往后退）
 *
 *        CDirectorChallengeMode::SpecialsShouldAssault()
 *            -> CDirector::GetScriptValue("SpecialInfectedAssault", 0) > 0
 *            -> 决定 JockeyBehavior 等特感行为是否主动突击
 *
 *     网上常见的 aggresive_specials_patch 插件是把这两个函数的入口字节直接
 *       patch 成 `mov eax,1; ret`（强行 return 1）。那是内存补丁：带硬编码
 *      地址和校验字节，游戏一更新就 SetFailState，而且没法优雅关掉。
 *
 *  【本插件的做法：三条纯脚本路径，都不碰内存、不用 BinHooks】
 *      ① 建两个同名 cvar 并设为 1
 *         L4D2 的 CDirector::GetScriptValue 在导演脚本作用域里找不到键时，
 *         会回退去查同名 cvar。所以把 cvar 建出来就等于把那个脚本值定了。
 *      ② 同时在 L4D_ / L4D2_ 两个 OnGetScriptValueInt forward 里直接改返回值
 *         （脚本作用域里真有这个键时，走的是这条路）
 *      ③ 用 L4D2_GetScriptValueInt 反向回读，把"引擎实际解析到的值"打出来，
 *         这样不用靠体感就能确认到底哪条路生效了
 *
 *      作者：DeepSeek Harness
 * ===========================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "1.1.0"

/** 【v1.1.0】回读用的"独一无二的兜底值"。
 *  为什么不用 -999：本服这两个键在导演脚本作用域里【根本不存在】，
 *  于是 L4D2_GetScriptValueInt() 会把我们传进去的兜底值原样返回。
 *  以前拿 -999 当兜底值时，"读不到"和"读到 -999 这个真实值"没法区分。
 *  换成一个不可能出现的哨兵值之后：
 *    回读 = 哨兵值 → 我们的覆盖【没有】生效（走的是引擎/脚本作用域的原值）
 *    回读 = 1      → 我们的覆盖【生效了】—— 这就是"特感会不会主动上"的硬证据 */
#define SIAI_SENTINEL -7777

ConVar g_cEnable, g_cAssault, g_cDebug;

int g_iReadAggressive = SIAI_SENTINEL;
int g_iReadAssault    = SIAI_SENTINEL;
bool g_bKeysSeen;

// 【v1.1.0】分别统计两个接口被【引擎】问过多少次（自测回读不计入）。
// 用途：区分"引擎真的在问这个问题"和"只有我们自己在回读"。
int g_iHitsOld;
int g_iHitsNew;
// 【v1.1.0】自测回读期间置位，避免把自己的回读算成引擎查询
bool g_bSelfReading;

public Plugin myinfo =
{
	name        = "[LTT] SI Aggressive AI",
	author      = "DeepSeek Harness",
	description = "纯脚本实现特感主动进攻，替代 BinHooks 的 SetSpecialAssault / 内存补丁",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cEnable  = CreateConVar("ltt_si_ai_enable",  "1", "1=开启特感主动进攻修正", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cAssault = CreateConVar("ltt_si_ai_assault", "1", "1=特感主动进攻（不再挨一枪就往后退）0=还原引擎默认被动行为", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cDebug   = CreateConVar("ltt_si_ai_debug",   "1", "1=输出日志", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "ltt_si_ai");
	RegAdminCmd("sm_siai", Cmd_Status, ADMFLAG_GENERIC, "查看特感主动进攻插件状态");

	g_cEnable.AddChangeHook(OnCvarChanged);
	g_cAssault.AddChangeHook(OnCvarChanged);

	// 延后一点再建 cvar / 回读：确保导演已经初始化
	CreateTimer(1.0, Timer_Init);
}

public Action Timer_Init(Handle timer)
{
	Apply();
	return Plugin_Stop;
}

public void OnConfigsExecuted()
{
	Apply();
}

public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	Apply();
}

// ------------------------------------------------------------------ 主逻辑

void Apply()
{
	int iWant = (g_cEnable.BoolValue && g_cAssault.BoolValue) ? 1 : 0;

	SetAggroCvar("cm_AggressiveSpecials", iWant);
	SetAggroCvar("SpecialInfectedAssault", iWant);

	Verify();
}

void SetAggroCvar(const char[] name, int value)
{
	ConVar c = FindConVar(name);
	if (c == null)
	{
		// 服务器上原本没有这两个 cvar，由本插件创建
		// 【v1.1.0 更正】"GetScriptValue 找不到键就回退查同名 cvar"这条说法
		// 【没有被证实】：本服这两个 cvar 一直是 1，而引擎回读恒为兜底值，
		// 说明至少在这两个键上不存在 cvar 回退。真正生效的是 forward 里
		// 的 Plugin_Handled 覆盖（见下方说明）。这两个 cvar 保留下来只作为
		// 可读的状态标记，不再当成"生效路径"来宣传。
		c = CreateConVar(name, "1", "ltt_si_ai: 特感主动进攻（状态标记；生效路径是 OnGetScriptValueInt 覆盖）", FCVAR_NOTIFY);
		if (g_cDebug.BoolValue)
			LogMessage("[SIAI] 已创建 cvar %s（状态标记用）", name);
	}
	if (c != null)
		c.SetInt(value);
}

/** 反查引擎实际解析到的脚本值 —— 【v1.1.0 起这是硬证据，不是参考信息】。
 *
 *  原理：L4D2_GetScriptValueInt(key, fallback) 走的就是被 L4D_OnGetScriptValueInt
 *  挂钩的那个 CDirector::GetScriptValue 函数（实测：调用时 forward 确实被触发）。
 *  所以：
 *    · 回读 == 1        ⇒ 我们在 forward 里写的 retVal 被引擎采纳了
 *                        ⇒ 引擎自己去问这两个键时，拿到的也是 1
 *    · 回读 == 哨兵值   ⇒ 我们的覆盖被丢掉了（原函数照样执行并冲掉了我们的值）
 *  用哨兵值 SIAI_SENTINEL 当兜底，就是为了让这两件事无法互相冒充。 */
void Verify()
{
	ConVar cA = FindConVar("cm_AggressiveSpecials");
	ConVar cB = FindConVar("SpecialInfectedAssault");

	g_bSelfReading = true;
	g_iReadAggressive = L4D2_GetScriptValueInt("cm_AggressiveSpecials", SIAI_SENTINEL);
	g_iReadAssault    = L4D2_GetScriptValueInt("SpecialInfectedAssault", SIAI_SENTINEL);
	g_bSelfReading = false;

	if (!g_cDebug.BoolValue)
		return;

	bool bWant = (g_cEnable.BoolValue && g_cAssault.BoolValue);

	LogMessage("[SIAI] cvar 值: cm_AggressiveSpecials=%d  SpecialInfectedAssault=%d（只是同名 cvar，不代表引擎采纳）",
		cA == null ? -1 : cA.IntValue, cB == null ? -1 : cB.IntValue);
	LogMessage("[SIAI] 引擎回读: cm_AggressiveSpecials=%d  SpecialInfectedAssault=%d（哨兵 %d = 覆盖没生效）",
		g_iReadAggressive, g_iReadAssault, SIAI_SENTINEL);

	if (!bWant)
	{
		LogMessage("[SIAI] 插件处于【关闭】状态 ⇒ 故意不干预，回读应为哨兵值 %d", SIAI_SENTINEL);
		return;
	}

	if (g_iReadAggressive == 1 && g_iReadAssault == 1)
		LogMessage("[SIAI] ✓✓ 覆盖已生效：引擎解析到的两个值都是 1（特感应处于主动进攻）");
	else
		LogMessage("[SIAI] ✗ 覆盖未生效：回读不是 1。见 forward 里 Plugin_Handled 的说明；这种情况下必须换手段（如 ltt_sispawn_assault 的 nb_assault 脉冲），不能靠体感硬撑");
}

// ------------------------------------------------------------------ 脚本值覆盖（第二条路）

bool IsAggroKey(const char[] key)
{
	return StrEqual(key, "cm_AggressiveSpecials", false)
	    || StrEqual(key, "AggressiveSpecials", false)
	    || StrEqual(key, "SpecialInfectedAssault", false);
}

public Action L4D_OnGetScriptValueInt(const char[] key, int &retVal)
{
	if (!IsAggroKey(key))
		return Plugin_Continue;

	bool bWant = (g_cEnable.BoolValue && g_cAssault.BoolValue);

	// 统计【引擎】问过多少次（自测回读不算），用来区分"引擎真的在问"和"只有我在回读"
	if (!g_bSelfReading)
	{
		g_iHitsOld++;
		if (g_iHitsOld <= 3 && g_cDebug.BoolValue)
			LogMessage("[SIAI] 引擎查询·旧接口 %s 原值=%d（第 %d 次）→ %s",
				key, retVal, g_iHitsOld, bWant ? "覆盖为 1" : "不干预（插件已关）");
	}

	if (!bWant)
		return Plugin_Continue;

	g_bKeysSeen = true;
	retVal = 1;

	// 【v1.1.0 关键修复 —— 这一行就是"特感主动攻击从来没生效"的根因】
	//
	// left4dhooks.inc 对这个 forward 的原话是：
	//     `@return Plugin_Handled to override return value, Plugin_Continue otherwise`
	// 也就是说：只有 Plugin_Handled 才会让引擎采纳 retVal。
	//
	// v1.0.1 曾经为了"返回 Handled 会挡住挂在同一个 forward 上的其它插件"而改成
	// Plugin_Changed —— 那个担心在【这两个 key】上是多余的，代价却是致命的：
	//   · 本插件只对 cm_AggressiveSpecials / SpecialInfectedAssault 这两个 key 返回
	//     Handled；cm_MaxSpecials / CommonLimit / PreferredSpecialDirection 等
	//     其它 key 一律 Continue ⇒ ltt_si_spawner 的监听完全不受影响；
	//   · 而 Plugin_Changed 的语义只是"我改了这个值、请继续往后传"，
	//     原函数照样执行、把我们写的值冲掉。
	// 指纹证据：改回 Handled 之前，引擎回读恒为 -999（=调用方传进去的兜底值，
	// 说明这两个键在导演脚本作用域里根本不存在、我们的写入被丢弃）。
	return Plugin_Handled;
}

public Action L4D2_OnGetScriptValueInt(const char[] key, int &retVal, int hScope)
{
	if (!IsAggroKey(key))
		return Plugin_Continue;

	bool bWant = (g_cEnable.BoolValue && g_cAssault.BoolValue);

	if (!g_bSelfReading)
	{
		g_iHitsNew++;
		if (g_iHitsNew <= 3 && g_cDebug.BoolValue)
			LogMessage("[SIAI] 引擎查询·新接口 %s 原值=%d scope=%d（第 %d 次）→ %s",
				key, retVal, hScope, g_iHitsNew, bWant ? "覆盖为 1" : "不干预（插件已关）");
	}

	if (!bWant)
		return Plugin_Continue;

	g_bKeysSeen = true;
	retVal = 1;
	// 同上：必须 Plugin_Handled 才是覆盖，Plugin_Changed 只是"继续传下去"
	return Plugin_Handled;
}

// ------------------------------------------------------------------ 自查

public Action Cmd_Status(int client, int args)
{
	ConVar cA = FindConVar("cm_AggressiveSpecials");
	ConVar cB = FindConVar("SpecialInfectedAssault");

	// 【v1.1.0】每次查询都重新回读一次，状态命令必须给"现在的真实答案"
	Verify();

	ReplyToCommand(client, "[SIAI] v%s 开关=%d 主动进攻=%d", PLUGIN_VERSION,
		g_cEnable.IntValue, g_cAssault.IntValue);
	ReplyToCommand(client, "[SIAI] cvar(状态标记): cm_AggressiveSpecials=%s  SpecialInfectedAssault=%s",
		cA == null ? "不存在" : (cA.IntValue ? "1" : "0"),
		cB == null ? "不存在" : (cB.IntValue ? "1" : "0"));
	ReplyToCommand(client, "[SIAI] 引擎回读: cm_AggressiveSpecials=%d  SpecialInfectedAssault=%d（1=覆盖生效；%d=覆盖没生效）",
		g_iReadAggressive, g_iReadAssault, SIAI_SENTINEL);
	ReplyToCommand(client, "[SIAI] 引擎查询次数: 旧接口=%d 新接口=%d（自测回读不计）｜forward 命中过: %s",
		g_iHitsOld, g_iHitsNew, g_bKeysSeen ? "是" : "否");
	ReplyToCommand(client, "[SIAI] 覆盖路径: OnGetScriptValueInt + Plugin_Handled（无内存补丁、不依赖 BinHooks）");

	if (!g_cEnable.BoolValue || !g_cAssault.BoolValue)
		ReplyToCommand(client, "[SIAI] ⚠ 当前是【关闭】状态 ⇒ 故意不干预，回读会是 %d", SIAI_SENTINEL);
	else if (g_iReadAggressive == 1 && g_iReadAssault == 1)
		ReplyToCommand(client, "[SIAI] ✓ 覆盖已生效，引擎解析到的两个值都是 1");
	else
		ReplyToCommand(client, "[SIAI] ✗ 覆盖未生效（回读不是 1）—— 别靠体感判断，先查这条");

	return Plugin_Handled;
}
