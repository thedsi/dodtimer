/*************************************
*                                    *
*           DODTIMER PLUGIN          *
*      by ADRENALINE ARENA KREEDZ    *
*           (c) 2017 TheDSi          *
*                                    *
*************************************/
#define DODTIMER_VERSION "1.0"

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>

enum State_e
{
    S_NewCampaign,
    S_Transition,
    S_RoundNotStarted,
    S_RoundStarted,
    S_SurvivorsFailed,
};

enum TimerMode_e
{
    TM_Off,
    TM_Total,
    TM_Chapter,
};

State_e g_State = S_NewCampaign;
bool g_Transitioned = false;
TimerMode_e g_TimerMode[MAXPLAYERS + 1];
bool g_InRun = false;
bool g_AutoRestart = true;
bool g_PlayerMoved = false;
bool g_InCutScene = false;
bool g_EnablePlayerKeyCheck = false;
Handle g_PanelTimer;

bool g_TimerActive = false;
float g_PrevChaptersTime = 0.0;
float g_PrevTryTime = 0.0; // Current chapter previous try
float g_TimerAddTime = 0.0;
float g_TimerStartTime = 0.0;

#define MAX_CAMPAIGN_MAP_COUNT 10
#define MAX_MAP_NAME_LENGTH 32
int g_MapCount = 0;
char g_MapNames[MAX_CAMPAIGN_MAP_COUNT][MAX_MAP_NAME_LENGTH];
float g_MapTimes[MAX_CAMPAIGN_MAP_COUNT];
float g_MapPureTimes[MAX_CAMPAIGN_MAP_COUNT]; // Not counting failures
int g_MapRestartCount[MAX_CAMPAIGN_MAP_COUNT];

char g_Tag[] = "\x04[d\xC3\xB8d]\x01 ";

ConVar g_VarRun;
ConVar g_VarAutoRestart;

Handle g_ModeCookie;

public Plugin myinfo =
{
    name = "dodtimer",
    author = "TheDSi",
    description = "L4D2 Campaign Timer",
    version = DODTIMER_VERSION,
    url = ""
};

public void OnPluginStart()
{
    HookEvent("map_transition", Evt_MapTransition, EventHookMode_PostNoCopy);
    HookEvent("finale_win", Evt_CampaignFinish, EventHookMode_PostNoCopy);
    HookEvent("round_start", Evt_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("gameinstructor_draw", Evt_CutsceneEnd, EventHookMode_PostNoCopy);
    HookEvent("gameinstructor_nodraw", Evt_CutsceneBegin, EventHookMode_PostNoCopy);
    HookEvent("mission_lost", Evt_MissionLost, EventHookMode_PostNoCopy);
    
    AddCommandListener(PlayerSayCommand, "say");
    AddCommandListener(PlayerSayCommand, "say_team");
    
    RegAdminCmd("dod_run_start", Cmd_RunStart, ADMFLAG_CHANGEMAP, "Start a new Run");
    RegAdminCmd("dod_run_stop", Cmd_RunStop, ADMFLAG_CHANGEMAP, "Stop current Run");
    RegConsoleCmd("dod_time", Cmd_Time, "Show current Run time");
    RegConsoleCmd("dod_mode", Cmd_Mode, "Control timer display");
    
    g_VarRun = CreateConVar("dod_run", "0", "Run mode activated");
    g_VarAutoRestart = CreateConVar("dod_autorestart", "1", "Auto restart the campaign if survivors fail", FCVAR_NOTIFY);
    CreateConVar("dod_version", DODTIMER_VERSION, "Timer plugin version", FCVAR_DONTRECORD | FCVAR_CHEAT);
    
    HookConVarChange(g_VarRun, VarChange);
    HookConVarChange(g_VarAutoRestart, VarChange);
    
    g_ModeCookie = RegClientCookie("DodTimerMode", "", CookieAccess_Private);
    
    AutoExecConfig(true, "dodtimer");
}

public void OnClientCookiesCached(int client)
{
    if(!IsFakeClient(client))
    {
        char str[16];
        GetClientCookie(client, g_ModeCookie, str, sizeof(str));
        if(StrEqual(str, "TM_Off"))
        {
            g_TimerMode[client] = TM_Off;
        }
        else if(StrEqual(str, "TM_Total"))
        {
            g_TimerMode[client] = TM_Total;
        }
        else if(StrEqual(str, "TM_Chapter"))
        {
            g_TimerMode[client] = TM_Chapter;
        }
    }
}

public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
    g_TimerMode[client] = g_InRun ? TM_Total : TM_Off;
    return true;
}

