#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <multicolors>

/**
 *  ltt_kd  v1.0.10 —— 击杀统计 + 排行榜（聊天框）
 *
 *  【需求 · 2026-09-27 服主定稿】
 *    参照 NekoKillHud 的"回合结束聊天框播报"改造，但**不要 HUD、不要 binhooks**，
 *    只做两件事：①每个玩家的击杀统计 ②排行榜。
 *    **只在过关/团灭/终局弹 + !kd 手动查询**，不做 Neko 那种每 30 秒循环播报。
 *
 *  【输出 · v1.0.10 = 全部数字统一橄榄绿（服主 12:2x 看图后定稿）】
 *    颜色按角色分派，两个 cvar 是可选微调钮：
 *      {主色}[查询]{default} 本局计时: {green}3:21
 *      特感 {主色}8{default} 僵尸 {主色}19{default} 友伤 {主色}0 {主色}|{default} Ellis
 *      ...
 *      {主色}[章节]{default}: {主色}0{default} 特感 {主色}37{default} 僵尸 {主色}[{主色}0{default} 女巫 {主色}0{default} 坦克{主色}]
 *    **默认 color_tag=3 与 color_num=3 都是 {olive}** ⇒ 所有数字/方括号/分隔符全橄榄绿，
 *    玩家名和标签词不带色（白），只有本局计时的时间值留 {green} 做区分。
 *    ⚠ 两个 cvar 仍各管一摊（见下面 cvar 描述），只是默认摆成同一个颜色。
 *      想让"数字"和"方括号"分开色，只改 color_num 一档即可 —— 不用改代码。
 *    ⚠ 汇总行是"数字在前、标签在后"（`37 特感`），单人行是"标签在前、数字在后"（`特感 8`）——
 *      这是 v1.0.0 就定下的排版，v1.0.10 只对齐颜色不动版式。
 *    ⚠ 一条消息里只能有一个 SayText2 类 tag（{lightgreen}/{blue}/{red} 三者之一）。
 *      默认配色里【一个都没有】（{olive}/{green} 都是内联色）⇒ 结构上最安全，
 *      debug 打出来每行都是 tags=0。详见调色板段落。
 *
 *  【v1.0.1 按服主实测反馈改的四处】
 *    ①去掉 `#1`~`#4` 名次前缀（行序仍然是按特感降序，只是不显示序号）
 *    ②去掉名字前面的 `ID ` 字面量
 *    ③④ 标签/数字颜色改成两个 cvar
 *
 *  【v1.0.2 修 v1.0.1 的一个会抛错的隐患 + 更正我对颜色的一个错误结论】
 *    ⚠ 服主指出 `{lightgreen}` 在 L4D2 能显示亮绿 —— **服主是对的，我错了**。
 *      我把"颜色"当成由 `C_TagCode` 的 \x03 决定，实际 L4D2 里 \x03 的含义是【队伍色】，
 *      取"消息属主(ent_idx)"的颜色；而 `C_SetupProfile()` 给 {lightgreen}/{red}/{blue}
 *      各派了不同队伍的属主（服务器/感染者/生还者）⇒ 它们是三个不同的颜色。
 *      详见下面"颜色调色板"那一整段。
 *    ⚠ v1.0.1 把名字硬编码成 {blue}，若标签色也选 2/4/5，同一行就有两个 SayText2 tag
 *      ⇒ `C_Format()` L407-411 会 `ThrowError("Using two team colors in one message is not allowed")`。
 *      现在：名字固定 {default}（内联），且 `ltt_kd_color_num` 只开放内联色 ⇒ 每条消息里
 *      SayText2 tag 最多一个（就是标签色），结构上不可能再触发那个 ThrowError。
 *    ⚠ 调色板剔除 {darkred}：L4D2 的档案没启用它，会显示成绿（见下）。
 *
 *  ============================================================================
 *  【计数逻辑：逐项对比两份参照后做的取舍，理由写在这里免得以后被"优化"掉】
 *
 *  参照 A = NekoKillHud\nhud\event.sp L140-167
 *  参照 B = 豆瓣酱 l4d2_emshud_info.sp  L259-398（+ L1546 IsClientIdle）
 *  （另查了 l4d2_skill_detect.sp：它对小僵尸计数【没有表态】——
 *    那处 GetEdictClassname 在 IsWitch() 里，不能当第三个数据点。）
 *
 *  ① 特感击杀 → 抄 A
 *     A: player_death，死者 team 3 且 **!IsPlayerTank(victim)**，攻击者 team 2
 *     B: player_death，只判死者 team 3
 *     ⇒ B 没排除坦克，坦克死亡会被算进"特感击杀"。A 更精确。取 A。
 *
 *  ② 僵尸击杀 → 抄 A
 *     A: **infected_death**，只看攻击者 team 2（不查死者）
 *     B: player_death + GetEventInt("entityid") → GetEdictClassname == "infected"
 *     ⇒ 两者都能工作，但 A 用【专用事件】、每次只读一个 userid；B 每次都要
 *       IsValidEdict + GetEdictClassname，而多特服一局小僵尸死上千只，这是真实重复开销。
 *       取 A。（兜底：若计数偏低，把 B 那条路径换上来只需改这一处。）
 *
 *  ③ 友伤 → 抄 B
 *     A: player_hurt，只判 victim team 2 + **!IsFakeClient(attacker)** 当"是生还者"的近似
 *     B: player_hurt，**双方都明确判 team 2**
 *     ⇒ A 会漏掉【电脑生还者造成的友伤】，且有人玩特感的服上会把特感伤害算成友伤。取 B。
 *
 *  ④ 闲置玩家归属重映射 → 抄 B（A 完全没有）
 *     B 的 IsClientIdle()：读 m_humanSpectatorUserID，把"电脑生还者替闲置玩家打的"
 *     功劳算回给那个玩家本人。
 *     ⚠ 比 B 多做一件事：B 写成 `if(iBot!=0){ if(IsValidClient(iBot)) 记 iBot }` ——
 *       iBot!=0 但无效时【这次击杀直接消失】。这里改成无效就落回原客户端，不丢数据。
 *     ⚠ 只对【假客户端】做重映射：真人的这个属性没有意义，别乱改写归属。
 *
 *  ⑤ 【不采用】的项：
 *     · B 的爆头计数、伤害量/承受伤害 —— 我们的输出不需要
 *     · B 的 Event_Incapacitate 致命伤补救 —— 只为"伤害量"更准（最后一击的 dmg_health
 *       会被剩余血量截断）；"友伤"作为羞耻指标不受影响。需要多维护血量快照 + 额外 hook，
 *       先不做，随时能加。
 *     · A/B 的"总计"口径都不是"本图总计"：A 是本次战役（OnConfigsExecuted +
 *       IsMapTransition），B 是直到服务器空置（hibernation hook）。
 *       服主原话是"本图总计" ⇒ 按字面做：**每次载图清零，跨团灭保留**。
 *  ============================================================================
 *
 *  【时机 · 移植自 Neko 那段改造】
 *    过关 = map_transition 且有活着的生还者    终局 = finale_win
 *    团灭 = 其余（round_end / mission_lost）
 *    ⚠ mission_lost 之后还会再触发一次 round_end ⇒ 必须有去重标志，否则播两遍。
 *    ⚠ 播报必须发生在"清空本轮数据"【之前】。
 *
 *  【颜色 · Multi-Colors】（三个 inc 里 native/forward 声明数都是 0 ⇒ 运行期不用装东西）
 *    ★ 关键：`C_Format()` 的 tag 替换跑在 **VFormat 之后的完整消息串**上
 *      （colors.inc L366-372：遍历 C_Tag[]，在消息里 StrContains 到就 ReplaceString），
 *      **不是**只处理格式串。所以本文件可以【先 VFormat 拼好 buffer 再传 "%s"】，
 *      着色照常生效 —— 这也是颜色能做成动态 cvar 的原因。
 *    ★ 【更正】我一开始写的是"L4D2 只有 5 个原生色码，而 Multi-Colors 把
 *      {lightgreen}/{red}/{blue} 都映射到同一个 \x03 ⇒ 没有第二个绿色"。
 *      **这句是错的，服主纠正的**：L4D2 里 \x03 的含义是【队伍色】，
 *      取"消息属主(ent_idx)"的颜色，而 Multi-Colors 给这三个 tag 各派了
 *      不同队伍的属主（服务器/感染者/生还者）⇒ 它们是三个真正不同的颜色。
 *      详见下面「颜色调色板」那一段。
 *    ⚠ 编译时必须用 Multi-Colors 真包的 include 目录；
 *      `_工具\build\include\multicolors\colors.inc` 是 3740 字节假货（build_kd.ps1 有断言拦它）。
 */

