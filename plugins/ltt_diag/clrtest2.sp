#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <multicolors>

public void OnPluginStart()
{
	RegAdminCmd("sm_clrtest", Cmd_Test, ADMFLAG_ROOT, "颜色对照测试");
}

public Action Cmd_Test(int client, int args)
{
	PrintToChatAll("[A]1普通 \x03 3号色 \x04 4号色 \x05 5号色 \x01 1号色");
	CPrintToChatAll("[B] {blue}blue蓝{default} {green}green绿{default} {olive}olive橄榄{default} {lightgreen}浅绿{default} {red}红{default} 完");
	CPrintToChatAll("[C] {teamcolor}队伍色{default} 完");
	return Plugin_Handled;
}
