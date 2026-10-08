#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>

public void OnPluginStart()
{
	RegAdminCmd("sm_clrtest", Cmd_Test, ADMFLAG_ROOT, "颜色对照测试");
}

public Action Cmd_Test(int client, int args)
{
	CPrintToChatAll("[A] {blue}蓝{default} {green}绿{default} {olive}橄榄{default} {lightgreen}浅绿{default} {red}红{default} 完");
	CPrintToChatAll("[B] {teamcolor}队伍色{default} 完");
	return Plugin_Handled;
}