#define PLUGIN_VERSION "1.0.17"

/**
 * 【颜色调色板 · L4D2 下真正可用的 tag 只有这 6 个】
 * 索引  标签            显示              机制 / 可靠性
 *  0   {default}       默认（白偏黄）    内联 \x01，永远可用
 *  1   {green}         绿                内联 \x04，永远可用
 *  2   {lightgreen}    ★亮绿（服务器色） SayText2，属主=SERVER_INDEX ⇒ 永远可用（见下）
 *  3   {olive}         橄榄绿（偏暗）    内联 \x05，永远可用
 *  4   {blue}          蓝（生还者色）    SayText2，属主=随机生还者 ⇒ 需场上有生还者
 *  5   {red}           红（感染者色）    SayText2，属主=随机特感   ⇒ 需场上有特感，否则退化
 *
 *  ★★ 为什么 {lightgreen} 不是蓝（我一开始搞错了，服主纠正的）：
 *     L4D2 里 \x03 的含义是【队伍色】，取的是"消息属主(ent_idx)"的颜色；
 *     `C_SetupProfile()` 的 L4D2 分支（colors.inc L527-536）把
 *       C_Profile_TeamIndex[Lightgreen] = SERVER_INDEX(0) / [Red] = 3(感染者) / [Blue] = 2(生还者)
 *     所以这三个 tag 各自被派给不同队伍当属主 ⇒ **是三个真正不同的颜色**，
 *     C_TagCode 里那个 \x03 只是内联占位。
 *     `C_FindRandomPlayerByTeam(SERVER_INDEX)` 直接 `return 0`（L426-428）
 *     ⇒ **{lightgreen} 永远可用，不会退化成绿**。这是最稳的一个"亮绿"。
 *     ⚠ {darkred} 在 L4D2 的档案里【没有启用】(只有 CS:GO 那支设了 true)
 *       ⇒ 会走 L373 被替换成 \x04 ⇒ **显示成绿，不是暗红**。所以调色板里没有它。
 *
 *  ★★ 【硬约束】一条消息里【只能有一个】SayText2 类 tag（2/4/5），否则
 *     `C_Format()` L407-411 直接 `ThrowError("Using two team colors in one message is not allowed")`。
 *     ⇒ v1.0.8 的默认配色里，SayText2 tag 只有"数字色"那一个（4={blue}）；
 *        分隔色默认 3={olive} 是内联的、名字/计时值写死内联 {green} ⇒ 结构上只有一个。
 *     ⇒ 若服主把两个 cvar 都调成 2/4/5，`Say()` 里的 CountSayText2Tags() 会兜底
 *        降级成 {green} 并大声记 LogError —— 不会静默失败，也不会崩。
 */
