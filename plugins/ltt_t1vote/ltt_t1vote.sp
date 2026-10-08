/**
 * ltt_t1vote —— 全图 T2→T1 武器替换（含三方图）+ 原生投票开关
 *
 * ============================ 一、这个插件做什么 ============================
 * 把地图里"刷出来的 T2/T3 枪"换成 T1 枪，做法是【替换实际武器实体】：
 *
 *   weapon_rifle（导演按 weapon_rifle_spawn 造出来的那把枪）
 *        ↓ 删掉，原地造一把 weapon_smg
 *   weapon_smg（玩家捡到的就是 T1）
 *
 * ==================== 二、为什么替换"枪"而不是"刷枪点" ====================
 * 有条更直接的路：把 `weapon_rifle_spawn` 这类刷枪点实体换掉。**故意不走这条路**，
 * 理由都是实测出来的（2026-09-29 从云服 sm_dump_datamaps 拿到的 CWeaponSpawn 字段表）：
 *
 *   1. 刷枪点身上的 `count`（数据表字段 m_itemCount，键名就是 count）决定"这一处刷几把"。
 *      它跟 origin/angles 一样是**地图摆的**。删了重建就必须自己把这堆字段原样搬过去，
 *      搬漏一个（count 变 1）就是"4 把步枪的位置只出 1 把"——这是**改地图内容**级别的错，
 *      而且只有玩到那张图、数枪的时候才会发现。
 *   2. 刷枪点还被地图作者挂着输出/发光/材质等一堆东西，删除重建等于把这些关系切断。
 *   3. 换成实际武器实体之后，count 是**引擎自己数好的**：刷枪点刷 4 把 T2，我们就换 4 把 T1，
 *      数量天然正确，`weapon_spawn`（用 weapon_selection 的通用刷枪点）与三方图 vscript
 *      用 SpawnEntityFromTable 造的枪**同样会被 OnEntityCreated 抓到**——比只改刷枪点覆盖面更大。
 *
 * ==================== 三、只换"躺在地上"的枪（关键安全阀） ====================
 * 判定条件：`m_hOwnerEntity <= 0` **且** `m_iState == 0`（0 = WEAPON_NOT_CARRIED，即在地上）。
 *   · 玩家手里/身上正拿着的枪 m_iState 是 1/2 → **一律不碰**，绝不会把枪从人手里换掉；
 *   · 引擎"发给玩家的初始装备"（GivePlayerItem 先造实体再装备）也在这条保护里：
 *     所以转换**延后 0.15 秒**做，等装备动作落定，免得删掉一个引擎正要塞给人的实体；
 *   · 地图开局就在地上的枪（m_iState=0）→ 换；
 *   · 玩家丢下的 T2（丢下后 m_iState 又变 0）→ 也换，符合"全图不许有 T2"。
 *
 * ==================== 四、映射表（默认 = RF 那套 10 条） ====================
 * 内置（键=实际武器类名，值=要换成哪把枪：
 *   普通步枪→SMG    沙漠/AK→消音 SMG   SG552→MP5
 *   连喷→单喷       SPAS→铬管单喷      猎枪→SMG
 *   军狙→铬管单喷   scout/awp→MP5
 * 改动方式（都不用改代码）：
 *   ltt_t1_pairs "weapon_rifle>weapon_smg_spawn,..."   ← 整表覆盖
 *   ltt_t1_extra "weapon_rifle_m60>weapon_smg_silenced_spawn,weapon_grenade_launcher>weapon_shotgun_chrome_spawn"
 *                                                      ← 在内置表上追加（服主另一份客户端脚本多出来的 T3 两条）
 * 值写不写 `_spawn` 都行，键写 `weapon_rifle_spawn` 也行（会自动剥后缀）。
 *
 * ==================== 五、投票 ====================
 * 任何人打 `!t1`（或 `sm_t1vote`）→ 切一次当前状态（开↔关），走的是本服已经在用的
 * `l4d2_nativevote`（F1 同意 / F2 反对、通过率 60%、15 秒），与 `!vt`、刷特菜单同一套底座。
 *   · 投票人只算 team 2/3 的真人 —— 旁观者收下面板但引擎不给投票键，会把**引擎全局投票锁**挂死
 *     （2026-09-23 已因这个重启过一次，见 ltt_si_menu.sp 的注释）；
 *   · 一次投票可能收到两次 VoteAction_End，用 g_iPendTarget 做"已处理"守卫，绝不 SetPass 之后再 SetFail；
 *   · 不通过也必须 SetFail，否则面板卡住 + 投票锁死。
 * 结果写进 cvar `ltt_t1_mode`，**跨换图保留**（投票开关的意义就在这里），服务器重启后回到 cfg 值。
 *
 * ==================== 六、命令 ====================
 *   !t1 / sm_t1vote            任何人：发起投票切换（原生投票不可用时直接生效，并说明原因）
 *   !t1s / sm_t1status         任何人：看当前状态与本图已换数量
 *   sm_t1set <0|1|2>           管理员：直接设置，不走投票（0=关 1=全图 2=只第一张图）
 *
 * ==================== 七、cfg 与"投票别被 cfg 冲掉" ====================
 * **故意不用 AutoExecConfig**：SM 的自动 cfg 每次换图都会重放一遍，
 * 里面若有 `ltt_t1_mode 0`，玩家投票开出来的状态会在下一张图被 cfg 静默改回去。
 * 所以这里只留 cvar 默认值（`ltt_t1_mode` 默认 0 = 投票说了算）。
 * 想开服就默认开：把 `ltt_t1_mode 1` 写进 **server.cfg**（只开服执行一次），
 * 不要写进任何"每图执行"的 cfg。
 *
 * ==================== 八、已知边界（先说清，免得当成 bug） ====================
 *   1. 玩家**手里正拿着**的 T2 不换（安全阀，见下）；他手里那把要么是上一张图带过来的，
 *      要么是本图开图时就装备好的。
 *   2. 本插件加载**之前**就已经躺在地上的枪，靠开图后 2 秒的全场扫描补换；若插件是
 *      "地图跑了一半才动态加载"的，那 2 秒扫描只在本图剩余时间里跑一次，可能漏掉个别。
 *   3. 关掉（模式 0）**不还原**已经被换掉的枪：换的时候原枪已经删了，信息不在。
 *      下一张图恢复正常武器。
 *   4. 与 Stripper 规则**不要同时上**：两套都改同一批实体，会互相打架/重复换。
 *      本插件已经把"含三方图"这条覆盖到了，Stripper 那份不必再启用。
 *
 * ==================== 九、怎么验证（都是可自查的硬证据） ====================
 *   · `ltt_t1_debug 1` → 每次替换写一行 `[T1Vote] 替换 weapon_rifle → weapon_smg（位置 …）`
 *   · 换图后日志里必有一行 `[T1Vote] 本图 开启 | 模式=1 … 本图已换=N`
 *   · 场上数枪：站到刷枪点看掉的是不是 T1；`!t1s` 看累计数
 *   · 反向验证（证明安全阀有效）：投票开启后自己手里那把 T2 **不会**被换掉
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <l4d2_nativevote>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0.2"

#define TEAM_SURVIVOR_L4D 2
#define TEAM_INFECTED_L4D 3

#define CONVERT_DELAY 0.15      // 等"装备动作"落定再判定（见头注释第三节）
#define MAP_CHECK_DELAY 2.0     // 开图后全场补扫 + 任务信息就绪判定

enum
{
	MAX_PAIRS    = 32,
	PAIR_LEN     = 128,
	MAX_SCAN_ENT = 256
}

ConVar g_cMode;
ConVar g_cPairs;
ConVar g_cExtra;
ConVar g_cGuardFinale;
ConVar g_cVote;
ConVar g_cRatio;
ConVar g_cVoteTime;
ConVar g_cMinVoters;
ConVar g_cAnnounce;
ConVar g_cDebug;

StringMap g_hMap;               // 实际武器类名（weapon_rifle …） -> 目标刷枪点类名（weapon_smg_spawn）

bool g_bHasNative;              // l4d2_nativevote 是否可用
bool g_bHasL4D;                 // left4dhooks 是否可用
bool g_bVoteActive;             // 本插件自己发起的投票是否在进行
bool g_bMapReady;               // 任务信息（第一张图/终局图）是否已可判定
int  g_iPendTarget = -1;        // 本次投票要设成的模式；-1 = 没有进行中的投票
int  g_iConverted;              // 本图已替换数量
int  g_iMapScanned;             // 本图补扫时判定过的数量

public Plugin myinfo =
{
	name = "ltt_t1vote",
	author = "ltt",
	description = "全图 T2→T1 武器替换（含三方图），原生投票开关",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_cMode = CreateConVar("ltt_t1_mode", "0",
		"T2→T1 替换：0=关 1=全图开启 2=只战役第一张图。投票改的就是它，改完立刻生效（跨换图保留）",
		FCVAR_NOTIFY, true, 0.0, true, 2.0);
	g_cPairs = CreateConVar("ltt_t1_pairs", "",
		"整表覆盖内置映射。格式 weapon_rifle>weapon_smg_spawn,weapon_rifle_ak47>weapon_smg_silenced_spawn（留空=用内置 RF 那 10 条）",
		FCVAR_NOTIFY);
	g_cExtra = CreateConVar("ltt_t1_extra", "",
		"在内置表上追加映射，格式同上。例：weapon_rifle_m60>weapon_smg_silenced_spawn,weapon_grenade_launcher>weapon_shotgun_chrome_spawn",
		FCVAR_NOTIFY);
	g_cGuardFinale = CreateConVar("ltt_t1_guard_finale", "0",
		"1=终局图不替换（照抄 RF 客户端脚本那道保险：有 trigger_finale 就不换）",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cVote = CreateConVar("ltt_t1_vote", "1",
		"1=!t1 走原生投票（F1/F2）；0=发起人一说就直接生效",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cRatio = CreateConVar("ltt_t1_ratio", "60",
		"投票通过率（%），基准=在场生还者+特感人数，不投票视为反对",
		FCVAR_NOTIFY, true, 1.0, true, 100.0);
	g_cVoteTime = CreateConVar("ltt_t1_votetime", "15",
		"投票时长（秒）", FCVAR_NOTIFY, true, 5.0, true, 60.0);
	g_cMinVoters = CreateConVar("ltt_t1_minvoters", "1",
		"在场投票人少于此数就直接生效（不弹面板）", FCVAR_NOTIFY, true, 1.0, true, 10.0);
	g_cAnnounce = CreateConVar("ltt_t1_announce", "1",
		"1=换图时播报本图 T1 替换是否生效", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cDebug = CreateConVar("ltt_t1_debug", "0",
		"1=每次替换都写一行日志（排查用）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cMode.AddChangeHook(OnModeChanged);
	g_cPairs.AddChangeHook(OnTableChanged);
	g_cExtra.AddChangeHook(OnTableChanged);

	g_bHasNative = (GetFeatureStatus(FeatureType_Native, "L4D2NativeVote_IsAllowNewVote") == FeatureStatus_Available);
	g_bHasL4D    = (GetFeatureStatus(FeatureType_Native, "L4D_IsFirstMapInScenario") == FeatureStatus_Available);

	BuildTable();

	RegConsoleCmd("sm_t1", Cmd_Vote, "投票开关 T2→T1（全图 T2 武器换成 T1）");
	RegConsoleCmd("sm_t1vote", Cmd_Vote, "同上");
	RegConsoleCmd("sm_t1s", Cmd_Status, "查看 T2→T1 当前状态");
	RegConsoleCmd("sm_t1status", Cmd_Status, "同上");
	RegAdminCmd("sm_t1set", Cmd_Set, ADMFLAG_GENERIC, "直接设置 T2→T1：sm_t1set <0|1|2>（0=关 1=全图 2=只第一张图）");
	RegAdminCmd("sm_t1scan", Cmd_Scan, ADMFLAG_GENERIC, "只读扫描：本图每种映射枪的刷枪点/场上实体/可换数量，明细写日志");

	// 动态加载（地图跑了一半才 load 插件）时 OnMapStart 不会再触发，
	// 用 GetGameTime() 判断"地图已经在跑"，直接补一遍就绪流程 + 全场补扫。
	if (GetGameTime() > 5.0)
	{
		g_bMapReady = true;
		CreateTimer(0.5, Timer_MapCheck, _, TIMER_FLAG_NO_MAPCHANGE);
		LogMessage("[T1Vote] 检测到地图已在运行（已 %.0f 秒）→ 按动态加载处理，稍后补扫全场", GetGameTime());
	}

	LogMessage("[T1Vote] v%s 就绪 | 原生投票=%d left4dhooks=%d 映射=%d 条 当前模式=%d",
		PLUGIN_VERSION, g_bHasNative ? 1 : 0, g_bHasL4D ? 1 : 0, g_hMap.Size, g_cMode.IntValue);
}

// ==================================================================== 映射表

void BuildTable()
{
	if (g_hMap == null)
		g_hMap = new StringMap();
	else
		g_hMap.Clear();

	char pairs[1024];
	g_cPairs.GetString(pairs, sizeof(pairs));
	TrimString(pairs);

	if (pairs[0] != '\0')
	{
		LoadPairs(pairs);
	}
	else
	{
		// 内置 = RF「T1 only on first map」那份表（10 条）
		g_hMap.SetString("weapon_rifle",           "weapon_smg_spawn");
		g_hMap.SetString("weapon_rifle_desert",    "weapon_smg_silenced_spawn");
		g_hMap.SetString("weapon_rifle_ak47",      "weapon_smg_silenced_spawn");
		g_hMap.SetString("weapon_rifle_sg552",     "weapon_smg_mp5_spawn");
		g_hMap.SetString("weapon_autoshotgun",     "weapon_pumpshotgun_spawn");
		g_hMap.SetString("weapon_shotgun_spas",    "weapon_shotgun_chrome_spawn");
		g_hMap.SetString("weapon_hunting_rifle",   "weapon_smg_spawn");
		g_hMap.SetString("weapon_sniper_military", "weapon_shotgun_chrome_spawn");
		g_hMap.SetString("weapon_sniper_scout",    "weapon_smg_mp5_spawn");
		g_hMap.SetString("weapon_sniper_awp",      "weapon_smg_mp5_spawn");
	}

	char extra[1024];
	g_cExtra.GetString(extra, sizeof(extra));
	TrimString(extra);
	if (extra[0] != '\0')
		LoadPairs(extra);
}

void LoadPairs(const char[] src)
{
	char buf[1024];
	strcopy(buf, sizeof(buf), src);

	char parts[MAX_PAIRS][PAIR_LEN];
	int n = ExplodeString(buf, ",", parts, MAX_PAIRS, PAIR_LEN);

	for (int i = 0; i < n; i++)
	{
		TrimString(parts[i]);
		if (parts[i][0] == '\0')
			continue;

		char kv[2][64];
		if (ExplodeString(parts[i], ">", kv, 2, 64) != 2)
		{
			LogError("[T1Vote] 映射条目格式不对（要 key>value）：%s", parts[i]);
			continue;
		}

		TrimString(kv[0]);
		TrimString(kv[1]);
		if (kv[0][0] == '\0' || kv[1][0] == '\0')
		{
			LogError("[T1Vote] 映射条目缺 key 或 value：%s", parts[i]);
			continue;
		}

		char key[64];
		strcopy(key, sizeof(key), kv[0]);
		StripSpawn(key);            // 键允许照地图写 weapon_rifle_spawn
		g_hMap.SetString(key, kv[1]);
	}
}

void StripSpawn(char[] s)
{
	int len = strlen(s);
	if (len > 6 && StrEqual(s[len - 6], "_spawn"))
		s[len - 6] = '\0';
}

// ==================================================================== 生命周期

public void OnMapStart()
{
	// 【v1.0.1 · 2026-10-02 源码审核修复】换图/换关必须清投票状态：
	// 投票进行中换图时 VoteAction_End 不会触发，g_bVoteActive 卡在 true
	// ⇒ :585 的判据永久拒绝新的 !t1（要重载插件才能恢复）。
	g_bVoteActive = false;
	g_iPendTarget = -1;
	g_bMapReady = false;
	g_iConverted = 0;
	g_iMapScanned = 0;
	CreateTimer(MAP_CHECK_DELAY, Timer_MapCheck, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
	LogMessage("[T1Vote] 本图结束：模式=%d 累计替换=%d 把", g_cMode.IntValue, g_iConverted);
	// 【v1.0.1 · 审核修复】本图结束同样清投票状态，双保险。
	g_bVoteActive = false;
	g_iPendTarget = -1;
}

public Action Timer_MapCheck(Handle timer)
{
	g_bMapReady = true;             // 到这里 left4dhooks 的任务信息才可靠（见 IsModeOn 注释）

	bool on = IsModeOn();
	if (on)
		ConvertWorld();

	if (on)
	{
		if (g_cAnnounce.BoolValue)
			PrintToChatAll("\x01[\x04T1\x01] 本图 \x04已开启\x01：地图里的 T2/T3 枪全部换成 T1（\x04!t1\x01 可投票关闭）");
	}
	else if (g_cMode.IntValue != 0 && g_cAnnounce.BoolValue)
	{
		PrintToChatAll("\x01[\x04T1\x01] 模式=%d，但本图不适用（%s），本图维持原版武器",
			g_cMode.IntValue, (g_cMode.IntValue == 2) ? "只第一张图" : "终局保护");
	}

	LogMessage("[T1Vote] 本图 %s | 模式=%d 第一张图=%d 终局图=%d 补扫判定=%d 本图已换=%d",
		on ? "开启" : "未开启", g_cMode.IntValue,
		IsFirstMap() ? 1 : 0, IsFinalMap() ? 1 : 0, g_iMapScanned, g_iConverted);
	return Plugin_Stop;
}

// ==================================================================== 替换

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity <= MaxClients || entity <= 0)     // 玩家实体（含刷特假人）不碰
		return;
	if (g_hMap == null || !IsModeOn())
		return;

	char target[64];
	if (!g_hMap.GetString(classname, target, sizeof(target)))
		return;                                   // 只认表里的键 = 实际的 T2/T3 枪

	DataPack dp = new DataPack();
	dp.WriteCell(entity);
	dp.WriteString(target);
	// 【v1.0.2 · 2026-10-02 源码审核修复】必须带 TIMER_DATA_HNDL_CLOSE：
	// 旧代码把 DataPack 交给 CreateTimer 后又不在 Timer_Check 里 delete（那个函数有 5 个
	// 提前 return 出口：无效实体/已换过/模式关闭/不在手上），于是【每一把被映射的 T2/T3 枪
	// 都泄漏一个 DataPack 句柄】——长期跑图必然累积。带这个标志后句柄由框架在计时器结束时关闭。
	CreateTimer(CONVERT_DELAY, Timer_Check, dp, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
}

public Action Timer_Check(Handle timer, DataPack dp)
{
	dp.Reset();
	int ent = dp.ReadCell();
	char target[64];
	dp.ReadString(target, sizeof(target));

	if (ent <= 0 || !IsValidEntity(ent))
		return Plugin_Stop;

	char cls[64];
	GetEntityClassname(ent, cls, sizeof(cls));

	char check[64];
	if (!g_hMap.GetString(cls, check, sizeof(check)))
		return Plugin_Stop;                       // 已经被换过 / 已经不是 T2 了
	if (!IsModeOn())
		return Plugin_Stop;

	if (!IsGroundWeapon(ent))
	{
		if (g_cDebug.BoolValue)
			LogMessage("[T1Vote] 跳过 #%d %s（不在手上/正在装备：owner=%d state=%d）",
				ent, cls, GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity"), ReadIntProp(ent, "m_iState"));
		return Plugin_Stop;
	}

	DoConvert(ent, target);
	return Plugin_Stop;
}

/** 只换"躺在地上"的枪：没主人 且 m_iState==0(WEAPON_NOT_CARRIED) */
bool IsGroundWeapon(int ent)
{
	if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") > 0)
		return false;
	if (HasEntProp(ent, Prop_Data, "m_iState") && GetEntProp(ent, Prop_Data, "m_iState") != 0)
		return false;
	if (HasEntProp(ent, Prop_Send, "m_iState") && GetEntProp(ent, Prop_Send, "m_iState") != 0)
		return false;
	return true;
}

