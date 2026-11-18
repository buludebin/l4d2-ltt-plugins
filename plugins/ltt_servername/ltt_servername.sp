#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

/**
 *  ltt_servername v1.0.0 —— 服务器名按模板动态刷新（照 NekoServerName 那套机制重写）
 *
 *  机制：
 *    模板放在 `addons/sourcemod/data/ltt_servername.txt`（KeyValues：ServerNameFormat "..."），
 *    每次刷新都重读文件 ⇒ 改完文件 + `sm_updatename` 立刻生效，不用重载插件。
 *    渲染完写回 `hostname`（内容没变就不写，避免无谓的网络同步）。
 *
 *  更新时机（照 Neko：开图 + 定时轮询 + cvar 变更 + 团灭 + 命令）：
 *    OnMapStart / OnConfigsExecuted / 每 ltt_servername_interval 秒 /
 *    ltt_sispawn_effwave|effcap|wave|cap|time|mode 变更（挂 AddChangeHook）/ mission_lost / 命令
 *
 *  占位符：
 *    {wave}      当前生效每波（含人数缩放；为 0 时回落到设定值）
 *    {setwave}   设定每波
 *    {cap}       当前生效上限（含缩放；为 0 时回落到设定值）
 *    {setcap}    设定上限
 *    {time}      刷新间隔（秒）
 *    {mode}      挡位名（原版引擎点 / 引擎+视野+分散 / 自建优先）
 *    {modenum}   挡位号（0 / 1 / 2）
 *    {mtime}     本图计时的**纯时间**（9m / 1h05m；模板里写 [{mtime}] 就渲染成 [9m]）
 *    {players}   真人玩家数        {allplayers} 在场客户端数
 *    {survivors} 生还者槽位数      {alive}      存活生还者数
 *    {flow}      队伍进度百分比    {maptime}    本图计时
 *    {map}       当前地图名        {difficulty} 难度中文
 *    {restarts}  本图团灭次数      {servernum}  端口尾号
 *    {customtext} ltt_servername_text 的内容
 *    【v1.0.12】{nearbias} 距离偏好：就近 / 均衡（读 ltt_si_spawner 的软连接 cvar）
 *    【v1.0.12】{distband} 距离档短名：贴 / 近 / 中 / 远 / 开（由 ltt_sispawn_min/max 反推）
 *
 *  命令（ADMFLAG_ROOT）：sm_updatename / sm_host / sm_showname / sm_setname <模板>
 */

#define PLUGIN_VERSION "1.0.15"

// 默认模板：几特几秒（{wave} 是生效值，4 人时就是设定值）
#define DEFAULT_FORMAT "L4D2 服务器[{wave}特{time}秒]"

#define TEAM_SURVIVOR 2

ConVar g_cEnable, g_cInterval, g_cSeconds, g_cDebug, g_cText;

Handle g_hTick;   // 【v1.0.7】驱动定时器句柄（换图必须重建，见 OnMapStart 注释）

// 刷特插件的软连接（取不到就是 null）
// 【v1.0.13】新增 Near/Min/Max：{nearbias} 与 {distband} 这两个新字段靠它们渲染，
// 也必须挂变更钩子 —— 否则服主在投票/菜单里一改距离，名字要等一个轮询周期（默认 10 秒）才更新，
// 看起来就像"投票了名字没变"。
ConVar g_cEffWave, g_cEffCap, g_cWave, g_cCap, g_cTime, g_cMode;
ConVar g_cNear, g_cMin, g_cMax;
bool   g_bHooked[10];

bool  g_bHasFlow;
int   g_iBigStamp[2];   // 【v1.0.4】GetTime 的 bigStamp 出参（诊断用）
int   g_iMapStart;
int   g_iNextUpdate;    // 【v1.0.8】下次刷新时刻（墙钟秒；空服上 GetGameTime() 冻住，不能用它节拍）      // 【v1.0.1】本图开始时刻（墙钟 GetTime()，换图不会重置）
int   g_iRestarts;

public Plugin myinfo =
{
	name        = "[LTT] Server Name",
	author      = "DeepSeek Harness",
	description = "按模板动态刷新服务器名（几特几秒 / 人数 / 进度 / 计时）",
	version     = PLUGIN_VERSION,
	url         = ""
};

int g_iLttRestart = 0;   // 【LTT 补丁 2026-10-07】本图重开次数