// 【v1.0.8】两个 cvar 共用同一套 6 档调色板。
// color_num（数字+标题括号，默认 4={blue}）、color_tag（[章节]/[]/| 分隔，默认 3={olive}）。
// 其中 2/4/5 是 SayText2 类，一条消息里只能出现一个 —— 靠 CountSayText2Tags() 兜底。
#define PALETTE_SIZE 6

ConVar g_cEnable, g_cRows, g_cShowGlobal, g_cShowTankWitch, g_cIncludeBots;
ConVar g_cColorTag, g_cColorNum;
ConVar g_cDebug;
ConVar g_cLog;
ConVar g_cVersion;

// ---- 本轮（round_start 清）----
int g_iSi[MAXPLAYERS + 1];       // 特感击杀
int g_iZb[MAXPLAYERS + 1];       // 僵尸击杀
int g_iFF[MAXPLAYERS + 1];       // 友伤（对队友造成的伤害量）
// ---- 汇总：[0] = 章节（本轮），[1] = 本图总计（跨团灭保留，载图清零）----
int g_iSiT[2];
int g_iZbT[2];
int g_iWitchT[2];
int g_iTankT[2];

float g_flRoundStart;
bool  g_bReported;        // 本轮是否已自动播报过（去重）
bool  g_bLateLoad;

enum
{
	RPT_SAFE = 0,   // 过关
	RPT_WIPE,       // 团灭
	RPT_FINALE,     // 终局
	RPT_QUERY       // !kd
}

