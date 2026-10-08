#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "2.2.1"

public Plugin myinfo =
{
	name        = "[Diag] Frame Hitch Logger",
	author      = "DeepSeek Harness",
	description = "记录真实卡顿(单帧>=25ms) + 每 5 秒无条件记录服务端真实 tick 率(用于与客户端 net_graph 对齐)",
	version     = PLUGIN_VERSION,
	url         = ""
};

// 【v2.1.0 重要】日志路径必须写成从游戏根目录算起的完整相对路径。
// v2.0.0 写的是 "framelog.log"，结果落到 left4dead2/framelog.log（游戏根目录），
// 而不是 addons/sourcemod/logs/ —— 之后找它找了半天，以为是插件没跑。
#define LOG_FILE "addons/sourcemod/logs/framelog.log"

// 【v2.2.0 为什么改成 5 秒无条件记录】
// 用户报 15:10 游戏内 net_graph 4 显示服务器 tick 掉到 75；但用 tick 计数增量算出来
// 15:09:02~15:12:59 的 9 个区间全部是 96.7~104.3 tick/s，一次都没掉。
// 旧的 15 秒心跳只在 fps<99.5 时写日志，**既看不见 <7.5 秒的短时掉帧，也不记录 sv_tickrate**，
// 所以没法和客户端的读数对齐。现在改成 5 秒无条件写一行，并带上服务端自己的三个真值。
#define SAMPLE_INTERVAL 5.0

ConVar g_cThreshold;
ConVar g_cTickrate;      // sv_tickrate（引擎 cvar，客户端 net_graph 的参考值）
float g_fPrevFrame;
float g_fWindowStart;
float g_fMaxFrame;
float g_fWorstFrame;
int g_iFrames;
int g_iHitches;
int g_iTotalHitches;
int g_iWindows;
int g_iPrevTick;      // 每帧更新, 用于算"本帧推进了几个 tick"
int g_iWindowTick;    // 只在上报时更新, 用于算窗口内真实 tick 速率

public void OnPluginStart()
{
	g_cThreshold = CreateConVar("framelog_threshold", "0.025",
		"单帧耗时超过该秒数才记录(0.025=25ms)。10~15ms 是引擎 sleep 精度造成的正常抖动",
		FCVAR_NOTIFY, true, 0.005, true, 1.0);
	g_cTickrate = FindConVar("sv_tickrate");
	RegAdminCmd("sm_framelog", Cmd_FrameLog, ADMFLAG_ROOT, "输出帧耗时统计");

	g_fPrevFrame = GetEngineTime();
	g_fWindowStart = g_fPrevFrame;
	g_iPrevTick = GetGameTickCount();
	g_iWindowTick = g_iPrevTick;

	CreateTimer(SAMPLE_INTERVAL, Timer_Report, _, TIMER_REPEAT);
	LogToFile(LOG_FILE, "=== 帧耗时监控 v2.2.0 启动（卡顿阈值 %.1f ms；tick 率每 %.1f 秒无条件记录一行）===",
		g_cThreshold.FloatValue * 1000.0, SAMPLE_INTERVAL);
}

int CountAlive(int team)
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == team && IsPlayerAlive(i))
		{
			n++;
		}
	}
	return n;
}

public void OnGameFrame()
{
	float now = GetEngineTime();
	float dt = now - g_fPrevFrame;
	g_fPrevFrame = now;
	g_iFrames++;

	int tick = GetGameTickCount();
	int consumed = tick - g_iPrevTick;   // 本帧期间推进了几个 tick
	g_iPrevTick = tick;

	if (dt > g_fMaxFrame)
	{
		g_fMaxFrame = dt;
	}

	if (dt > g_cThreshold.FloatValue)
	{
		g_iHitches++;
		g_iTotalHitches++;
		if (dt > g_fWorstFrame)
		{
			g_fWorstFrame = dt;
		}
		// tick<500 = 开图加载阶段, 长帧属正常, 单独标记避免与游戏内卡顿混淆
		// 【v2.2.1 · 2026-10-02 源码审核修复】两行都补 地图= —— 长期跑图要按图切分卡顿样本，
		// 而换图时刻的 tick 号会归零，光看 tick 分不清是哪张图。
		char sMapHitch[64];
		GetCurrentMap(sMapHitch, sizeof(sMapHitch));
		if (tick < 500)
		{
			LogToFile(LOG_FILE, "开图加载 %.1f ms | 地图=%s | 本帧tick=%d | tick=%d | 实体=%d | 客户端=%d",
				dt * 1000.0, sMapHitch, consumed, tick, GetEntityCount(), GetClientCount(true));
		}
		else
		{
			LogToFile(LOG_FILE, "卡顿 %.1f ms | 地图=%s | 本帧tick=%d | tick=%d | 实体=%d | 客户端=%d | 生还=%d | 特感=%d",
				dt * 1000.0, sMapHitch, consumed, tick, GetEntityCount(), GetClientCount(true),
				CountAlive(2), CountAlive(3));
		}
	}
}

