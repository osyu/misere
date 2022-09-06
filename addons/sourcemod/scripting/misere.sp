/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

//------------------------------------------------------------------------------
#include <sourcemod>
#include <dhooks>
#include <sdkhooks>
#include <sdktools>
#include <tf2>
#include <tf2_stocks>
#include <sendproxy>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "0.1.0"

#define ROUND_TIME 300
#define SETUP_TIME 10
#define MAX_SCORES 3

#define ZONE_MODEL "models/misere/zone1"

//------------------------------------------------------------------------------
public Plugin myinfo =
{
  name = "[TF2] Misère PASS Time",
  author = "ugng",
  description = "Alternative PASS Time gamemode",
  version = PLUGIN_VERSION,
  url = "https://osyu.sh/"
};

//------------------------------------------------------------------------------
// Virtual hooks
Handle g_hSetWinningTeam;
Handle g_hPassesFilterImpl;
Handle g_hIsAllowedToPickUpFlag;
// Detours
Handle g_hCanPlayerPickUpBall;
Handle g_hValidPassTarget;
Handle g_hSendHudNotification;
// SDK calls
Handle g_hStateTransition;
Handle g_hCancelEurekaTeleport;
// Addresses
Address g_pCTFRobotDestructionLogic;

// ConVars
Handle g_hFriendlyFire;
Handle g_hMaxScores;
bool g_bPrevFriendlyFire;
int g_iPrevMaxScores;
bool g_bCVarReverted;

// Hud/visual entities
int g_iPDLogic;
int g_iCapFlags[2];
int g_iZoneProps[2];

// Map state
bool g_bMapInInit = false;
bool g_bInPassTime = false;

// Game state
int g_iScores[2] = {0, 0};
int g_iGoals[2] = {0, 0};
float g_vCenter[3];
int g_iBall = 0;
int g_iCarrier = 0;
int g_iCarrierTeam;

//------------------------------------------------------------------------------
public void OnPluginStart()
{
  CreateConVar("misere_version", PLUGIN_VERSION, "Misère PASS Time version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

  g_hFriendlyFire = FindConVar("mp_friendlyfire");
  g_hMaxScores = FindConVar("tf_passtime_scores_per_round");

  LoadTranslations("misere.phrases");

  Handle hGameConf = LoadGameConfigFile("misere");

  g_hSetWinningTeam = DHookCreateFromConf(hGameConf, "CTFGameRules::SetWinningTeam");
  g_hPassesFilterImpl = DHookCreateFromConf(hGameConf, "CFilterTFTeam::PassesFilterImpl");
  g_hIsAllowedToPickUpFlag = DHookCreateFromConf(hGameConf, "CTFPlayer::IsAllowedToPickUpFlag");
  g_hCanPlayerPickUpBall = DHookCreateFromConf(hGameConf, "CTFPasstimeLogic::BCanPlayerPickUpBall");
  g_hValidPassTarget = DHookCreateFromConf(hGameConf, "CPasstimeGun::BValidPassTarget");
  g_hSendHudNotification = DHookCreateFromConf(hGameConf, "CTFGameRules::SendHudNotification");

  StartPrepSDKCall(SDKCall_GameRules);
  PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "CTeamplayRoundBasedRules::State_Transition");
  PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
  g_hStateTransition = EndPrepSDKCall();

  StartPrepSDKCall(SDKCall_Player);
  PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "CTFPlayer::CancelEurekaTeleport");
  g_hCancelEurekaTeleport = EndPrepSDKCall();

  g_pCTFRobotDestructionLogic = GameConfGetAddress(hGameConf, "m_sCTFRobotDestructionLogic");

  CloseHandle(hGameConf);

  DHookEnableDetour(g_hCanPlayerPickUpBall, false, CanPlayerPickUpBall_Pre);
  DHookEnableDetour(g_hCanPlayerPickUpBall, true, CanPlayerPickUpBall_Post);
  DHookEnableDetour(g_hValidPassTarget, false, ValidPassTarget_Pre);

  HookEvent("pass_get", Event_PassGet);
  HookEvent("pass_pass_caught", Event_PassCaught);
  HookEvent("pass_ball_stolen", Event_PassStolen);
  HookEvent("pass_free", Event_PassFree);
  HookEvent("pass_score", Event_PassScore);
}