public Plugin myinfo =
{
	name        = "[LTT] Kill Report",
	author      = "DeepSeek Harness",
	description = "击杀统计 + 排行榜（聊天框）。过关/团灭/终局自动播报，另有 !kd 手动查询",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cEnable = CreateConVar("ltt_kd_enable", "1",
		"总开关。0=完全不工作（不计数也不播报）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cRows = CreateConVar("ltt_kd_rows", "4",
		"排行榜显示前几名（Neko 也是 4）。0=不打排行榜只打汇总", FCVAR_NOTIFY, true, 0.0, true, 15.0);
	g_cShowGlobal = CreateConVar("ltt_kd_show_global", "0",
		"是否多打一行 [总计]（本图总计：跨团灭保留、载图清零）。默认 0", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cShowTankWitch = CreateConVar("ltt_kd_show_tankwitch", "1",
		"汇总行的方括号里是否带 女巫/坦克 数量", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cIncludeBots = CreateConVar("ltt_kd_include_bots", "1",
		"排行榜是否包含电脑生还者（0=只列真人）。替闲置玩家出场的 bot 其数据已归属给本人",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 【颜色 · v1.0.8 回到第一版(v1.0.0)配色 —— 服主 2026-09-27 定的】
	//   服主原话："不好，我觉得颜色搭配还是太难了，我们直接回到第一版的配色吧"
	//   v1.0.0（12:18 第一次上线的那版）的实际配色是：
	//     {blue}  = 标题方括号 [过关] + 所有数字
	//     {green} = 本局计时的时间值 + 玩家名
	//     {olive} = [章节]/[总计] 的方括号、内层 [] 、排行榜的 `|` 分隔符
	//     {default} = 其余文字（本局计时:/特感/僵尸/友伤/女巫/坦克）
	//   ⇒ v1.0.8 把上面四个角色【写死按这个来】，两个 cvar 退化成可选的微调旋钮：
	//     · color_num 现在只管"数字+标题方括号"，默认改成 4={blue}（v1 就是这个色）
	//     · color_tag 现在只管"[章节]/[]/| 这类分隔"，默认 3={olive}（v1 就是这个色）
	//   这样"回到第一版"是【零操作】的默认效果，想再试别的色也只要动这两个 cvar。
	//   ★ 一条消息里 2/4/5 只能出现一个（都是 SayText2 类），Say() 里仍有兜底。
	g_cColorTag = CreateConVar("ltt_kd_color_tag", "3",
		"主色 A：标题方括号 [查询]/[过关]/[团灭]/[终局]、[章节]/[总计] 方括号、内层 []、排行榜的 |、僵尸击杀数。0={default}白 | 1={green}绿 | 2={lightgreen}亮绿 | 3={olive}橄榄绿←当前默认 | 4={blue}蓝 | 5={red}红。★一条消息里 2/4/5 只能出现一个",
		FCVAR_NOTIFY, true, 0.0, true, float(PALETTE_SIZE - 1));
	g_cColorNum = CreateConVar("ltt_kd_color_num", "3",
		"主色 B：特感击杀数、友伤数、汇总行里的特感数、女巫数、坦克数。取值含义同 color_tag（同一套调色板）。3={olive}橄榄绿←当前默认（与 color_tag 同色，即所有数字都是橄榄绿；想让数字另外配色就改这一档）",
		FCVAR_NOTIFY, true, 0.0, true, float(PALETTE_SIZE - 1));
	g_cLog = CreateConVar("ltt_kd_log", "1",
		"1=把每次播报（过关/团灭/终局/查询）写成一行服务端日志（[KD] 前缀，含服务器时间与全部数字），便于事后离线查问题",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cDebug = CreateConVar("ltt_kd_debug", "0",
		"调试：1=把每一条要发出去的聊天串（含颜色 tag）写进 SM 日志。平时 0",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 计数事件：全部 Post（只读，不改事件）
	HookEvent("player_death",   Event_PlayerDeath,   EventHookMode_Post);
	HookEvent("infected_death", Event_InfectedDeath, EventHookMode_Post);
	HookEvent("player_hurt",    Event_PlayerHurt,    EventHookMode_Post);
	HookEvent("witch_killed",   Event_WitchKilled,   EventHookMode_Post);
	HookEvent("tank_killed",    Event_TankKilled,    EventHookMode_Post);

	// 回合/关卡事件：PostNoCopy 够用（只读事件名，不读事件数据）
	HookEvent("round_start",    Event_RoundStart,    EventHookMode_PostNoCopy);
	HookEvent("round_end",      Event_RoundEnd,      EventHookMode_PostNoCopy);
	HookEvent("map_transition", Event_MapTransition, EventHookMode_PostNoCopy);
	HookEvent("mission_lost",   Event_MissionLost,   EventHookMode_PostNoCopy);
	HookEvent("finale_win",     Event_FinaleWin,     EventHookMode_PostNoCopy);

	RegConsoleCmd("sm_kd", Cmd_Kd, "查看本局击杀统计与排行榜");

	if (g_bLateLoad)
		g_flRoundStart = GetGameTime();   // 中途加载：别让"本局计时"变成天文数字

	g_cVersion = CreateConVar("ltt_kd_version", PLUGIN_VERSION, "ltt_kd 版本", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	// ★【为什么必须显式纠正这三处 —— 踩过两次】
	// `CreateConVar` 若遇到【同名已存在】的 cvar，会直接返回旧对象：
	//   **值、描述、上下界都不会更新**（只有服务器重启后才按新代码生效）。
	// 后果：① `ltt_kd_version` 一直显示上一次编译的版本号 —— 等于这个 cvar 在说假话；
	//       ② 调色板从 5 档扩到 6 档后，`ltt_kd_color_tag` 的 max 还停在旧的 4，
	//          服主就没法选到 5({red})。
	// 所以这里显式把版本号和两个颜色 cvar 的上界纠正过来。
	// ⚠ 注意：能纠正的只有【值和上下界】。Console 里 `ltt_kd_color_num` 后面括号里那个
	//   `( def. "..." )` 是【默认值】，SM 没有 SetDefault 这个 native（只有 RestoreDefault/
	//   GetDefault），所以原地 reload 之后那个 def 会一直停在"第一次编译时的默认值"，
	//   服务器重启后才归位。**不是 bug，也不用管；以值为准，值这里已经是对的。**
	SetConVarString(g_cVersion, PLUGIN_VERSION);
	SetConVarBounds(g_cColorTag, ConVarBound_Upper, true, float(PALETTE_SIZE - 1));
	SetConVarBounds(g_cColorNum, ConVarBound_Upper, true, float(PALETTE_SIZE - 1));
	AutoExecConfig(true, "ltt_kd");
	LogMessage("[KD] v%s 已加载 | 自动播报=过关/团灭/终局 | 手动=!kd", PLUGIN_VERSION);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLateLoad = late;
	return APLRes_Success;
}

// ====================================================== 归属

/**
 * 归属重映射（抄豆瓣酱 l4d2_emshud_info.sp L1546-1552，A 没有）。
 * 电脑生还者若对应某个闲置玩家，功劳算给那个玩家本人。
 * 只对假客户端做 —— 真人的这个属性没有意义。
 * 属性无效/映射不到人时【落回原客户端】，绝不丢数据（B 那个写法会丢）。
 */
int Credit(int client)
{
	if (!IsValidClient(client) || !IsFakeClient(client))
		return client;

	if (!HasEntProp(client, Prop_Send, "m_humanSpectatorUserID"))
		return client;

	int owner = GetClientOfUserId(GetEntProp(client, Prop_Send, "m_humanSpectatorUserID"));
	if (owner < 1 || owner > MaxClients || !IsClientInGame(owner))
		return client;

	return owner;
}

// ====================================================== 计数

int  g_iRestart = 0;      // 【v1.0.17】本图团灭次数（= 这张图重开了几次）

void ResetRound()
{
	for (int i = 0; i <= MaxClients; i++)
	{
		g_iSi[i] = 0;
		g_iZb[i] = 0;
		g_iFF[i] = 0;
	}
	g_iSiT[0]    = 0;
	g_iZbT[0]    = 0;
	g_iWitchT[0] = 0;
	g_iTankT[0]  = 0;
}

/** 【v1.0.14 · 2026-10-02 源码审核修复】新玩家进入时清空"本槽位"的战绩。
 *  原来只有 OnMapStart / round_start 会 ResetRound()。玩家中途退出后槽位立刻会被新玩家复用
 *  （本服引擎槽位 32、进出频繁），新玩家一进来就顶着上一个人的特感/僵尸/友伤数字，
 *  排行榜（!kd）与 [KD] 结果行都会把别人的战绩记到他头上 —— 长期跑图收集的数据会脏。
 *  放在 PutInServer（而不是 Disconnect）是为了保住宿主退出前的数字：
 *  他退出的那一刻不抹，仍然记在过关/团灭的结果行里，只是不传给下一个人。 */
public void OnClientPutInServer(int client)
{
	if (client > 0 && client <= MaxClients)
	{
		g_iSi[client] = 0;
		g_iZb[client] = 0;
		g_iFF[client] = 0;
	}
}

/** ① 特感击杀 —— 抄 NekoKillHud\nhud\event.sp L145-150（多一条排除坦克）。 */
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cEnable.BoolValue)
		return;

	int victim   = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (IsValidClient(victim) && GetClientTeam(victim) == 3 && !IsPlayerTank(victim)
		&& IsValidClient(attacker) && GetClientTeam(attacker) == 2)
	{
		int c = Credit(attacker);
		g_iSi[c]++;
		g_iSiT[0]++;
		g_iSiT[1]++;
	}
}

/** ② 僵尸击杀 —— 抄 NekoKillHud\nhud\event.sp L157-164（不查死者）。 */
public void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cEnable.BoolValue)
		return;

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (IsValidClient(attacker) && GetClientTeam(attacker) == 2)
	{
		int c = Credit(attacker);
		g_iZb[c]++;
		g_iZbT[0]++;
		g_iZbT[1]++;
	}
}

/** ③ 友伤 —— 抄豆瓣酱 l4d2_emshud_info.sp L266-294（双方都明确判 team 2）。 */
public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cEnable.BoolValue)
		return;

	int victim   = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (IsValidClient(victim) && IsValidClient(attacker) && victim != attacker
		&& GetClientTeam(victim) == 2 && GetClientTeam(attacker) == 2)
	{
		int c = Credit(attacker);
		g_iFF[c] += event.GetInt("dmg_health");
	}
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cEnable.BoolValue)
		return;
	g_iWitchT[0]++;
	g_iWitchT[1]++;
}

