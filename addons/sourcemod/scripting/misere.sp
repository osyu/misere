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

#define PLUGIN_VERSION "0.2.0"

#define ROUND_TIME 600
#define SETUP_TIME 10
#define MAX_SCORES 3

#define SHRINK_SPEED 2.0
#define SHRINK_MULT 2.0
#define SHRINK_EXP 2000.0

#define NEAR_DIST 800.0

#define ROCKETJ_INDEX 237
#define STICKYJ_INDEX 265

#define SERVER_TAG "misere"
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
Handle g_hRadiusDamage;
Handle g_hApplyOnDamageAliveModifyRules;
Handle g_hSendHudNotification;
// SDK calls
Handle g_hStateTransition;
Handle g_hCancelEurekaTeleport;
Handle g_hAddTag;
Handle g_hRemoveTag;
// Addresses
Address g_pRecalculatingTags;
Address g_pCTFRobotDestructionLogic;
// Offsets
int g_iTakeDamageInfoWeapon;
int g_iTakeDamageInfoDamage;
int g_iWeaponBaseWeaponInfo;
int g_iWeaponDataDamage;

// ConVars
Handle g_hFriendlyFire;
Handle g_hMaxScores;
bool g_bPrevFriendlyFire;
int g_iPrevMaxScores;

// Hud/visual entities
int g_iPDLogic;
int g_iCapFlags[2];
int g_iZoneProps[2];

// Map state
bool g_bMapInInit;
bool g_bInPassTime;
float g_fTickInterval;

// Game state
float g_fRadii[2];
int g_iGoals[2];
float g_vecCenter[3];
int g_iBall;
int g_iCarrier;
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
  g_hRadiusDamage = DHookCreateFromConf(hGameConf, "CTFGameRules::RadiusDamage");
  g_hApplyOnDamageAliveModifyRules = DHookCreateFromConf(hGameConf, "CTFGameRules::ApplyOnDamageAliveModifyRules");
  g_hSendHudNotification = DHookCreateFromConf(hGameConf, "CTFGameRules::SendHudNotification");

  StartPrepSDKCall(SDKCall_GameRules);
  PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "CTeamplayRoundBasedRules::State_Transition");
  PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
  g_hStateTransition = EndPrepSDKCall();

  StartPrepSDKCall(SDKCall_Player);
  PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "CTFPlayer::CancelEurekaTeleport");
  g_hCancelEurekaTeleport = EndPrepSDKCall();

  StartPrepSDKCall(SDKCall_Server);
  PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "CBaseServer::AddTag");
  PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
  g_hAddTag = EndPrepSDKCall();

  StartPrepSDKCall(SDKCall_Server);
  PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "CBaseServer::RemoveTag");
  PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
  g_hRemoveTag = EndPrepSDKCall();

  g_pRecalculatingTags = GameConfGetAddress(hGameConf, "bRecalculatingTags");
  g_pCTFRobotDestructionLogic = GameConfGetAddress(hGameConf, "m_sCTFRobotDestructionLogic");

  g_iTakeDamageInfoWeapon = GameConfGetOffset(hGameConf, "CTakeDamageInfo::m_hWeapon");
  g_iTakeDamageInfoDamage = GameConfGetOffset(hGameConf, "CTakeDamageInfo::m_flDamage");
  g_iWeaponBaseWeaponInfo = GameConfGetOffset(hGameConf, "CTFWeaponBase::m_pWeaponInfo");
  g_iWeaponDataDamage = GameConfGetOffset(hGameConf, "CTFWeaponInfo::m_WeaponData[0]::m_nDamage");

  CloseHandle(hGameConf);

  DHookEnableDetour(g_hCanPlayerPickUpBall, false, CanPlayerPickUpBall_Pre);
  DHookEnableDetour(g_hCanPlayerPickUpBall, true, CanPlayerPickUpBall_Post);
  DHookEnableDetour(g_hValidPassTarget, false, ValidPassTarget_Pre);

  HookEvent("pass_get", Event_PassGet);
  HookEvent("pass_pass_caught", Event_PassCaught);
  HookEvent("pass_ball_stolen", Event_PassStolen);
  HookEvent("pass_free", Event_PassFree);
  HookEvent("pass_score", Event_PassScore);

  HookConVarChange(FindConVar("sv_tags"), OnTagsChanged);
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
    g_fTickInterval = GetTickInterval();

    // Make clients think we're in PD rather than PASS Time so the PD hud is shown
    SendProxy_HookGameRules("m_nGameType", Prop_Int, GameTypeProxy);
    SendProxy_HookGameRules("m_bPlayingRobotDestructionMode", Prop_Int, GameTypeProxy);

    DHookGamerules(g_hSetWinningTeam, false, _, SetWinningTeam_Pre);
    DHookEnableDetour(g_hRadiusDamage, false, RadiusDamage_Pre);
    DHookEnableDetour(g_hApplyOnDamageAliveModifyRules, false, ApplyOnDamageAliveModifyRules_Pre);
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

    float vecBallSpawn[3];
    GetEntPropVector(iBallSpawn, Prop_Send, "m_vecOrigin", vecBallSpawn);

    // Set the map center to where the ball would land after spawning
    TR_TraceRayFilter(vecBallSpawn, {90.0, 0.0, 0.0}, MASK_SOLID_BRUSHONLY, RayType_Infinite, TraceFilter);
    TR_GetEndPosition(g_vecCenter);

    if (g_bMapInInit)
    {
      // Call this so the PD hud & others are shown during the first pregame
      Event_TeamplayRoundStart(INVALID_HANDLE, "", false);
    }
    else
    {
      // The plugin was started late, restart the round
      RestartRound();
    }
  }

  SDKCall(g_bInPassTime ? g_hAddTag : g_hRemoveTag, SERVER_TAG);

  g_bMapInInit = false;
}