//------------------------------------------------------------------------------
public void OnPluginEnd()
{
  if (g_bInPassTime)
  {
    OnMapEnd();
    RestartRound();
  }
}

//------------------------------------------------------------------------------
public void OnMapInit()
{
  g_bMapInInit = true;
}

//------------------------------------------------------------------------------
public void OnMapStart()
{
  g_bInPassTime = GameRules_GetProp("m_nGameType") == 7;

  if (g_bInPassTime)
  {
    // Make clients think we're in PD rather than PASS Time so the PD hud is shown
    SendProxy_HookGameRules("m_nGameType", Prop_Int, GameTypeProxy);
    SendProxy_HookGameRules("m_bPlayingRobotDestructionMode", Prop_Int, GameTypeProxy);

    DHookGamerules(g_hSetWinningTeam, false, _, SetWinningTeam_Pre);
    DHookEnableDetour(g_hSendHudNotification, false, SendHudNotification_Pre);

    for (int i = 1; i <= MaxClients; i++)
    {
      if (IsClientInGame(i))
      {
        OnClientPutInServer(i);
      }
    }

    HookEvent("teamplay_round_start", Event_TeamplayRoundStart);
    /* We have to do this since OnPassFree isn't called if someone is holding the
     * ball when the round ends (no overtime). */
    HookEvent("teamplay_round_win", Event_PassFree);
    HookEvent("player_spawn", Event_PlayerSpawn);

    AddCommandListener(Command_Taunt, "taunt");
    AddCommandListener(Command_Suicide, "kill");
    AddCommandListener(Command_Suicide, "explode");
    AddCommandListener(Command_Suicide, "joinclass");

    g_bPrevFriendlyFire = GetConVarBool(g_hFriendlyFire);
    SetConVarBool(g_hFriendlyFire, true);

    g_iPrevMaxScores = GetConVarInt(g_hMaxScores);
    SetConVarInt(g_hMaxScores, MAX_SCORES);

    HookConVarChange(g_hFriendlyFire, OnConVarChanged);
    HookConVarChange(g_hMaxScores, OnConVarChanged);

    PrecacheModel(ZONE_MODEL ... ".mdl");
    AddFileToDownloadsTable(ZONE_MODEL ... ".mdl");
    AddFileToDownloadsTable(ZONE_MODEL ... ".dx80.vtx");
    AddFileToDownloadsTable(ZONE_MODEL ... ".dx90.vtx");
    AddFileToDownloadsTable(ZONE_MODEL ... ".sw.vtx");
    AddFileToDownloadsTable(ZONE_MODEL ... ".vvd");

    int iBallSpawn = FindEntityByClassname(-1, "info_passtime_ball_spawn");

    float vBallSpawn[3];
    GetEntPropVector(iBallSpawn, Prop_Send, "m_vecOrigin", vBallSpawn);

    // Set the map center to where the ball would land after spawning
    TR_TraceRayFilter(vBallSpawn, {90.0, 0.0, 0.0}, MASK_SOLID_BRUSHONLY, RayType_Infinite, TraceFilter);
    TR_GetEndPosition(g_vCenter);

    if (g_bMapInInit)
    {
      // Call this so the PD hud & others are shown during the first pregame
      Event_TeamplayRoundStart(INVALID_HANDLE, "", false);
    }
    RestartRound();
  }

  g_bMapInInit = false;
}

//------------------------------------------------------------------------------
public void OnMapEnd()
{
  if (g_bInPassTime)
  {
    DHookDisableDetour(g_hSendHudNotification, false, SendHudNotification_Pre);

    UnhookEvent("teamplay_round_start", Event_TeamplayRoundStart);
    UnhookEvent("teamplay_round_win", Event_PassFree);
    UnhookEvent("player_spawn", Event_PlayerSpawn);

    RemoveCommandListener(Command_Taunt, "taunt");
    RemoveCommandListener(Command_Suicide, "kill");
    RemoveCommandListener(Command_Suicide, "explode");
    RemoveCommandListener(Command_Suicide, "joinclass");

    UnhookConVarChange(g_hFriendlyFire, OnConVarChanged);
    UnhookConVarChange(g_hMaxScores, OnConVarChanged);

    SetConVarBool(g_hFriendlyFire, g_bPrevFriendlyFire);
    SetConVarInt(g_hMaxScores, g_iPrevMaxScores);

    g_bInPassTime = false;
  }
}

