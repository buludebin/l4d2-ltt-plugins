#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

public void OnPluginStart()
{
	char a[] = "\x0799CCFF";
	char b[] = "\x07%06X";
	LogMessage("[CLRTEST] 字面量长度=%d (期望 7) 前4字节=%d,%d,%d,%d  fmt模板长度=%d",
		strlen(a), a[0], a[1], a[2], a[3], strlen(b));
}