//------------------------------------------------------------------------------
public void OnMapEnd()
{
  if (g_bInPassTime)
  {
    DHookDisableDetour(g_hRadiusDamage, false, RadiusDamage_Pre);
    DHookDisableDetour(g_hApplyOnDamageAliveModifyRules, false, ApplyOnDamageAliveModifyRules_Pre);
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

    SDKCall(g_hRemoveTag, SERVER_TAG);
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
// Handle zone scaling behavior.
public void OnGameFrame()
{
  if (g_bInPassTime)
  {
    float fDistance;

    /* If the carrier's distance from the center is greater than their team's
     * zone radius, grow the zone to that distance and notify the carrier. */
    if (g_iCarrier)
    {
      float vecCarrier[3];
      GetClientAbsOrigin(g_iCarrier, vecCarrier);

      fDistance = GetVectorDistance(vecCarrier, g_vecCenter);

      if (fDistance > g_fRadii[g_iCarrierTeam])
      {
        SetZoneRadius(g_iCarrierTeam, fDistance);
        ShowTFHudText(g_iCarrier, "%t", "Leaving zone");
      }
    }

    /* Shrink zones. Speed increases exponentially with radius, and has a
     * multiplier while the zone's team is carrying the ball. */
    if (GameRules_GetRoundState() == RoundState_RoundRunning)
    {
      for (int i = 0; i < 2; i++)
      {
        bool bIsCarrierTeam = g_iCarrier && i == g_iCarrierTeam;

        if (g_fRadii[i] != 0.0 && !(bIsCarrierTeam && g_fRadii[i] == fDistance))
        {
          float fSpeed = SHRINK_SPEED * Exponential(g_fRadii[i] / SHRINK_EXP);
          if (bIsCarrierTeam)
          {
            fSpeed *= SHRINK_MULT;
          }

          float fRadius = g_fRadii[i] - fSpeed * g_fTickInterval;
          float fMin = bIsCarrierTeam ? fDistance : 0.0;

          SetZoneRadius(i, (fRadius > fMin) ? fRadius : fMin);
        }
      }
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
  static bool bCVarSet;

  if (!bCVarSet)
  {
    bCVarSet = true;
    SetConVarString(hConVar, sOld);
    bCVarSet = false;
  }
}

//------------------------------------------------------------------------------
/* Enforce the custom server tag's inclusion/exclusion, depending on whether or
 * not we are in PASS Time. This is done the first time bRecalculatingTags is
 * true to avoid CBaseServer::RecalculateTags being called twice, which would
 * break alphabetical tag sorting in most cases. */
void OnTagsChanged(Handle hConVar, const char[] sOld, const char[] sNew)
{
  static bool bTagSet;

  if (LoadFromAddress(g_pRecalculatingTags, NumberType_Int8))
  {
    if (!bTagSet)
    {
      bTagSet = true;
      SDKCall(g_bInPassTime ? g_hAddTag : g_hRemoveTag, SERVER_TAG);
    }
  }
  else
  {
    bTagSet = false;
  }
}

//------------------------------------------------------------------------------
// Prevent the carrier from starting a taunt, and show them a hud notification.
Action Command_Taunt(int iClient, const char[] sCommand, int iArgc)
{
  if (iClient == g_iCarrier)
  {
    ShowTFHudText(g_iCarrier, "#TF_Passtime_No_Taunt");
    return Plugin_Handled;
  }

  return Plugin_Continue;
}

//------------------------------------------------------------------------------
/* Prevent players from suiciding or changing class if they are the carrier or
 * near the ball, and show them a suitable hud notification. */
Action Command_Suicide(int iClient, const char[] sCommand, int iArgc)
{
  bool bPrevent;

  if (iClient == g_iCarrier)
  {
    bPrevent = true;
  }
  else if (IsPlayerAlive(iClient))
  {
    int iTarget = GetEntityMoveType(g_iBall) ? g_iBall : g_iCarrier;

    if (iTarget)
    {
      float vecClient[3];
      float vecTarget[3];
      GetClientAbsOrigin(iClient, vecClient);
      GetEntPropVector(iTarget, Prop_Send, "m_vecOrigin", vecTarget);

      float fDistance = GetVectorDistance(vecClient, vecTarget);

      if (fDistance < NEAR_DIST)
      {
        bPrevent = true;
      }
    }
  }

  if (bPrevent)
  {
    ShowTFHudText(iClient, "%t", StrEqual(sCommand, "joinclass") ? "No class" : "No suicide");
    return Plugin_Handled;
  }

  return Plugin_Continue;
}

//------------------------------------------------------------------------------
void Event_TeamplayRoundStart(Handle hEvent, const char[] sName, bool bDontBroadcast)
{
  g_iBall = 0;
  g_iCarrier = 0;
  g_fRadii = {0.0, 0.0};
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

  int iEnt = -1;

  while ((iEnt = FindEntityByClassname(iEnt, "filter_activator_tfteam")) != -1)
  {
    DHookEntity(g_hPassesFilterImpl, false, iEnt, _, PassesFilterImpl_Pre);
  }

  while ((iEnt = FindEntityByClassname(iEnt, "func_respawnroomvisualizer")) != -1)
  {
    RemoveEntity(iEnt);
  }

  while ((iEnt = FindEntityByClassname(iEnt, "func_passtime_no_ball_zone")) != -1)
  {
    RemoveEntity(iEnt);
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

  if (RoundFloat(g_fRadii[0]) < RoundFloat(g_fRadii[1]))
  {
    iWinningTeam = TFTeam_Red;
  }
  else if (RoundFloat(g_fRadii[0]) > RoundFloat(g_fRadii[1]))
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
/* Set damage dealt by jumper weapon projectiles to base damage. This is done
 * here particularly because RadiusDamage is the first function in the chain
 * to have a check & exit for zero damage; later functions down the line like
 * OnTakeDamage won't be called at all unless there is damage present here. */
MRESReturn RadiusDamage_Pre(Handle hParams)
{
  Address pTakeDamageInfo = LoadFromAddress(DHookGetParamAddress(hParams, 1), NumberType_Int32);
  int iWeapon = GetWeaponIndexIfJumper(pTakeDamageInfo);

  if (iWeapon)
  {
    Address pWeapon = GetEntityAddress(iWeapon);
    Address pWeaponInfo = LoadFromAddress(pWeapon + view_as<Address>(g_iWeaponBaseWeaponInfo), NumberType_Int32);
    int iDamage = LoadFromAddress(pWeaponInfo + view_as<Address>(g_iWeaponDataDamage), NumberType_Int32);

    StoreToAddress(pTakeDamageInfo + view_as<Address>(g_iTakeDamageInfoDamage), float(iDamage), NumberType_Int32);
  }

  return MRES_Ignored;
}

//------------------------------------------------------------------------------
/* Set damage dealt by jumper weapon projectiles back to 0. Note that push force
 * is still calculated using the damage value from CTakeDamageInfo that we set
 * earlier, whereas the value returned by this function is used for subtracting
 * health from the victim (the game uses this same flow for normal self damage
 * from jumper weapons). */
MRESReturn ApplyOnDamageAliveModifyRules_Pre(Handle hReturn, Handle hParams)
{
  Address pTakeDamageInfo = DHookGetParamAddress(hParams, 1);

  if (GetWeaponIndexIfJumper(pTakeDamageInfo))
  {
    DHookSetReturn(hReturn, 0.0);
    return MRES_Override;
  }

  return MRES_Ignored;
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
// Set a zone's radius, updating the model scale and PD hud to match.
void SetZoneRadius(int iTeam, float fRadius)
{
  int iRadius = RoundFloat(fRadius);
  int iDelta = iRadius - RoundFloat(g_fRadii[iTeam]);

  g_fRadii[iTeam] = fRadius;

  SetEntPropFloat(g_iZoneProps[iTeam], Prop_Send, "m_flModelScale", fRadius * 2.0);

  if (iDelta)
  {
    SetEntProp(g_iPDLogic, Prop_Send, iTeam ? "m_nBlueScore" : "m_nRedScore", iRadius);

    if (iDelta > 0)
    {
      SendRDPointsChange(iTeam + 2);
    }
  }
}

//------------------------------------------------------------------------------
/* Create a prop_dynamic for a zone. We have to do some weird stuff here...
 *
 * There is a bug which causes scaled props to be drawn at n^2 scale, while the
 * render bounds stay at n scale. Although setting the scale to sqrt(n) *will*
 * make it draw at the correct size, frustrum culling will be broken due to the
 * render bounds being smaller than the drawn model.
 *
 * Fortunately this bug only appears to happen on the root, and child entities
 * aren't affected. As a workaround, we create two props with the same model:
 * - an invisible parent (which is returned here and later scaled) and
 * - a visible child (what we actually see in-game). */
int CreateZoneProp(int iSkin)
{
  int iPropParent = CreateEntityByName("prop_dynamic");
  SetEntityModel(iPropParent, ZONE_MODEL ... ".mdl");
  SetEntPropFloat(iPropParent, Prop_Send, "m_flModelScale", 0.0);
  AddEntityEffects(iPropParent, 32); // EF_NODRAW
  TeleportEntity(iPropParent, g_vecCenter, NULL_VECTOR, NULL_VECTOR);

  int iPropChild = CreateEntityByName("prop_dynamic");
  SetEntityModel(iPropChild, ZONE_MODEL ... ".mdl");
  SetEntProp(iPropChild, Prop_Send, "m_nSkin", iSkin);
  AddEntityEffects(iPropChild, 1 | 16); // EF_BONEMERGE | EF_NOSHADOW
  TeleportEntity(iPropChild, g_vecCenter, NULL_VECTOR, NULL_VECTOR);

  SetVariantString("!activator");
  AcceptEntityInput(iPropChild, "SetParent", iPropParent);

  return iPropParent;
}

//------------------------------------------------------------------------------
// Send message to all clients to play the score change animation on the PD hud.
void SendRDPointsChange(int iTeam)
{
  Handle hMessage = StartMessageAll("RDTeamPointsChanged", USERMSG_RELIABLE);
  BfWriteShort(hMessage, 0);
  BfWriteByte(hMessage, iTeam);
  BfWriteByte(hMessage, 0);
  EndMessage();
}

//------------------------------------------------------------------------------
void ShowTFHudText(int iClient, const char[] sFmt, any ...)
{
  char sMessage[128];
  SetGlobalTransTarget(iClient);
  VFormat(sMessage, sizeof(sMessage), sFmt, 3);

  Handle hMessage = StartMessageOne("HudNotifyCustom", iClient, USERMSG_RELIABLE);
  BfWriteString(hMessage, sMessage);
  BfWriteString(hMessage, "ico_notify_flag_moving_alt");
  BfWriteByte(hMessage, 0);
  EndMessage();
}

//------------------------------------------------------------------------------
/* Restart the round. Used to clean entities when the plugin starts or ends. */
void RestartRound()
{
  RoundState iPrevState = GameRules_GetRoundState();
  SDKCall(g_hStateTransition, RoundState_Preround);

  // If we were in pregame, go back to prevent redundant state transitions
  if (iPrevState == RoundState_Pregame)
  {
    SDKCall(g_hStateTransition, iPrevState);
  }
}

//------------------------------------------------------------------------------
/* Given a CTakeDamageInfo address, return the entity index of the weapon used
 * if it is a jumper weapon; otherwise return 0. */
int GetWeaponIndexIfJumper(Address pTakeDamageInfo)
{
  int hWeapon = LoadFromAddress(pTakeDamageInfo + view_as<Address>(g_iTakeDamageInfoWeapon), NumberType_Int32);

  if (hWeapon != -1)
  {
    int iWeapon = EntRefToEntIndex(hWeapon | (1<<31));
    int iItemIndex = GetEntProp(iWeapon, Prop_Send, "m_iItemDefinitionIndex");

    if (iItemIndex == ROCKETJ_INDEX || iItemIndex == STICKYJ_INDEX)
    {
      return iWeapon;
    }
  }

  return 0;
}

//------------------------------------------------------------------------------
/* Our own criteria for whether players should be allowed to pick up the ball.
 * The game doesn't already check for canteen uber, which is used by both the
 * Phlogistinator taunt and our spawn protection. */
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
Action GameTypeProxy(const char[] sProp, int &iValue, int iElement)
{
  iValue = StrEqual(sProp, "m_nGameType") ? 0 : 1;
  return Plugin_Changed;
}