//------------------------------------------------------------------------------
public void OnClientPutInServer(int iClient)
{
  if (g_bInPassTime)
  {
    DHookEntity(g_hIsAllowedToPickUpFlag, false, iClient, _, IsAllowedToPickUpFlag_Pre);
  }
}

//------------------------------------------------------------------------------
// Handle zone scoring and model scale.
public void OnGameFrame()
{
  if (g_bInPassTime && g_iCarrier)
  {
    float vCarrier[3];
    GetClientAbsOrigin(g_iCarrier, vCarrier);

    int iDistance = RoundFloat(GetVectorDistance(vCarrier, g_vCenter));

    if (iDistance > g_iScores[g_iCarrierTeam])
    {
      g_iScores[g_iCarrierTeam] = iDistance;

      ShowTFHudText(g_iCarrier, _, 0, "%t", "Leaving zone");

      SetEntPropFloat(g_iZoneProps[g_iCarrierTeam], Prop_Send, "m_flModelScale", iDistance * 2.0);

      SetEntProp(g_iPDLogic, Prop_Send, g_iCarrierTeam ? "m_nBlueScore" : "m_nRedScore", iDistance);
      SendRDPointsChange(g_iCarrierTeam + 2, false);
    }
  }
}

//------------------------------------------------------------------------------
public void OnEntityCreated(int iEnt, const char[] sClassName)
{
  if (g_bInPassTime && !g_iBall && StrEqual(sClassName, "passtime_ball"))
  {
    g_iBall = iEnt;
  }
}

//------------------------------------------------------------------------------
/* Remove the fading uber condition when medigun uber is removed. The game never
 * removes this condition on its own when uber is depleted, and when checking if
 * players can pick up the ball the game also considers it as invulnerability.
 * This causes any player who has been ubered in their current life to be unable
 * to pick up the ball, which we don't want to happen. */
public void TF2_OnConditionRemoved(int iClient, TFCond iCondition)
{
  if (g_bInPassTime && iCondition == TFCond_Ubercharged)
  {
    TF2_RemoveCondition(iClient, TFCond_UberchargeFading);
  }
}

//------------------------------------------------------------------------------
// Prevent ConVars that we changed from getting messed with.
void OnConVarChanged(Handle hConVar, const char[] sOld, const char[] sNew)
{
  if (!g_bCVarReverted)
  {
    g_bCVarReverted = true;
    SetConVarString(hConVar, sOld);
  }
  else
  {
    g_bCVarReverted = false;
  }
}

//------------------------------------------------------------------------------
// Prevent the carrier from starting a taunt, and show them a hud notification.
Action Command_Taunt(int iClient, const char[] iCommand, int iArgc)
{
  if (iClient == g_iCarrier)
  {
    ShowTFHudText(g_iCarrier, _, 0, "#TF_Passtime_No_Taunt");
    return Plugin_Handled;
  }

  return Plugin_Continue;
}

//------------------------------------------------------------------------------
/* Prevent players from suiciding or changing class if they are the carrier or
 * near the ball, and show them a suitable hud notification. */
Action Command_Suicide(int iClient, const char[] iCommand, int iArgc)
{
  bool bJoinClass = StrEqual(iCommand, "joinclass");

  if (iClient == g_iCarrier)
  {
    ShowTFHudText(iClient, _, 0, "%t", bJoinClass ? "No class carry" : "No suicide carry");
    return Plugin_Handled;
  }
  else if (IsPlayerAlive(iClient))
  {
    int iTarget = GetEntityMoveType(g_iBall) ? g_iBall : g_iCarrier;

    if (iTarget)
    {
      float vClient[3];
      float vTarget[3];
      GetClientAbsOrigin(iClient, vClient);
      GetEntPropVector(iTarget, Prop_Send, "m_vecOrigin", vTarget);

      int iDistance = RoundFloat(GetVectorDistance(vClient, vTarget));

      if (iDistance < 800)
      {
        ShowTFHudText(iClient, _, 0, "%t", bJoinClass ? "No class" : "No suicide");
        return Plugin_Handled;
      }
    }
  }

  return Plugin_Continue;
}