public void Event_TankKilled(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cEnable.BoolValue)
		return;
	g_iTankT[0]++;
	g_iTankT[1]++;
}

// ====================================================== 生命周期

/** 【本图总计】每次载图都清（跨团灭保留）—— 服主要的"本图"口径。 */
public void OnMapStart()
{
	ResetRound();
	g_iSiT[1]    = 0;
	g_iZbT[1]    = 0;
	g_iWitchT[1] = 0;
	g_iTankT[1]  = 0;
	g_iRestart    = 0;      // 【v1.0.17】本图团灭次数清零
	g_bReported    = false;
	g_flRoundStart = GetGameTime();
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{

	ResetRound();
	g_bReported    = false;
	g_flRoundStart = GetGameTime();
}

public void Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
	Report(RPT_SAFE);
}

public void Event_FinaleWin(Event event, const char[] name, bool dontBroadcast)
{
	Report(RPT_FINALE);
}

/** 团灭。⚠ mission_lost 之后还会再触发一次 round_end ⇒ 靠 g_bReported 去重。 */
public void Event_MissionLost(Event event, const char[] name, bool dontBroadcast)
{
	Report(RPT_WIPE);
}

/** round_end 兜底。有活人时不按团灭处理（那属于过关那条路径）。 */
public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (HasAliveSurvivor())
		return;
	Report(RPT_WIPE);
}

// ====================================================== 播报