void DoConvert(int old, const char[] spawnClass)
{
	char newCls[64];
	strcopy(newCls, sizeof(newCls), spawnClass);
	StripSpawn(newCls);                            // weapon_smg_spawn -> weapon_smg

	char oldCls[64];
	GetEntityClassname(old, oldCls, sizeof(oldCls));

	float pos[3], ang[3];
	GetEntPropVector(old, Prop_Send, "m_vecOrigin", pos);
	GetEntPropVector(old, Prop_Send, "m_angRotation", ang);

	int clip  = ReadIntProp(old, "m_iClip1");
	int extra = ReadIntProp(old, "m_iExtraPrimaryAmmo");

	int ent = CreateEntityByName(newCls);
	if (ent == -1)
	{
		LogError("[T1Vote] CreateEntityByName(%s) 失败，%s 未替换", newCls, oldCls);
		return;
	}

	DispatchSpawn(ent);

	// 弹药照搬：捡到的这把 T1 带多少子弹 = 原 T2 带多少（-1 = 引擎默认值，照搬也对）
	if (clip != 0)
		WriteIntProp(ent, "m_iClip1", clip);
	if (extra != 0)
		WriteIntProp(ent, "m_iExtraPrimaryAmmo", extra);

	TeleportEntity(ent, pos, ang, NULL_VECTOR);
	RemoveEntity(old);

	g_iConverted++;

	if (g_cDebug.BoolValue)
		LogMessage("[T1Vote] 替换 %s → %s（位置 %.0f,%.0f,%.0f）", oldCls, newCls, pos[0], pos[1], pos[2]);
}