//------------------------------------------------------------------------------
void Event_TeamplayRoundStart(Handle hEvent, const char[] sName, bool bDontBroadcast)
{
  g_iBall = 0;
  g_iCarrier = 0;
  g_iScores = {0, 0};
  g_iGoals = {0, 0};

  g_iZoneProps[0] = CreateZoneProp(0);
  g_iZoneProps[1] = CreateZoneProp(1);

  g_iPDLogic = CreateEntityByName("tf_logic_player_destruction");
  /* Null out RD logic global. Prevents various PD logic from running
   * (e.g. players dropping flags when killed). */
  StoreToAddress(g_pCTFRobotDestructionLogic, 0, NumberType_Int32);
  /* We need to set the .res file here because PD logic inherits from RD logic,
   * and as a result the default .res file is for RD and won't work. */
  SetEntPropString(g_iPDLogic, Prop_Send, "m_szResFile", "resource/UI/HudObjectivePlayerDestruction.res");
  SetEntProp(g_iPDLogic, Prop_Send, "m_nMaxPoints", MAX_SCORES);
  SDKHook(g_iPDLogic, SDKHook_Think, PDLogicThink_Pre);

  /* PD "escrow" is counted by the client hud code by iterating over all stolen
   * CCaptureFlags, adding up their point values and attributing them to the
   * previous owner's team. We create two teamed dummy flags here (which have
   * themselves set as the previous owner) to show goals on the hud. */
  for (int i = 0; i < 2; i++)
  {
    g_iCapFlags[i] = CreateEntityByName("item_teamflag");
    SetEntProp(g_iCapFlags[i], Prop_Send, "m_iTeamNum", i + 2);
    SetEntProp(g_iCapFlags[i], Prop_Send, "m_nFlagStatus", 1);
    SetEntPropEnt(g_iCapFlags[i], Prop_Send, "m_hPrevOwner", g_iCapFlags[i]);
    // Needs a model to prevent client console spam
    SetEntityModel(g_iCapFlags[i], "models/empty.mdl");
  }

  int iRoundTimer = FindEntityByClassname(-1, "team_round_timer");
  SetVariantInt(ROUND_TIME);
  AcceptEntityInput(iRoundTimer, "SetMaxTime");
  SetVariantInt(SETUP_TIME);
  AcceptEntityInput(iRoundTimer, "SetSetupTime");

  int iFilterTeam = -1;
  while ((iFilterTeam = FindEntityByClassname(iFilterTeam, "filter_activator_tfteam")) != -1)
  {
    DHookEntity(g_hPassesFilterImpl, false, iFilterTeam, _, PassesFilterImpl_Pre);
  }

  int iBarrier = -1;
  while ((iBarrier = FindEntityByClassname(iBarrier, "func_respawnroomvisualizer")) != -1)
  {
    if (GetEntProp(iBarrier, Prop_Data, "m_bSolid"))
    {
      RemoveEntity(iBarrier);
    }
  }

  int iNoBall = -1;
  while ((iNoBall = FindEntityByClassname(iNoBall, "func_passtime_no_ball_zone")) != -1)
  {
    if (!GetEntProp(iNoBall, Prop_Data, "m_bDisabled"))
    {
      RemoveEntity(iNoBall);
    }
  }
}

//------------------------------------------------------------------------------
// Apply spawn protection (a la Mannpower).
void Event_PlayerSpawn(Handle hEvent, const char[] sName, bool bDontBroadcast)
{
  TF2_AddCondition(GetClientOfUserId(GetEventInt(hEvent, "userid")), TFCond_UberchargedCanteen, 8.0);
}

//------------------------------------------------------------------------------
void Event_PassGet(Handle hEvent, const char[] sName, bool bDontBroadcast)
{
  OnPassCarried(GetEventInt(hEvent, "owner"));
}
void Event_PassCaught(Handle hEvent, const char[] sName, bool bDontBroadcast)
{
  OnPassCarried(GetEventInt(hEvent, "catcher"));
}
void Event_PassStolen(Handle hEvent, const char[] sName, bool bDontBroadcast)
{
  OnPassCarried(GetEventInt(hEvent, "attacker"));
}