public void OnClientPutInServer(int client)
{
    if(!IsFakeClient(client))
    {
        SDKHook(client, SDKHook_Spawn, PlayerSpawnCallback);
    }
}

public void OnConfigsExecuted()
{
    if(g_Transitioned)
    {
        SetConVarBool(g_VarRun, g_InRun);
        SetConVarBool(g_VarAutoRestart, g_AutoRestart);
        g_Transitioned = false;
    }
}

public Action PlayerSpawnCallback(int entity)
{
    if(g_State == S_RoundStarted && !g_InRun && !g_PlayerMoved)
    {
        SetPlayerMoved();
    }
    return Plugin_Continue;
}

public void VarChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if(!g_Transitioned)
    {
        if(g_InRun != GetConVarBool(g_VarRun))
        {
            g_InRun = !g_InRun;
            if(g_InRun)
            {
                g_State = S_NewCampaign;
                SetConVarBool(FindConVar("mp_restartgame"), true);
            }
            else
            {
                SetPlayerMoved();
            }
        }
        g_AutoRestart = GetConVarBool(g_VarAutoRestart);
    }
}

public Action Cmd_RunStart(int client, int args)
{
    if(!g_InRun)
    {
        ReplyToCommand(client, "%sStarting new Run...", g_Tag);
        SetConVarBool(g_VarRun, true);
    }
    return Plugin_Handled;
}

public Action Cmd_RunStop(int client, int args)
{
    if(g_InRun)
    {
        ReplyToCommand(client, "%sStopping a run...", g_Tag);
        SetConVarBool(g_VarRun, false);
    }
    return Plugin_Handled;
}

public Action Cmd_Time(int client, int args)
{
    PrintTimeToClient(client, GetCmdReplySource());
    return Plugin_Handled;
}

void SetTimerMode(int client, TimerMode_e mode)
{
    if(mode == TM_Off)
    {
        SetClientCookie(client, g_ModeCookie, "TM_Off");
    }
    else if(mode == TM_Total)
    {
        SetClientCookie(client, g_ModeCookie, "TM_Total");
    }
    else if(mode == TM_Chapter)
    {
        SetClientCookie(client, g_ModeCookie, "TM_Chapter");
    }
    if(g_TimerMode[client] != mode)
    {
        g_TimerMode[client] = mode;
        DisplayTimerPanel(client);
    }
}

void ToggleTimerMode(int client)
{
    SetTimerMode(client, g_TimerMode[client] == TM_Total ? TM_Chapter : TM_Total);
}

public Action Cmd_Mode(int client, int args)
{
    char str[8];
    GetCmdArg(1, str, sizeof(str));
    if(StrEqual(str, "off", false))
    {
        SetTimerMode(client, TM_Off);
    }
    else if(StrEqual(str, "on", false))
    {
        SetTimerMode(client, TM_Total);
    }
    else if(StrEqual(str, "chapter", false))
    {
        SetTimerMode(client, TM_Chapter);
    }
    else if(StrEqual(str, "toggle", false))
    {
        ToggleTimerMode(client);
    }
    else
    {
        ReplyToCommand(client, "Syntax: dod_mode <on|off|chapter|toggle>");
    }
    return Plugin_Handled;
}

void PrintTimeToClient(int client, ReplySource src)
{
    ReplySource oldSrc = SetCmdReplySource(src);
    float curTime = GetTimerValue();
    char timeStr[16];
    for(int i = 0; i < g_MapCount; ++i)
    {
        TimeToString(g_MapTimes[i], timeStr, sizeof(timeStr), true);
        ReplyToCommand(client, "%s%s: \x04%s\x01.", g_Tag, g_MapNames[i], timeStr);
    }
    if(g_State == S_RoundStarted)
    {
        char mapName[MAX_MAP_NAME_LENGTH];
        GetCurrentMap(mapName, sizeof(mapName));
        TimeToString(curTime - g_PrevChaptersTime, timeStr, sizeof(timeStr), true);
        ReplyToCommand(client, "%s%s: \x04%s\x01 (Current).", g_Tag, mapName, timeStr);
    }
    TimeToString(curTime, timeStr, sizeof(timeStr), true);
    ReplyToCommand(client, "%sTotal: \x04%s\x01", g_Tag, timeStr);
    if(!g_InRun)
    {
        ReplyToCommand(client, "%sNote: not in Run mode!", g_Tag);
    }
    SetCmdReplySource(oldSrc);
}