/** 全场补扫：开图 2 秒后 / 投票开启的瞬间，把"已经躺在地上"的 T2 全换掉 */
void ConvertWorld()
{
	if (g_hMap == null)
		return;

	StringMapSnapshot snap = g_hMap.Snapshot();
	char key[64], val[64];
	int list[MAX_SCAN_ENT];

	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		if (!g_hMap.GetString(key, val, sizeof(val)))
			continue;

		int n = 0;
		int ent = -1;
		while (n < MAX_SCAN_ENT && (ent = FindEntityByClassname(ent, key)) != -1)
			list[n++] = ent;

		for (int j = 0; j < n; j++)
		{
			int e = list[j];
			if (!IsValidEntity(e))
				continue;
			g_iMapScanned++;
			if (!IsGroundWeapon(e))
				continue;
			DoConvert(e, val);
		}
	}

	delete snap;
}

// ==================================================================== 模式判定

bool IsModeOn()
{
	if (g_cMode == null)
		return false;

	int m = g_cMode.IntValue;
	if (m <= 0)
		return false;

	// 开图瞬间 left4dhooks 的"第一张图/终局图"可能还没就绪。宁可先不换，
	// 因为开图 2 秒后的全场补扫会把这段时间出现在地上的枪全捞回来；
	// 反过来若这里抢跑判错，就会出现"第一张图限定"在非第一张图上生效、或终局保护失效。
	if ((m == 2 || g_cGuardFinale.BoolValue) && !g_bMapReady)
		return false;

	if (g_cGuardFinale.BoolValue && IsFinalMap())
		return false;
	if (m == 2 && !IsFirstMap())
		return false;

	return true;
}