//------------------------------------------------------------------------------
void OnPassCarried(int iClient)
{
  g_iCarrier = iClient;
  g_iCarrierTeam = GetClientTeam(g_iCarrier) - 2;
  SetEntProp(g_iPDLogic, Prop_Send, g_iCarrierTeam ? "m_nBlueTargetPoints" : "m_nRedTargetPoints", MAX_SCORES);
}

//------------------------------------------------------------------------------
void Event_PassFree(Handle hEvent, const char[] sName, bool bDontBroadcast)
{
  g_iCarrier = 0;
  SetEntProp(g_iPDLogic, Prop_Send, g_iCarrierTeam ? "m_nBlueTargetPoints" : "m_nRedTargetPoints", 0);
}

//------------------------------------------------------------------------------
void Event_PassScore(Handle hEvent, const char[] sName, bool bDontBroadcast)
{
  g_iGoals[g_iCarrierTeam] += GetEventInt(hEvent, "points");
  SetEntProp(g_iCapFlags[g_iCarrierTeam], Prop_Send, "m_nPointValue", g_iGoals[g_iCarrierTeam]);
}

//------------------------------------------------------------------------------
// Prevent the PD logic entity from thinking (it wreaks havoc with game state).
Action PDLogicThink_Pre(int iEnt)
{
  return Plugin_Handled;
}

//------------------------------------------------------------------------------
// When the round ends, set the winning team based on our scores.
MRESReturn SetWinningTeam_Pre(Handle hParams)
{
  TFTeam iWinningTeam = TFTeam_Unassigned;

  if (g_iScores[0] < g_iScores[1])
  {
    iWinningTeam = TFTeam_Red;
  }
  else if (g_iScores[0] > g_iScores[1])
  {
    iWinningTeam = TFTeam_Blue;
  }
  
  DHookSetParam(hParams, 1, iWinningTeam);
  return MRES_Handled;
}

//------------------------------------------------------------------------------
// Return true for all team filters so players can activate enemy doors.
MRESReturn PassesFilterImpl_Pre(Handle hReturn)
{
  DHookSetReturn(hReturn, true);
  return MRES_Supercede;
}

//------------------------------------------------------------------------------
/* Normally this function checks if the player has a weapon equipped with the
 * cannot_pick_up_intelligence attribute (jumper weapons), but we want those
 * players to be able to pick up the ball here. We also want players to be
 * immune to the ball based on our own criteria, so by superceding this with
 * IsClientImmune's value we kill two birds with one stone. */
MRESReturn IsAllowedToPickUpFlag_Pre(int iClient, Handle hReturn)
{
  DHookSetReturn(hReturn, !IsClientImmune(iClient));
  return MRES_Supercede;
}

//------------------------------------------------------------------------------
/* Stop non-immune players from taunting before the game checks if they can
 * pick up the ball (the carrier cannot taunt). */
MRESReturn CanPlayerPickUpBall_Pre(Handle hReturn, Handle hParams)
{
  int iClient = DHookGetParam(hParams, 1);
  if (TF2_IsPlayerInCondition(iClient, TFCond_Taunting) && !IsClientImmune(iClient))
  {
    TF2_RemoveCondition(iClient, TFCond_Taunting);
    SDKCall(g_hCancelEurekaTeleport, iClient);
  }

  return MRES_Handled;
}

//------------------------------------------------------------------------------
/* Prevent stock cannot-pick-up-ball hud notifications from being sent, since
 * not being able to hold the ball is an advantage. */
MRESReturn CanPlayerPickUpBall_Post(Handle hReturn, Handle hParams)
{
  if (DHookGetParamAddress(hParams, 2))
  {
    DHookSetParamObjectPtrVar(hParams, 2, 0, ObjectValueType_Int, 0);
    return MRES_Handled;
  }

  return MRES_Ignored;
}

//------------------------------------------------------------------------------
// Disable pass targeting (we don't want the ball to chase teammates).
MRESReturn ValidPassTarget_Pre(Handle hReturn, Handle hParams)
{
  if (DHookGetParamAddress(hParams, 3))
  {
    // We need to set this to 0 so we don't get random hud notifications
    DHookSetParamObjectPtrVar(hParams, 3, 0, ObjectValueType_Int, 0);
  }
  DHookSetReturn(hReturn, false);
  return MRES_Supercede;
}