public Action PlayerSayCommand(int client, const char[] command, int argc)
{
    char msg[8];
    GetCmdArg(1, msg, sizeof(msg));
    if(StrEqual(msg, "time", false))
    {       
        PrintTimeToClient(client, SM_REPLY_TO_CHAT);
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

public Action PanelTimerCallback(Handle timer)
{
    for(int i = 1; i <= MaxClients; ++i)
    {
        if(IsClientInGame(i) && !IsFakeClient(i))
        {
            DisplayTimerPanel(i);
        }
    }
    return Plugin_Continue;
}

void TimerReset()
{    
    g_TimerAddTime = 0.0;
    g_TimerActive = false;
}

public void OnMapStart()
{
    g_PanelTimer = CreateTimer(1.0, PanelTimerCallback, 0, TIMER_REPEAT);
}

public void OnMapEnd()
{
    KillTimer(g_PanelTimer);
    if(g_InRun && !g_PlayerMoved && !g_InCutScene)
    {
        FreezeBots(false);
    }
    if(g_State != S_Transition)
    {
        g_State = S_NewCampaign;
    }
}

void PlayerPressedKey(int client)
{
    if(!g_PlayerMoved && g_State == S_RoundStarted && !g_InCutScene && g_EnablePlayerKeyCheck)
    {
        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));
        PrintToChatAll("%s%s has started the timer", g_Tag, name);
        SetPlayerMoved();
    }
}

void SetPlayerMoved()
{
    if(!g_PlayerMoved)
    {
        g_PlayerMoved = true;
        if(!g_InCutScene)
        {
            if(g_InRun)
            {
                FreezeBots(false);
            }
            TimerEnable(true);
        }
    }
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if(buttons != 0 && !IsFakeClient(client))
    {
        PlayerPressedKey(client);
    }
    return Plugin_Continue;
}

void FreezeBots(bool freeze)
{
    SetConVarBool(FindConVar("nb_stop"), freeze);
}

public int TimerPanelHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_Select)
    {
        if(param2 >= 1 && param2 <= 5)
        {
            int weapon = GetPlayerWeaponSlot(param1, param2 - 1);
            if(weapon != -1)
            {
                char className[32];
                if(GetEntityClassname(weapon, className, sizeof(className)))
                {
                    FakeClientCommand(param1, "use %s", className);
                    PlayerPressedKey(param1);
                }
            }
        }
        else
        {
            ToggleTimerMode(param1);
        }
        DisplayTimerPanel(param1);
    }
}

void DisplayTimerPanel(int client)
{
    if(g_TimerMode[client] != TM_Off)
    {
        char prefix[4] = "";
        float time = GetTimerValue();
        if(g_TimerMode[client] == TM_Chapter)
        {
            strcopy(prefix, sizeof(prefix), "Ch ");
            time -= g_PrevChaptersTime;
        }
        char timeStr[16];
        TimeToString(time, timeStr, sizeof(timeStr), false);
        
        char str[32];
        Format(str, sizeof(str), "%s%s", prefix, timeStr);
        if(!g_InRun)
            StrCat(str, sizeof(str), " (Not in Run)");
        
        Panel panel = new Panel();
        panel.SetTitle(str);
        panel.SetKeys(-1);
        panel.Send(client, TimerPanelHandler, 2);
        delete panel;
    }
}

void TimeToString(float ftime, char[] str, int strsize, bool canonical)
{
    int inttime = RoundToNearest(ftime);
    int hr = inttime / 3600;
    int min = inttime % 3600 / 60;
    int sec = inttime % 60;
    if(hr == 0 && !canonical)
    {
        Format(str, strsize, "%02i:%02i", min, sec);
    }
    else
    {
        Format(str, strsize, "%i:%02i:%02i", hr, min, sec);
    }
}

void FinishMap(bool print)
{
    TimerEnable(false);
    GetCurrentMap(g_MapNames[g_MapCount], MAX_MAP_NAME_LENGTH);
    g_MapTimes[g_MapCount] = GetTimerValue() - g_PrevChaptersTime;
    if(print)
    {
        char mapTimeStr[16];
        TimeToString(g_MapTimes[g_MapCount], mapTimeStr, sizeof(mapTimeStr), true);
        PrintToChatAll("%sMap %s finished in %s.", g_Tag, g_MapNames[g_MapCount], mapTimeStr);
    }
    g_MapCount++;
}