bool IsFirstMap()
{
	if (g_bHasL4D)
		return L4D_IsFirstMapInScenario();

	// 没装 left4dhooks 时的兜底：地图名带 m1（c1m1_hotel / l4d_…）。不完美，只作降级。
	char map[64];
	GetCurrentMap(map, sizeof(map));
	return (StrContains(map, "m1", false) != -1);
}

bool IsFinalMap()
{
	if (g_bHasL4D)
		return L4D_IsMissionFinalMap();
	return false;
}

void ModeName(int m, char[] buf, int maxlen)
{
	switch (m)
	{
		case 1:
		{
			strcopy(buf, maxlen, "全图开启");
			return;
		}
		case 2:
		{
			strcopy(buf, maxlen, "只第一张图");
			return;
		}
	}
	strcopy(buf, maxlen, "关闭");
}

// ==================================================================== cvar 变化

public void OnModeChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (StrEqual(oldValue, newValue))
		return;

	int m = StringToInt(newValue);
	if (m != 0 && g_bMapReady)
		ConvertWorld();                            // 立刻生效：场上已有的 T2 当场换掉

	char mn[16];
	ModeName(m, mn, sizeof(mn));

	if (g_cAnnounce.BoolValue)
		PrintToChatAll("\x01[\x04T1\x01] T2→T1 已\x04%s\x01（%s）", (m != 0) ? "开启" : "关闭", mn);

	LogMessage("[T1Vote] 模式变化 %s → %s（%s）本图累计替换=%d 把",
		oldValue, newValue, mn, g_iConverted);
}