public void OnPluginStart()
{
	g_cEnable   = CreateConVar("ltt_servername_enable",   "1",    "总开关 1=开 0=关", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cInterval = CreateConVar("ltt_servername_interval", "10.0", "每隔多少秒刷新一次（1~300）", FCVAR_NOTIFY, true, 1.0, true, 300.0);
	g_cSeconds  = CreateConVar("ltt_servername_seconds",  "0",    "1=计时带秒（[计时:3m:21s]）0=只到分", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cText     = CreateConVar("ltt_servername_text",     "",     "{customtext} 的内容", FCVAR_NONE);
	g_cDebug    = CreateConVar("ltt_servername_debug",    "0",    "1=每次刷新写一条日志", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "ltt_servername");

	RegAdminCmd("sm_updatename", Cmd_Update,  ADMFLAG_ROOT, "立刻按模板刷新服务器名");
	RegAdminCmd("sm_host",       Cmd_Update,  ADMFLAG_ROOT, "立刻按模板刷新服务器名");
	RegAdminCmd("sm_showname",   Cmd_Show,    ADMFLAG_ROOT, "显示当前模板与渲染结果");
	RegAdminCmd("sm_setname",    Cmd_SetName, ADMFLAG_ROOT, "sm_setname <模板>：写入模板并立刻生效");

	HookEvent("mission_lost", Event_MissionLost, EventHookMode_PostNoCopy);

	// 老版 left4dhooks 可能缺 flow 原生（缺了 {flow} 就恒为 0%）
	g_bHasFlow = (GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetMapMaxFlowDistance") == FeatureStatus_Available)
		&& (GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetFlowDistance") == FeatureStatus_Available)
		&& (GetFeatureStatus(FeatureType_Native, "L4D_HasAnySurvivorLeftSafeArea") == FeatureStatus_Available);

	EnsureDataFile();
	SeedMapStart();   // 【v1.0.3】中途加载也能接上本图计时
	BindCvars();

	CreateTimer(30.0, Timer_Bind, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);   // 30 秒重绑一次软连接
	// 【v1.0.7】驱动定时器改到 OnMapStart 建（换图会回收句柄，只在这里建才会静默停摆）

	LogMessage("[ServerName] v%s 就绪（模板文件 data/ltt_servername.txt，flow 原生=%s）",
		PLUGIN_VERSION, g_bHasFlow ? "有" : "无");
}

/** 【v1.0.3】推算本图开始时刻。
 *  优先用 GetGameTime()（换图会重置，正常情况下就是"本图已运行秒数"）反推；
 *  它明显不合理（0 或超过一天）时才退回"从现在算" —— 这样插件中途加载/重载也能接上真实计时。 */
void SeedMapStart()
{
	// 【v1.0.5】先试"从 data 文件续上"：地图没变且不超过 6 小时 ⇒ 用记下的起点
	// （插件重载/中途加载时，这是唯一能拿回真实本图时间的办法 ——
	//   空服挂机时引擎时钟冻住，GetGameTime()/tick 都不动）
	int  savedAt = 0, savedEng = 0, savedBeat = 0;
	char savedMap[64];
	if (ReadMapStamp(savedMap, sizeof(savedMap), savedAt, savedEng, savedBeat))
	{
		char cur[64];
		GetCurrentMap(cur, sizeof(cur));
		if (StrEqual(cur, savedMap, false) && savedAt > 0 && (GetTime() - savedAt) < 21600
			&& (GetTime() - savedAt) >= 0)
		{
			g_iMapStart = savedAt;
			return;
		}
	}

	// 兜底：引擎时钟若在走就用它反推，否则从现在算
	int game = RoundToNearest(GetGameTime());
	if (game > 5 && game < 86400)
		g_iMapStart = GetTime() - game;
	else
		g_iMapStart = GetTime();
}

/** 【v1.0.5】把本图开始时刻与地图名写进 data 文件（与模板同一个 KV 文件） */
void SaveMapStamp(int at)
{
	char p[PLATFORM_MAX_PATH];
	DataPath(p, sizeof(p));

	char cur[64];
	GetCurrentMap(cur, sizeof(cur));

	KeyValues kv = new KeyValues("ltt_servername");
	kv.ImportFromFile(p);

	char fmt[512];
	kv.GetString("ServerNameFormat", fmt, sizeof(fmt));
	if (fmt[0] == '\0')
		strcopy(fmt, sizeof(fmt), DEFAULT_FORMAT);

	kv.SetString("ServerNameFormat", fmt);   // 保留模板
	kv.SetString("LastMap", cur);
	kv.SetNum("LastMapStart", at);
	kv.SetNum("LastEngineTime", RoundToNearest(GetEngineTime()));   // 【v1.0.14 更正】这是 **srcds 进程**运行时长（证据见 OnMapStart 里的注释），v1.0.9 写的"机器开机时长"是错的
	kv.SetNum("LastHeartbeat", GetTime());                          // 【v1.0.10】心跳：区分服务器重启 vs 插件重载
	kv.ExportToFile(p);
	delete kv;
}

/** 【v1.0.5】读回上次记的地图与起点 */
bool ReadMapStamp(char[] map, int maxlen, int &at, int &eng, int &beat)
{
	char p[PLATFORM_MAX_PATH];
	DataPath(p, sizeof(p));

	at   = 0;
	eng  = 0;
	beat = 0;
	map[0] = '\0';

	KeyValues kv = new KeyValues("ltt_servername");
	if (!kv.ImportFromFile(p))
	{
		delete kv;
		return false;
	}

	kv.GetString("LastMap", map, maxlen);
	at   = kv.GetNum("LastMapStart", 0);
	eng  = kv.GetNum("LastEngineTime", 0);
	beat = kv.GetNum("LastHeartbeat", 0);   // 【v1.0.10】
	delete kv;
	return (map[0] != '\0' && at > 0);
}

/** 【v1.0.5】本图已运行秒数 = max(墙钟, 引擎本图时间)
 *  空服挂机时引擎时钟冻住（实测），靠墙钟；有人玩时引擎时钟在走，重载后也能接上。 */
int MapElapsedSecs()
{
	int wall = GetTime() - g_iMapStart;
	int game = RoundToNearest(GetGameTime());
	if (wall < 0)
		wall = 0;
	if (game < 0)
		game = 0;
	return (game > wall) ? game : wall;
}

public void OnPluginEnd()
{
	// 故意不 delete：换图时句柄可能已被引擎回收，再 delete 会抛 "Handle is invalid"
	g_hTick = null;
}

// ------------------------------------------------------------------ 数据文件

void DataPath(char[] out, int maxlen)
{
	BuildPath(Path_SM, out, maxlen, "data/ltt_servername.txt");
}

void EnsureDataFile()
{
	char p[PLATFORM_MAX_PATH];
	DataPath(p, sizeof(p));

	if (FileExists(p))
		return;

	KeyValues kv = new KeyValues("ltt_servername");
	kv.SetString("ServerNameFormat", DEFAULT_FORMAT);
	kv.ExportToFile(p);
	delete kv;

	LogMessage("[ServerName] 已生成默认模板 %s（内容：%s）", p, DEFAULT_FORMAT);
}

bool ReadFormat(char[] buf, int maxlen)
{
	char p[PLATFORM_MAX_PATH];
	DataPath(p, sizeof(p));

	buf[0] = '\0';

	KeyValues kv = new KeyValues("ltt_servername");
	if (!kv.ImportFromFile(p))
	{
		delete kv;
		LogError("[ServerName] 读不到模板文件 %s", p);
		return false;
	}

	kv.GetString("ServerNameFormat", buf, maxlen);
	delete kv;

	if (buf[0] == '\0')
	{
		LogError("[ServerName] 模板文件里没有 ServerNameFormat 键");
		return false;
	}
	return true;
}

void WriteFormat(const char[] fmt)
{
	char p[PLATFORM_MAX_PATH];
	DataPath(p, sizeof(p));

	KeyValues kv = new KeyValues("ltt_servername");
	kv.SetString("ServerNameFormat", fmt);
	kv.ExportToFile(p);
	delete kv;
}

// ------------------------------------------------------------------ 软连接

void BindCvars()
{
	if (g_cEffWave == null)
	{
		g_cEffWave = FindConVar("ltt_sispawn_effwave");
		if (g_cEffWave != null && !g_bHooked[0])
		{
			g_cEffWave.AddChangeHook(OnSpawnerCvarChanged);
			g_bHooked[0] = true;
		}
	}
	if (g_cEffCap == null)
	{
		g_cEffCap = FindConVar("ltt_sispawn_effcap");
		if (g_cEffCap != null && !g_bHooked[1])
		{
			g_cEffCap.AddChangeHook(OnSpawnerCvarChanged);
			g_bHooked[1] = true;
		}
	}
	if (g_cWave == null)
	{
		g_cWave = FindConVar("ltt_sispawn_wave");
		if (g_cWave != null && !g_bHooked[2])
		{
			g_cWave.AddChangeHook(OnSpawnerCvarChanged);
			g_bHooked[2] = true;
		}
	}
	if (g_cCap == null)
	{
		g_cCap = FindConVar("ltt_sispawn_cap");
		if (g_cCap != null && !g_bHooked[3])
		{
			g_cCap.AddChangeHook(OnSpawnerCvarChanged);
			g_bHooked[3] = true;
		}
	}
	if (g_cTime == null)
	{
		g_cTime = FindConVar("ltt_sispawn_time");
		if (g_cTime != null && !g_bHooked[4])
		{
			g_cTime.AddChangeHook(OnSpawnerCvarChanged);
			g_bHooked[4] = true;
		}
	}
	if (g_cMode == null)
	{
		g_cMode = FindConVar("ltt_sispawn_mode");
		if (g_cMode != null && !g_bHooked[5])
		{
			g_cMode.AddChangeHook(OnSpawnerCvarChanged);
			g_bHooked[5] = true;
		}
	}
	// 【v1.0.13】{nearbias} / {distband} 的数据源也要挂钩子（改动即刷新名字）
	if (g_cNear == null)
	{
		g_cNear = FindConVar("ltt_sispawn_nearbias");
		if (g_cNear != null && !g_bHooked[6])
		{
			g_cNear.AddChangeHook(OnSpawnerCvarChanged);
			g_bHooked[6] = true;
		}
	}
	if (g_cMin == null)
	{
		g_cMin = FindConVar("ltt_sispawn_min");
		if (g_cMin != null && !g_bHooked[7])
		{
			g_cMin.AddChangeHook(OnSpawnerCvarChanged);
			g_bHooked[7] = true;
		}
	}
	if (g_cMax == null)
	{
		g_cMax = FindConVar("ltt_sispawn_max");
		if (g_cMax != null && !g_bHooked[8])
		{
			g_cMax.AddChangeHook(OnSpawnerCvarChanged);
			g_bHooked[8] = true;
		}
	}
}

public void OnSpawnerCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	SetServerName();
}

// ------------------------------------------------------------------ 事件 / 定时器

public void OnMapStart()
{
	// 【v1.0.6】注意：`sm plugins reload` **也会触发 OnMapStart**（实证：重载时刻覆盖了换图时刻）。
	// 所以这里不能无脑把起点设成"现在"：同一张图若 data 文件里已有更早的起点（6 小时内），沿用它。
	char cur[64];
	GetCurrentMap(cur, sizeof(cur));
	int now = GetTime();

	int  savedAt = 0, savedEng = 0, savedBeat = 0;
	char savedMap[64];
	ReadMapStamp(savedMap, sizeof(savedMap), savedAt, savedEng, savedBeat);   // 先读出来判断*/

	// 【v1.0.14 · 判据整改】原来只用"心跳间隔 > 10 秒"区分重启/重载，实测两头都会错：
	//   ① 假阴性：`systemctl restart` 时旧实例**卸到最后才写心跳** ⇒ 间隔只有几秒，
	//      被当成"插件重载"，本图计时沿用了重启前的值（2026-10-03 11:58 实测：名字显示 43m）。
	//   ② 假阳性：换图过渡期心跳也会断 > 10 秒，于是日志写成"判定为服务器重启" ——
	//      动作（重置计时）是对的，但**日志在说假话**（那天 12:00:33 / 12:01:16 两次就是换图）。
	//
	// 现在改用【srcds 进程运行时长】做主判据，证据：
	//   · 机器 uptime = 4 天 12 小时，而重启后 data 文件里 LastEngineTime = **3 秒**
	//     ⇒ `GetEngineTime()` 是【进程/引擎】运行时长，不是机器开机时长
	//       （v1.0.9 注释里写的"机器开机时长、实测不可用"是错的，本次一并更正）。
	//   · `sm plugins reload` 不会让进程时长变小 ⇒ 插件重载永远不会被误判成重启。
	// 三种情况分开判、并且日志分别说实话。
	int now2 = GetTime();
	int engNow = RoundToNearest(GetEngineTime());          // 【v1.0.14】srcds 进程已运行秒数
	bool bFreshProcess = (engNow >= 0 && engNow < 60);     // 刚起来（重启）
	bool bGapLong      = (savedBeat > 0 && (now2 - savedBeat) > 10);
	bool bSameMap      = (savedAt > 0 && StrEqual(cur, savedMap, false)
	                      && savedAt < now && (now - savedAt) < 21600);

	if (bFreshProcess)
	{
		g_iMapStart = now;
		g_iLttRestart = 0; // 【LTT 补丁】服务器重启清零
		LogMessage("[ServerName] 判定=服务器重启（本进程已运行 %d 秒｜心跳间隔 %d 秒）⇒ 本图计时从 0 重新开始",
			engNow, (savedBeat > 0) ? (now2 - savedBeat) : -1);
	}
	else if (bSameMap && !bGapLong)
	{
		g_iMapStart = savedAt;   // 同图 + 进程没重启 + 心跳没断 ⇒ 这是插件重载，接着算
		LogMessage("[ServerName] 判定=插件重载（本进程已运行 %d 秒｜心跳间隔 %d 秒）⇒ 沿用本图起点（已运行 %d 分钟）",
			engNow, (savedBeat > 0) ? (now2 - savedBeat) : -1, (now - savedAt) / 60);
	}
	else if (bSameMap)
	{
		// 进程没重启、同一张图，但心跳断过 >10 秒：实测这是**换图/重开同图的过渡期**
		g_iMapStart = now;
		g_iLttRestart++;   // 【LTT 补丁】同图重开计数
		LogMessage("[ServerName] 判定=同图重开/过渡（本进程已运行 %d 秒｜心跳间隔 %d 秒）⇒ 本图计时从 0 重新开始",
			engNow, now2 - savedBeat);
	}
	else
	{
		g_iMapStart = now;
		g_iLttRestart = 0; // 【LTT 补丁】换图清零
		LogMessage("[ServerName] 判定=换图（本进程已运行 %d 秒｜%s → %s）⇒ 本图计时从 0 重新开始",
			engNow, savedMap, cur);
	}

	g_iRestarts   = 0;
	g_iNextUpdate = 0;
	SaveMapStamp(g_iMapStart);   // 【v1.0.5】记下"本图 + 起点"

	// 【v1.0.7】重建驱动定时器：实测换图后旧句柄会被回收（我们刷特插件源码里早记过这条），
	// 只依赖 OnPluginStart 建一次的话，换图后自动刷新就静默停了（名字会一直停在旧值）。
	// 【v1.0.8 补】旧句柄若还有效就先干掉（IsValidHandle 保护，避免 "Handle is invalid"）。
	if (g_hTick != null && IsValidHandle(g_hTick))
		KillTimer(g_hTick);
	g_hTick = CreateTimer(1.0, Timer_Tick, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnConfigsExecuted()
{
	// 【v1.0.1】插件中途加载时收不到 OnMapStart ⇒ 这里补一次起点
	// 【v1.0.3】改成"反推本图起点"，这样重载后计时不会归零
	if (g_iMapStart == 0)
		SeedMapStart();

	BindCvars();
	SetServerName();
}

public void Event_MissionLost(Event event, const char[] name, bool dontBroadcast)
{
	g_iRestarts++;
	SetServerName();
}

public Action Timer_Tick(Handle timer)
{
	if (!g_cEnable.BoolValue)
		return Plugin_Continue;

	// 【v1.0.8】节拍用墙钟：空服上 GetGameTime() 冻结（实测 1.0 不动），用它判断会导致永不刷新
	if (GetTime() < g_iNextUpdate)
		return Plugin_Continue;

	g_iNextUpdate = GetTime() + RoundToNearest(g_cInterval.FloatValue);
	SetServerName();
	return Plugin_Continue;
}

public Action Timer_Bind(Handle timer)
{
	BindCvars();
	TouchHeartbeat();   // 【v1.0.10】每 30 秒写一次心跳（服务器重启后据此判定"断过"）
	return Plugin_Continue;
}

/** 【v1.0.10】只更新心跳与地图名，不动模板 */
void TouchHeartbeat()
{
	char p[PLATFORM_MAX_PATH];
	DataPath(p, sizeof(p));

	KeyValues kv = new KeyValues("ltt_servername");
	kv.ImportFromFile(p);

	char fmt[512];
	kv.GetString("ServerNameFormat", fmt, sizeof(fmt));
	if (fmt[0] == '\0')
		strcopy(fmt, sizeof(fmt), DEFAULT_FORMAT);

	char cur[64];
	GetCurrentMap(cur, sizeof(cur));

	kv.SetString("ServerNameFormat", fmt);
	kv.SetString("LastMap", cur);
	kv.SetNum("LastHeartbeat", GetTime());
	if (kv.GetNum("LastMapStart", 0) <= 0)
		kv.SetNum("LastMapStart", GetTime());

	kv.ExportToFile(p);
	delete kv;
}

// ------------------------------------------------------------------ 渲染

int ModeName(int mode, char[] out, int maxlen)
{
	if (mode == 0)
		strcopy(out, maxlen, "原版引擎点");
	else if (mode == 1)
		strcopy(out, maxlen, "引擎+视野+分散");
	else if (mode == 2)
		strcopy(out, maxlen, "自建优先");
	else
		Format(out, maxlen, "挡位%d", mode);
	return 0;
}

void DifficultyName(char[] out, int maxlen)
{
	ConVar c = FindConVar("z_difficulty");
	if (c == null)
	{
		strcopy(out, maxlen, "未知");
		return;
	}

	char s[32];
	c.GetString(s, sizeof(s));

	if (StrEqual(s, "Easy", false))
		strcopy(out, maxlen, "简单");
	else if (StrEqual(s, "Normal", false))
		strcopy(out, maxlen, "普通");
	else if (StrEqual(s, "Hard", false))
		strcopy(out, maxlen, "高级");
	else if (StrEqual(s, "Impossible", false))
		strcopy(out, maxlen, "专家");
	else
		strcopy(out, maxlen, s);
}

void ServerNum(char[] out, int maxlen)
{
	strcopy(out, maxlen, "0");

	ConVar c = FindConVar("hostport");
	if (c == null)
		return;

	char s[16];
	c.GetString(s, sizeof(s));

	int len = strlen(s);
	if (len >= 2)
		strcopy(out, maxlen, s[len - 2]);
	else
		strcopy(out, maxlen, s);
}

void SetServerName()
{
	if (!g_cEnable.BoolValue)
		return;

	ConVar cHost = FindConVar("hostname");
	if (cHost == null)
		return;

	char fmt[512];
	if (!ReadFormat(fmt, sizeof(fmt)))
		return;

	char name[512];
	strcopy(name, sizeof(name), fmt);

	char tmp[128];

	// ---- 几特几秒（{wave} 优先用生效值，取不到就回落设定值）----
	int effW = (g_cEffWave != null && g_cEffWave.IntValue > 0) ? g_cEffWave.IntValue : 0;
	int setW = (g_cWave != null) ? g_cWave.IntValue : 0;
	int wave = (effW > 0) ? effW : setW;
	Format(tmp, sizeof(tmp), "%d", wave);
	ReplaceString(name, sizeof(name), "{wave}", tmp);
	Format(tmp, sizeof(tmp), "%d", setW);
	ReplaceString(name, sizeof(name), "{setwave}", tmp);

	int effC = (g_cEffCap != null && g_cEffCap.IntValue > 0) ? g_cEffCap.IntValue : 0;
	int setC = (g_cCap != null) ? g_cCap.IntValue : 0;
	int cap  = (effC > 0) ? effC : setC;
	Format(tmp, sizeof(tmp), "%d", cap);
	ReplaceString(name, sizeof(name), "{cap}", tmp);
	Format(tmp, sizeof(tmp), "%d", setC);
	ReplaceString(name, sizeof(name), "{setcap}", tmp);

	int itv = (g_cTime != null) ? RoundToNearest(g_cTime.FloatValue) : 0;
	Format(tmp, sizeof(tmp), "%d", itv);
	ReplaceString(name, sizeof(name), "{time}", tmp);

	int modeNum = (g_cMode != null) ? g_cMode.IntValue : 0;
	char smode[32];
	ModeName(modeNum, smode, sizeof(smode));
	ReplaceString(name, sizeof(name), "{mode}", smode);
	Format(tmp, sizeof(tmp), "%d", modeNum);
	ReplaceString(name, sizeof(name), "{modenum}", tmp);

	// ---- 人数 ----
	int real = 0, all = 0, surv = 0, alive = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;

		all++;
		if (!IsFakeClient(i))
			real++;
		if (GetClientTeam(i) == TEAM_SURVIVOR)
		{
			surv++;
			if (IsPlayerAlive(i))
				alive++;
		}
	}
	Format(tmp, sizeof(tmp), "%d", real);    ReplaceString(name, sizeof(name), "{players}", tmp);
	Format(tmp, sizeof(tmp), "%d", all);     ReplaceString(name, sizeof(name), "{allplayers}", tmp);
	Format(tmp, sizeof(tmp), "%d", surv);    ReplaceString(name, sizeof(name), "{survivors}", tmp);
	Format(tmp, sizeof(tmp), "%d", alive);   ReplaceString(name, sizeof(name), "{alive}", tmp);

	// ---- 进度 ----
	float pct = 0.0;
	if (g_bHasFlow && L4D_HasAnySurvivorLeftSafeArea())
	{
		int idx = L4D_GetHighestFlowSurvivor();
		float f = (idx > 0 && idx <= MaxClients && IsClientInGame(idx))
			? L4D2Direct_GetFlowDistance(idx)
			: L4D2_GetFurthestSurvivorFlow();
		float maxf = L4D2Direct_GetMapMaxFlowDistance();
		if (maxf > 0.0 && f > 0.0)
			pct = f / maxf * 100.0;
	}
	Format(tmp, sizeof(tmp), "%d%%", RoundToNearest(pct));
	ReplaceString(name, sizeof(name), "{flow}", tmp);

	// ---- 本图计时 ----
	int secs = MapElapsedSecs();   // 【v1.0.5】max(墙钟, 引擎本图时间)
	int mins = secs / 60;
	if (g_cSeconds.BoolValue)
		Format(tmp, sizeof(tmp), "[计时:%dm:%ds]", mins, secs % 60);
	else
		Format(tmp, sizeof(tmp), "[计时:%dm]", mins);
	ReplaceString(name, sizeof(name), "{maptime}", tmp);

	// 【v1.0.2】{mtime}：纯时间，不带"计时"字样也不带方括号（模板自己决定要不要 []
	char mtime[32];
	if (mins >= 60)
		Format(mtime, sizeof(mtime), "%dh%02dm", mins / 60, mins % 60);
	else if (g_cSeconds.BoolValue)
		Format(mtime, sizeof(mtime), "%dm%ds", mins, secs % 60);
	else
		Format(mtime, sizeof(mtime), "%dm", mins);
	ReplaceString(name, sizeof(name), "{mtime}", mtime);

	// ---- 其它 ----
	char sMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
	ReplaceString(name, sizeof(name), "{map}", sMap);

	char sDiff[32];
	DifficultyName(sDiff, sizeof(sDiff));
	ReplaceString(name, sizeof(name), "{difficulty}", sDiff);

	Format(tmp, sizeof(tmp), "%d", g_iRestarts);
	ReplaceString(name, sizeof(name), "{restarts}", tmp);

	char sNum[8];
	ServerNum(sNum, sizeof(sNum));
	ReplaceString(name, sizeof(name), "{servernum}", sNum);

	char sText[128];
	g_cText.GetString(sText, sizeof(sText));
	ReplaceString(name, sizeof(name), "{customtext}", sText);

	// ---- 【v1.0.12】距离偏好 / 距离档 ----
	// 为什么读 cvar 而不是读文件：这两个值都挂在 ltt_si_spawner 上，而它是【另一个插件】。
	// 用 FindConVar 软连接读（和 ltt_si_menu / ltt_svote 一样的口径），插件不在就退化成"关/?"，
	// 绝不让服务器名因为缺插件而变成空字符串。
	ConVar cNear = FindConVar("ltt_sispawn_nearbias");
	char sNear[16];
	if (cNear == null)
		strcopy(sNear, sizeof(sNear), "关");
	else if (cNear.BoolValue)
		strcopy(sNear, sizeof(sNear), "就近");
	else
		strcopy(sNear, sizeof(sNear), "均衡");
	ReplaceString(name, sizeof(name), "{nearbias}", sNear);

	// 距离档短名：口径与 ltt_si_menu 的 g_sDistName 对齐
	//   贴脸 100~500 / 近 200~600 / 中 200~900 / 远 400~1500 / 开阔 200~2000
	ConVar cMin = FindConVar("ltt_sispawn_min");
	ConVar cMax = FindConVar("ltt_sispawn_max");
	char sBand[8];
	strcopy(sBand, sizeof(sBand), "?");
	if (cMin != null && cMax != null)
	{
		int mn = RoundToNearest(cMin.FloatValue);
		int mx = RoundToNearest(cMax.FloatValue);
		if (mn == 100 && mx == 500)       strcopy(sBand, sizeof(sBand), "贴");
		else if (mn == 200 && mx == 600)  strcopy(sBand, sizeof(sBand), "近");
		else if (mn == 200 && mx == 900)  strcopy(sBand, sizeof(sBand), "中");
		else if (mn == 400 && mx == 1500) strcopy(sBand, sizeof(sBand), "远");
		else if (mn == 200 && mx == 2000) strcopy(sBand, sizeof(sBand), "开");
	}
	ReplaceString(name, sizeof(name), "{distband}", sBand);

	// 【LTT 补丁 2026-10-07】服务器名末尾带上本图重开次数（团灭重启才涨，换图/重启清零）
	char sLttRs[24];
	Format(sLttRs, sizeof(sLttRs), "重%d", g_iLttRestart);   // 去掉管道符 + 用「重N」省字节（服务器名有字节上限，原来被截断）
	StrCat(name, sizeof(name), sLttRs);

	// ---- 写回（内容没变就不写）----
	char cur[512];
	cHost.GetString(cur, sizeof(cur));
	if (StrEqual(cur, name, true))
		return;

	cHost.SetString(name, true, false);

	if (g_cDebug.BoolValue)
		LogMessage("[ServerName] 地图=%s 新名字：%s", sMap, name);
}

// ------------------------------------------------------------------ 命令

public Action Cmd_Update(int client, int args)
{
	SetServerName();

	char cur[512];
	ConVar cHost = FindConVar("hostname");
	if (cHost != null)
		cHost.GetString(cur, sizeof(cur));

	ReplyToCommand(client, "[ServerName] 已刷新：%s", cur);
	return Plugin_Handled;
}

public Action Cmd_Show(int client, int args)
{
	char fmt[512];
	if (!ReadFormat(fmt, sizeof(fmt)))
	{
		ReplyToCommand(client, "[ServerName] 模板读不到（data/ltt_servername.txt）");
		return Plugin_Handled;
	}

	char cur[512];
	ConVar cHost = FindConVar("hostname");
	if (cHost != null)
		cHost.GetString(cur, sizeof(cur));

	ReplyToCommand(client, "[ServerName] 模板：%s", fmt);
	ReplyToCommand(client, "[ServerName] 当前：%s", cur);
	ReplyToCommand(client, "[ServerName] 诊断：GetTime=%d｜GetGameTime=%.1f｜tick=%d×%.4fs｜本图起点=%d｜墙钟已走=%ds｜本图计时取=%ds",
		GetTime(g_iBigStamp), GetGameTime(), GetGameTickCount(), GetTickInterval(),
		g_iMapStart, GetTime() - g_iMapStart, MapElapsedSecs());
	ReplyToCommand(client, "[ServerName] 占位符：{wave}{setwave}{cap}{setcap}{time}{mode}{modenum}{players}{allplayers}{survivors}{alive}{flow}{mtime}{maptime}{map}{difficulty}{restarts}{servernum}{customtext}{nearbias}{distband}");
	return Plugin_Handled;
}

public Action Cmd_SetName(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[ServerName] 用法: sm_setname <模板>（含空格要用引号）");
		ReplyToCommand(client, "[ServerName] 例: sm_setname \"L4D2 服务器[{wave}特{time}秒] {players}人\"");
		return Plugin_Handled;
	}

	char buf[512];
	GetCmdArgString(buf, sizeof(buf));
	StripQuotes(buf);
	TrimString(buf);

	if (buf[0] == '\0')
	{
		ReplyToCommand(client, "[ServerName] 模板不能为空");
		return Plugin_Handled;
	}

	WriteFormat(buf);
	SetServerName();

	char cur[512];
	ConVar cHost = FindConVar("hostname");
	if (cHost != null)
		cHost.GetString(cur, sizeof(cur));

	ReplyToCommand(client, "[ServerName] 模板已保存并生效：%s", cur);
	return Plugin_Handled;
}