//------------------------------------------------------------------------------
/* Prevent PASS Time how-to hud notifications from being sent, since they
 * explain how to play the original gamemode and we don't want confusion. */
MRESReturn SendHudNotification_Pre(Handle hParams)
{
  if (DHookGetParam(hParams, 2) == 16)
  {
    return MRES_Supercede;
  }

  return MRES_Ignored;
}

//------------------------------------------------------------------------------
// Heresy! Witchcraft! More words!
int CreateZoneProp(int iSkin)
{
  int iPropParent = CreateEntityByName("prop_dynamic");
  SetEntityModel(iPropParent, ZONE_MODEL ... ".mdl");
  SetEntPropFloat(iPropParent, Prop_Send, "m_flModelScale", 0.0);
  AddEntityEffects(iPropParent, 8 | 32); // EF_NOINTERP | EF_NODRAW
  TeleportEntity(iPropParent, g_vCenter, NULL_VECTOR, NULL_VECTOR);

  int iPropChild = CreateEntityByName("prop_dynamic");
  SetEntityModel(iPropChild, ZONE_MODEL ... ".mdl");
  SetEntProp(iPropChild, Prop_Send, "m_nSkin", iSkin);
  AddEntityEffects(iPropChild, 1 | 16); // EF_BONEMERGE | EF_NOSHADOW
  TeleportEntity(iPropChild, g_vCenter, NULL_VECTOR, NULL_VECTOR);

  SetVariantString("!activator");
  AcceptEntityInput(iPropChild, "SetParent", iPropParent);

  return iPropParent;
}

//------------------------------------------------------------------------------
// Send message to all clients to play the score change animation on the PD hud.
void SendRDPointsChange(int iTeam, bool bPositive)
{
  Handle hMessage = StartMessageAll("RDTeamPointsChanged", USERMSG_RELIABLE);
  BfWriteShort(hMessage, bPositive);
  BfWriteByte(hMessage, iTeam);
  BfWriteByte(hMessage, 0);
  EndMessage();
}

//------------------------------------------------------------------------------
void ShowTFHudText(int iClient, char[] sIcon = "ico_notify_flag_moving_alt", int iTeam, char[] sFmt, any ...)
{
  char sMessage[128];
  SetGlobalTransTarget(iClient);
  VFormat(sMessage, sizeof(sMessage), sFmt, 5);

  Handle hMessage = StartMessageOne("HudNotifyCustom", iClient, USERMSG_RELIABLE);
  BfWriteString(hMessage, sMessage);
  BfWriteString(hMessage, sIcon);
  BfWriteByte(hMessage, iTeam);
  EndMessage();
}

//------------------------------------------------------------------------------
/* Restart the round (if the map is not initializing). Used to clean entities
 * when the plugin starts or ends. */
void RestartRound()
{
  if (!g_bMapInInit)
  {
    RoundState iPrevState = GameRules_GetRoundState();
    SDKCall(g_hStateTransition, RoundState_Preround);

    // If we were in pregame, go back to prevent redundant state transitions
    if (iPrevState == RoundState_Pregame)
    {
      SDKCall(g_hStateTransition, iPrevState);
    }
  }
}

//------------------------------------------------------------------------------
/* Our own criteria for whether players should be allowed to pick up the ball.
 * For some reason the game doesn't already check for canteen uber, which is
 * used by the Phlogistinator taunt (and our spawn protection). */
bool IsClientImmune(int iClient)
{
  return (TF2_IsPlayerInCondition(iClient, TFCond_Ubercharged) ||
          TF2_IsPlayerInCondition(iClient, TFCond_UberchargedCanteen));
}

//------------------------------------------------------------------------------
void AddEntityEffects(int iEnt, int iToAdd)
{
  int iEffects = GetEntProp(iEnt, Prop_Send, "m_fEffects");
  SetEntProp(iEnt, Prop_Send, "m_fEffects", iEffects | iToAdd);
}

//------------------------------------------------------------------------------
bool TraceFilter(int iEnt, int iContentsMask)
{
  return GetEntityMoveType(iEnt) == MOVETYPE_NONE;
}

//------------------------------------------------------------------------------
Action GameTypeProxy(const char[] sProp, int &iValue, int iElement, int iClient)
{
  iValue = StrEqual(sProp, "m_nGameType") ? 0 : 1;
  return Plugin_Changed;
}