public void OnTableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	BuildTable();
	LogMessage("[T1Vote] 映射表已重载：%d 条", g_hMap.Size);
}

// ==================================================================== 投票

public Action Cmd_Vote(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Handled;

	int target = (g_cMode.IntValue != 0) ? 0 : 1;

	// 投票人只算 team 2/3 的真人。旁观者会挂住引擎投票锁（2026-09-23 事故根因）。
	int voters[MAXPLAYERS + 1];
	int n = 0;
	int nSpec = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		int team = GetClientTeam(i);
		if (team == TEAM_SURVIVOR_L4D || team == TEAM_INFECTED_L4D)
			voters[n++] = i;
		else
			nSpec++;
	}

	bool byIsVoter = false;
	for (int i = 0; i < n; i++)
	{
		if (voters[i] == client)
		{
			byIsVoter = true;
			break;
		}
	}

	// 不需要投票的情形：关掉了 / 原生不可用 / 投票人太少 / 发起人自己没投票权
	if (!g_cVote.BoolValue || !g_bHasNative || n < g_cMinVoters.IntValue || !byIsVoter)
	{
		SayAll("\x01[\x04T1\x01] 直接生效（没走投票）：T2→T1 %s", (target != 0) ? "开启" : "关闭");
		SetConVarInt(g_cMode, target);
		LogMessage("[T1Vote] 直接生效：目标模式=%d 走投票=%d 原生=%d 投票人=%d 旁观=%d 发起人有投票权=%d 门槛=%d",
			target, g_cVote.IntValue, g_bHasNative ? 1 : 0, n, nSpec, byIsVoter ? 1 : 0, g_cMinVoters.IntValue);
		return Plugin_Handled;
	}

	if (g_bVoteActive || !L4D2NativeVote_IsAllowNewVote())
	{
		Say(client, "\x01[\x04T1\x01] 当前已有别的投票在进行，等它结束再试");
		LogMessage("[T1Vote] 投票被拒：本地进行中=%d IsAllowNewVote=%d",
			g_bVoteActive ? 1 : 0, L4D2NativeVote_IsAllowNewVote() ? 1 : 0);
		return Plugin_Handled;
	}

	g_iPendTarget = target;

	L4D2NativeVote vote = L4D2NativeVote(Handler_Vote);
	vote.Initiator = client;
	vote.SetDisplayText("%s T2→T1（全图 T2 武器换成 T1）?",
		(target != 0) ? "开启" : "关闭");

	int duration = g_cVoteTime.IntValue;
	if (!vote.DisplayVote(voters, n, duration))
	{
		g_iPendTarget = -1;
		Say(client, "\x01[\x04T1\x01] 投票发起失败，请稍后再试");
		LogMessage("[T1Vote] DisplayVote 返回 false（在场真人=%d 时长=%d）", n, duration);
		return Plugin_Handled;
	}

	g_bVoteActive = true;

	char who[MAX_NAME_LENGTH];
	GetClientName(client, who, sizeof(who));
	SayAll("\x01[\x04T1\x01] \x04%s\x01 发起投票：T2→T1 %s —— %d 秒内 \x04F1 同意\x01 / \x04F2 反对\x01",
		who, (target != 0) ? "开启" : "关闭", duration);
	LogMessage("[T1Vote] 已发起投票：%s 目标模式=%d（投票人 %d 人，旁观 %d 人不计）", who, target, n, nSpec);
	return Plugin_Handled;
}

