#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

// When the last human leaves, an L4D2 server should drop into engine hibernation
// (~10 fps). After a competitive match the leftover bot/Director/team state can
// suppress that, so with ZoneMod's fleet-wide `fps_max 0` the empty server spins
// its main loop at 900+ fps (~20% of a core) until hibernation eventually engages.
//
// This plugin forces the clean transition: a short while after the last human
// disconnects, with the server confirmed empty, it re-asserts hibernation and
// reloads the current map. The map reload clears the residual state, so the empty
// server hibernates immediately. It never fires while humans are connected, so it
// leaves live matches (and `fps_max 0`) untouched.

#define EMPTY_DELAY 15.0   // seconds to wait after the last human leaves

ConVar g_cvHibernate;
Handle g_hTimer = null;

public Plugin myinfo =
{
    name        = "Idle Hibernation Enforcer",
    author      = "Luciano Giraldo",
    description = "Forces an empty server to hibernate so it doesn't spin at fps_max 0 after a match.",
    version     = "1.0.0",
    url         = ""
};

public void OnPluginStart()
{
    g_cvHibernate = FindConVar("sv_hibernate_when_empty");
}

public void OnClientPutInServer(int client)
{
    // A human is present again — cancel any pending empty-enforcement.
    if (client > 0 && !IsFakeClient(client))
    {
        delete g_hTimer;
        g_hTimer = null;
    }
}

public void OnClientDisconnect(int client)
{
    // Ignore bots: the map reload below churns bots, and reacting to that would
    // loop. Only a *human* leaving can schedule the check.
    if (IsFakeClient(client))
        return;

    delete g_hTimer;
    g_hTimer = CreateTimer(EMPTY_DELAY, Timer_EnforceIdle);
}

public Action Timer_EnforceIdle(Handle timer)
{
    g_hTimer = null;

    if (HumanCount() > 0)
        return Plugin_Stop; // someone is (still) here — do nothing

    // Allow hibernation, then reload the map so the engine drops into it cleanly.
    if (g_cvHibernate != null)
        g_cvHibernate.IntValue = 1;

    char map[PLATFORM_MAX_PATH];
    GetCurrentMap(map, sizeof(map));
    ServerCommand("changelevel %s", map);

    return Plugin_Stop;
}

int HumanCount()
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && !IsFakeClient(i))
            n++;
    return n;
}