public Action Timer_Report(Handle timer)
{
	float now = GetEngineTime();
	float span = now - g_fWindowStart;
	if (span <= 0.0)
	{
		return Plugin_Continue;
	}

	int ticks = GetGameTickCount();
	int dticks = ticks - g_iWindowTick;   // 窗口内真实推进的 tick 数
	// 【v2.2.1 · 2026-10-02 源码审核修复】换图时 GetGameTickCount() 归零，而 g_iWindowTick
	// 还是上一张图的值 ⇒ dticks 为负 ⇒ 日志里写出负的 tick/s（实测会落到文件里）。
	// 这一窗口按"本图已跑 tick 数"处理，不再让负数进日志。
	if (dticks < 0)
		dticks = ticks;
	char sMapRep[64];
	GetCurrentMap(sMapRep, sizeof(sMapRep));
	float fps = float(g_iFrames) / span;
	float realtick = float(dticks) / span;
	float frametime = fps > 0.0 ? 1000.0 / fps : 0.0;
	g_iWindows++;

	// 【v2.2.0】无条件记录。这一行就是"服务端真值"：
	//   实测 tick/s  = 窗口内 GetGameTickCount() 的真实增量 / 窗口墙钟秒数
	//   sv_tickrate  = 引擎 tickrate cvar（客户端 net_graph 的参考）
	//   interval     = GetTickInterval()，1/interval 应等于 sv_tickrate
	// 客户端 net_graph 报的数如果和这里对不上，那就是客户端侧(tick 率)读数，不是服务端掉 tick。
	int tickrate = (g_cTickrate != null) ? g_cTickrate.IntValue : -1;
	LogToFile(LOG_FILE, "tick采样 %.1fs: 地图=%s | 服务端实测 %.2f tick/s (dticks=%d) | sv_tickrate=%d | interval=%.5f (=%.1f/s) | 帧=%d (%.1f fps) | 最大单帧 %.1f ms | 卡顿 %d 次 | 实体=%d 客户端=%d 生还=%d 特感=%d",
		span, sMapRep, realtick, dticks, tickrate, GetTickInterval(),
		GetTickInterval() > 0.0 ? 1.0 / GetTickInterval() : 0.0,
		g_iFrames, fps, g_fMaxFrame * 1000.0, g_iHitches,
		GetEntityCount(), GetClientCount(true), CountAlive(2), CountAlive(3));

	// 掉帧时额外留一条 15 秒级别的心跳（保留 v2.1 的负载快照，便于和旧日志比对）
	if (fps < 99.5)
	{
		LogToFile(LOG_FILE, "掉帧心跳 %.1fs: %d 帧 = %.1f fps (平均帧时间 %.3f ms) | 实测 %.2f tick/s | 最大单帧 %.1f ms | 本段卡顿(>=%.0fms) %d 次 | 累计 %d 次 | 实体=%d 客户端=%d 生还=%d 特感=%d",
			span, g_iFrames, fps, frametime, realtick, g_fMaxFrame * 1000.0,
			g_cThreshold.FloatValue * 1000.0, g_iHitches, g_iTotalHitches,
			GetEntityCount(), GetClientCount(true), CountAlive(2), CountAlive(3));
	}

	g_iFrames = 0;
	g_iHitches = 0;
	g_fMaxFrame = 0.0;
	g_fWindowStart = now;
	g_iWindowTick = ticks;
	return Plugin_Continue;
}

public Action Cmd_FrameLog(int client, int args)
{
	ReplyToCommand(client, "[framelog] 阈值 %.1f ms | 累计卡顿 %d 次 | 历史最长单帧 %.1f ms | 当前 tick=%d | sv_tickrate=%d | 实测 interval=%.5f (=%.1f/s)",
		g_cThreshold.FloatValue * 1000.0, g_iTotalHitches, g_fWorstFrame * 1000.0,
		GetGameTickCount(), (g_cTickrate != null) ? g_cTickrate.IntValue : -1,
		GetTickInterval(), GetTickInterval() > 0.0 ? 1.0 / GetTickInterval() : 0.0);
	return Plugin_Handled;
}
