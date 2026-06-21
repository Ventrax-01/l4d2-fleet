#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

// Player chat is written to a dedicated per-server file
// (/var/log/l4d2-fleet/chat-<port>.log) which Promtail tails into Loki for the Grafana
// chat panel. We write a file instead of PrintToServer because SourceMod console output
// does NOT reach the headless srcds stdout/journald on this engine build (Facepunch
// garrysmod-issues #2343 — engine Msg does, plugin prints don't). File I/O bypasses
// stdout and is reliable, and a dedicated file is zero-noise so the panel needs no
// filtering. The log dir lives outside /home/steam (which is 0750) so the separate
// promtail user can read it. (Server/RCON `say` is NOT captured: the engine doesn't route
// console-originated say through SourceMod's command listener — only real player chat.)

public Plugin myinfo =
{
    name        = "Chat Logger",
    author      = "Luciano Giraldo",
    description = "Writes player chat to a per-server log file for aggregation (Loki/Grafana).",
    version     = "2.0.0",
    url         = ""
};

int g_port;

public void OnPluginStart()
{
    AddCommandListener(OnSay, "say");
    AddCommandListener(OnSay, "say_team");
}

public Action OnSay(int client, const char[] command, int argc)
{
    // Only real players: the engine does NOT route server console / RCON `say`
    // through the command-listener system, so those can't be caught here.
    if (client < 1 || IsFakeClient(client))
        return Plugin_Continue;

    char msg[256];
    GetCmdArgString(msg, sizeof(msg));
    StripQuotes(msg);
    TrimString(msg);
    if (msg[0] == '\0')
        return Plugin_Continue;

    // hostport isn't reliably set at plugin load, so resolve it lazily on first chat.
    if (g_port == 0)
    {
        ConVar cvPort = FindConVar("hostport");
        if (cvPort != null)
            g_port = cvPort.IntValue;
    }

    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));

    char path[PLATFORM_MAX_PATH];
    // Absolute path (BuildPath strips the file:// prefix and uses the rest verbatim): a
    // world-readable dir outside /home/steam (0750) so Promtail can read it directly.
    BuildPath(Path_SM, path, sizeof(path), "file:///var/log/l4d2-fleet/chat-%d.log", g_port);

    // Open/append/close per line: chat is low-volume, so this is cheap and avoids any
    // flush/buffering concerns and survives logrotate. Lead with the Unix epoch so
    // Promtail can stamp the real chat time on ingest.
    File fh = OpenFile(path, "a");
    if (fh != null)
    {
        bool team = StrEqual(command, "say_team", false);
        fh.WriteLine("%d %s %s: %s", GetTime(), team ? "(team)" : "(all)", name, msg);
        delete fh;
    }

    return Plugin_Continue; // never block chat
}
