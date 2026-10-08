#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

public Plugin myinfo =
{
	name = "[Diag] Frame Hitch Logger",
	author = "DeepSeek Harness",
	description = "记录服务端单帧耗时异常与真实 tick 增量，用于判定掉 tick 来源（临时诊断插件，可随时卸载）",
	version = "1.0.0",
	url = ""
};

ConVar g_cThreshold;
float g_fPrevFrame;
float g_fWindowStart;
float g_fMaxFrame;
float g_fWorstFrame;
int g_iFrames;
int g_iHitches;
int g_iLastTick;
int g_iTotalHitches;

public void OnPluginStart()
{
	g_cThreshold = CreateConVar("framelog_threshold", "0.0105", "单帧耗时超过该秒数即记录（0.0105 秒 = 100tick 预算 10.5ms）", FCVAR_NOTIFY);
	RegAdminCmd("sm_framelog", Cmd_FrameLog, ADMFLAG_ROOT, "输出帧耗时统计");
	g_fPrevFrame = GetEngineTime();
	g_fWindowStart = g_fPrevFrame;
	g_iLastTick = GetGameTickCount();
	CreateTimer(15.0, Timer_Report, _, TIMER_REPEAT);
	LogToFile("framelog.log", "=== 帧耗时监控启动（阈值 %.2f ms）===", g_cThreshold.FloatValue * 1000.0);
}

public void OnGameFrame()
{
	float now = GetEngineTime();
	float dt = now - g_fPrevFrame;
	g_fPrevFrame = now;
	g_iFrames++;

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
		LogToFile("framelog.log", "卡顿 %.2f ms | tick=%d | 实体=%d | 客户端=%d",
			dt * 1000.0, GetGameTickCount(), GetEntityCount(), GetClientCount(true));
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
	int dticks = ticks - g_iLastTick;
	float fps = float(g_iFrames) / span;
	float realtick = float(dticks) / span;
	float frametime = fps > 0.0 ? 1000.0 / fps : 0.0;

	LogToFile("framelog.log", "心跳 %.1fs: %d 帧 = %.1f fps (平均帧时间 %.3f ms) | tick 增量 %d (应 %.0f, 实测 %.2f tick/s) | 最大单帧 %.2f ms | 本段卡顿 %d 次 | 累计 %d 次",
		span, g_iFrames, fps, frametime, dticks, span * 100.0, realtick, g_fMaxFrame * 1000.0, g_iHitches, g_iTotalHitches);

	g_iFrames = 0;
	g_iHitches = 0;
	g_fMaxFrame = 0.0;
	g_fWindowStart = now;
	g_iLastTick = ticks;
	return Plugin_Continue;
}

public Action Cmd_FrameLog(int client, int args)
{
	ReplyToCommand(client, "[framelog] 阈值 %.2f ms | 累计卡顿 %d 次 | 历史最长单帧 %.2f ms | 当前 tick=%d",
		g_cThreshold.FloatValue * 1000.0, g_iTotalHitches, g_fWorstFrame * 1000.0, GetGameTickCount());
	return Plugin_Handled;
}