public void Handler_Vote(L4D2NativeVote vote, VoteAction action, int param1, int param2)
{
	if (action == VoteAction_Start)
	{
		int need = VoteNeed(vote.PlayerCount, vote.YesCount, vote.NoCount);
		SayAll("\x01[\x04T1\x01] 通过条件：在场 \x04%d\x01 人中需 \x04%d\x01 票同意（不投票视为反对）",
			vote.PlayerCount, need);
		return;
	}

	if (action != VoteAction_End)
		return;

	// 【关键守卫】同一次投票可能收到两次 VoteAction_End（ltt_si_menu 2026-09-24 实测）。
	// g_iPendTarget 在第一次处理时被清成 -1，正好当"本次已处理"的标记。
	// 绝不能在 SetPass 之后再发一次 SetFail：那会让引擎投票状态自相矛盾
	// → 面板卡住 + 全服投票锁死（2026-09-23 已经因此重启过一次）。
	if (g_iPendTarget < 0)
	{
		LogMessage("[T1Vote] 收到重复的 VoteAction_End（本次已处理过），已忽略");
		return;
	}

	int need = VoteNeed(vote.PlayerCount, vote.YesCount, vote.NoCount);
	int target = g_iPendTarget;

	g_bVoteActive = false;
	g_iPendTarget = -1;

	if (vote.YesCount >= need && vote.YesCount > vote.NoCount)
	{
		vote.SetPass("T2→T1 %s 通过", (target != 0) ? "开启" : "关闭");
		SayAll("\x01[\x04T1\x01] \x04通过！\x01T2→T1 %s（同意 %d / 反对 %d，需 %d）",
			(target != 0) ? "开启" : "关闭", vote.YesCount, vote.NoCount, need);
		LogMessage("[T1Vote] 投票通过: 目标模式=%d (同意%d 反对%d 需%d)", target, vote.YesCount, vote.NoCount, need);
		SetConVarInt(g_cMode, target);
	}
	else
	{
		// 不通过也必须 SetFail，否则面板卡住 + 投票锁死
		vote.SetFail();
		SayAll("\x01[\x04T1\x01] \x02未通过\x01，维持原设置（同意 %d / 反对 %d，需 %d）",
			vote.YesCount, vote.NoCount, need);
		LogMessage("[T1Vote] 投票未通过: 目标模式=%d (同意%d 反对%d 需%d)", target, vote.YesCount, vote.NoCount, need);
	}
}