void Report(int reason, int target = 0)
{
	// 自动播报去重；!kd 查询不受影响
	if (reason != RPT_QUERY)
	{
		if (g_bReported)
			return;
		g_bReported = true;
	}

	if (!g_cEnable.BoolValue)
		return;

	// 【v1.0.17】重开次数改按“团灭”计：玩家口径 = 这张图灭了几次。
	// 原来按 round_start 计，但实测载图后的第一局不产生 round_start 事件，
	// 于是第一次团灭后的那次重开被当成“第一局”吞掉 ⇒ 显示永远比实际少 1。
	if (reason == RPT_WIPE)
		g_iRestart++;

	char sHead[24];
	switch (reason)
	{
		case RPT_SAFE:   strcopy(sHead, sizeof(sHead), "过关");
		case RPT_WIPE:   strcopy(sHead, sizeof(sHead), "团灭");
		case RPT_FINALE: strcopy(sHead, sizeof(sHead), "终局");
		default:         strcopy(sHead, sizeof(sHead), "查询");
	}

	char sTime[16];
	FormatRoundTime(sTime, sizeof(sTime));

	// 颜色标签（可动态换 —— 见文件头对 C_Format 的说明）
	// 【v1.0.9 按服主反馈微调】
	//   ① 僵尸击杀数 从"主色 B"改走"主色 A sTag"（= [章节] 的颜色，服主要的语义就是
	//      "跟 [章节] 同色"，所以这里必须复用 sTag 而不是新开一档，否则两边会脱钩）
	//   ② 标题方括号 [查询]/[过关]/[团灭]/[终局] 也从"主色 B"改走 sTag
	//   ③ 玩家名 从 {green} 改成不带颜色（{default}）
	// 【v1.0.10 按服主看图后的反馈】"特感、友伤、坦克、女巫统计数字全改橄榄绿"
	//   ⇒ 特感数/友伤数/女巫数/坦克数 仍走 sNum，但把 color_num 的【默认值】从 4={blue}
	//     改成 3={olive} ⇒ 效果上"所有数字都是橄榄绿"，而代码分组不用动、两个旋钮都还活着。
	char sTag[16], sNum[16];
	PaletteTag(g_cColorTag.IntValue, sTag, sizeof(sTag));
	PaletteTag(g_cColorNum.IntValue, sNum, sizeof(sNum));

	int order[MAXPLAYERS + 1];
	int n = BuildOrder(order);
	int rows = g_cRows.IntValue;
	if (n > rows)
		n = rows;

	// ---- 第 1 行 ----
	// ⚠【2026-09-27 实测踩过，别再犯】这里曾经写死 "{blue}[%s]..." 而标签色动态选到
	//   {lightgreen}（两个都是 SayText2 类）⇒ 一条消息里两个 ⇒ C_Format() L407-411
	//   直接 ThrowError ⇒ Report() 从第一行就中断，服主看到"游戏内 !kd 完全没输出"。
	//   ⇒ 方括号的颜色必须和同一行其它颜色 tag 互斥。v1.0.9 起跟 sTag 走（默认 {olive}
	//     是内联色），Say() 里另有一道兜底，见 CountSayText2Tags。
	// 【v1.0.11】把「本章节计时」并到同一行（服主要的效果：本局计时 ｜ 本章节计时）。
	// 口径说明：`GetGameTime()` 就是"本图已运行了多少秒"（换图自动归零、跨团灭重生保留），
	// 正好等于"这一章一共耗了多久"，所以不需要另存时间戳，也就不会跟 OnMapStart/RoundStart 打架。
	// 【v1.0.12】第一行加"当前服务器时间"（服主要求：方便确认什么时候发生的）。
	// sChap / sNow 提到函数作用域，末尾写日志时还要用。
	char sChap[16];
	int csec = RoundToFloor(GetGameTime());
	FormatEx(sChap, sizeof(sChap), "%d:%02d", csec / 60, csec % 60);
	char sNow[32];
	FormatTime(sNow, sizeof(sNow), "%Y-%m-%d %H:%M:%S", GetTime());
	{
		// 颜色只用一个 sTag + 内联 {default}/{green}：与上面那条"同一行不能出现两个 SayText2 类色"的
		// 教训保持一致（{blue}/{lightgreen} 才是 SayText2 类，这里不用）。
		Say(target, "%s[%s]{default} 服务器时间 {default}%s{default} ｜ 本局计时: {green}%s{default} ｜ %s本章节计时{default}: {green}%s{default} ｜ 重开: {green}%d",
			sTag, sHead, sNow, sTime, sTag, sChap, g_iRestart);   // 【v1.0.16】章节计时后面带本图重开次数
	}

	// ---- 排行榜 ----
	if (rows > 0)
	{
		if (n <= 0)
		{
			Say(target, "%s未检测有玩家在生还队伍", sTag);
		}
		else
		{
			char sName[MAX_NAME_LENGTH];
			for (int k = 0; k < n; k++)
			{
				int c = order[k];
				GetClientName(c, sName, sizeof(sName));
				// 【v1.0.1】去掉 `#N` 名次前缀；去掉名字前的 `ID `
				// 【v1.0.8】排版回到 v1.0.0：标签词白、数字走数字色、`|` 走分隔色
				// 【v1.0.9】僵尸数走 sTag；名字不带色（末尾那个 %s 前面是 {default}）
				Say(target, "特感 %s%d{default} 僵尸 %s%d{default} 友伤 %s%d %s|{default} %s",
					sNum, g_iSi[c], sTag, g_iZb[c], sNum, g_iFF[c], sTag, sName);
			}
		}
	}

	// ---- 汇总行 ----
	// ⚠【2026-09-27 第二次踩，记牢】这行曾经为了给【内层方括号】也单独上色，写成
	//   `%s[%s%d{default} ... %s坦克{default}%s]` —— 格式串变成 15 个占位符
	//   而只给了 13 个参数 ⇒ 运行时 VFormat 报
	//   "String formatted incorrectly - parameter 16 (total 15)"，整行发不出去。
	//   ⚠ 这类错误【编译器不会报】，只在运行时炸 ⇒ 已加 _工具/build/lint_format.ps1 静态挡。
	//   ⇒ v1.0.8 回到 v1.0.0 的写法：内层方括号用分隔色 sTag 包住整段，不再单独染色。
	//   ⇒ v1.0.9 这里"僵尸数"那一格也从 sNum 换成 sTag（占位符个数不变，只换实参）。
	if (g_cShowTankWitch.BoolValue)
		Say(target, "%s[章节]{default}: %s%d{default} 特感 %s%d{default} 僵尸 %s[%s%d{default} 女巫 %s%d{default} 坦克%s]",
			sTag, sNum, g_iSiT[0], sTag, g_iZbT[0], sTag, sNum, g_iWitchT[0], sNum, g_iTankT[0], sTag);
	else
		// ⚠ v1.0.6 之前这行只有 6 个参数、7 个占位符（少一个末尾的 sTag）——
		//   一旦把 ltt_kd_show_tankwitch 设成 0，!kd 就会在这里抛
		//   "String formatted incorrectly" 整条中断。新建的 lint_format.ps1 抓到的。
		Say(target, "%s[章节]{default}: %s%d{default} 特感 %s%d{default} 僵尸",
			sTag, sNum, g_iSiT[0], sTag, g_iZbT[0]);

	if (g_cShowGlobal.BoolValue)
	{
		if (g_cShowTankWitch.BoolValue)
			Say(target, "%s[总计]{default}: %s%d{default} 特感 %s%d{default} 僵尸 %s[%s%d{default} 女巫 %s%d{default} 坦克%s]",
				sTag, sNum, g_iSiT[1], sTag, g_iZbT[1], sTag, sNum, g_iWitchT[1], sNum, g_iTankT[1], sTag);
		else
			Say(target, "%s[总计]{default}: %s%d{default} 特感 %s%d{default} 僵尸",
				sTag, sNum, g_iSiT[1], sTag, g_iZbT[1]);
	}

	// ---- 【v1.0.12】服务端日志 ----
	// 动机（服主 2026-10-02）：播报只在游戏内聊天框，人不在服里就看不到；写一行进 SM 日志，
	// 事后直接 grep [KD] 就能复盘"哪一局、什么时间、谁打了多少、章节/总计各多少"。
	// 一行写完、字段带名字，便于 awk/grep；LogMessage 自带 `L MM/DD/YYYY - HH:MM:SS:` 前缀。
	// 注意：排行榜在聊天里只发 rows 行，日志里写**全部上榜玩家**（n 个），避免"日志缺人"。
	if (g_cLog.BoolValue)
	{
		// 【v1.0.13 · 2026-10-02 源码审核修复】原来 sPly[512]，每人约 50~60 字符
		// ⇒ 9 人以上会被 Format 静默截断（本服引擎槽位 32，人类上限也远不止 9）。
		// 放大到 2048，并在真的放不下时写明"已截断"，不能让日志悄悄少人。
		char sPly[2048];
		sPly[0] = '\0';
		char sNameLog[MAX_NAME_LENGTH];
		bool bPlyTrunc = false;
		for (int k = 0; k < n; k++)
		{
			int c = order[k];
			GetClientName(c, sNameLog, sizeof(sNameLog));
			char sOne[128];
			Format(sOne, sizeof(sOne), "%s%s=特感%d/僵尸%d/友伤%d",
				(k > 0) ? "; " : "", sNameLog, g_iSi[c], g_iZb[c], g_iFF[c]);
			if (strlen(sPly) + strlen(sOne) + 32 >= sizeof(sPly))
			{
				bPlyTrunc = true;
				break;
			}
			StrCat(sPly, sizeof(sPly), sOne);
		}
		if (bPlyTrunc)
			StrCat(sPly, sizeof(sPly), "; …(缓冲区已满,后面的人被截断)");
		// 【v1.0.12】日志里必须带地图名 —— 离线复盘第一件事就是"这是哪张图"
		char sMapLog[64];
		GetCurrentMap(sMapLog, sizeof(sMapLog));
		LogMessage("[KD] 结果=%s 地图=%s 服务器时间=%s 本局=%s 本章节=%s | 重开=%d | 章节: 特感%d 僵尸%d 女巫%d 坦克%d | 总计: 特感%d 僵尸%d 女巫%d 坦克%d | 玩家(%d): %s",
			sHead, sMapLog, sNow, sTime, sChap, g_iRestart,
			g_iSiT[0], g_iZbT[0], g_iWitchT[0], g_iTankT[0],
			g_iSiT[1], g_iZbT[1], g_iWitchT[1], g_iTankT[1],
			n, (sPly[0] != '\0') ? sPly : "（无）");
	}
}

