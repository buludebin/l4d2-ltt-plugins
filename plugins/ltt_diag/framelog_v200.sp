#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

public Plugin myinfo =
{
	name        = "[Diag] Frame Hitch Logger",
	author      = "DeepSeek Harness",
	description = "只记录真实卡顿(单帧 >=25ms)与掉帧心跳窗(fps<99.5)；10~15ms 是引擎 sleep 精度抖动，不算卡顿",
	version     = "2.0.0",
	url         = ""
};

ConVar g_cThreshold;
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
	RegAdminCmd("sm_framelog", Cmd_FrameLog, ADMFLAG_ROOT, "输出帧耗时统计");

	g_fPrevFrame = GetEngineTime();
	g_fWindowStart = g_fPrevFrame;
	g_iPrevTick = GetGameTickCount();
	g_iWindowTick = g_iPrevTick;

	CreateTimer(15.0, Timer_Report, _, TIMER_REPEAT);
	LogToFile("framelog.log", "=== 帧耗时监控 v2.0.0 启动（阈值 %.1f ms；心跳只在 fps<99.5 或每 5 分钟记一次）===",
		g_cThreshold.FloatValue * 1000.0);
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
		if (tick < 500)
		{
			LogToFile("framelog.log", "开图加载 %.1f ms | 本帧tick=%d | tick=%d | 实体=%d | 客户端=%d",
				dt * 1000.0, consumed, tick, GetEntityCount(), GetClientCount(true));
		}
		else
		{
			LogToFile("framelog.log", "卡顿 %.1f ms | 本帧tick=%d | tick=%d | 实体=%d | 客户端=%d | 生还=%d | 特感=%d",
				dt * 1000.0, consumed, tick, GetEntityCount(), GetClientCount(true),
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
	float fps = float(g_iFrames) / span;
	float realtick = float(dticks) / span;
	float frametime = fps > 0.0 ? 1000.0 / fps : 0.0;
	g_iWindows++;

	// 只在真正掉帧(<99.5fps)或每 5 分钟(20 个窗口)记一次，避免刷日志
	if (fps < 99.5 || (g_iWindows % 20) == 0)
	{
		LogToFile("framelog.log", "心跳 %.1fs: %d 帧 = %.1f fps (平均帧时间 %.3f ms) | 实测 %.2f tick/s | 最大单帧 %.1f ms | 本段卡顿(>=%.0fms) %d 次 | 累计 %d 次",
			span, g_iFrames, fps, frametime, realtick, g_fMaxFrame * 1000.0,
			g_cThreshold.FloatValue * 1000.0, g_iHitches, g_iTotalHitches);
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
	ReplyToCommand(client, "[framelog] 阈值 %.1f ms | 累计卡顿 %d 次 | 历史最长单帧 %.1f ms | 当前 tick=%d",
		g_cThreshold.FloatValue * 1000.0, g_iTotalHitches, g_fWorstFrame * 1000.0, GetGameTickCount());
	return Plugin_Handled;
}