/** 通过所需同意票：基准 = 在场投票人数（不投票视为反对） */
int VoteNeed(int players, int yes, int no)
{
	int base = players;
	if (base < 1)
		base = yes + no;
	if (base < 1)
		base = 1;

	int need = RoundToCeil(float(base) * g_cRatio.FloatValue / 100.0);
	if (need < 1)
		need = 1;
	if (need > base)
		need = base;
	return need;
}

// ==================================================================== 命令

public Action Cmd_Status(int client, int args)
{
	char maps[256];
	StringMapSnapshot snap = g_hMap.Snapshot();
	char key[64], val[64];
	maps[0] = '\0';
	for (int i = 0; i < snap.Length && strlen(maps) < 180; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		if (!g_hMap.GetString(key, val, sizeof(val)))
			continue;
		char one[96];
		Format(one, sizeof(one), "%s%s", (maps[0] == '\0') ? "" : ",", key);
		StrCat(maps, sizeof(maps), one);
	}
	delete snap;

	char mn[16];
	ModeName(g_cMode.IntValue, mn, sizeof(mn));

	Say(client, "\x01[\x04T1\x01] 模式=\x04%s\x01(%d) 本图已换 \x04%d\x01 把 ｜ 映射 %d 条 ｜ 原生投票 %s ｜ 参与映射的枪：%s",
		mn, g_cMode.IntValue, g_iConverted, g_hMap.Size,
		g_bHasNative ? "可用" : "不可用", maps);
	Say(client, "\x01[\x04T1\x01] \x04!t1\x01 投票开关 ｜ 管理员 \x04sm_t1set <0|1|2>\x01 直接设置");
	return Plugin_Handled;
}