/**
 * target 0 = 全体，否则单人。
 * ★ 先 VFormat 拼好 buffer 再传 "%s" 是【安全】的：Multi-Colors 的 tag 替换
 *   跑在 C_Format() 里的完整消息串上（colors.inc L366-372），不是只看格式串。
 */
void Say(int target, const char[] fmt, any ...)
{
	char buf[512];
	VFormat(buf, sizeof(buf), fmt, 3);

	// ★【结构性兜底 —— 2026-09-27 服主实测"!kd 完全没输出"之后加的】
	// Multi-Colors 的 C_Format() 在一条消息里发现【第二个】SayText2 类 tag 时
	// 会直接 ThrowError（colors.inc L407-411）。后果很隐蔽：
	//   消息发不出去 + Report() 后面的行全部不执行 ⇒ 表现成"整条指令没反应"。
	// 所以发送前自己数一遍；超过一个就把它们全部降级成内联 {green}，
	// 并【大声记一条 LogError】—— 宁可颜色差一点，也不能让播报莫名消失。
	// （真正的修法是格式串里只放一个 SayText2 槽位；这道兜底是防以后又漏。）
	if (CountSayText2Tags(buf) > 1)
	{
		// ⚠ SourcePawn【不支持】C 那样的相邻字符串自动拼接 —— 必须写在一行里。
		LogError("[KD] 一条消息里出现多个 SayText2 类 tag（{lightgreen}/{blue}/{red}），Multi-Colors 会 ThrowError 导致整条消息发不出去 → 已降级为内联色。原串: %s", buf);
		ReplaceString(buf, sizeof(buf), "{lightgreen}", "{green}", false);
		ReplaceString(buf, sizeof(buf), "{blue}",       "{green}", false);
		ReplaceString(buf, sizeof(buf), "{red}",        "{green}", false);
	}

	// ★【调试口 · v1.0.8 加】ltt_kd_debug 1 时把【真正要发出去的串】写进 SM 日志。
	//   为什么值得加：颜色这件事我已经凭猜测错过两次（一次"!kd 没输出"、一次
	//   "String formatted incorrectly"），光靠"没报错"不足以说明"每条消息里
	//   到底带了哪几个颜色 tag"。有了这个口，可以直接在服务器日志里看到
	//   每一行的原始 tag 序列，用于核对"一行里只有一个 SayText2 类 tag"。
	if (g_cDebug.BoolValue)
		LogMessage("[KD-DEBUG] target=%d tags=%d | %s", target, CountSayText2Tags(buf), buf);

	if (target > 0 && IsClientInGame(target))
		CPrintToChat(target, "%s", buf);
	else
		CPrintToChatAll("%s", buf);
}

