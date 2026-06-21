#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

// This server's console/logs are extremely verbose (competitive plugins log every
// player command), so isolating chat by filtering raw output is hopeless. Instead
// this plugin echoes chat — from players AND the server console / RCON — to the
// console with a unique [CHAT] tag, which journald ships to Loki, where the Grafana
// chat panel matches it exactly: no false positives, no noise.

public Plugin myinfo =
{
    name        = "Chat Logger",
    author      = "Luciano Giraldo",
    description = "Echoes player and server/RCON chat to the console with a [CHAT] tag for log aggregation.",
    version     = "1.0.0",
    url         = ""
};

public void OnPluginStart()
{
    AddCommandListener(OnSay, "say");
    AddCommandListener(OnSay, "say_team");
}

public Action OnSay(int client, const char[] command, int argc)
{
    // Allow real players (client > 0) and the server console / RCON (client 0);
    // only skip bots.
    if (client > 0 && IsFakeClient(client))
        return Plugin_Continue;

    char msg[256];
    GetCmdArgString(msg, sizeof(msg));
    StripQuotes(msg);
    TrimString(msg);
    if (msg[0] == '\0')
        return Plugin_Continue;

    char name[MAX_NAME_LENGTH];
    if (client < 1)
        strcopy(name, sizeof(name), "[RCON/Console]");
    else
        GetClientName(client, name, sizeof(name));

    bool team = StrEqual(command, "say_team", false);
    PrintToServer("[CHAT]%s %s: %s", team ? "(team)" : "", name, msg);

    return Plugin_Continue; // never block chat
}