public Action Cmd_Set(int client, int args)
{
	if (args < 1)
	{
		Say(client, "\x01[\x04T1\x01] 用法：sm_t1set <0|1|2>（0=关 1=全图开启 2=只第一张图）当前=%d",
			g_cMode.IntValue);
		return Plugin_Handled;
	}

	char arg[8];
	GetCmdArg(1, arg, sizeof(arg));
	int m = StringToInt(arg);
	if (m < 0 || m > 2)
	{
		Say(client, "\x01[\x04T1\x01] 只接受 0/1/2");
		return Plugin_Handled;
	}

	char who[MAX_NAME_LENGTH];
	if (client > 0 && IsClientInGame(client))
		GetClientName(client, who, sizeof(who));
	else
		strcopy(who, sizeof(who), "控制台");

	char mn[16];
	ModeName(m, mn, sizeof(mn));

	SayAll("\x01[\x04T1\x01] 管理员 \x04%s\x01 直接设置：T2→T1 %s", who, mn);
	LogMessage("[T1Vote] 管理员设置：%s → 模式=%d", who, m);
	SetConVarInt(g_cMode, m);
	return Plugin_Handled;
}

/** 只读扫描：本图每种映射枪各有多少"刷枪点 / 场上实体 / 可换"。不改任何东西，纯取证。 */
public Action Cmd_Scan(int client, int args)
{
	if (g_hMap == null)
		return Plugin_Handled;

	StringMapSnapshot snap = g_hMap.Snapshot();
	char key[64], val[64], spawnCls[96];
	int lines = 0;

	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		if (!g_hMap.GetString(key, val, sizeof(val)))
			continue;

		int nWeap  = CountClass(key);
		Format(spawnCls, sizeof(spawnCls), "%s_spawn", key);
		int nSpawn = CountClass(spawnCls);
		int nSwap  = CountGround(key);

		if (nSpawn + nWeap == 0)
			continue;

		LogMessage("[T1Vote] 扫描 %s：刷枪点 %d 个 ｜ 场上这把枪 %d 把（躺在地上可换 %d 把）→ 目标 %s",
			key, nSpawn, nWeap, nSwap, val);
		lines++;
	}

	delete snap;

	Say(client, "\x01[\x04T1\x01] 扫描完成：有命中 %d 类，明细已写日志（模式=%d 本图已换=%d 把）",
		lines, g_cMode.IntValue, g_iConverted);
	return Plugin_Handled;
}

int CountClass(const char[] cls)
{
	int n = 0;
	int e = -1;
	while ((e = FindEntityByClassname(e, cls)) != -1)
		n++;
	return n;
}

int CountGround(const char[] cls)
{
	int n = 0;
	int e = -1;
	while ((e = FindEntityByClassname(e, cls)) != -1)
	{
		if (IsGroundWeapon(e))
			n++;
	}
	return n;
}

// ==================================================================== 小工具

int ReadIntProp(int ent, const char[] prop)
{
	if (HasEntProp(ent, Prop_Send, prop))
		return GetEntProp(ent, Prop_Send, prop);
	if (HasEntProp(ent, Prop_Data, prop))
		return GetEntProp(ent, Prop_Data, prop);
	return 0;
}

bool WriteIntProp(int ent, const char[] prop, int val)
{
	if (HasEntProp(ent, Prop_Send, prop))
	{
		SetEntProp(ent, Prop_Send, prop, val);
		return true;
	}
	if (HasEntProp(ent, Prop_Data, prop))
	{
		SetEntProp(ent, Prop_Data, prop, val);
		return true;
	}
	return false;
}

void Say(int client, const char[] fmt, any ...)
{
	char buf[512];
	VFormat(buf, sizeof(buf), fmt, 3);

	if (client > 0 && client <= MaxClients && IsClientInGame(client))
		PrintToChat(client, "%s", buf);
	else
		PrintToServer("%s", buf);
}

void SayAll(const char[] fmt, any ...)
{
	char buf[512];
	VFormat(buf, sizeof(buf), fmt, 2);
	PrintToChatAll("%s", buf);
}