/** 数一条消息里有几个 SayText2 类 tag。★ 这三个 tag 各自被派给不同队伍当属主：
 *  {lightgreen}=服务器色 / {blue}=生还者色 / {red}=感染者色 —— 一条消息只能用一个。 */
int CountSayText2Tags(const char[] buf)
{
	int n = 0;
	if (StrContains(buf, "{lightgreen}", false) != -1) n++;
	if (StrContains(buf, "{blue}",       false) != -1) n++;
	if (StrContains(buf, "{red}",        false) != -1) n++;
	return n;
}

/** 调色板索引 → Multi-Colors 标签。两个颜色 cvar 共用这一套（v1.0.5 起）。
 *  v1.0.8 的默认取值：color_num=4({blue}) 管数字+标题括号，color_tag=3({olive}) 管分隔符。 */
void PaletteTag(int idx, char[] out, int maxlen)
{
	switch (idx)
	{
		case 1:  strcopy(out, maxlen, "{green}");
		case 2:  strcopy(out, maxlen, "{lightgreen}");
		case 3:  strcopy(out, maxlen, "{olive}");
		case 4:  strcopy(out, maxlen, "{blue}");
		case 5:  strcopy(out, maxlen, "{red}");
		default: strcopy(out, maxlen, "{default}");
	}
}

/**
 * 排行顺序（下标数组），返回人数。
 * 排序：特感降序 → 僵尸降序 → 客户端号升序（保证名次可复现）。
 * 自己写插入排序而不是 ArrayList.Sort：SourcePawn 的 Sort 稳定性没有保证，
 * 而这里要的是"确定的排名"，不该赌排序实现。
 */
int BuildOrder(int order[MAXPLAYERS + 1])
{
	bool bBots = g_cIncludeBots.BoolValue;
	int  n = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || IsClientSourceTV(i))
			continue;
		int team = GetClientTeam(i);
		if (team != 2 && team != 1)   // 只列生还者/旁观；特感不列
			continue;
		if (!bBots && IsFakeClient(i))
			continue;
		order[n++] = i;
	}

	for (int i = 1; i < n; i++)
	{
		int key = order[i];
		int j   = i - 1;
		while (j >= 0 && Better(key, order[j]))
		{
			order[j + 1] = order[j];
			j--;
		}
		order[j + 1] = key;
	}
	return n;
}

bool Better(int a, int b)
{
	if (g_iSi[a] != g_iSi[b])
		return g_iSi[a] > g_iSi[b];
	if (g_iZb[a] != g_iZb[b])
		return g_iZb[a] > g_iZb[b];
	return a < b;
}

void FormatRoundTime(char[] out, int maxlen)
{
	int secs = RoundToFloor(GetGameTime() - g_flRoundStart);
	if (secs < 0)
		secs = 0;
	Format(out, maxlen, "%d:%02d", secs / 60, secs % 60);
}

bool HasAliveSurvivor()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
			return true;
	}
	return false;
}

// ====================================================== 命令

public Action Cmd_Kd(int client, int args)
{
	Report(RPT_QUERY, (client > 0) ? client : 0);
	return Plugin_Handled;
}

// ====================================================== 工具

/** 与两家参照一致：**不排除假客户端**（Neko nekotools.inc L229-236 / 豆瓣酱 L1580-1583）。 */
bool IsValidClient(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

/** 坦克判定：与 Neko 的 IsPlayerTank 一致 —— team 3 且 m_zombieClass == 8。 */
bool IsPlayerTank(int client)
{
	if (!IsValidClient(client) || GetClientTeam(client) != 3)
		return false;
	return GetEntProp(client, Prop_Send, "m_zombieClass") == 8;
}