public void Evt_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
    FinishMap(true);
    if(g_State == S_RoundStarted)
    {
        g_State = S_Transition;
    }
}

public void Evt_CampaignFinish(Event event, const char[] name, bool dontBroadcast)
{
    FinishMap(false);
    if(g_State == S_RoundStarted)
    {
        g_State = S_NewCampaign;
    }
    PrintToChatAll("%sCampaign finished!", g_Tag);
    for(int i = 1; i <= MaxClients; ++i)
    {
        if(IsClientInGame(i) && !IsFakeClient(i))
        {
            PrintTimeToClient(i, SM_REPLY_TO_CHAT);
        }
    }
}

void EnablePlayerKeyCheck(bool data)
{
    g_EnablePlayerKeyCheck = data;
}

public void Evt_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_InCutScene = false;
    g_PlayerMoved = false;
    g_EnablePlayerKeyCheck = false;
    for(;;)
    {
        switch(g_State)
        {
            case S_NewCampaign:
            {
                TimerReset();
                if(g_InRun)
                {
                    for(int i = 1; i <= MaxClients; ++i)
                    {
                        if(IsClientInGame(i) && !IsFakeClient(i))
                        {
                            SetTimerMode(i, TM_Total);
                        }
                    }
                }
                g_PrevTryTime = 0.0;
                g_PrevChaptersTime = 0.0;
                g_MapCount = 0;
                g_State = S_RoundNotStarted;
                g_Transitioned = false;
                continue;
            }
            case S_Transition:
            {
                g_PrevTryTime = 0.0;
                g_PrevChaptersTime = GetTimerValue();
                g_State = S_RoundNotStarted;
                g_Transitioned = true;
                continue;
            }
            case S_RoundNotStarted:
            {
                if(g_InRun)
                {
                    FreezeBots(true);
                    RequestFrame(EnablePlayerKeyCheck, true);
                }
                else
                {
                    for(int i = 1; i <= MaxClients; ++i)
                    {
                        if(IsClientInGame(i) && !IsFakeClient(i))
                        {
                            SetPlayerMoved();
                            break;
                        }
                    } 
                }
                g_State = S_RoundStarted;
            }
            case S_RoundStarted:
            {
                // User has restarted campaign on first chapter
                g_State = S_NewCampaign;
                continue;
            }
            case S_SurvivorsFailed:
            {
                if(g_InRun && g_AutoRestart)
                {
                    g_State = S_NewCampaign;
                    SetConVarBool(FindConVar("mp_restartgame"), true);
                }
                else
                {
                    g_State = S_RoundNotStarted;
                    g_PrevTryTime = GetTimerValue() - g_PrevChaptersTime;
                    continue;
                }
            }
        }
        break;
    }
}

void TimerEnable(bool enable)
{
    if(!enable && g_TimerActive)
    {
        g_TimerAddTime += GetEngineTime() - g_TimerStartTime;
        g_TimerActive = false;
    }
    else if(enable && !g_TimerActive)
    {
        g_TimerStartTime = GetEngineTime();
        g_TimerActive = true;
    }
}

float GetTimerValue()
{
    return g_TimerActive ? (g_TimerAddTime + GetEngineTime() - g_TimerStartTime) : g_TimerAddTime;
}

void EnterCutScene(bool inCutScene)
{
    if(g_InCutScene != inCutScene)
    {
        g_InCutScene = inCutScene;
        if(g_State == S_RoundStarted)
        {
            if(!g_PlayerMoved)
            {
                if(g_InRun)
                {
                    FreezeBots(!inCutScene);
                }
            }
            else
            {
                TimerEnable(!inCutScene);
            }
        }
    }
}

// May fire twice
public void Evt_CutsceneBegin(Event event, const char[] name, bool dontBroadcast)
{
    EnterCutScene(true);
}

public void Evt_CutsceneEnd(Event event, const char[] name, bool dontBroadcast)
{
    EnterCutScene(false);
}

public void Evt_MissionLost(Event event, const char[] name, bool dontBroadcast)
{
    TimerEnable(false);
    if(g_State == S_RoundStarted)
    {
        if(g_InRun && g_AutoRestart)
        {
            PrintToChatAll("%sCampaign will be restarted", g_Tag);
        }
        g_State = S_SurvivorsFailed;
    }
}
