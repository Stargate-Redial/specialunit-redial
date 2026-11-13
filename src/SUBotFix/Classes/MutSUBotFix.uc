// SUBotFix - server-side bot fixes for Special Unit.
// Keep this package OUT of ServerPackages: nothing here is replicated, clients never need it.
//
// Fix 1 (objectives lost after warmup): SU's 15 s warmup ends with SUGameInfo calling
//   Reset() on every actor except Controllers/TeamInfo. SquadAI.Reset() clears
//   SquadObjective and nothing reassigns it (TeamAI.ReAssessStrategy only handles the
//   freelance squad), so attack/defend squads wander for the whole round.
// Fix 2 (objectives with no path): several objectives have no ReachSpec at all (Abydos wall,
//   Chulak generator computer...) or sit in a part of the network a team cannot reach.
//   We precompute, per team, an "approach point": the nearest reachable NavigationPoint
//   with line of sight to the objective. SUBotSquadAI routes bots there instead of wandering.
// Fix 3 (stranded spawns): some spawn areas have no path out (Goa'uld Hatak on Abydos):
//   humans leave through the rings, bots cannot plan through them. Bots spawning there are
//   put on the ring pad and the rings are activated for them.
// Fix 4 (unreachable defense scripts): see SUBotSquadAI.CheckSquadObjectives (SU-Chulak).
// Fix 5 (paths too small for SU pawns): see FixSpecSizes.
// Fix 6 (bots frozen after completing an objective, or stuck in place): see UnstickBots.
// Fix 7 (map rotation), Fix 8 (objectives no shot can hit), Fix 9 (truncated navigation list,
//   SU-Asgard[Medium]): see PostBeginPlay, FixShootableObjectives, RelinkOrphans.
class MutSUBotFix extends Mutator
    config;

var() config bool  bLogFixes;
var() config float ApproachRadius;     // max distance between an objective and its approach point
var() config float EscapeDelay;        // seconds a stranded bot waits before using the rings
var() config float RingEscapeRadius;   // rings farther than this from a stranded spawn are not its exit
var() config float FastForwardDist;    // walking route from a stranded spawn longer than this: a vehicle trip
var() config float FarSpawnDist;       // a spawn whose walk to the front is longer than this is hopped (fix 28)
var() config float FrontDistance;      // ... the bot then starts this far (route length) from the objective
var() config float DefenderSpawnDist;  // fix 37: same for a team that only defends (0: off)
var() config float DefenderFront;      // ... which then starts this far from what it defends
var() config int   PawnHeight;         // largest SU pawn collision (SUPawnGoa 20x55)
var() config int   PawnRadius;
var() config int   SmallPawnHeight;    // smallest SU pawn (SUPawn 20x50, the Tau'ri)
var() config bool  bNativeSpecTest;    // validate raised specs with the engine's walk test (scout)
var() config float OrphanLinkRadius;  // how far a node may be to be linked to an orphan objective
var() config float GapRadius;          // max length of a link between two islands of the network
var() config int   MaxGapTests;        // budget of island-to-island walk tests at load
var() config int   MaxFloodCells;      // flood-fill budget per goal without waypoints
var() config int   PoolNodes;          // runtime nodes spawned at startup (dog-legs, corridors)
struct CellInfo
{
    var vector Loc;                     // floor point
    var int Parent;
    var byte Drop;                      // reached from Parent by climbing a ledge: the way in is a drop (fix 32)
    var Mover OnMover;                  // the floor here is a mover (a bridge that is only there once triggered, fix 34)
};
var array<CellInfo> Cells;
var array<int> HKeys, HVals;
var int HashSize;
var string StepWhy;
var bool FloodDrops;                    // goal floods (fix 32): a ledge up to MaxDropRise may be climbed, as a one-way drop
var bool StepDrop;                      // the last StepTo was such a ledge
var Actor StepFloor;                    // what the last StepTo stood on
var array<Mover> BridgeMovers;          // remote-triggered movers that are a floor once open (fix 34)
var array<vector> BridgeClosedLoc;

var array<NavigationPoint> GateFrom, GateTo;   // links waiting for their mover to be open (fix 34)
var array<Mover> GateMover;
var array<ReachSpec> GateSpec;         // gated links already made: closed again whenever their mover is (fix 49)
var array<Mover> GateSpecMover;
var array<ReachSpec> BannedSpecs;      // links a bot could not walk, closed for a while (fix 49)
var array<float> BannedUntil;
var() config float LinkBanTime;
var int NumLinkBans;
var array<float> ObjTrigNext;          // next time an objective trigger may be stepped on (fix 49)
var Bot ErrandBot;                     // a bot sent to step on an objective trigger (fix 54), where, until when
var Actor ErrandGoal;
var float ErrandUntil;
var array<Bot> ShooterBots;            // UnstickShooters: since when each bot has not fired / had nothing to do
var array<float> ShooterSince;
var int NumShotMoves, NumGunnerExits;
var array<NavigationPoint> HopFrom, HopTo;   // links a bot had to hop over (fix 52)
var array<Bot> HopBots;                // bots nearly stopped at the start of one, and since when
var array<float> HopSince;
var int NumFastHops;
var() config bool bBotsSprint;         // fix 53: bots sprint to far goals, as players do
var int NumSprints;
var float LastSprintTime;
var() config float HummerEntryDist;    // fix 55: bots get into a Hummer from beside its hull (0: off)
var int NumVehicleEntries;
var int NumSpreadPuts;                 // fix 61: puts moved off another pawn
var int NumExitFixes;                  // fix 62: hop targets moved to a node from which others can be reached
var array<Bot> NoAnchorBots;           // fix 64: bots with no anchor, and since when
var array<float> NoAnchorSince;
var int NumAnchorWalks, NumAnchorPuts, NumAnchorRespawns;
var int NumFactoryHolds;               // fix 65: vehicle spawns held while someone stood on the spot
var() config float HumanMaxBias;       // fix 69: with a human playing, the skill gap of fix 36 is held to this much each way (co-op excepted)
var bool bHumansIn;                    // fix 69: a human plays (checked by BalanceSkills)
var int NumExitAlternates;             // fix 69: hops put next to a taken exit
var() config bool bTestHuman;          // tests only: act as if a human played and saw everything (fixes 54, 69 and 70)
var() config float HopTransitSpeed;    // fix 70: with a human playing, a bot whose team only has hopped spawns stays dead as
                                       // long as a drive at this speed (uu/s) from its spawn to the hop target takes (0: off)
var array<Bot> TransitBots;            // fix 70: dead bots, and when they may respawn
var array<float> TransitUntil;
var int NumTransits;
var float TransitSecs;
var NavigationPoint TransitFrom, TransitTo;  // the spawn and hop target the last TransitTime measured
var() config float PullOutTime;        // fix 71: a fighter about to hit something within this many seconds turns away,
var() config float PullOutDist;        // ... or within this distance, even when it attacks or the obstacle is its target
var() config float PilotStrikeRange;   // fix 71: a fighter flying at an objective it attacks opens fire this close
var() config float PilotStrikeTime;    // ... fires at it for this many seconds (0: no attack runs)
var() config float PilotBreakTime;     // ... then flies off for this many seconds before coming back
var int NumPullOuts, NumStrikes, NumBreaks;
var() config float GuardFighterRange;  // fix 72: defenders of a destroyable objective shoot the enemy fighters this close to it first (0: off)
var int NumGuardShots;
var() config bool bKeepSoleLinks;      // fix 56: a stuck link that is a bot's only way is not closed
var int NumLinkPuts;
var() config float TrappedTime;        // fix 57: a bot with no walk to its team's objectives respawns after this (0: off)
var array<float> FrontRD0, FrontRD1;   // each team's FrontDist from the last ComputeReach
var array<NavigationPoint> FrontNodes; // ... and the nodes they are for
var array<Bot> TrapBots;
var array<float> TrapSince;
var int NumTrapRespawns;
var() config float DriverStuckTime;    // fix 58: a bot whose ground vehicle has not moved DriverStuckDist
var() config float DriverStuckDist;    // in DriverStuckTime gets out (0: off)
var array<Bot> DriveBots;
var array<vector> DriveLoc;
var array<float> DriveSince;
var int NumDriverExits;
var() config bool bDefendersHunt;      // fix 50: defenders go after whoever damages their objective
var array<GameObjective> DmgObj;       // destroyable objectives and their last health seen
var array<int> DmgHealth;
var array<Bot> HuntBots;               // defenders on their way to the shooter, and until when
var array<Pawn> HuntTarget;
var array<float> HuntUntil;
var int NumHunts;
var int NumWideSteps;                   // flood steps found by the foot-wide floor trace (plank bridges)
var array<GameObjective> ObjTrigObj;    // proximity triggers beside objectives that move a remote mover (fix 34)
var array<Trigger> ObjTrigT;
var array<byte> ObjTrigDone;
var() config float MaxDropRise;
var int FloodBudget;                    // cells left for this BridgeGoals pass
var int FloodCap;                       // cells per goal
var array<NavigationPoint> MainNodes;  // main network (BridgeGoals), in a spatial hash
var array<int> MainNext, MainFails, BucketHead;
var array<Mover> DoorMovers;           // proximity doors made non-colliding during the gap tests
var array<byte> DoorBlocksPlayers;
var bool bDoorsLogged;
var int NumNewSpecs;
var array<GameObjective> OrphanRetry;  // orphan objectives to link again later (doors, force fields)
var string WalkWhy;                    // why the last WalkLine failed
var array<SUBotNavNode> NodePool;     // spawned during InitGame (resolvable names), placed on demand
var array<SUBotRingPad> RingPads;     // one per rings actor, spawned during InitGame
var SUBotScout Scout;
var SUBotScoutController ScoutC;
var int NumPlaceFail, NumNativeOnly, NumTraceOnly, NumJumpTrust;

var int AnalyzeStep;                   // load-time analysis steps done (one per timer tick)
var int CountDone;                      // disabled objectives at the last check
var float RebridgeAt;
var array<int> GHead, GNext, GCX, GCY;    // BridgeGaps spatial grid (BuildGapGrid)
var array<NavigationPoint> RefusedFrom, RefusedTo;   // drops the engine walk test refused (BridgeGaps)
var int RebridgeStep;                   // Rebridge step to run at the next timer tick (0: none)
var string TimedWhat;                   // the next Tick logs how long the frame of this work took
var int TimedWall;                      // wall clock (ms) of the frame that did the timed work
var int  Ticks;

// navigation graph (valid only during Analyze, indices are stored in visitedWeight)
var array<NavigationPoint> Nodes;
var array<int>  RevStart, RevCount, RevList;
var array<byte> CanReachAny;            // node can reach at least one objective
var array<byte> TeamReach;              // [team * NumNodes + node]
var array<byte> Mark;
var array<int>  Queue;

struct ObjData
{
    var GameObjective O;
    var byte bUnreachable[2];
    var NavigationPoint Approach[2];
    var int CandStart, CandCount;       // into ObjCand
};
var array<ObjData> Objs;
var array<int> ObjCand;

var array<PlayerStart> StrandedStarts;
var array<NavigationPoint> StrandedExit; // when there are no rings: node of the playable network to hop to
var array<Actor>       StrandedEscape;   // TheRings, or a map's own copy of it (TheRingsTemp on SU-TokRa)

struct EscapeInfo
{
    var Pawn P;
    var Actor R;
    var float Time;
    var int Stage;
    var NavigationPoint Exit;
};
var array<EscapeInfo> Escapes;

var array<string> Notes;                // messages already logged by Note()
var array<Actor> RingFrom, RingTo;      // RingTarget cache for map-embedded rings classes
var bool bBareRefs;                     // object references as bare names (see Ref)

struct TrackInfo
{
    var Bot B;
    var vector Loc;
    var float Since;                    // time the bot was last seen moving
    var int Tries;                      // re-decisions since then
    var Actor Goal;                     // route goal being tracked, best distance to it and since when
    var float GoalDist, GoalSince;
    var int Drops;                      // drop assists toward this goal
};
var array<TrackInfo> Tracks;
var array<Bot> NoPawnBots;             // bots seen alive-state without a pawn, and since when
var array<float> NoPawnSince;
var array<SquadAI> SquadSeen;          // squads and the objective they had (fix 25)
var array<GameObjective> SquadLastObj;
var array<byte> SquadDefends;
var array<Bot> LadderBots;             // bots on a ladder, and since when
var array<float> LadderSince;
var int NumLadderAssists, NumDropAssists, NumMonsterShots, NumCaptures;
var int NumStaffsGiven, NumZatSwitches, NumCampRedecides, NumCloseIns, NumDuels, NumTurretHolds;
var bool bSawWarmup, bRoundTimeDone;    // fix 41
var int MapScore;                       // this map's balance score (fix 36)
var SUBalanceData BalData;              // learned scores, saved in their own ini (SUBotFixBalance.ini)
var string ScoreSource;                // "learned" or "starting score", for the log (fix 54)
var bool bScoreRead, bScoreDone;
var array<Bot> CampBots;               // bots camping far from their squad objective, and since when (fix 31)
var array<float> CampSince;
var() config bool bFightMonsters;       // fix 23 on/off
var() config bool bArmGoauld;           // fix 30 on/off
var() config bool bMapRoundTime;        // fix 41: the map's round time, not TimeLimit, after the warmup
var() config bool bTurretClearShots;    // fix 43: gunners do not fire through their own ship
var() config float CapitalDuelRange;    // fix 42: attacking capital ships fight enemy ones this close first
var() config float PilotObjectiveRange; // fix 40: fighters attack objectives from no farther than this
var() config float PilotAttackDist;    // fix 24: attack points this far out from an objective on an asteroid
var() config float PilotAttackRadius;  // ... and pilots attack once this close to it
var() config float CapitalFightRange;  // fix 38: capital ships close in on targets farther than this
var() config bool bFightOnTheWay;       // fix 23: fire at monsters even on the way to a reachable objective
var() config bool bAutoBalance;         // fix 36: bot skill per team from the map's recent results
var() config bool bBalanceLearn;        // ... and update those results after each round (saved in the ini)
var() config float BalanceStep;         // skill per point of score
var() config int MaxBalanceScore;       // score range: -Max (Tau'ri win) .. +Max (Goa'uld win)
var() config array<string> BalanceScores;   // starting scores ("SU-Chulak=-1"); learned ones go to SUBotFixBalance.ini
var() config string DefaultMapList;     // fix 33: rotation used when [SpecialUnit.SUMapListMission] lists no map
var() config bool bMedicHeal;           // fix 44: medic bots heal hurt teammates with their syringe
var() config int HealBelow;             // ... teammates at or under this health
var() config float HealSeekRange;       // ... in sight, walkable and this close
var() config float DefendPostDist;      // fix 45: defenders farther than this from their post (0: off) ...
var() config float FarEnemyDist;        // ... go back to it, fighting on the way, when their enemy is this far
var int NumPostReturns;
var byte PathsLogged[2];                // the maps' alternate attack routes were logged for this team
var() config bool bFireOnTheMove;       // fix 47: bots on foot fire at enemy players while walking
var() config float MoveFireRange;       // ... within this distance
var int NumMoveShots;
var() config bool bRefillAmmo;          // fix 48: Tau'ri bots short of ammo refill at the maps' ammo crates
var() config float RefillBelow;         // ... when every gun they carry is at or under this share of its ammo
var() config float RefillSeekDist;      // ... and a crate is this close by walk (route length)
var() config float DryRefillDist;       // ... or this close for a bot with no shot left
var array<Actor> Crates;                // the map's AmmoCrates
var bool bCratesListed;
var array<Bot> RefillBots;              // bots on their way to a crate
var array<Actor> RefillCrate;
var array<float> RefillUntil;
var int NumRefillTrips, NumRefills;
var float LastRefillScan;

struct HealInfo
{
    var Bot B;                          // the medic
    var Pawn M;                         // the teammate it heals
    var Weapon S;                       // its syringe (rating raised while in reach)
    var int H0;                         // the teammate's health when the syringe was used
    var float Until, FiredAt;
};
var array<HealInfo> Heals;
var int NumSyringesGiven, NumHealTrips, NumHeals, NumHealHP, NumHealMisses;
var float LastHealScan;

struct FollowInfo
{
    var Bot B;
    var NavigationPoint Route[15];      // the engine's route, after the node the bot loops on
    var int Len, Idx;
    var float Until;
};
var array<FollowInfo> Follows;

struct PilotInfo
{
    var Bot B;
    var SUBotFlyPoint P;                // move target while steering around an obstacle
    var float AvoidUntil;
    var float StrikeSince;              // fix 71: since when it has fired at an objective from where it stands
    var float BreakUntil;               // ... and until when it flies off after that
};
var array<PilotInfo> Pilots;
var int NumAvoid;
var float LastAvoid;
var() config float StuckTime;           // seconds without moving in a movement state
var float LastAnchorFix;

function PostBeginPlay()
{
    local int i;
    local SUBotNavNode P;
    local SUBotRingPad RP;
    local Actor A;
    local vector L, HL, HN;

    Super.PostBeginPlay();
    // Fix 7 (map rotation): SUGameInfo sets MapListType="SUMapListMission" without its package,
    // the class never loads and RestartGame falls back to the next SU-* map alphabetically,
    // ignoring the server's list. With the full name, [SpecialUnit.SUMapListMission] Maps=... works.
    if (Level.Game.MapListType ~= "SUMapListMission")
        Level.Game.MapListType = "SpecialUnit.SUMapListMission";
    for (i = 0; i < PoolNodes; i++)
    {
        P = Spawn(class'SUBotNavNode',,, Location);
        if (P != None)
            NodePool[NodePool.Length] = P;
    }
    foreach AllActors(class'Actor', A)
        if (TheRings(A) != None || A.IsA('TheRingsTemp'))
        {
            L = A.Location;
            if (Trace(HL, HN, A.Location - vect(0,0,250), A.Location + vect(0,0,40), false) != None)
                L = HL + vect(0,0,45);
            RP = Spawn(class'SUBotRingPad',,, L);
            if (RP != None)
            {
                RP.MyRings = A;
                RingPads[RingPads.Length] = RP;
            }
        }
    RelinkOrphans();
    SetTimer(1.0, true);
}

// Fix 63 (bots that killed themselves at once). Stock Bot.FindRoamDest: a bot whose anchor search
// fails jumps at random, and after five such jumps kills itself (Died(self, class'Suicided')). The count
// (NumRandomJumps) belongs to the controller and only goes back to 0 when the bot roams from a valid
// anchor, which defenders on their posts never do: once over 4 it stayed there for the rest of the
// round, and any instant without an anchor (the fall after a spawn hop) killed the bot on the spot.
// SU-Chulak's Goa'uld defenders hopped by the generator died 10-35 times a game that way. The count
// starts again at every spawn and after every put.
function ModifyPlayer(Pawn Other)
{
    if (Other != None && Bot(Other.Controller) != None)
        Bot(Other.Controller).NumRandomJumps = 0;
    Super.ModifyPlayer(Other);
}

// Fix 64 (no anchor, no way back). Resetting the count at each life (fix 63) was not enough: SU-Chulak's
// generator room is full of crates with few nodes, and a defender that stepped off the path to fight
// or stake out ended in a pocket where no anchor could be found, jumped five times and killed itself,
// 17-28 times in some games. The stock suicide is kept from firing (the count is held under 5); a bot
// with no anchor for 4 s walks to the nearest node in sight, or is put there when it cannot walk to it
// and no human sees either place; after 30 s with no anchor, it respawns (logged).
function RescueAnchorless()
{
    local Controller C;
    local Bot B;
    local NavigationPoint N;
    local int i;

    for (i = NoAnchorBots.Length - 1; i >= 0; i--)
        if (NoAnchorBots[i] == None || NoAnchorBots[i].bDeleteMe)
        {
            NoAnchorBots.Remove(i, 1);
            NoAnchorSince.Remove(i, 1);
        }
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None)
            continue;
        if (B.NumRandomJumps > 3)
            B.NumRandomJumps = 3;
        for (i = 0; i < NoAnchorBots.Length && NoAnchorBots[i] != B; i++);
        if (B.Pawn == None || Vehicle(B.Pawn) != None || B.Pawn.Health <= 0 || B.Pawn.Physics == PHYS_Ladder
            || B.Pawn.Anchor != None || Level.TimeSeconds - B.Pawn.FindAnchorFailedTime > 2
            || B.IsInState('Dead') || B.IsInState('GameEnded'))
        {
            if (i < NoAnchorBots.Length)
            {
                NoAnchorBots.Remove(i, 1);
                NoAnchorSince.Remove(i, 1);
            }
            continue;
        }
        if (i == NoAnchorBots.Length)
        {
            NoAnchorBots[i] = B;
            NoAnchorSince[i] = Level.TimeSeconds;
            continue;
        }
        if (Level.TimeSeconds - NoAnchorSince[i] > 30)
        {
            NoAnchorBots.Remove(i, 1);
            NoAnchorSince.Remove(i, 1);
            NumAnchorRespawns++;
            Note("no anchor: " $ B.PlayerReplicationInfo.PlayerName $ " found no node for 30 s at " $ Vec(B.Pawn.Location) $ ", respawns");
            B.Pawn.Suicide();
            continue;
        }
        if (Level.TimeSeconds - NoAnchorSince[i] < 4 || (B.Enemy != None && B.EnemyVisible()))
            continue;
        N = SeenNodeNear(B.Pawn);
        if (N == None)
            continue;
        NoAnchorSince[i] = Level.TimeSeconds - 4 + 3;      // look again in 3 s
        if (B.ActorReachable(N))
        {
            B.MoveTarget = N;
            B.GoalString = "SUBotFix: no anchor, walks to " $ N.Name;
            B.GotoState('Roaming', 'Begin');
            NumAnchorWalks++;
        }
        else if (!HumanSees(B.Pawn.Location) && !HumanSees(N.Location)
            && PutPawn(B.Pawn, N.Location + vect(0,0,1) * (B.Pawn.CollisionHeight - N.CollisionHeight + 4)))
        {
            NumAnchorPuts++;
            Note("no anchor: " $ B.PlayerReplicationInfo.PlayerName $ " put on " $ N.Name $ " from " $ Vec(B.Pawn.Location));
            B.WhatToDoNext(72);
        }
    }
}

// Fix 65 (a new Hummer on top of people). Factory_SUHummer.SpawnVehicle only waits for pawns within
// 1.25 x the Hummer's CollisionRadius, which is 20 (fix 55), so a new Hummer appeared on bots (and
// players) standing by the factory and crushed them (Engine.Gibbed, no killer): 3 bots in 4 SU-IceDet
// games at the Tau'ri spawn. While the build effect plays (the next factory timer spawns the vehicle)
// and someone stands within 300 uu, the spawn waits another second.
function GuardFactories()
{
    local ONSVehicleFactory F;
    local Pawn P;
    local vector D;

    foreach DynamicActors(class'ONSVehicleFactory', F)
    {
        if (!F.bActive || F.bPreSpawn || F.VehicleCount >= F.MaxVehicleCount || F.TimerRate <= 0
            || F.VehicleClass == None || F.VehicleClass.default.CollisionRadius > 100)
            continue;
        foreach F.CollidingActors(class'Pawn', P, 400)
        {
            if (P.Health <= 0 || Vehicle(P) != None)
                continue;
            D = P.Location - F.Location;
            if (Abs(D.Z) > 250)
                continue;
            D.Z = 0;
            if (VSize(D) > 300)
                continue;
            if (F.TimerRate - F.TimerCounter < 1.2)
            {
                F.SetTimer(1.2, false);
                NumFactoryHolds++;
            }
            break;
        }
    }
}

// nearest navigation point with paths within 1000 uu that P can see (eye to the node)
function NavigationPoint SeenNodeNear(Pawn P)
{
    local NavigationPoint N, Best;
    local float D, BestD;

    BestD = 1000;
    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        D = VSize(N.Location - P.Location);
        if (D >= BestD || N.PathList.Length == 0 || N.IsA('SUBotRingPad')
            || !FastTrace(N.Location, P.Location + vect(0,0,1) * P.BaseEyeHeight))
            continue;
        Best = N;
        BestD = D;
    }
    return Best;
}

// Fix 33 (no map list): a server whose [SpecialUnit.SUMapListMission] lists no map warns "has no maps
// configured" at the end of every round and loads SU-Abydos (first alphabetically) again and again. The
// list is filled with the ten SU maps when it is empty; the engine then saves it in the server ini,
// where the admin can edit it.
function bool CheckReplacement(Actor Other, out byte bSuperRelevant)
{
    local string M;

    if (Other.IsA('SUMapListMission') && DefaultMapList != "")
    {
        M = Other.GetPropertyText("Maps");
        if (M == "" || M == "()")
        {
            Other.SetPropertyText("Maps", DefaultMapList);
            if (bLogFixes)
                Log("no map list configured: rotating through " $ Other.GetPropertyText("Maps"), 'SUBotFix');
        }
    }
    return true;
}

function Timer()
{
    local int i, j;
    Ticks++;
    if (AnalyzeStep < 4)
    {
        AnalyzeStep++;      // set first: never retry a failing step every second
        Analyze(AnalyzeStep);
    }
    SetSquadTypes();
    if (bAutoBalance)
        BalanceSkills();
    if (bMapRoundTime)
        RestoreRoundTime();
    if (Level.Game.IsInState('MatchInProgress'))
    {
        if ((Ticks % 2) == 0)
            ReassignObjectives();
        HandleStrandedBots();
        UnstickBots();
        RescueAnchorless();
        GuardFactories();
        if (DriverStuckTime > 0)
            UnstickDrivers();
        if (TrappedTime > 0 && RebridgeAt == 0 && RebridgeStep == 0 && AnalyzeStep >= 4)
            RespawnTrapped();
        else
        {
            TrapBots.Length = 0;
            TrapSince.Length = 0;
        }
        if ((Ticks % 2) == 1)
            SpacePilots();
        if ((Ticks % 10) == 5 && OrphanRetry.Length > 0)
            LinkOrphanObjectives(true);
        i = DoneObjectives();
        if (i != CountDone)
        {
            CountDone = i;
            RebridgeAt = Level.TimeSeconds + 5;
        }
        if (RebridgeAt > 0 && Level.TimeSeconds >= RebridgeAt)
        {
            RebridgeAt = 0;
            RebridgeStep = 1;
        }
        if (ObjTrigT.Length > 0)
            TouchObjectiveTriggers();
        if (GateFrom.Length > 0 || GateSpec.Length > 0)
            GateLinks();
        if (BannedSpecs.Length > 0)
            UnbanLinks();
        if (RebridgeStep > 0)
            Rebridge();
        if ((Ticks % 60) == 0 && bLogFixes && RingPads.Length > 0)
        {
            j = 0;
            for (i = 0; i < RingPads.Length; i++)
                j += RingPads[i].Trips;
            Log("rings: " $ j $ " ring trips by bots so far", 'SUBotFix');
        }
        if ((Ticks % 60) == 25 && bLogFixes && NumMoveShots > 0)
            Log("so far: " $ NumMoveShots $ " shots by bots firing on the move at enemy players", 'SUBotFix');
        if ((Ticks % 60) == 15 && bLogFixes && NumSprints > 0)
            Log("so far: bots started " $ NumSprints $ " sprints", 'SUBotFix');
        if ((Ticks % 60) == 10 && bLogFixes && NumVehicleEntries > 0)
            Log("so far: bots got into a Hummer from beside its hull " $ NumVehicleEntries $ " times", 'SUBotFix');
        if ((Ticks % 60) == 2 && bLogFixes && NumAnchorWalks + NumAnchorPuts + NumAnchorRespawns > 0)
            Log("so far: bots with no anchor walked to a node in sight " $ NumAnchorWalks $ " times, were put on one " $ NumAnchorPuts $ " times, respawned " $ NumAnchorRespawns $ " times", 'SUBotFix');
        if ((Ticks % 60) == 5 && bLogFixes && NumSpreadPuts > 0)
            Log("so far: " $ NumSpreadPuts $ " puts moved off a pawn standing at the spot", 'SUBotFix');
        if ((Ticks % 60) == 20 && bLogFixes && NumRefillTrips > 0)
            Log("so far: Tau'ri bots short of ammo went to a crate " $ NumRefillTrips $ " times and refilled "
                $ NumRefills $ " times", 'SUBotFix');
        if ((Ticks % 60) == 35 && bLogFixes && NumPostReturns > 0)
            Log("so far: " $ NumPostReturns $ " times a defender far from its post went back to it instead of fighting a distant enemy",
                'SUBotFix');
        if ((Ticks % 60) == 40 && bLogFixes && NumSyringesGiven > 0)
            Log("so far: " $ NumSyringesGiven $ " syringes given to medic bots, which went to " $ NumHealTrips $ " hurt teammates, healed " $ NumHeals $ " times ("
                $ NumHealHP $ " health), " $ NumHealMisses $ " syringe shots missed", 'SUBotFix');
        if ((Ticks % 60) == 55 && bLogFixes && NumTurretHolds > 0)
            Log("so far: " $ NumTurretHolds $ " times a gunner aiming through its own ship was turned or held", 'SUBotFix');
        if ((Ticks % 60) == 50 && bLogFixes && NumDuels > 0)
            Log("so far: " $ NumDuels $ " times an attacking capital ship turned on an enemy one", 'SUBotFix');
        if ((Ticks % 60) == 45 && bLogFixes && NumCloseIns > 0)
            Log("so far: " $ NumCloseIns $ " times a pilot shooting an objective from afar was sent closer", 'SUBotFix');
        if ((Ticks % 60) == 17 && bLogFixes && NumGuardShots > 0)
            Log("so far: " $ NumGuardShots $ " times a defender turned on an enemy fighter attacking its objective", 'SUBotFix');
        if ((Ticks % 60) == 7 && bLogFixes && NumPullOuts + NumStrikes > 0)
            Log("so far: fighters pulled out " $ NumPullOuts $ " times just before hitting their target or the ground, opened fire on an objective "
                $ NumStrikes $ " times instead of flying into it, broke off " $ NumBreaks $ " attack runs", 'SUBotFix');
        if ((Ticks % 60) == 12 && bLogFixes && NumTransits > 0)
            Log("so far: " $ NumTransits $ " bots took the drive time from their hopped spawn (" $ int(TransitSecs / NumTransits) $ " s on average)", 'SUBotFix');
        if ((Ticks % 60) == 30 && bLogFixes && (NumStaffsGiven > 0 || NumCampRedecides > 0))
            Log("so far: " $ NumStaffsGiven $ " staffs given to Zat-only Goa'uld bots, " $ NumZatSwitches
                $ " forced switches Zat -> staff, " $ NumCampRedecides $ " re-decisions of bots camping far from their objective",
                'SUBotFix');
    }
}

// Fix 6 (frozen bots): SUTriggeredObjective.TellBotHowToDisable calls UsedBy and returns
// true without giving the bot anything to do, so the bot that completes it stays in a
// latent MoveToward on the (now disabled) objective forever (SU-Chulak). More generally,
// a bot in a movement state that has not moved for StuckTime seconds re-decides.
function UnstickBots()
{
    local Controller C;
    local Bot B;
    local NavigationPoint N;
    local int i;
    local bool bFound;
    local Actor Goal;

    // Fix 14 (bots without a body): when an SU fighter or glider is destroyed, its driver can lose
    // its pawn without PawnDied, so the bot stays in a living state forever and never respawns
    // (SUBot in RestFormation with Pawn=None). Two seconds like that: declare it dead.
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn != None || B.PlayerReplicationInfo == None || B.PlayerReplicationInfo.bOutOfLives
            || B.PlayerReplicationInfo.bOnlySpectator || B.IsInState('Dead') || B.IsInState('GameEnded')
            || B.IsInState('RoundEnded'))
            continue;
        for (i = 0; i < NoPawnBots.Length && NoPawnBots[i] != B; i++);
        if (i == NoPawnBots.Length)
        {
            NoPawnBots[i] = B;
            NoPawnSince[i] = Level.TimeSeconds;
        }
        else if (Level.TimeSeconds - NoPawnSince[i] >= 2)
        {
            Note("bot without a body: " $ B.PlayerReplicationInfo.PlayerName $ " stuck in state " $ B.GetStateName()
                $ ", declared dead so that it respawns");
            NoPawnBots.Remove(i, 1);
            NoPawnSince.Remove(i, 1);
            B.PawnDied(None);
        }
    }
    for (i = NoPawnBots.Length - 1; i >= 0; i--)
        if (NoPawnBots[i] == None || NoPawnBots[i].Pawn != None || NoPawnBots[i].IsInState('Dead'))
        {
            NoPawnBots.Remove(i, 1);
            NoPawnSince.Remove(i, 1);
        }
    for (i = CampBots.Length - 1; i >= 0; i--)
        if (CampBots[i] == None || CampBots[i].Pawn == None || !CampBots[i].IsInState('RestFormation'))
        {
            CampBots.Remove(i, 1);
            CampSince.Remove(i, 1);
        }

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn == None || Vehicle(B.Pawn) != None)
            continue;
        // (only when the disabled objective is where the bot is going: an objective is also a node, and
        // routes pass through done ones. SU-Asgard[Medium]: re-deciding there sent a bot back to the
        // same node of its route every second, and it stood still for 6 minutes)
        if (GameObjective(B.MoveTarget) != None && GameObjective(B.MoveTarget).bDisabled
            && (B.RouteGoal == None || B.RouteGoal == B.MoveTarget || GameObjective(B.RouteGoal) == None
                || GameObjective(B.RouteGoal).bDisabled))
        {
            Note("unstuck " $ B.PlayerReplicationInfo.PlayerName $ " (moving to disabled " $ B.MoveTarget.Name $ ")");
            B.MoveTarget = None;
            B.WhatToDoNext(62);
            continue;
        }
        // Fix 31 (camping far from the objective): when a stage falls, the routes to the next one can
        // fail for a moment (SU-Chulak: Door0 opens as the Goa'uld Computer is done). Bots that ask
        // then get no route, "wander or camp" and stroll in RestFormation, re-deciding only when the
        // stroll ends: Chulak's four Goa'uld defenders walked off for 80 s while the Tau'ri crossed
        // to the generator, which fell without a fight. A bot camping that far from an active
        // objective of its squad, with no enemy in sight, decides again every 4 s.
        if (B.IsInState('RestFormation') && B.Squad != None && PlayerController(B.Squad.SquadLeader) == None
            && B.Squad.SquadObjective != None && !B.Squad.SquadObjective.bDisabled && B.Squad.SquadObjective.bActive
            && (B.Enemy == None || !B.EnemyVisible())
            && VSize(B.Squad.SquadObjective.Location - B.Pawn.Location) > 2500)
        {
            for (i = 0; i < CampBots.Length && CampBots[i] != B; i++);
            if (i == CampBots.Length)
            {
                CampBots[i] = B;
                CampSince[i] = Level.TimeSeconds;
            }
            else if (Level.TimeSeconds - CampSince[i] >= 4)
            {
                CampSince[i] = Level.TimeSeconds;
                NumCampRedecides++;
                Note("camping far from " $ B.Squad.SquadObjective.Name $ ": " $ B.PlayerReplicationInfo.PlayerName
                    $ " decides again");
                B.WhatToDoNext(65);
                continue;
            }
        }
        // Lost anchor (SU-IceDet): a bot pushed off the network (wandering into a corner) finds no
        // anchor, so it has no route to its objective and keeps "wandering or camping" on the
        // spot, although a node it can walk to is right there. Walk it to that node first.
        if (B.Squad != None && B.Squad.SquadObjective != None && B.Pawn.Anchor == None && B.Enemy == None
            && (B.IsInState('RestFormation') || B.IsInState('Roaming')) && Level.TimeSeconds - LastAnchorFix > 0.5
            && InStr(B.GoalString, "Wander") >= 0 && B.FindPathToward(B.Squad.SquadObjective) == None)
        {
            LastAnchorFix = Level.TimeSeconds;
            N = ReachableNodeNear(B);
            if (N != None)
            {
                Note("lost anchor: " $ B.PlayerReplicationInfo.PlayerName $ " walks back to " $ N.Name);
                B.MoveTarget = N;
                B.GotoState('Roaming', 'Begin');
                continue;
            }
        }
        // Anchor loop (SU-IceDet PathNode71): the route handed back starts with the node the bot
        // already stands on, so MoveToward ends at once, WhatToDoNext computes the same route and
        // the bot never moves. Step to the next node of the route instead.
        if (B.MoveTarget != None && B.MoveTarget == B.Pawn.Anchor && B.RouteCache[0] == B.MoveTarget
            && B.RouteCache[1] != None && B.Pawn.ReachedDestination(B.MoveTarget)
            && VSize(B.Pawn.Velocity) < 20 && (B.IsInState('Roaming') || B.IsInState('Fallback'))
            && FollowIndex(B) < 0)
        {
            // the next nodes can be just as bad as anchors (IceDet PathNode70): drive the bot along
            // the whole route the engine computed, instead of one step
            StartFollow(B);
            continue;
        }
        // Ladder tops (SU-Abydos AutoLadder3591 -> PathNode51, a jump off the top): SU pawns climb
        // and then bob at the top of the ladder forever. After 6 s on a ladder, put the bot on the
        // node it heads for, when that node is off the ladder and close.
        if (B.Pawn.Physics == PHYS_Ladder)
        {
            for (i = 0; i < LadderBots.Length && LadderBots[i] != B; i++);
            if (i == LadderBots.Length)
            {
                LadderBots[i] = B;
                LadderSince[i] = Level.TimeSeconds;
            }
            else if (Level.TimeSeconds - LadderSince[i] > 6)
            {
                LadderSince[i] = Level.TimeSeconds;
                N = LadderExit(B);
                if (N != None && !HumanSees(B.Pawn.Location) && !HumanSees(N.Location)
                    && PutPawn(B.Pawn, N.Location + vect(0,0,1) * (B.Pawn.CollisionHeight - N.CollisionHeight + 4)))
                {
                    B.Pawn.SetPhysics(PHYS_Falling);
                    B.Pawn.Velocity = vect(0,0,0);
                    NumLadderAssists++;
                    Note("ladder: " $ B.PlayerReplicationInfo.PlayerName $ " stuck at the top of a ladder, put on " $ N.Name);
                    B.MoveTarget = None;
                    B.WhatToDoNext(64);
                    continue;
                }
            }
        }
        else
            for (i = LadderBots.Length - 1; i >= 0; i--)
                if (LadderBots[i] == B || LadderBots[i] == None)
                {
                    LadderBots.Remove(i, 1);
                    LadderSince.Remove(i, 1);
                }
        bFound = false;
        for (i = 0; i < Tracks.Length; i++)
            if (Tracks[i].B == B)
            {
                bFound = true;
                break;
            }
        if (!bFound)
        {
            i = Tracks.Length;
            Tracks.Length = i + 1;
            Tracks[i].B = B;
            Tracks[i].Loc = B.Pawn.Location;
            Tracks[i].Since = Level.TimeSeconds;
            continue;
        }
        // No progress toward the route goal for 15 s while moving about (SU-IceDet PathNode77 ->
        // PathNode79, a 400 uu drop the map marks as a jump: SU pawns jump and land back on the
        // upper floor, then walk around up there): throw the bot along a ballistic arc that lands
        // on the first node of its route that is well below it; the second time, put it there.
        // (the squad objective is tracked: RouteGoal changes at every re-decision)
        Goal = None;
        if (B.Squad != None)
            Goal = B.Squad.SquadObjective;
        if (Goal != None && Goal == Tracks[i].Goal && (B.Enemy == None || !B.EnemyVisible())
            && (B.IsInState('Roaming') || B.IsInState('Fallback')) && B.Pawn.Physics == PHYS_Walking)
        {
            if (VSize(B.Pawn.Location - Goal.Location) < Tracks[i].GoalDist - 150)
            {
                Tracks[i].GoalDist = VSize(B.Pawn.Location - Goal.Location);
                Tracks[i].GoalSince = Level.TimeSeconds;
            }
            else if (Level.TimeSeconds - Tracks[i].GoalSince > 15)
            {
                Tracks[i].GoalSince = Level.TimeSeconds;
                N = DropTarget(B);
                if (N != None)
                {
                    Tracks[i].Drops++;
                    if (Tracks[i].Drops >= 2 && !HumanSees(B.Pawn.Location) && !HumanSees(N.Location)
                        && PutPawn(B.Pawn, N.Location + vect(0,0,1) * (B.Pawn.CollisionHeight - N.CollisionHeight + 4)))
                        Note("drop: " $ B.PlayerReplicationInfo.PlayerName $ " cannot make the drop to " $ N.Name $ ", put there");
                    else
                    {
                        ThrowTo(B.Pawn, N.Location);
                        Note("drop: " $ B.PlayerReplicationInfo.PlayerName $ " stuck above " $ N.Name $ ", jumps down to it");
                    }
                    NumDropAssists++;
                    continue;
                }
            }
        }
        else if (Goal != Tracks[i].Goal)
        {
            Tracks[i].Goal = Goal;
            Tracks[i].GoalSince = Level.TimeSeconds;
            Tracks[i].Drops = 0;
            if (Goal != None)
                Tracks[i].GoalDist = VSize(B.Pawn.Location - Goal.Location);
        }
        if (VSize(B.Pawn.Location - Tracks[i].Loc) > 64 || !(B.IsInState('Roaming') || B.IsInState('Fallback')))
        {
            Tracks[i].Loc = B.Pawn.Location;
            Tracks[i].Since = Level.TimeSeconds;
            Tracks[i].Tries = 0;
        }
        else if (Level.TimeSeconds - Tracks[i].Since > StuckTime)
        {
            Note("unstuck " $ B.PlayerReplicationInfo.PlayerName $ " (no move for " $ int(StuckTime) $ " s in "
                $ B.GetStateName() $ ", movetarget " $ B.MoveTarget $ ")");
            Tracks[i].Since = Level.TimeSeconds;
            Tracks[i].Tries++;
            // a vehicle it cannot get to (IceDet: 16 bots stuck on their way to a parked Hummer):
            // its team leaves it alone for a minute (fix 52)
            if (Vehicle(B.MoveTarget) != None)
            {
                Vehicle(B.MoveTarget).TeamUseTime = Level.TimeSeconds + 60;
                Vehicle(B.MoveTarget).VehicleLostTime = Level.TimeSeconds + 60;
                Note("unstuck: " $ B.MoveTarget.Name $ " cannot be reached, left alone for 60 s");
            }
            // re-deciding gave the same route: hop over whatever lip holds the pawn, onto the move
            // target when it is close (fix 49: IceDet's walkway from the light bridge, at
            // 13221,1028,-1592, held Tau'ri on SUBotNavNode188 -> 189 in 7 games of 8)
            if (Tracks[i].Tries >= 2 && B.Pawn.Physics == PHYS_Walking)
            {
                N = NavigationPoint(B.MoveTarget);
                if (N != None && Tracks[i].Tries <= 3 && VSize(N.Location - B.Pawn.Location) < 700
                    && Abs(N.Location.Z - B.Pawn.Location.Z) < 200)
                {
                    RememberHop(B, N);
                    ThrowTo(B.Pawn, N.Location);
                    Note("unstuck: " $ B.PlayerReplicationInfo.PlayerName $ " hops onto " $ N.Name);
                }
                else
                {
                    B.Pawn.Velocity = Normal(B.Pawn.Velocity + VRand() * 50) * B.Pawn.GroundSpeed * 0.5;
                    B.Pawn.DoJump(true);
                }
            }
            // still there: the link cannot be walked, close it for a while (fix 49)
            if (Tracks[i].Tries >= 4 && LinkBanTime > 0)
                BanStuckLink(B);
            B.MoveTarget = None;
            B.WhatToDoNext(63);
        }
    }
    for (i = Tracks.Length - 1; i >= 0; i--)
        if (Tracks[i].B == None || Tracks[i].B.bDeleteMe)
            Tracks.Remove(i, 1);
}

// Fix 49 (links nobody can walk). On SU-IceDet two Tau'ri stood 15 minutes on the ledge node
// PathNode54, move target PathNode55, 430 uu away along a link BridgeGaps had added (fix 16): the
// walk tests passed, the pawn did not move. Re-deciding (fix 6) gave the same route and the jump
// (fix 6) did not help. After a third StuckTime, the link from the node the bot stands at to its
// move target gets R_PROSCRIBED for LinkBanTime, for every bot; it opens again afterwards, in case
// it was only blocked for a while (a pawn, a door).
// Fix 56: a link that is the bot's only way to its objective is not closed. On SU-IceDet the
// walkway link SUBotNavNode188 -> 189 (same height, 528 uu; something 40 uu past 188 stops the pawn
// and the hop does not lift it) was closed once or twice a game, and every Tau'ri attacker then had no
// route to the crystal and camped for the 120 s. The bot is put on the link's end instead when no
// human sees either place (as fixes 18 and 21 do), else the link stays open.
function bool BanStuckLink(Bot B)
{
    local NavigationPoint N, T;
    local ReachSpec R;
    local Actor G;
    local int i;

    T = NavigationPoint(B.MoveTarget);
    if (T == None)
        return false;
    G = RouteTarget(B);
    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        if (N == T || VSize(N.Location - B.Pawn.Location) > 200)
            continue;
        for (i = 0; i < N.PathList.Length; i++)
        {
            R = N.PathList[i];
            if (R == None || R.End != T || (R.reachFlags & 128) != 0)
                continue;
            R.reachFlags = R.reachFlags | 128;
            if (bKeepSoleLinks && G != None && B.FindPathToward(G) == None)
            {
                R.reachFlags = R.reachFlags & ~128;
                if (!HumanSees(B.Pawn.Location) && !HumanSees(T.Location)
                    && PutPawn(B.Pawn, T.Location + vect(0,0,1) * (B.Pawn.CollisionHeight - T.CollisionHeight + 4)))
                {
                    NumLinkPuts++;
                    Note("link " $ N.Name $ " -> " $ T.Name $ " is the only way to " $ G.Name $ ": "
                        $ B.PlayerReplicationInfo.PlayerName $ " put across");
                }
                return false;
            }
            BannedSpecs[BannedSpecs.Length] = R;
            BannedUntil[BannedUntil.Length] = Level.TimeSeconds + LinkBanTime;
            NumLinkBans++;
            Note("link " $ N.Name $ " -> " $ T.Name $ " closed for " $ int(LinkBanTime) $ " s: "
                $ B.PlayerReplicationInfo.PlayerName $ " could not walk it");
            return true;
        }
    }
    return false;
}

// Fix 49, continued (SU-IceDet's last stage, every 0.25 s).
// - A bot in RangedAttack on a destroyable objective that has not fired for 8 s cannot hit it from
//   where it stands: a Tau'ri medic stood 400 s by the crystal, guns full, while the rock it sits on
//   took every trace. It walks to the nearest node within 2000 uu of the objective from which an
//   eye-height trace hits the objective itself (ShotReaches), if it has a route there.
// - A bot in the gun seat of a ground vehicle nobody drives, with no enemy in sight for 20 s and its
//   squad objective more than 3000 uu away, gets out: a Hummer's rear gunner sat 400 s on IceDet's
//   ledge path, blocking it. A vehicle driven by a human keeps its bot gunner.
function UnstickShooters()
{
    local Controller C;
    local Bot B;
    local GameObjective O;
    local NavigationPoint N, Best;
    local ONSWeaponPawn G;
    local float D, BestD;
    local int i;

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn == None || B.PlayerReplicationInfo == None)
            continue;
        i = ShooterIndex(B);
        // gunner with no driver
        G = ONSWeaponPawn(B.Pawn);
        if (G != None && G.VehicleBase != None && G.VehicleBase.Driver == None && G.VehicleBase.Physics != PHYS_Flying
            && !G.VehicleBase.IsA('ONSChopperCraft')      // capital ships: never step out into space
            && B.Squad != None && B.Squad.SquadObjective != None
            && VSize(B.Squad.SquadObjective.Location - G.Location) > 3000)
        {
            if (B.Enemy != None && B.EnemyVisible())
                ShooterSince[i] = Level.TimeSeconds;
            else if (Level.TimeSeconds - ShooterSince[i] > 20)
            {
                ShooterSince[i] = Level.TimeSeconds;
                G.KDriverLeave(false);
                NumGunnerExits++;
                Note("gunner " $ B.PlayerReplicationInfo.PlayerName $ " gets out of " $ G.VehicleBase.Name
                    $ " (no driver, nothing to shoot)");
            }
            continue;
        }
        // ranged attack on an objective, no shot fired
        O = GameObjective(B.Target);
        if (Vehicle(B.Pawn) != None || O == None || !O.bProjTarget || O.bDisabled || !B.IsInState('RangedAttack')
            || B.Pawn.Weapon == None || B.Pawn.Weapon.IsFiring())
        {
            ShooterSince[i] = Level.TimeSeconds;
            continue;
        }
        if (Level.TimeSeconds - ShooterSince[i] < 8)
            continue;
        ShooterSince[i] = Level.TimeSeconds;
        Best = None;
        BestD = 1000000;
        for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
        {
            if (VSize(N.Location - O.Location) > 2000 || N.PathList.Length == 0)
                continue;
            D = VSize(N.Location - B.Pawn.Location);
            if (D < 150 || D >= BestD || !ShotReaches(N, O))
                continue;
            if (!B.ActorReachable(N) && B.FindPathToward(N) == None)
                continue;
            Best = N;
            BestD = D;
        }
        if (Best == None)
        {
            Note("shooter " $ B.PlayerReplicationInfo.PlayerName $ " cannot hit " $ O.Name $ " and no node near it can");
            continue;
        }
        NumShotMoves++;
        Note("shooter " $ B.PlayerReplicationInfo.PlayerName $ " cannot hit " $ O.Name $ ", moves to " $ Best.Name
            $ " (" $ int(BestD) $ " uu)");
        B.GoalString = "SUBotFix: move to shoot " $ O.Name $ " from " $ Best.Name;
        if (!B.SetRouteToGoal(Best))
        {
            B.MoveTarget = Best;
            B.SetAttractionState();
        }
    }
}

function int ShooterIndex(Bot B)
{
    local int i;

    for (i = 0; i < ShooterBots.Length; i++)
        if (ShooterBots[i] == B)
            return i;
    for (i = 0; i < ShooterBots.Length; i++)
        if (ShooterBots[i] == None || ShooterBots[i].bDeleteMe)
            break;
    ShooterBots[i] = B;
    ShooterSince[i] = Level.TimeSeconds;
    return i;
}

// Fix 50 (defenders ignored attacks on their objective). Stock DestroyableObjective.TakeDamage
// warns its defense squad (TeamAI.CriticalObjectiveWarning), but SU's SUDestroyableObjective does
// not, and a defender only fights enemies it sees. On SU-IceDet the Goa'uld stood "Near" the crystal
// while Tau'ri shot it from places they could not see, and the Tau'ri won at any bot skill (1:5 at
// score 1, 1:2 at -5). When a destroyable objective loses health, the likely shooter (the enemy
// nearest to it that is firing and sees it, within 8000 uu) is given to up to two defending bots on
// foot with no enemy in sight, within 6000 uu, not led by a human: they walk to it for up to 20 s
// (SUBotSquadAI routes them) and fight it once in sight.
function int ObjHealth(GameObjective O)
{
    if (SUDestroyableObjective(O) != None)
        return SUDestroyableObjective(O).Health;
    if (DestroyableObjective(O) != None)
        return DestroyableObjective(O).Health;
    return -1;
}

function WatchObjectiveDamage()
{
    local GameObjective O;
    local Controller C;
    local Pawn P, Shooter;
    local Bot B, Pick[2];
    local float D, BestD, PickD[2];
    local int i, k, H;

    // drop hunts that are over
    for (i = HuntBots.Length - 1; i >= 0; i--)
        if (HuntBots[i] == None || HuntBots[i].Pawn == None || HuntTarget[i] == None || HuntTarget[i].Health <= 0
            || Level.TimeSeconds > HuntUntil[i])
        {
            HuntBots.Remove(i, 1);
            HuntTarget.Remove(i, 1);
            HuntUntil.Remove(i, 1);
        }
    foreach AllActors(class'GameObjective', O)
    {
        H = ObjHealth(O);
        if (H < 0 || O.bDisabled || !O.bActive)
            continue;
        for (k = 0; k < DmgObj.Length && DmgObj[k] != O; k++);
        if (k == DmgObj.Length)
        {
            DmgObj[k] = O;
            DmgHealth[k] = H;
            continue;
        }
        if (H >= DmgHealth[k])
        {
            DmgHealth[k] = H;
            continue;
        }
        DmgHealth[k] = H;
        // the likely shooter
        Shooter = None;
        BestD = 8000;
        for (C = Level.ControllerList; C != None; C = C.NextController)
        {
            P = C.Pawn;
            if (P == None || P.Health <= 0 || C.PlayerReplicationInfo == None || C.GetTeamNum() == O.DefenderTeamIndex
                || P.Weapon == None || !P.Weapon.IsFiring())
                continue;
            D = VSize(P.Location - O.Location);
            // aiming at it (IceDet's crystal centre is inside its rock: a line to it always fails)
            if (D < BestD && (Normal(O.Location - P.Location) Dot vector(C.GetViewRotation()) > 0.95
                || FastTrace(O.Location, P.Location + vect(0,0,1) * P.BaseEyeHeight)))
            {
                Shooter = P;
                BestD = D;
            }
        }
        if (Shooter == None || Vehicle(Shooter) != None)
        {
            Note("defense: " $ O.Name $ " took damage, no shooter found");
            continue;
        }
        // the two nearest idle defenders
        Pick[0] = None;
        Pick[1] = None;
        PickD[0] = 6000;
        PickD[1] = 6000;
        for (C = Level.ControllerList; C != None; C = C.NextController)
        {
            B = Bot(C);
            if (B == None || B.Pawn == None || Vehicle(B.Pawn) != None || B.GetTeamNum() != O.DefenderTeamIndex
                || (B.Enemy != None && B.EnemyVisible()) || BotTask(B) != '' || B.Squad == None
                || PlayerController(B.Squad.SquadLeader) != None)
                continue;
            D = VSize(B.Pawn.Location - O.Location);
            if (D < PickD[0])
            {
                Pick[1] = Pick[0];
                PickD[1] = PickD[0];
                Pick[0] = B;
                PickD[0] = D;
            }
            else if (D < PickD[1])
            {
                Pick[1] = B;
                PickD[1] = D;
            }
        }
        for (i = 0; i < 2; i++)
        {
            B = Pick[i];
            if (B == None)
                continue;
            HuntBots[HuntBots.Length] = B;
            HuntTarget[HuntTarget.Length] = Shooter;
            HuntUntil[HuntUntil.Length] = Level.TimeSeconds + 20;
            NumHunts++;
            B.Squad.SetEnemy(B, Shooter);
            Note("defense: " $ B.PlayerReplicationInfo.PlayerName $ " goes after " $ Shooter.GetHumanReadableName()
                $ ", who shoots " $ O.Name $ " from " $ int(BestD) $ " uu");
            B.WhatToDoNext(69);
        }
    }
}

function int HuntIndex(Bot B)
{
    local int i;

    for (i = 0; i < HuntBots.Length; i++)
        if (HuntBots[i] == B)
            return i;
    return -1;
}

// The one task that holds a bot, or '' when it is free. Heals (fix 44), ammo trips (48), hunts (50),
// trigger errands (54) and route following (10) each steer the bot; a new task only takes a free bot,
// so two of them never pull the same bot two ways.
function name BotTask(Bot B)
{
    if (B == None)
        return '';
    if (HealIndex(B) >= 0)
        return 'Heal';
    if (RefillIndex(B) >= 0)
        return 'Refill';
    if (HuntIndex(B) >= 0)
        return 'Hunt';
    if (B == ErrandBot)
        return 'Errand';
    if (FollowIndex(B) >= 0)
        return 'Follow';
    return '';
}

// where a bot was sent on an errand (an objective trigger, fix 54), or None
function Actor ErrandGoalFor(Bot B)
{
    if (B == None || B != ErrandBot)
        return None;
    return ErrandGoal;
}

// the shooter a defender is going after (SUBotSquadAI.CheckSquadObjectives), or None
function Pawn HuntTargetFor(Bot B)
{
    local int i;

    i = HuntIndex(B);
    if (i < 0 || HuntTarget[i] == None || HuntTarget[i].Health <= 0)
        return None;
    return HuntTarget[i];
}

// Fix 52 (lips found again by every bot). Fix 49's hop comes after two StuckTimes (20 s), and every
// bot that takes the same link stops there again: IceDet logged 68 stops before SUBotNavNode189 and
// 48 before SUBotNavNode229 in 34 games. A link a bot had to hop over is remembered (the node it
// stood near -> its move target); a bot walking that link that nearly stops within 250 uu of its
// start for 1 s hops at once.
function RememberHop(Bot B, NavigationPoint To)
{
    local NavigationPoint N, From;
    local float D, BestD;
    local int i;

    BestD = 250;
    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        D = VSize(N.Location - B.Pawn.Location);
        if (N != To && D < BestD)
        {
            From = N;
            BestD = D;
        }
    }
    if (From == None)
        return;
    for (i = 0; i < HopTo.Length; i++)
        if (HopTo[i] == To && HopFrom[i] == From)
            return;
    HopFrom[HopFrom.Length] = From;
    HopTo[HopTo.Length] = To;
    Note("hop link remembered: " $ From.Name $ " -> " $ To.Name);
}

function FastHops()
{
    local Controller C;
    local Bot B;
    local NavigationPoint T;
    local int i, k;

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn == None || Vehicle(B.Pawn) != None || B.Pawn.Physics != PHYS_Walking)
            continue;
        T = NavigationPoint(B.MoveTarget);
        if (T == None)
            continue;
        for (k = 0; k < HopTo.Length; k++)
            if (HopTo[k] == T && HopFrom[k] != None && VSize(HopFrom[k].Location - B.Pawn.Location) < 250)
                break;
        for (i = 0; i < HopBots.Length && HopBots[i] != B; i++);
        if (k == HopTo.Length || VSize(B.Pawn.Velocity) > 60)
        {
            if (i < HopBots.Length)
                HopSince[i] = Level.TimeSeconds;
            continue;
        }
        if (i == HopBots.Length)
        {
            HopBots[i] = B;
            HopSince[i] = Level.TimeSeconds;
            continue;
        }
        if (Level.TimeSeconds - HopSince[i] < 1.0)
            continue;
        HopSince[i] = Level.TimeSeconds + 2;    // not again while in the air
        ThrowTo(B.Pawn, T.Location);
        NumFastHops++;
        Note("hop: " $ B.PlayerReplicationInfo.PlayerName $ " hops over the known lip to " $ T.Name);
    }
    for (i = HopBots.Length - 1; i >= 0; i--)
        if (HopBots[i] == None || HopBots[i].bDeleteMe)
        {
            HopBots.Remove(i, 1);
            HopSince.Remove(i, 1);
        }
}

// Fix 53 (bots never sprinted). Tau'ri players sprint: SUPawnTorri.Tick moves a pawn whose
// bIsSprinting is set at 1.6 times its speed while its stamina (levelTired, 0-100) lasts, draining 15
// a second and regaining 5, and it cannot fire meanwhile. Only the player controller ever sets it.
// A Tau'ri bot on foot walking to a goal more than 1500 uu away, with no enemy in sight, no heavy
// weapon out and no Zat stun, sprints (from at least 50 stamina; it stops at 10, as players do).
// Goa'uld players sprint too, paying in health (SUPawnGoa.Tick: 1.6 times the speed while HealthFloat
// is over 20, draining 15 - 2 x RegenValue a second, no regeneration meanwhile), but SUPawnGoa.Tick
// only runs that for players: for a bot it only regenerates. Goa'uld bots get the same sprint here,
// from at least 60 health, stopping at 20 (SprintGoauld).
function SprintBots()
{
    local Controller C;
    local Bot B;
    local SUPawnTorri P;
    local bool bWant;
    local float DT;

    DT = FClamp(Level.TimeSeconds - LastSprintTime, 0, 1);
    LastSprintTime = Level.TimeSeconds;
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None)
            continue;
        if (SUPawnGoa(B.Pawn) != None)
        {
            SprintGoauld(B, SUPawnGoa(B.Pawn), DT);
            continue;
        }
        P = SUPawnTorri(B.Pawn);
        if (P == None)
            continue;
        bWant = P.Health > 0 && P.Physics == PHYS_Walking && (B.IsInState('Roaming') || B.IsInState('Fallback'))
            && (B.Enemy == None || !B.EnemyVisible()) && P.ZatLevel == 0
            && P.WeaponAttachment != None && !P.WeaponAttachment.bHeavy
            && B.RouteGoal != None && VSize(B.RouteGoal.Location - P.Location) > 1500 && HealIndex(B) < 0
            && (P.levelTired > 50 || (P.bIsSprinting && P.levelTired > 10));
        if (bWant != P.bIsSprinting)
        {
            P.SetSprinting(bWant);
            if (bWant)
                NumSprints++;
        }
    }
}

function SprintGoauld(Bot B, SUPawnGoa P, float DT)
{
    local bool bWant;

    bWant = P.Health > 0 && P.Physics == PHYS_Walking && (B.IsInState('Roaming') || B.IsInState('Fallback'))
        && (B.Enemy == None || !B.EnemyVisible()) && P.ZatLevel == 0
        && P.WeaponAttachment != None && !P.WeaponAttachment.bHeavy
        && B.RouteGoal != None && VSize(B.RouteGoal.Location - P.Location) > 1500
        && (P.HealthFloat > 80 || (P.bIsSprinting && P.HealthFloat > 50));   // (players go down to 20; a bot
                                                    // would reach the fight at 15-20 health, fix 54)
    if (bWant)
    {
        if (!P.bIsSprinting)
            NumSprints++;
        P.bIsSprinting = true;
        P.GroundSpeed = P.default.GroundSpeed * 1.6;
        P.bNoWeaponFiring = true;
        // the player's drain, and SU's bot regeneration this frame undone (players get none)
        P.HealthFloat -= DT * (15 - P.default.RegenValue * 2) + DT * P.default.RegenValue;
        if (P.HealthFloat < 20)
            P.HealthFloat = 15;
        P.ChangeHealth(int(P.HealthFloat));
    }
    else if (P.bIsSprinting)
    {
        P.bIsSprinting = false;
        P.GroundSpeed = P.default.GroundSpeed;
        P.bNoWeaponFiring = false;
    }
}

// Fix 55 (bots glued to a Hummer). Stock SquadAI.CheckVehicle lets a bot in when it is within
// its own radius + the vehicle's CollisionRadius + EntryRadius of the seat it takes. SU's Hummer copies
// the Hellbender (an empty one gives a bot the rear gun first, so a second bot drives), but its
// CollisionRadius is 20 where the Hellbender's is 175: the bot had to come within 160 uu of the gun on
// the roof, and the hull stops it farther out. It stood against the vehicle until fix 52 sent it away
// (SU-Chulak about one bot a game, SU-IceDet two). A bot on foot heading for a Hummer now gets in once
// it is beside the hull (300 uu from its centre), into the seat the stock code picks.
function EnterVehicles()
{
    local Controller C;
    local Bot B;
    local Vehicle T, V, VBase;
    local vector D;

    // not during the warmup: its Reset() destroys every vehicle, with the bots inside (fix 55: two
    // bots a game died that way on SU-Chulak at 25 s)
    if (Level.Game.GetPropertyText("ResetCountDown") != "0")
        return;
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn == None || Vehicle(B.Pawn) != None || B.Pawn.Health <= 0
            || B.IsInState('Dead') || B.IsInState('GameEnded'))
            continue;
        T = Vehicle(B.RouteGoal);
        if (T == None)
            T = Vehicle(B.MoveTarget);
        if (T == None)
            continue;
        VBase = T;
        if (T.GetVehicleBase() != None)
            VBase = T.GetVehicleBase();
        if (!VBase.IsA('SUHummer') || VBase.Health <= 0 || VBase.PlayerStartTime > Level.TimeSeconds)
            continue;
        D = VBase.Location - B.Pawn.Location;
        if (Abs(D.Z) > 200)
            continue;
        D.Z = 0;
        if (VSize(D) > HummerEntryDist)
            continue;
        V = T.FindEntryVehicle(B.Pawn);
        if (V == None || V.Driver != None)
        {
            Note("vehicle: " $ B.PlayerReplicationInfo.PlayerName $ " beside " $ VBase.Name $ " for " $ T.Name
                $ ": no free seat (" $ V $ ")");
            continue;
        }
        V.UsedBy(B.Pawn);
        if (Vehicle(B.Pawn) == None)
        {
            Note("vehicle: " $ B.PlayerReplicationInfo.PlayerName $ " could not get into " $ V.Name $ " (crouched "
                $ B.Pawn.bIsCrouched $ ", locked " $ V.bTeamLocked $ " team " $ V.Team $ ", driven by " $ B.Pawn.DrivenVehicle
                $ ", can enter " $ Level.Game.CanEnterVehicle(V, B.Pawn) $ ")");
            continue;
        }
        NumVehicleEntries++;
        Note("vehicle: " $ B.PlayerReplicationInfo.PlayerName $ " got into " $ V.Name $ " beside the hull ("
            $ int(VSize(D)) $ " uu from its centre)");
        if (B.Squad != None)
            B.Squad.BotEnteredVehicle(B);
        B.WhatToDoNext(70);
    }
}

// Fix 58 (Hummers parked for good). SU's Hummer has CollisionRadius 20, so the native pathfinder
// routes it along every foot path; on SU-IceDet drivers followed the ledge path of stage 1 (PathNode64,
// 52, 54, about 6000-6900,-1415) and stuck there, charging a Goa'uld on the ledge above or roaming in
// place, for hundreds of seconds a game (one game: two drivers for most of 30 minutes, the Goa'uld held
// stage 1). A Hummer driver cannot fire. A bot driving a ground vehicle that has not moved
// DriverStuckDist in DriverStuckTime gets out and goes on foot; its team leaves that vehicle alone
// for 30 s. Not when a human rides in it.
function UnstickDrivers()
{
    local Controller C;
    local Bot B;
    local ONSVehicle V;
    local NavigationPoint N;
    local int i, j;
    local bool bHuman;

    for (i = DriveBots.Length - 1; i >= 0; i--)
        if (DriveBots[i] == None || DriveBots[i].bDeleteMe)
        {
            DriveBots.Remove(i, 1);
            DriveLoc.Remove(i, 1);
            DriveSince.Remove(i, 1);
        }
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None)
            continue;
        for (i = 0; i < DriveBots.Length && DriveBots[i] != B; i++);
        V = ONSVehicle(B.Pawn);
        bHuman = false;
        if (V != None)
            for (j = 0; j < V.WeaponPawns.Length; j++)
                if (V.WeaponPawns[j] != None && PlayerController(V.WeaponPawns[j].Controller) != None)
                    bHuman = true;
        if (V == None || V.Health <= 0 || V.Physics == PHYS_Flying || V.IsA('ONSChopperCraft') || V.bStationary || bHuman)
        {
            if (i < DriveBots.Length)
            {
                DriveBots.Remove(i, 1);
                DriveLoc.Remove(i, 1);
                DriveSince.Remove(i, 1);
            }
            continue;
        }
        if (i == DriveBots.Length || VSize(V.Location - DriveLoc[i]) > DriverStuckDist)
        {
            DriveBots[i] = B;
            DriveLoc[i] = V.Location;
            DriveSince[i] = Level.TimeSeconds;
            continue;
        }
        if (Level.TimeSeconds - DriveSince[i] < DriverStuckTime)
            continue;
        DriveSince[i] = Level.TimeSeconds;
        V.VehicleLostTime = Level.TimeSeconds + 30;
        V.TeamUseTime = Level.TimeSeconds + 30;
        V.KDriverLeave(false);
        // no room by the doors (IceDet's ledge path: the stock exit places all failed): out on the
        // nearest node in sight of the vehicle, when no human sees it
        if (Vehicle(B.Pawn) != None)
        {
            N = ExitNode(V);
            if (N == None || HumanSees(V.Location) || HumanSees(N.Location))
            {
                Note("vehicle: " $ B.PlayerReplicationInfo.PlayerName $ " cannot get out of " $ V.Name $ " at "
                    $ Vec(V.Location) $ " (" $ N $ ")");
                continue;
            }
            V.KDriverLeave(true);
            if (B.Pawn == None || Vehicle(B.Pawn) != None)
                continue;
            PutPawn(B.Pawn, N.Location + vect(0,0,1) * (B.Pawn.CollisionHeight - N.CollisionHeight + 4));
            Note("vehicle: " $ B.PlayerReplicationInfo.PlayerName $ " put out of " $ V.Name $ " onto " $ N.Name);
        }
        NumDriverExits++;
        Note("vehicle: " $ B.PlayerReplicationInfo.PlayerName $ " gets out of " $ V.Name $ ", stuck "
            $ int(DriverStuckTime) $ " s at " $ Vec(V.Location) $ " (" $ B.GetStateName() $ ")");
        if (B.Pawn != None)
            B.WhatToDoNext(71);
    }
}

// nearest walkable navigation point within 800 uu in sight of the vehicle, outside its hull
function NavigationPoint ExitNode(Vehicle V)
{
    local NavigationPoint N, Best;
    local float D, BestD;
    local vector Eye;

    Eye = V.Location + vect(0,0,60);
    BestD = 800;
    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        D = VSize(N.Location - V.Location);
        if (D >= BestD || D < 120 || N.PathList.Length == 0 || N.IsA('SUBotFlyPoint') || N.IsA('SUBotRingPad')
            || !FastTrace(N.Location, Eye))
            continue;
        Best = N;
        BestD = D;
    }
    return Best;
}

// Fix 57 (bots trapped where nothing leads out). SU-IceDet's stage 4 (SUTriggeredObjective0) is at
// the bottom of the big cave, reached through a one-way drop (fix 32); once it is done, the Tau'ri
// there have no walk to the crystal and camped in RestFormation until a Goa'uld came down for them
// (about 100 bot-seconds a game, up to 1000 s in one). A player there would type "suicide". A bot on
// foot whose nearest node has no walk to any objective its team goes for (FrontDist), that has no
// route to its squad objective either, with no enemy in sight, for TrappedTime, does the same, as
// long as its team's active spawns do lead to the front. Not in co-op, where lives are counted.
function bool HopPending(Pawn P)
{
    local int j;

    for (j = 0; j < Escapes.Length; j++)
        if (Escapes[j].P == P && P != None)
            return true;
    return false;
}

function RespawnTrapped()
{
    local Controller C;
    local Bot B;
    local NavigationPoint N;
    local PlayerStart P;
    local byte bOK[2];
    local int i, j, t;

    if (Level.Game.GetPropertyText("bReplicator") ~= "True")
        return;
    // does respawning lead anywhere? (an enabled start with a walk to the front, or whose hop does)
    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        P = PlayerStart(N);
        if (P == None || !P.bEnabled || P.TeamNumber < 0 || P.TeamNumber > 1 || bOK[P.TeamNumber] != 0)
            continue;
        t = P.TeamNumber;
        if (FrontOf(t, P) >= 0 && FrontOf(t, P) < 1000000000)
            bOK[t] = 1;
        else
            for (j = 0; j < StrandedStarts.Length; j++)
                if (StrandedStarts[j] == P && (StrandedExit[j] == None
                    || (FrontOf(t, StrandedExit[j]) >= 0 && FrontOf(t, StrandedExit[j]) < 1000000000)))
                    bOK[t] = 1;
    }
    for (i = TrapBots.Length - 1; i >= 0; i--)
        if (TrapBots[i] == None || TrapBots[i].bDeleteMe || TrapBots[i].Pawn == None)
        {
            TrapBots.Remove(i, 1);
            TrapSince.Remove(i, 1);
        }
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None)
            continue;
        for (i = 0; i < TrapBots.Length && TrapBots[i] != B; i++);
        t = B.GetTeamNum();
        // fix 69: a bot waiting for its spawn hop is not trapped (SU-TokRa: with a player by the valley's
        // exit, Goa'uld bots waiting there killed themselves at 20 s, 6 times in 7 minutes)
        if (t < 0 || t > 1 || bOK[t] == 0 || !Trapped(B) || HopPending(B.Pawn))
        {
            if (i < TrapBots.Length)
            {
                TrapBots.Remove(i, 1);
                TrapSince.Remove(i, 1);
            }
            continue;
        }
        if (i == TrapBots.Length)
        {
            TrapBots[i] = B;
            TrapSince[i] = Level.TimeSeconds;
            continue;
        }
        if (Level.TimeSeconds - TrapSince[i] < TrappedTime)
            continue;
        TrapBots.Remove(i, 1);
        TrapSince.Remove(i, 1);
        NumTrapRespawns++;
        Note("trapped: " $ B.PlayerReplicationInfo.PlayerName $ " has had no walk to " $ RouteTarget(B).Name $ " for "
            $ int(TrappedTime) $ " s at " $ Vec(B.Pawn.Location) $ ", respawns");
        B.Pawn.Suicide();
    }
}

function bool Trapped(Bot B)
{
    local NavigationPoint N;
    local Actor G;
    local float F;

    if (B.Pawn == None || Vehicle(B.Pawn) != None || B.Pawn.Health <= 0 || B.Pawn.Physics != PHYS_Walking
        || B.IsInState('Dead') || B.IsInState('GameEnded') || B.PlayerReplicationInfo == None
        || (B.Squad != None && PlayerController(B.Squad.SquadLeader) != None)
        || (B.Enemy != None && B.EnemyVisible()) || BotTask(B) != '' || CarriesCrystal(B.Pawn))
        return false;
    G = RouteTarget(B);
    if (G == None || B.Squad.SquadObjective == None || B.Squad.SquadObjective.bDisabled)
        return false;
    N = ReachableNodeNear(B);
    if (N == None)
        return false;       // off the network: fix 10's lost-anchor walk handles that
    F = FrontOf(B.GetTeamNum(), N);
    if (F < 1000000000)
        return false;       // a walk to the front exists (or nothing is known: -1)
    return B.FindPathToward(G) == None;
}

// Fix 61 (bots put on top of each other). Every put (spawn hops of fixes 3, 28 and 37, ladder and
// drop puts, links put across, drivers put out) went to one point: SU-TokRa's eight Goa'uld valley
// spawns all hop to PathNode80, SU-Chulak's defenders to one node before the computer. A pawn put
// onto another dies (telefrag) and its killer is the one standing there: 38 % of SU-TokRa's deaths
// and 54 % of SU-Chulak's were team kills, bots dying again at every respawn. Put P at L, or at the
// first free place around it (no pawn within 90 uu, in sight of L), 70 then 140 uu out.
function bool PutPawn(Pawn P, vector L)
{
    local vector Try;
    local rotator Dir;
    local int r, i, n;

    for (r = 0; r < 3; r++)
    {
        n = 1;
        if (r > 0)
            n = 8;
        for (i = 0; i < n; i++)
        {
            Try = L;
            if (r > 0)
            {
                Dir.Yaw = i * 8192;
                Try = L + vector(Dir) * (r * 70);
            }
            // a place one can walk to and from L (fix 63: SU-Chulak's generator hop among crates put bots
            // 70 uu off, in pockets from which no node could be reached, and they killed themselves)
            if (r > 0 && (!FastTrace(Try, L) || !WalkLine(Try, L) || !WalkLine(L, Try)))
                continue;
            if (PawnNear(Try, P, 90))
                continue;
            if (P.SetLocation(Try))
            {
                // fix 63: a put pawn falls for a moment and has no anchor; see ModifyPlayer
                if (Bot(P.Controller) != None)
                    Bot(P.Controller).NumRandomJumps = 0;
                if (r > 0)
                    NumSpreadPuts++;
                return true;
            }
        }
    }
    return false;
}

function bool PawnNear(vector L, Pawn Me, float Radius)
{
    local Pawn Q;

    foreach CollidingActors(class'Pawn', Q, Radius + 60, L)
        if (Q != Me && Q.Health > 0 && Q != Me.DrivenVehicle)
            return true;
    return false;
}

// Fix 54 (things a human player should not see). A human within 5000 uu has a line of sight to L.
// Spawn hops wait (up to 15 s) and ladder and drop puts are skipped while one does.
function bool HumanSees(vector L)
{
    local Controller C;

    if (bTestHuman)
        return true;
    for (C = Level.ControllerList; C != None; C = C.NextController)
        if (PlayerController(C) != None && C.Pawn != None && VSize(C.Pawn.Location - L) < 5000
            && FastTrace(L, C.Pawn.Location + vect(0,0,1) * C.Pawn.BaseEyeHeight))
            return true;
    return false;
}

function UnbanLinks()
{
    local int i;

    for (i = BannedSpecs.Length - 1; i >= 0; i--)
        if (Level.TimeSeconds > BannedUntil[i])
        {
            if (BannedSpecs[i] != None)
                BannedSpecs[i].reachFlags = BannedSpecs[i].reachFlags & ~128;
            BannedSpecs.Remove(i, 1);
            BannedUntil.Remove(i, 1);
        }
}

// the end of the next jump or drop on the bot's way: a node Q of its route (move target first) at
// least 150 uu below it and within 900 uu, with a jump or drop spec from a node within 500 uu of the
// bot (it rarely has an anchor where it got stuck)
function NavigationPoint DropTarget(Bot B)
{
    local NavigationPoint P, Q;
    local ReachSpec R;
    local int i, k;

    for (i = -1; i < 15; i++)
    {
        if (i < 0)
            Q = NavigationPoint(B.MoveTarget);
        else
            Q = NavigationPoint(B.RouteCache[i]);
        if (Q == None)
        {
            if (i >= 0)
                break;
            continue;
        }
        if (Q.Location.Z > B.Pawn.Location.Z - 150 || VSize(Q.Location - B.Pawn.Location) > 900)
            continue;
        foreach RadiusActors(class'NavigationPoint', P, 500, B.Pawn.Location)
            for (k = 0; k < P.PathList.Length; k++)
            {
                R = P.PathList[k];
                if (R != None && R.End == Q && ((R.reachFlags & 8) != 0 || R.MaxLandingVelocity > 0)
                    && Q.Location.Z < P.Location.Z - 150)
                    return Q;
            }
    }
    return None;
}

// ballistic launch that lands on Dest, with a jump's rise first (about 100 uu: clears the rail or
// rock that holds the pawn on the upper floor, IceDet's Roche1 between PathNode77 and PathNode79)
function ThrowTo(Pawn P, vector Dest)
{
    local vector D, V;
    local float Horiz, T, G, VZ, Disc;

    D = Dest - P.Location;
    D.Z += P.CollisionHeight - 40;
    Horiz = VSize(D * vect(1,1,0));
    G = -P.PhysicsVolume.Gravity.Z;
    if (G < 100)
        G = 950;
    VZ = 450;
    Disc = VZ * VZ + 2 * G * -D.Z;
    if (Disc < 0)
    {
        VZ = Sqrt(2 * G * D.Z) + 50;
        Disc = VZ * VZ + 2 * G * -D.Z;
    }
    T = (VZ + Sqrt(FMax(0, Disc))) / G;
    V = (D * vect(1,1,0)) / FMax(0.3, T);
    V.Z = VZ;
    P.SetPhysics(PHYS_Falling);
    P.Velocity = V;
    P.Acceleration = vect(0,0,0);
}

// first node of the bot's way that is not on a ladder, within 600 uu
function NavigationPoint LadderExit(Bot B)
{
    local NavigationPoint N;
    local int i;

    N = NavigationPoint(B.MoveTarget);
    for (i = 0; i < 16 && (N == None || Ladder(N) != None); i++)
        N = NavigationPoint(B.RouteCache[i]);
    if (N == None || Ladder(N) != None || VSize(N.Location - B.Pawn.Location) > 600)
        return None;
    return N;
}

// ---------------------------------------------------------------- squads

function SetSquadTypes()
{
    local TeamGame G;
    local int i;

    G = TeamGame(Level.Game);
    if (G == None)
        return;
    for (i = 0; i < 2; i++)
        if (G.Teams[i] != None && G.Teams[i].AI != None && G.Teams[i].AI.SquadType == class'SquadAI')
            G.Teams[i].AI.SquadType = class'SUBotSquadAI';
}

function ReassignObjectives()
{
    local TeamGame G;
    local SquadAI S, NextS;
    local int i;

    G = TeamGame(Level.Game);
    if (G == None)
        return;
    for (i = 0; i < 2; i++)
    {
        if (G.Teams[i] == None || G.Teams[i].AI == None)
            continue;
        for (S = G.Teams[i].AI.Squads; S != None; S = NextS)
        {
            NextS = S.NextSquad;   // FindNewObjectiveFor may merge (destroy) S
            if (S.bDeleteMe || Bot(S.SquadLeader) == None)
                continue;
            if (S.SquadObjective != None)
            {
                RememberSquad(S, i);
                continue;
            }
            // Fix 25: a squad that defended before the warmup reset defends again. FindNewObjectiveFor
            // asks GetOrders(), which says 'Attack' for a squad without objective, so every defense
            // squad became an attack squad wherever its team had something to attack (SU-Abydos,
            // SU-P3X-548, SU-TokRa: 0 defenders, attackers won in 2-3 minutes)
            if (RestoreDefense(S, G.Teams[i].AI, i))
                continue;
            G.Teams[i].AI.FindNewObjectiveFor(S, true);
            if (bLogFixes && S != None && !S.bDeleteMe && S.SquadObjective != None)
                Log("team " $ i $ " squad of " $ S.SquadLeader.GetHumanReadableName() $ " (" $ S.GetOrders()
                    $ ") -> " $ S.SquadObjective.Name, 'SUBotFix');
        }
        PreferReachable(G.Teams[i].AI, i);
    }
}

function RememberSquad(SquadAI S, int Team)
{
    local int k;

    for (k = 0; k < SquadSeen.Length && SquadSeen[k] != S; k++);
    if (k == SquadSeen.Length)
    {
        SquadSeen[k] = S;
        SquadDefends[k] = 0;
    }
    SquadLastObj[k] = S.SquadObjective;
    if (S.SquadObjective.DefenderTeamIndex == Team)
        SquadDefends[k] = 1;
    else
        SquadDefends[k] = 0;
}

function bool RestoreDefense(SquadAI S, TeamAI AI, int Team)
{
    local int k;
    local GameObjective O;

    for (k = 0; k < SquadSeen.Length && SquadSeen[k] != S; k++);
    if (k == SquadSeen.Length || SquadDefends[k] == 0)
        return false;
    O = SquadLastObj[k];
    if (O == None || O.bDisabled || !O.bActive || O.DefenderTeamIndex != Team)
        O = AI.GetLeastDefendedObjective();
    if (O == None)
        return false;
    S.SetObjective(O, true);
    if (O.DefenseSquad == None)
        O.DefenseSquad = S;
    if (bLogFixes)
        Log("team " $ Team $ " squad of " $ S.SquadLeader.GetHumanReadableName() $ " defends " $ O.Name $ " again (after the warmup reset)", 'SUBotFix');
    return true;
}

// Fix 20 (unreachable pick among equals): after SU-IceDet's first stage, four objectives are active
// with the same DefensePriority and TeamAI picks one at random (GetPriorityAttackObjectiveFor). When
// it picked the one sealed in a room bots cannot reach, the attackers waited at their spawn for the
// rest of the round. Attack the reachable one of the highest priority instead.
function PreferReachable(TeamAI AI, int Team)
{
    local GameObjective O, Alt;
    local SquadAI S;

    Alt = None;
    for (O = AI.Objectives; O != None; O = O.NextObjective)
        if (!O.bDisabled && O.bActive && O.DefenderTeamIndex != Team && ObjReachable(O, Team)
            && (Alt == None || O.DefensePriority > Alt.DefensePriority))
            Alt = O;
    if (Alt == None)
        return;
    if (AI.PickedObjective != None && !ObjReachable(AI.PickedObjective, Team) && Alt.DefensePriority >= AI.PickedObjective.DefensePriority)
    {
        Note("team " $ Team $ " attacks " $ Alt.Name $ " instead of " $ AI.PickedObjective.Name $ " (no way to it)");
        AI.PickedObjective = Alt;
    }
    for (S = AI.Squads; S != None; S = S.NextSquad)
    {
        O = S.SquadObjective;
        if (S.bDeleteMe || O == None || O == Alt || O.DefenderTeamIndex == Team || Bot(S.SquadLeader) == None
            || ObjReachable(O, Team) || Alt.DefensePriority < O.DefensePriority)
            continue;
        S.SetObjective(Alt, true);
    }
}

// a bot of Team can walk to O, or to a point from where it can be attacked
function bool ObjReachable(GameObjective O, int Team)
{
    local int i;

    if (Team < 0 || Team > 1)
        return true;
    for (i = 0; i < Objs.Length; i++)
        if (Objs[i].O == O)
            return Objs[i].bUnreachable[Team] == 0 || Objs[i].Approach[Team] != None;
    return true;
}

// Where B's squad sends it: its objective, or the objective's approach point when it has one.
function Actor RouteTarget(Bot B)
{
    local GameObjective O;
    local NavigationPoint A;

    if (B.Squad == None || B.Squad.SquadObjective == None)
        return None;
    O = B.Squad.SquadObjective;
    A = GetApproach(O, B.GetTeamNum());
    if (A != None)
        return A;
    return O;
}

// Called by SUBotSquadAI: where a bot of Team should go for O, or None if normal pathing works.
function NavigationPoint GetApproach(GameObjective O, int Team)
{
    local int i;

    if (Team < 0 || Team > 1)
        return None;
    for (i = 0; i < Objs.Length; i++)
        if (Objs[i].O == O)
        {
            if (Objs[i].bUnreachable[Team] != 0)
                return Objs[i].Approach[Team];
            return None;
        }
    return None;
}

// The rings an actor teleports to, or None if it is not a rings actor. Works for TheRings and for
// maps that embed their own copy of the class (SU-TokRa's TheRingsTemp), read by property name.
function Actor RingTarget(Actor A)
{
    local Actor T, Found;
    local string S;
    local int i;

    if (A == None)
        return None;
    if (TheRings(A) != None)
        return TheRings(A).TargetRings;
    if (!A.IsA('TheRingsTemp'))
        return None;
    for (i = 0; i < RingFrom.Length; i++)
        if (RingFrom[i] == A)
            return RingTo[i];
    S = A.GetPropertyText("TargetRings") $ "'";     // TheRingsTemp'SU-TokRa.TheRingsTemp1' or None
    Found = None;
    foreach AllActors(class'Actor', T)
        if (T != A && T.IsA('TheRingsTemp') && InStr(S, "." $ T.Name $ "'") >= 0)
        {
            Found = T;
            break;
        }
    RingFrom[RingFrom.Length] = A;
    RingTo[RingTo.Length] = Found;
    return Found;
}

// ---------------------------------------------------------------- navigation list repair

// Fix 9 (truncated navigation list): SU-Asgard[Medium] was saved with a Level.NavigationPointList
// that links only its 9 SUReplicatorSpawnPoints, although the map holds 205 navigation points with
// their ReachSpecs; the native pathfinder only knows listed nodes, so bots could not move at all.
// The orphans are appended to the list. The fields are const in script: they are written with
// the engine's POKE console command and every write is verified (finding of the SUNav research,
// docs/research-runtime-nav.md).
function RelinkOrphans()
{
    local NavigationPoint N, Tail;
    local int Guard, InList, Added, Failed;

    foreach AllActors(class'NavigationPoint', N)
        N.visitedWeight = 0;
    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        Guard++;
        if (Guard > 100000)
        {
            Log("navigation list has a cycle: left untouched", 'SUBotFix');
            return;
        }
        N.visitedWeight = 1;
        Tail = N;
        InList++;
    }
    if (Tail != None)
        foreach AllActors(class'NavigationPoint', N)
        {
            if (N.visitedWeight != 0 || N.bDeleteMe || N.IsA('SUNavNode') || SUBotNavNode(N) != None)
                continue;
            if (AppendNav(Tail, N))
            {
                N.visitedWeight = 1;
                Tail = N;
                Added++;
            }
            else
                Failed++;
        }
    foreach AllActors(class'NavigationPoint', N)
        N.visitedWeight = 0;
    if (bLogFixes && (Added > 0 || Failed > 0))
        Log("navigation list: " $ InList $ " listed, " $ Added $ " orphan navigation points relinked, "
            $ Failed $ " failed", 'SUBotFix');
}

function bool AppendNav(NavigationPoint Tail, NavigationPoint X)
{
    // an orphan can carry a stale next pointer into the list, which would close a cycle
    if (X.nextNavigationPoint != None)
    {
        Poke(X, "nextNavigationPoint", "None");
        if (X.nextNavigationPoint != None)
            return false;
    }
    Poke(Tail, "nextNavigationPoint", Ref(X));
    if (Tail.nextNavigationPoint != X && !bBareRefs)
    {
        bBareRefs = true;      // ImportText cannot parse package names with brackets
        Poke(Tail, "nextNavigationPoint", Ref(X));
    }
    return Tail.nextNavigationPoint == X;
}

// ---------------------------------------------------------------- injected ReachSpecs

// Fix 12 (orphan objectives): objectives that no ReachSpec leads to (SU-IceDet ProximityObjective2
// next to a teleporter exit, SUDestroyableObjective0 800 uu from PathNode96, the Chulak generator)
// get walk specs to and from the closest nodes from which a scout of the largest SU pawn size can
// walk to them (engine PointReachable). The specs are created at runtime through POKE.
function LinkOrphanObjectives(optional bool bRetry)
{
    local GameObjective O;
    local NavigationPoint N;
    local array<NavigationPoint> Cand;
    local array<float> Dist;
    local float D;
    local int i, k, Incoming, Linked, Tested;
    local string How;

    foreach AllActors(class'GameObjective', O)
    {
        if (O.bDisabled || (bRetry && RetryIndex(O) < 0))
            continue;
        Incoming = 0;
        for (N = Level.NavigationPointList; N != None && Incoming == 0; N = N.NextNavigationPoint)
            for (k = 0; k < N.PathList.Length; k++)
                if (N.PathList[k] != None && N.PathList[k].End == O && Walkable(N.PathList[k]))
                {
                    Incoming++;
                    break;
                }
        if (Incoming > 0)
            continue;
        if (DoorMovers.Length == 0 && !bRetry)      // not during the match: a pawn may be in a doorway
            OpenProximityDoors();
        Cand.Length = 0;
        Dist.Length = 0;
        for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
        {
            if (N == O || GameObjective(N) != None || N.PathList.Length == 0)
                continue;
            D = VSize(N.Location - O.Location);
            if (D > OrphanLinkRadius)
                continue;
            for (i = 0; i < Cand.Length && Dist[i] <= D; i++);
            if (i >= 6)
                continue;
            Cand.Insert(i, 1);
            Dist.Insert(i, 1);
            Cand[i] = N;
            Dist[i] = D;
            if (Cand.Length > 6)
            {
                Cand.Length = 6;
                Dist.Length = 6;
            }
        }
        Linked = 0;
        Tested = 0;
        for (i = 0; i < Cand.Length && Linked < 2; i++)
        {
            Tested++;
            // the engine's walk test, else a sampled walk line (PointReachable rejects some stairs)
            if (NativeReachLoc(Cand[i], InFront(O, Cand[i].Location), PawnHeight) == 1)
                How = "walk test";
            else if (WalkLine(Cand[i].Location, InFront(O, Cand[i].Location)))
                How = "walk line";
            else
            {
                if (bLogFixes && !bRetry)
                    Log("  " $ O.Name $ " <- " $ Cand[i].Name $ " (" $ int(Dist[i]) $ " uu): " $ WalkWhy, 'SUBotFix');
                continue;
            }
            if (Link(Cand[i], O, 1) != None)
            {
                Linked++;
                Link(O, Cand[i], 1);
                if (bLogFixes)
                    Log("objective " $ O.Name $ " '" $ O.ObjectiveName $ "' had no path: linked to " $ Cand[i].Name
                        $ " (" $ int(Dist[i]) $ " uu, " $ How $ ")" $ Mid(" - later in the match", 0, 21 * int(bRetry)), 'SUBotFix');
            }
        }
        // no straight line: try a dog-leg through one new node (around a corner)
        for (i = 0; i < Cand.Length && Linked == 0; i++)
            if (DogLeg(Cand[i], O))
                Linked++;
        if (Linked == 0 && !bRetry)
        {
            OrphanRetry[OrphanRetry.Length] = O;     // a door or force field may open later
            if (bLogFixes)
                Log("objective " $ O.Name $ " '" $ O.ObjectiveName $ "' has no path and no walkable node within "
                    $ int(OrphanLinkRadius) $ " uu (" $ Tested $ " tested), will retry", 'SUBotFix');
        }
        else if (Linked > 0 && bRetry)
        {
            OrphanRetry.Remove(RetryIndex(O), 1);
            for (k = 0; k < Objs.Length; k++)
                if (Objs[k].O == O)
                {
                    Objs[k].bUnreachable[0] = 0;
                    Objs[k].bUnreachable[1] = 0;
                }
        }
    }
    CloseProximityDoors();
    KillScout();
}

function int RetryIndex(GameObjective O)
{
    local int i;

    for (i = 0; i < OrphanRetry.Length; i++)
        if (OrphanRetry[i] == O)
            return i;
    return -1;
}

// Fix 13 (rings as paths): pair the pads spawned in PostBeginPlay, put them in the navigation
// list, link each pad with the nodes around it and the pad to its partner pad, so that bots plan
// routes through the rings (SU-Abydos crystal chamber and Hatak, SU-TokRa) instead of only being
// teleported out of stranded spawns.
function SetupRingPads()
{
    local int i, j, k, NumTrips, InL, OutL;
    local ReachSpec R;
    local Actor T;
    local SUBotRingPad P, Q;
    local NavigationPoint N;
    local array<NavigationPoint> Cand;
    local array<float> Dist;
    local float D;

    for (i = 0; i < RingPads.Length; i++)
    {
        P = RingPads[i];
        T = RingTarget(P.MyRings);
        Q = None;
        for (j = 0; j < RingPads.Length; j++)
            if (RingPads[j].MyRings == T)
                Q = RingPads[j];
        if (Q == None)
            continue;
        // Q is reached from P
        Q.PartnerPad = P;
        Q.PartnerRings = P.MyRings;
        if (!RegisterNav(P) || !RegisterNav(Q))
            continue;
        R = Link(P, Q, 1);
        if (R != None)
        {
            R.Distance = 300;     // a ring trip is quick
            NumTrips++;
        }
    }
    // walk links between each pad and the network around it
    for (i = 0; i < RingPads.Length; i++)
    {
        P = RingPads[i];
        if (P.PathList.Length == 0 && P.PartnerPad == None)
            continue;
        Cand.Length = 0;
        Dist.Length = 0;
        for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
        {
            if (SUBotRingPad(N) != None || N.PathList.Length == 0)
                continue;
            D = VSize(N.Location - P.Location);
            if (D > 900)
                continue;
            for (k = 0; k < Cand.Length && Dist[k] <= D; k++);
            if (k >= 4)
                continue;
            Cand.Insert(k, 1);
            Dist.Insert(k, 1);
            Cand[k] = N;
            Dist[k] = D;
            if (Cand.Length > 4)
            {
                Cand.Length = 4;
                Dist.Length = 4;
            }
        }
        InL = 0;
        OutL = 0;
        for (k = 0; k < Cand.Length; k++)
        {
            if ((NativeReachLoc(Cand[k], P.Location, PawnHeight) == 1 || WalkLine(Cand[k].Location, P.Location))
                && Link(Cand[k], P, 1) != None)
                InL++;
            if ((NativeReachLoc(P, Cand[k].Location, PawnHeight) == 1 || WalkLine(P.Location, Cand[k].Location))
                && Link(P, Cand[k], 1) != None)
                OutL++;
        }
        if (bLogFixes)
            Log("rings pad on " $ P.MyRings.Name $ " (" $ P.MyRings.Tag $ "): " $ Cand.Length $ " nodes within 900 uu, "
                $ InL $ " lead to it, " $ OutL $ " reached from it", 'SUBotFix');
    }
    KillScout();
    if (bLogFixes && RingPads.Length > 0)
        Log("rings: " $ RingPads.Length $ " pads, " $ NumTrips $ " ring trips linked into the navigation", 'SUBotFix');
}

// Fix 15 (networks in pieces): some maps' path networks are broken into islands that are a few
// steps apart on open floor (SU-Abydos: the Goa'uld capture spot and the room under the rings form
// three islands along one straight corridor, so no bot ever brought a crystal there). Split the
// walk graph into strongly connected components; for node pairs of different components within
// GapRadius, nearest first, add a walk link both ways when the straight line is walkable both ways
// (sampled floor) and the engine's walk test does not refuse it. One link per pair of components.
function BridgeGaps(optional bool bInMatch)
{
    local NavigationPoint N;
    local array<int> Comp, UF, Size, PA, PB;
    local array<float> PD;
    local array<byte> Ok;
    local int i, j, k, NumN, NumComp, Tests, Links, Pass, a, b, Biggest, Fails, DropTests;
    local float D, Band, Dz;
    local string Why;
    local array<int> DropFrom, DropTo, Near;

    IndexNodes();
    NumN = Nodes.Length;
    Ok.Length = NumN;
    for (i = 0; i < NumN; i++)
    {
        Ok[i] = 0;
        if (GapNode(Nodes[i]))
            Ok[i] = 1;
    }
    NumComp = ComputeSCC(Comp);
    UF.Length = NumComp;
    Size.Length = NumComp;
    for (i = 0; i < NumComp; i++)
    {
        UF[i] = i;
        Size[i] = 0;
    }
    for (i = 0; i < NumN; i++)
        Size[Comp[i]] = Size[Comp[i]] + 1;
    for (i = 0; i < NumComp; i++)
        Biggest = Max(Biggest, Size[i]);
    // candidate pairs: different components, close, similar floor height. Nodes are bucketed in a
    // 1024 uu grid and only neighbour cells are compared: the all-pairs loops cost 120-160 ms on
    // SU-Abydos and SU-Chulak (400-800 nodes), at every in-match rebuild
    BuildGapGrid(Ok);
    for (i = 0; i < NumN; i++)
    {
        if (Ok[i] == 0)
            continue;
        GridNear(i, Near);
        for (k = 0; k < Near.Length; k++)
        {
            j = Near[k];
            if (j <= i || Comp[i] == Comp[j])
                continue;
            D = VSize(Nodes[j].Location - Nodes[i].Location);
            if (D > GapRadius || Abs(Nodes[j].Location.Z - Nodes[i].Location.Z) > 0.5 * D + 40)
                continue;
            PA[PA.Length] = i;
            PB[PB.Length] = j;
            PD[PD.Length] = D;
        }
    }
    // nearest first, in distance bands (no sort needed); doors that open when a pawn comes near
    // do not count as walls (SU-Abydos Mover9 'porte2': no Door navigation point, so no path).
    // Not during the match: a pawn may stand in a doorway.
    if (!bInMatch)
        OpenProximityDoors();
    for (Pass = 1; Pass <= 4; Pass++)
    {
        Band = GapRadius * Pass / 4;
        for (i = 0; i < PA.Length && Tests < MaxGapTests; i++)
        {
            if (PD[i] > Band || PD[i] <= GapRadius * (Pass - 1) / 4)
                continue;
            a = FindComp(UF, Comp[PA[i]]);
            b = FindComp(UF, Comp[PB[i]]);
            if (a == b)
                continue;
            Tests++;
            Why = "";
            if (!WalkLine(Nodes[PA[i]].Location, Nodes[PB[i]].Location))
                Why = "there: " $ WalkWhy;
            else if (!WalkLine(Nodes[PB[i]].Location, Nodes[PA[i]].Location))
                Why = "back: " $ WalkWhy;
            else if (NativeReach(Nodes[PA[i]], Nodes[PB[i]], PawnHeight) == 0)
                Why = "engine walk test there";
            else if (NativeReach(Nodes[PB[i]], Nodes[PA[i]], PawnHeight) == 0)
                Why = "engine walk test back";
            if (Why != "")
            {
                Fails++;
                if (bLogFixes && Fails <= 30)
                    Log("  gap " $ Nodes[PA[i]].Name $ " <-> " $ Nodes[PB[i]].Name $ " (" $ int(PD[i]) $ " uu) refused: " $ Why, 'SUBotFix');
                continue;
            }
            if (Link(Nodes[PA[i]], Nodes[PB[i]], 1) == None || Link(Nodes[PB[i]], Nodes[PA[i]], 1) == None)
                continue;
            UF[a] = b;
            Links++;
            if (bLogFixes && Links <= 40)
                Log("gap: linked " $ Nodes[PA[i]].Name $ " <-> " $ Nodes[PB[i]].Name $ " (" $ int(PD[i]) $ " uu, islands of "
                    $ Size[Comp[PA[i]]] $ " and " $ Size[Comp[PB[i]]] $ " nodes) at " $ int(Nodes[PA[i]].Location.X) $ ","
                    $ int(Nodes[PA[i]].Location.Y) $ "," $ int(Nodes[PA[i]].Location.Z), 'SUBotFix');
        }
    }
    // one-way drops out of or into small islands (dead-end rooms and pits: players jump down, the
    // path builder linked nothing). The engine's walk test, which walks off ledges and checks the
    // landing, is the judge. One drop per pair of islands.
    for (i = 0; i < NumN && DropTests < 300; i++)
    {
        if (Ok[i] == 0)
            continue;
        GridNear(i, Near);
        for (k = 0; k < Near.Length && DropTests < 300; k++)
        {
            j = Near[k];
            if (Comp[i] == Comp[j] || (Size[Comp[i]] > 30 && Size[Comp[j]] > 30))
                continue;
            Dz = Nodes[i].Location.Z - Nodes[j].Location.Z;
            if (Dz < 100 || Dz > 500 || VSize((Nodes[j].Location - Nodes[i].Location) * vect(1,1,0)) > 900)
                continue;
            for (a = 0; a < DropFrom.Length && (DropFrom[a] != Comp[i] || DropTo[a] != Comp[j]); a++);
            if (a < DropFrom.Length)
                continue;
            // a drop the engine refused once is refused again: the ground does not change (the
            // in-match rebuilds of SU-Abydos and SU-Chulak spent most of their 120-160 ms here)
            if (DropRefused(Nodes[i], Nodes[j]))
                continue;
            DropTests++;
            if (!HasSpec(Nodes[i], Nodes[j]) && NativeReach(Nodes[i], Nodes[j], PawnHeight) != 1)
            {
                RefusedFrom[RefusedFrom.Length] = Nodes[i];
                RefusedTo[RefusedTo.Length] = Nodes[j];
                continue;
            }
            if (Link(Nodes[i], Nodes[j], 1) == None)
                continue;
            DropFrom[DropFrom.Length] = Comp[i];
            DropTo[DropTo.Length] = Comp[j];
            if (bLogFixes && DropFrom.Length <= 20)
                Note("gap: drop " $ Nodes[i].Name $ " -> " $ Nodes[j].Name $ " (" $ int(Dz) $ " uu down, island of "
                    $ Size[Comp[i]] $ " nodes) at " $ Vec(Nodes[i].Location));
        }
    }
    KillScout();
    CloseProximityDoors();
    if (bLogFixes)
        Log("gaps: " $ NumN $ " navpoints in " $ NumComp $ " islands (largest " $ Biggest $ "), " $ PA.Length
            $ " close pairs across islands, " $ Tests $ " tested, " $ Links $ " two-way links and " $ DropFrom.Length
            $ " drops added (" $ DropTests $ " drop tests)", 'SUBotFix');
    for (i = 0; i < NumN; i++)
        Nodes[i].visitedWeight = 0;
    Nodes.Length = 0;
}

// Fix 16 (goals in rooms without waypoints): SU-TokRa's crystals sit in tunnels with no node within
// 900 uu, objectives that LinkOrphanObjectives could not link sit behind corners or in rooms the
// path builder skipped. Flood-fill the walkable floor from the goal (128 uu grid, steps and ramps
// both ways, head room, clear lines with the body's width) until a cell can walk straight to a node
// of the main network, then lay pool nodes along that corridor (a node wherever the straight walk
// from the previous one breaks) and link them both ways.
function BridgeGoals(optional bool bInMatch)
{
    local array<int> Comp, Size;
    local int i, NumComp, Biggest, Built, Tried;
    local GameObjective O;
    local SUCrystalObject K;
    local array<vector> Seeds;
    local array<int> Island;
    local array<byte> InMain;
    local int Idx, Ni;
    local NavigationPoint N;
    local PlayerStart PS;

    IndexNodes();
    NumComp = ComputeSCC(Comp);
    Size.Length = NumComp;
    for (i = 0; i < Nodes.Length; i++)
        Size[Comp[i]] = Size[Comp[i]] + 1;
    Biggest = 0;
    for (i = 1; i < NumComp; i++)
        if (Size[i] > Size[Biggest])
            Biggest = i;
    // main network nodes, in a coarse spatial hash
    BucketHead.Length = 4096;
    for (i = 0; i < 4096; i++)
        BucketHead[i] = -1;
    MainNodes.Length = 0;
    MainNext.Length = 0;
    MainFails.Length = 0;
    // main network: the largest component and everything it reaches (one-way drops included:
    // a corridor from there is usable by bots coming from the main network)
    InMain.Length = Nodes.Length;
    for (i = 0; i < Nodes.Length; i++)
        InMain[i] = byte(Comp[i] == Biggest);
    ForwardClosure(InMain);
    for (i = 0; i < Nodes.Length; i++)
        if (InMain[i] != 0 && GapNode(Nodes[i]))
            AddMainNode(Nodes[i]);
    if (MainNodes.Length < 20)
    {
        Nodes.Length = 0;
        return;             // flying maps (SU-Antartica, SU-Asteroid): nothing to join
    }
    if (!bInMatch)
        OpenProximityDoors();
    // flood budget for the whole pass: about 0.1-0.3 s at load; during the match a stage change must
    // not freeze the server (players notice frames over ~100 ms)
    FloodBudget = 16000;
    FloodCap = MaxFloodCells;
    if (bInMatch)
    {
        FloodBudget = 1500;
        FloodCap = 600;     // per goal: big enclosed areas must not eat the budget of the others
    }
    Cells.Length = 0;
    FloodDrops = true;      // bots only need to get to an objective: drops on the way are fine (fix 32)
    // objectives linked to an island only (SU-IceDet ProximityObjective2: its room is entered through
    // Teleporter0, which nothing links to): flood from the island's nodes, farthest from it first
    foreach AllActors(class'GameObjective', O)
    {
        Idx = IndexOf(O);
        if (O.bDisabled || RetryIndex(O) >= 0 || NodePool.Length < 4 || Idx < 0 || InMain[Idx] != 0)
            continue;
        if (!IslandOf(Idx, InMain, Island))
            continue;
        Tried++;
        for (Ni = 0; Ni < Island.Length && Ni < 12; Ni++)
        {
            N = Nodes[Island[Ni]];
            if (GameObjective(N) != None)
                continue;
            if (FloodBudget <= 0)
                break;
            Seeds.Length = 0;
            RingSeeds(N, N.CollisionRadius + 40, Seeds);
            // the floor the last (failed) flood covered: this one would fail the same way
            if (Cells.Length > 0 && Seeds.Length > 0 && CellFind(CellKey(Seeds[0]), -1) >= 0)
                continue;
            if (FloodBridge(N, Seeds))
            {
                Built++;
                if (bLogFixes)
                    Log("corridor: " $ O.Name $ " '" $ O.ObjectiveName $ "' was on an island of " $ Island.Length
                        $ " nodes, joined through " $ N.Name, 'SUBotFix');
                for (i = 0; i < Objs.Length; i++)
                    if (Objs[i].O == O)
                    {
                        Objs[i].bUnreachable[0] = 0;
                        Objs[i].bUnreachable[1] = 0;
                    }
                // the island is part of the network now: the floods below may end on it (SU-IceDet:
                // the cave behind Teleporter1)
                for (i = 0; i < Island.Length; i++)
                    if (InMain[Island[i]] == 0)
                    {
                        InMain[Island[i]] = 1;
                        if (GapNode(Nodes[Island[i]]))
                            AddMainNode(Nodes[Island[i]]);
                    }
                break;
            }
        }
    }
    foreach AllActors(class'GameObjective', O)
    {
        if (O.bDisabled || RetryIndex(O) < 0 || NodePool.Length < 2 || FloodBudget <= 0)
            continue;
        Tried++;
        Seeds.Length = 0;
        RingSeeds(O, O.CollisionRadius + 40, Seeds);
        RingSeeds(O, O.CollisionRadius + 100, Seeds);
        if (FloodBridge(O, Seeds))
        {
            Built++;
            OrphanRetry.Remove(RetryIndex(O), 1);
        }
    }
    // spawn rooms with no way out on the network (SU-IceDet: the Goa'uld phase-3 spawn area, which
    // the light bridge joins at stage 4): flood from one of their starts, both ways (fix 34)
    FloodDrops = false;
    foreach AllActors(class'PlayerStart', PS)
    {
        Idx = IndexOf(PS);
        if (Idx < 0 || InMain[Idx] != 0 || NodePool.Length < 4 || FloodBudget <= 0)
            continue;
        if (!IslandOf(Idx, InMain, Island) || Island.Length < 2)
            continue;
        Tried++;
        Seeds.Length = 0;
        RingSeeds(PS, PS.CollisionRadius + 40, Seeds);
        if (Cells.Length > 0 && Seeds.Length > 0 && CellFind(CellKey(Seeds[0]), -1) >= 0)
            continue;
        if (FloodBridge(PS, Seeds))
        {
            Built++;
            if (bLogFixes)
                Log("corridor: spawn room of " $ PS.Name $ " (" $ Island.Length $ " nodes) joined the network", 'SUBotFix');
            for (i = 0; i < Island.Length; i++)
                if (InMain[Island[i]] == 0)
                {
                    InMain[Island[i]] = 1;
                    if (GapNode(Nodes[Island[i]]))
                        AddMainNode(Nodes[Island[i]]);
                }
        }
    }
    FloodDrops = false;     // carriers must walk back out with the crystal
    foreach DynamicActors(class'SUCrystalObject', K)
    {
        if (NodePool.Length < 2 || NearMainWalk(K.Location + vect(0,0,1) * (45 - K.CollisionHeight), 500) >= 0)
            continue;
        Tried++;
        Seeds.Length = 0;
        RingSeeds(K, 40, Seeds);
        RingSeeds(K, 90, Seeds);
        RingSeeds(K, 140, Seeds);
        if (FloodBridge(K, Seeds))
            Built++;
    }
    FloodDrops = false;
    CloseProximityDoors();
    KillScout();
    if (bLogFixes && Tried > 0)
        Log("corridors: " $ Built $ " of " $ Tried $ " goals without waypoints linked to the main network ("
            $ MainNodes.Length $ " nodes), " $ NodePool.Length $ " pool nodes left", 'SUBotFix');
    for (i = 0; i < Nodes.Length; i++)
        Nodes[i].visitedWeight = 0;
    Nodes.Length = 0;
    Cells.Length = 0;
    HKeys.Length = 0;
    HVals.Length = 0;
}

// floor points around Loc (the goal's own mesh often fills its centre)
// marks every node reachable on foot from a marked node
function ForwardClosure(out array<byte> M)
{
    local array<int> Q;
    local int Head, i, e, j;
    local ReachSpec R;

    for (i = 0; i < Nodes.Length; i++)
        if (M[i] != 0)
            Q[Q.Length] = i;
    for (Head = 0; Head < Q.Length; Head++)
    {
        i = Q[Head];
        for (e = 0; e < Nodes[i].PathList.Length; e++)
        {
            R = Nodes[i].PathList[e];
            if (!Walkable(R))
                continue;
            j = IndexOf(R.End);
            if (j >= 0 && M[j] == 0)
            {
                M[j] = 1;
                Q[Q.Length] = j;
            }
        }
    }
}

// Nodes that can walk to node Idx (reverse closure over walkable specs), farthest from it first.
// False when one of them is in the main component (then the objective is reachable anyway).
function bool IslandOf(int Idx, array<byte> InMain, out array<int> Island)
{
    local array<byte> M;
    local array<float> D;
    local int i, j, k, e;
    local bool bChanged;
    local ReachSpec R;
    local float Dist;

    M.Length = Nodes.Length;
    M[Idx] = 1;
    bChanged = true;
    for (k = 0; k < 200 && bChanged; k++)
    {
        bChanged = false;
        for (i = 0; i < Nodes.Length; i++)
        {
            if (M[i] != 0)
                continue;
            for (e = 0; e < Nodes[i].PathList.Length; e++)
            {
                R = Nodes[i].PathList[e];
                if (!Walkable(R))
                    continue;
                j = IndexOf(R.End);
                if (j >= 0 && M[j] != 0)
                {
                    M[i] = 1;
                    bChanged = true;
                    if (InMain[i] != 0)
                        return false;
                    break;
                }
            }
        }
    }
    Island.Length = 0;
    for (i = 0; i < Nodes.Length; i++)
    {
        if (M[i] == 0 || i == Idx)
            continue;
        Dist = VSize(Nodes[i].Location - Nodes[Idx].Location);
        for (k = 0; k < Island.Length && D[k] >= Dist; k++);
        Island.Insert(k, 1);
        D.Insert(k, 1);
        Island[k] = i;
        D[k] = Dist;
    }
    return true;
}

// floor points around Goal at distance R (its own mesh often fills its centre), each with a clear
// line to the rim of the goal's cylinder (no wall, closed door or force field in between)
function RingSeeds(Actor Goal, float R, out array<vector> Seeds)
{
    local int d;
    local vector Loc, P, Dir, Rim, HL, HN;

    Loc = Goal.Location;
    for (d = 0; d < 9; d++)
    {
        P = Loc;
        if (d > 0)
        {
            Dir.X = Cos(d * 0.7853982);
            Dir.Y = Sin(d * 0.7853982);
            Dir.Z = 0;
            P = Loc + Dir * R;
            Rim = Loc + Dir * FMin(Goal.CollisionRadius, R - 10);
            if (!FastTrace(Rim, P))
                continue;
        }
        if (Trace(HL, HN, P - vect(0,0,300), P + vect(0,0,20), false) == None || HN.Z < 0.7
            || !FastTrace(HL + vect(0,0,100), HL + vect(0,0,6)))
            continue;
        if (d > 0 && !FastTrace(Rim, HL + vect(0,0,48)))
            continue;
        Seeds[Seeds.Length] = HL;
    }
}

function AddMainNode(NavigationPoint N)
{
    local int i, B;

    i = MainNodes.Length;
    MainNodes[i] = N;
    MainFails[i] = 0;
    B = BucketOf(N.Location);
    MainNext[i] = BucketHead[B];
    BucketHead[B] = i;
}

// gap candidates (BridgeGaps): Nodes[] with Ok != 0 hashed in a 1024 uu grid
function BuildGapGrid(array<byte> Ok)
{
    local int i, B;

    GHead.Length = 4096;
    for (i = 0; i < 4096; i++)
        GHead[i] = -1;
    GNext.Length = Nodes.Length;
    GCX.Length = Nodes.Length;
    GCY.Length = Nodes.Length;
    for (i = 0; i < Nodes.Length; i++)
    {
        GNext[i] = -1;
        if (Ok[i] == 0)
            continue;
        GCX[i] = FloorDiv(Nodes[i].Location.X, 1024);
        GCY[i] = FloorDiv(Nodes[i].Location.Y, 1024);
        B = GridBucket(GCX[i], GCY[i]);
        GNext[i] = GHead[B];
        GHead[B] = i;
    }
}

function int GridBucket(int CX, int CY)
{
    return ((CX + 8192) * 31 + (CY + 8192) * 1009) & 4095;
}

// grid nodes in the 3x3 cells around node I (I itself included)
function GridNear(int I, out array<int> Near)
{
    local int dx, dy, j;

    Near.Length = 0;
    for (dx = -1; dx <= 1; dx++)
        for (dy = -1; dy <= 1; dy++)
            for (j = GHead[GridBucket(GCX[I] + dx, GCY[I] + dy)]; j >= 0; j = GNext[j])
                if (GCX[j] == GCX[I] + dx && GCY[j] == GCY[I] + dy)
                    Near[Near.Length] = j;
}

function int BucketOf(vector L)
{
    return ((FloorDiv(L.X, 512) + 8192) * 31 + (FloorDiv(L.Y, 512) + 8192) * 1009) & 4095;
}

function int FloorDiv(float V, float S)
{
    local int I;

    I = int(V / S);
    if (V < I * S)
        I--;
    return I;
}

// main node within Radius of P (pawn height above the floor) that P walks to and from, or -1
// (the two nearest candidates are tested; a node that failed 6 times is not tried again)
function int NearMainWalk(vector P, float Radius)
{
    local int bx, by, B, i, k, Tests;
    local float D;
    local vector C;
    local array<int> Cand, Seen;
    local array<float> CandD;

    for (bx = -1; bx <= 1; bx++)
        for (by = -1; by <= 1; by++)
        {
            C = P;
            C.X += bx * 512;
            C.Y += by * 512;
            B = BucketOf(C);
            for (k = 0; k < Seen.Length && Seen[k] != B; k++);
            if (k < Seen.Length)
                continue;           // two cells hashed to the same bucket
            Seen[Seen.Length] = B;
            for (i = BucketHead[B]; i >= 0; i = MainNext[i])
            {
                if (MainFails[i] >= 6 || Abs(MainNodes[i].Location.Z - P.Z) > 160)
                    continue;
                D = VSize(MainNodes[i].Location - P);
                if (D > Radius)
                    continue;
                for (k = 0; k < Cand.Length && CandD[k] <= D; k++);
                Cand.Insert(k, 1);
                CandD.Insert(k, 1);
                Cand[k] = i;
                CandD[k] = D;
            }
        }
    for (k = 0; k < Cand.Length && Tests < 2; k++)
    {
        Tests++;
        if (WalkLine(P, MainNodes[Cand[k]].Location) && WalkLine(MainNodes[Cand[k]].Location, P))
            return Cand[k];
        MainFails[Cand[k]] = MainFails[Cand[k]] + 1;
    }
    return -1;
}

// Flood from Seeds until a cell walks to the main network, then build the corridor. Goal is the
// objective (linked to the first node) or another actor (crystal: bots path to the nearest node).
function bool FloodBridge(Actor Goal, array<vector> Seeds)
{
    local int Head, i, d, Term, Main, Cnt;
    local vector Delta, FloorPt, Loc;
    local array<int> Path;
    local array<NavigationPoint> Chain;
    local NavigationPoint GoalNav;
    local int Last, c;
    local bool bOk, bLast;
    local string Why;
    local array<int> ChainCell;         // Path index of each Chain node
    local int NumDrops, NumGated;
    local Mover Gate;

    if (Seeds.Length == 0)
    {
        if (bLogFixes)
            Log("corridor to " $ Goal.Name $ ": no floor around it", 'SUBotFix');
        return false;
    }
    Cells.Length = 0;
    HashSize = 16384;
    HKeys.Length = HashSize;
    HVals.Length = HashSize;
    for (i = 0; i < HashSize; i++)
        HKeys[i] = 0;
    for (i = 0; i < Seeds.Length; i++)
        if (CellFind(CellKey(Seeds[i]), -1) < 0)
            AddCell(Seeds[i], -1);
    Term = -1;
    Main = -1;
    for (Head = 0; Head < Cells.Length && Cnt < Min(Min(MaxFloodCells, FloodBudget), FloodCap) && Term < 0; Head++)
    {
        Loc = Cells[Head].Loc;
        Cnt++;
        Main = NearMainWalk(Loc + vect(0,0,45), 450);
        if (Main >= 0)
        {
            Term = Head;
            break;
        }
        for (d = 0; d < 8; d++)
        {
            Delta = vect(0,0,0);
            switch (d)
            {
                case 0: Delta.X = 128; break;
                case 1: Delta.X = -128; break;
                case 2: Delta.Y = 128; break;
                case 3: Delta.Y = -128; break;
                case 4: Delta.X = 90; Delta.Y = 90; break;
                case 5: Delta.X = -90; Delta.Y = 90; break;
                case 6: Delta.X = 90; Delta.Y = -90; break;
                case 7: Delta.X = -90; Delta.Y = -90; break;
            }
            if (CellFind(CellKey(Loc + Delta), -1) >= 0)
                continue;
            if (!StepTo(Loc, Delta, FloorPt))
            {
                // log bridges (SU-IceDet): the trace fell between two logs, try a little short or long
                // (objective floods only, fix 34)
                // (the longer step first: the shorter one often lands back in the same cell)
                if (!FloodDrops || Left(StepWhy, 5) != "floor"
                    || (!StepTo(Loc, Delta * 1.25, FloorPt)
                        && (!StepTo(Loc, Delta * 0.75, FloorPt) || CellKey(FloorPt) == CellKey(Loc))))
                {
                    if (Head == 0 && bLogFixes)
                        Why = Why $ " " $ d $ ":" $ StepWhy;
                    continue;
                }
            }
            if (CellFind(CellKey(FloorPt), -1) >= 0)
                continue;
            AddCell(FloorPt, Head);
            if (StepDrop)
                Cells[Cells.Length - 1].Drop = 1;
            Cells[Cells.Length - 1].OnMover = Mover(StepFloor);
        }
    }
    FloodBudget -= Cnt;
    if (Term < 0)
    {
        if (bLogFixes)
            Log("corridor to " $ Goal.Name $ ": the floor around it (" $ Cells.Length $ " cells) never comes near the main network;"
                $ " first cell " $ Vec(Cells[0].Loc) $ " blocked:" $ Why, 'SUBotFix');
        return false;
    }
    // corridor cells, from the goal to the network
    for (c = Term; c >= 0; c = Cells[c].Parent)
    {
        Path.Insert(0, 1);
        Path[0] = c;
    }
    // the first node must really reach the goal: walk into an objective, see and touch a crystal
    GoalNav = NavigationPoint(Goal);
    Loc = Cells[Path[0]].Loc + vect(0,0,45);
    WalkWhy = "too far or out of sight";
    // (a cell right next to an objective counts: the walk line can hit the objective's own mesh,
    // SU-IceDet SUTriggeredObjective0)
    if ((GoalNav != None && !WalkLine(Loc, InFront(Goal, Loc))
            && (VSize((Goal.Location - Loc) * vect(1,1,0)) > Goal.CollisionRadius + 100
                || Abs(Goal.Location.Z - Loc.Z) > Goal.CollisionHeight + 60))
        || (GoalNav == None && (VSize(Goal.Location - Loc) > 240
            || (!FastTrace(Goal.Location, Loc) && !FastTrace(Goal.Location, Loc + vect(0,0,40))))))
    {
        if (bLogFixes)
            Log("corridor to " $ Goal.Name $ ": its first cell " $ Vec(Loc) $ " cannot get to it (" $ WalkWhy $ ")", 'SUBotFix');
        return false;
    }
    // string pulling: keep walking straight from the last node while it works
    Chain.Length = 0;
    Last = 0;
    if (!PlaceCorridorNode(Cells[Path[0]].Loc, Chain))
        return false;
    ChainCell.Length = 0;
    ChainCell[0] = 0;
    for (i = 1; i < Path.Length; i++)
    {
        // a drop (fix 32): a node on each side, linked one way only; same where the floor changes
        // between solid ground and a mover (fix 34: those links wait for the mover to be open)
        if (Cells[Path[i]].Drop != 0 || Cells[Path[i]].OnMover != Cells[Path[i - 1]].OnMover)
        {
            if (i - 1 > Last)
            {
                if (!PlaceCorridorNode(Cells[Path[i - 1]].Loc, Chain))
                    return false;
                ChainCell[ChainCell.Length] = i - 1;
            }
            if (!PlaceCorridorNode(Cells[Path[i]].Loc, Chain))
                return false;
            ChainCell[ChainCell.Length] = i;
            Last = i;
            if (Cells[Path[i]].Drop != 0)
                NumDrops++;
            continue;
        }
        bLast = (i == Path.Length - 1);
        bOk = VSize(Cells[Path[i]].Loc - Cells[Path[Last]].Loc) < 600
            && WalkLine(Cells[Path[Last]].Loc + vect(0,0,45), Cells[Path[i]].Loc + vect(0,0,45))
            && WalkLine(Cells[Path[i]].Loc + vect(0,0,45), Cells[Path[Last]].Loc + vect(0,0,45));
        if (bOk && !bLast)
            continue;
        if (bOk)
            c = i;
        else if (i - 1 > Last)
        {
            c = i - 1;
            i--;
        }
        else
            c = i;      // neighbour cells: the flood's own step test passed (bumpy floors fail the 32 uu samples)
        if (!PlaceCorridorNode(Cells[Path[c]].Loc, Chain))
            return false;
        ChainCell[ChainCell.Length] = c;
        Last = c;
    }
    // bots come from the network (the end of the chain) toward the goal; a drop between two nodes
    // can only be taken that way
    for (i = 1; i < Chain.Length; i++)
    {
        Gate = None;
        for (c = ChainCell[i - 1]; c <= ChainCell[i]; c++)
            if (Cells[Path[c]].OnMover != None)
                Gate = Cells[Path[c]].OnMover;
        bOk = true;
        for (c = ChainCell[i - 1] + 1; c <= ChainCell[i]; c++)
            if (Cells[Path[c]].Drop != 0)
                bOk = false;
        if (Gate != None)
        {
            AddGate(Chain[i], Chain[i - 1], Gate);
            if (bOk)
                AddGate(Chain[i - 1], Chain[i], Gate);
            NumGated++;
            continue;
        }
        if (Link(Chain[i], Chain[i - 1], 1) == None)
            return false;
        if (bOk && Link(Chain[i - 1], Chain[i], 1) == None)
            return false;
    }
    if (Link(Chain[Chain.Length - 1], MainNodes[Main], 1) == None || Link(MainNodes[Main], Chain[Chain.Length - 1], 1) == None)
        return false;
    if (GoalNav != None)
    {
        Link(Chain[0], GoalNav, 1);
        Link(GoalNav, Chain[0], 1);
    }
    for (i = 0; i < Chain.Length; i++)
        AddMainNode(Chain[i]);      // later goals may join this corridor
    if (bLogFixes)
        Log("corridor to " $ Goal.Name $ ": " $ Chain.Length $ " new nodes over " $ Path.Length $ " cells (" $ Cells.Length
            $ " flooded), " $ NumDrops $ " one-way drops, " $ NumGated $ " links waiting for a mover, " $ NumWideSteps $ " wide steps so far, joins " $ MainNodes[Main].Name $ " at " $ Vec(MainNodes[Main].Location), 'SUBotFix');
    return true;
}

function bool PlaceCorridorNode(vector Floor, out array<NavigationPoint> Chain)
{
    local SUBotNavNode X;

    if (NodePool.Length == 0)
    {
        if (bLogFixes)
            Log("corridor: out of pool nodes", 'SUBotFix');
        return false;
    }
    X = NodePool[NodePool.Length - 1];
    if (!X.SetLocation(Floor + vect(0,0,45)) || !RegisterNav(X))
        return false;
    NodePool.Remove(NodePool.Length - 1, 1);
    Chain[Chain.Length] = X;
    return true;
}

// next floor point from floor point From, Delta away horizontally: steps up to 36 uu, ramps and
// stairs up to 130 uu per cell in either direction (corridors must be walkable both ways),
// head room for a 55 uu pawn, clear lines at knee and head height with the body's width
function bool StepTo(vector From, vector Delta, out vector FloorPt)
{
    local vector Top, Bottom, HL, HN, Mid, MHL, MHN, Ext, Edge;
    local float Rise;

    StepDrop = false;
    Top = From + Delta + vect(0,0,56);
    Bottom = From + Delta - vect(0,0,150);
    StepFloor = Trace(HL, HN, Bottom, Top, false);
    if (StepFloor == None || HN.Z < 0.7 || HL.Z > Top.Z - 2)
    {
        Top = From + Delta + vect(0,0,150);
        StepFloor = Trace(HL, HN, Bottom, Top, false);
        if (StepFloor == None || HN.Z < 0.7 || HL.Z > Top.Z - 2)
        {
            Top = From + Delta + vect(0,0,1) * (MaxDropRise + 20);
            if (FloodDrops)
                StepFloor = Trace(HL, HN, Bottom, Top, false);
            if (!FloodDrops || StepFloor == None || HN.Z < 0.7 || HL.Z > Top.Z - 2)
            {
                // a plank bridge (SU-IceDet's log bridge to the crystal): thin traces fall between
                // the planks, a pawn's feet do not. A trace as wide as a foot finds them (goal floods only)
                Top = From + Delta + vect(0,0,56);
                if (FloodDrops)
                    StepFloor = Trace(HL, HN, Bottom, Top, false, vect(16,16,4));
                if (!FloodDrops || StepFloor == None || HN.Z < 0.7 || HL.Z > Top.Z - 6)
                {
                    StepWhy = "floor (normal " $ HN.Z $ ", dz " $ int(HL.Z - From.Z) $ ")";
                    return false;
                }
                HL.Z -= 4;
                NumWideSteps++;
            }
        }
    }
    FloorPt = HL;
    Rise = FloorPt.Z - From.Z;
    if (Abs(Rise) > 36)
    {
        if (Abs(Rise) <= 130)
        {
            Mid = (From + FloorPt) * 0.5;
            if (Trace(MHL, MHN, Mid - vect(0,0,160), Mid + vect(0,0,160), false) != None
                && Abs(MHL.Z - (From.Z + Rise * 0.5)) <= Abs(Rise) * 0.3)
                Rise = 0;           // a ramp or stairs: walkable both ways
        }
        // a step a bot jumps up (SU pawns jump about 64 uu): SU-IceDet's gallery is 41 uu below the
        // corridor to Teleporter0. Objective floods only (fix 32)
        if (FloodDrops && Abs(Rise) <= 48)
            Rise = 0;
        if (Rise != 0)
        {
            // Fix 32: in a goal flood, a ledge the flood climbs is a drop for the bots coming the
            // other way (SU-IceDet: the round room of Teleporter0 is 55 uu below its east corridor).
            // The pawn walks off the upper edge and falls: clear lines at knee and head height out
            // over the lower floor, and a clear fall down to it.
            if (!FloodDrops || Rise < 0 || Rise > MaxDropRise)
            {
                StepWhy = "ledge of " $ int(FloorPt.Z - From.Z);
                return false;
            }
            Ext = vect(18,18,12);
            Edge = From;
            Edge.Z = FloorPt.Z;
            StepWhy = "drop: head room";
            if (!FastTrace(FloorPt + vect(0,0,112), FloorPt + vect(0,0,6)))
                return false;
            StepWhy = "drop: wall at knee height";
            if (Trace(HL, HN, Edge + vect(0,0,48), FloorPt + vect(0,0,48), false, Ext) != None)
                return false;
            StepWhy = "drop: wall at head height";
            if (Trace(HL, HN, Edge + vect(0,0,98), FloorPt + vect(0,0,98), false, Ext) != None)
                return false;
            StepWhy = "drop: blocked fall";
            if (Trace(HL, HN, From + vect(0,0,48), Edge + vect(0,0,48), false, Ext) != None)
                return false;
            StepDrop = true;
            StepWhy = "";
            return true;
        }
    }
    Ext = vect(18,18,12);
    StepWhy = "head room";
    if (!FastTrace(FloorPt + vect(0,0,112), FloorPt + vect(0,0,6)))
        return false;
    StepWhy = "wall at knee height";
    if (Trace(HL, HN, FloorPt + vect(0,0,48), From + vect(0,0,48), false, Ext) == None)
    {
        StepWhy = "wall at head height";
        if (Trace(HL, HN, FloorPt + vect(0,0,98), From + vect(0,0,98), false, Ext) == None)
        {
            StepWhy = "";
            return true;
        }
    }
    // objective floods (fix 32): narrower lines at knee and head height (the body-wide box catches
    // door frames and pillar edges a pawn slides past). Not a bare line: on SU-IceDet a corridor ran
    // along a ledge edge through a row of friezes a pawn cannot pass
    Ext = vect(10,10,10);
    if (!FloodDrops || Trace(HL, HN, FloorPt + vect(0,0,40), From + vect(0,0,40), false, Ext) != None
        || Trace(HL, HN, FloorPt + vect(0,0,95), From + vect(0,0,95), false, Ext) != None)
        return false;
    StepWhy = "";
    return true;
}

function int CellKey(vector Loc)
{
    local int X, Y, Z;

    X = FloorDiv(Loc.X, 128) + 1024;
    Y = FloorDiv(Loc.Y, 128) + 1024;
    Z = FloorDiv(Loc.Z, 96) + 256;
    return ((X & 2047) << 20) | ((Y & 2047) << 9) | (Z & 511);
}

// cell index for Key, or -1; inserts Val when Val >= 0 (open addressing)
function int CellFind(int Key, int Val)
{
    local int H, Probes;

    H = ((Key ^ (Key >>> 11) ^ (Key >>> 22)) * 40503) & (HashSize - 1);
    for (Probes = 0; Probes < HashSize; Probes++)
    {
        if (HKeys[H] == 0)
        {
            if (Val >= 0)
            {
                HKeys[H] = Key + 1;
                HVals[H] = Val;
            }
            return -1;
        }
        if (HKeys[H] == Key + 1)
            return HVals[H];
        H = (H + 1) & (HashSize - 1);
    }
    return -1;
}

function AddCell(vector Loc, int Parent)
{
    local int i;

    i = Cells.Length;
    Cells.Length = i + 1;
    Cells[i].Loc = Loc;
    Cells[i].Parent = Parent;
    Cells[i].Drop = 0;
    Cells[i].OnMover = None;
    CellFind(CellKey(Loc), i);
}

function string Vec(vector V)
{
    return int(V.X) $ "," $ int(V.Y) $ "," $ int(V.Z);
}

function IndexNodes()
{
    local NavigationPoint N;

    Nodes.Length = 0;
    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        N.visitedWeight = Nodes.Length;
        Nodes[Nodes.Length] = N;
    }
}

// Strongly connected components of the walk graph over Nodes (indexed): Comp[node] = component,
// returns the number of components. Tarjan's algorithm, iterative (no deep recursion in script).
function int ComputeSCC(out array<int> Comp)
{
    local array<int> Idx, Low, Stk, CallN, CallE;
    local array<byte> OnStk;
    local int i, v, w, NumN, Counter, NumComp, Sp, Cp;
    local ReachSpec R;
    local bool bDescend;

    NumN = Nodes.Length;
    Idx.Length = NumN;
    Low.Length = NumN;
    OnStk.Length = NumN;
    Comp.Length = NumN;
    for (i = 0; i < NumN; i++)
        Idx[i] = -1;
    for (i = 0; i < NumN; i++)
    {
        if (Idx[i] >= 0)
            continue;
        Idx[i] = Counter;
        Low[i] = Counter;
        Counter++;
        Stk[Sp] = i;
        Sp++;
        OnStk[i] = 1;
        CallN[0] = i;
        CallE[0] = 0;
        Cp = 1;
        while (Cp > 0)
        {
            v = CallN[Cp - 1];
            bDescend = false;
            while (CallE[Cp - 1] < Nodes[v].PathList.Length)
            {
                R = Nodes[v].PathList[CallE[Cp - 1]];
                CallE[Cp - 1] = CallE[Cp - 1] + 1;
                if (!Walkable(R))
                    continue;
                w = IndexOf(R.End);
                if (w < 0)
                    continue;
                if (Idx[w] < 0)
                {
                    Idx[w] = Counter;
                    Low[w] = Counter;
                    Counter++;
                    Stk[Sp] = w;
                    Sp++;
                    OnStk[w] = 1;
                    CallN[Cp] = w;
                    CallE[Cp] = 0;
                    Cp++;
                    bDescend = true;
                    break;
                }
                if (OnStk[w] != 0 && Idx[w] < Low[v])
                    Low[v] = Idx[w];
            }
            if (bDescend)
                continue;
            if (Low[v] == Idx[v])
            {
                do
                {
                    Sp--;
                    w = Stk[Sp];
                    OnStk[w] = 0;
                    Comp[w] = NumComp;
                } until (w == v);
                NumComp++;
            }
            Cp--;
            if (Cp > 0 && Low[v] < Low[CallN[Cp - 1]])
                Low[CallN[Cp - 1]] = Low[v];
        }
    }
    return NumComp;
}

// Movers that open by themselves for a pawn coming near: bump-opened doors, and trigger-opened ones
// whose Trigger reacts to pawn proximity. Doors opened by an objective or a switch are left closed.
// Made non-colliding during the walk tests, CloseProximityDoors restores them.
function OpenProximityDoors()
{
    local Mover M;
    local Trigger T;
    local bool bProx;
    local string S;

    foreach AllActors(class'Mover', M)
    {
        if (!M.bCollideActors || !M.bBlockActors || M.NumKeys < 2)
            continue;
        // bumped open. (bBlockPlayers=False does not make a mover passable: movers are encroachers,
        // and pawns collide with them through bBlockActors. SU-Asgard's IonSphere Mover13 shuts the
        // DHD in until "teleports thor" is done; treating it as open sent the bots to crowd against it.)
        bProx = M.InitialState == 'BumpOpenTimed' || M.InitialState == 'StandOpenTimed';
        if (!bProx && M.Tag != 'None' && M.Tag != ''
            && (M.InitialState == 'TriggerControl' || M.InitialState == 'TriggerOpenTimed' || M.InitialState == 'TriggerToggle'))
            foreach AllActors(class'Trigger', T)
                // the trigger must stand by the door: SU-IceDet's light bridge Mover7 is toggled by a
                // trigger at an objective 16 k uu away, it is not open to whoever comes near
                if (T.Event == M.Tag && T.bInitiallyActive && ProximityTrigger(T)
                    && VSize(T.Location - M.Location) < 1500)
                {
                    bProx = true;
                    break;
                }
        if (!bProx)
            continue;
        DoorMovers[DoorMovers.Length] = M;
        DoorBlocksPlayers[DoorBlocksPlayers.Length] = byte(M.bBlockPlayers);
        M.SetCollision(false, false, false);
        if (DoorMovers.Length <= 8)
            S = S $ " " $ M.Name $ "(" $ M.Tag $ ")";
    }
    if (bLogFixes && DoorMovers.Length > 0 && !bDoorsLogged)
        Log("gaps: " $ DoorMovers.Length $ " doors open for pawns that come near, tested as open:" $ S, 'SUBotFix');
}

function bool ProximityTrigger(Trigger T)
{
    switch (T.TriggerType)
    {
        case TT_PlayerProximity:
        case TT_PawnProximity:
        case TT_AnyProximity:
        case TT_LivePlayerProximity:
            return true;
        case TT_ClassProximity:
            return T.ClassProximityType != None && ClassIsChildOf(class'xPawn', T.ClassProximityType);
    }
    return false;
}

// Fix 35b (monster paths): Replicator spawn points have forced specs to rally nodes thousands of uu
// away, across walls the bugs climb (SU-Asgard[Medium]: 66 of them, sized 72x100). Bots routed
// through them and ran into walls near the spawn points for the rest of the round. They are shrunk
// to Replicator size (15x15): the native pathfinder skips specs smaller than the pawn.
function MonsterOnlySpecs()
{
    local NavigationPoint N;
    local int i, Count;
    local ReachSpec R;

    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        if (!N.IsA('SUReplicatorSpawnPoint'))
            continue;
        for (i = 0; i < N.PathList.Length; i++)
        {
            R = N.PathList[i];
            if (R == None || (R.reachFlags & 256) == 0 || R.CollisionHeight <= 18)
                continue;
            R.CollisionRadius = 18;
            R.CollisionHeight = 18;
            Count++;
        }
    }
    if (bLogFixes && Count > 0)
        Log("monster paths: " $ Count $ " forced specs out of Replicator spawn points shrunk to monster size", 'SUBotFix');
}

// Fix 35 (forced paths out of a done objective): on SU-Asgard[Medium], "Teleports the stargate" has a
// forced spec to PathNode38, 4400 uu away (through the gate). Once the objective is done the gate has
// been beamed away, but routes still went through it: every bot of the team gathered on the spot and
// waited there for the rest of the round. Forced specs that start at a done objective are proscribed.
function ProscribeDoneForcedSpecs()
{
    local GameObjective O;
    local int i;
    local ReachSpec R;

    foreach AllActors(class'GameObjective', O)
    {
        if (!O.bDisabled)
            continue;
        for (i = 0; i < O.PathList.Length; i++)
        {
            R = O.PathList[i];
            if (R == None || (R.reachFlags & 256) == 0 || (R.reachFlags & 128) != 0)
                continue;
            R.reachFlags = R.reachFlags | 128;
            Note("forced path from done objective " $ O.Name $ " to " $ R.End.Name $ " (" $ int(VSize(R.End.Location - O.Location))
                $ " uu) proscribed");
        }
    }
}

// Fix 36 (win balance): maps favour one side (bots-only, difficulty 3, 4 games each: SU-Abydos
// Goa'uld 4/4, SU-Chulak Tau'ri 4/4, SU-TokRa mostly Goa'uld, co-op maps always the Replicators).
// Each map keeps a score of its recent rounds (+1 per Goa'uld win, -1 per Tau'ri win, within
// +-MaxBalanceScore). Bots of the side that wins more play BalanceStep lower per point, the others
// as much higher (difficulty 3 with a score of 4: 1 against 5). The score is updated at the end of
// each round and saved, so a server converges on its own.
function BalanceSkills()
{
    local Controller C;
    local Bot B;
    local float Want;
    local TeamInfo W;
    local bool bWere;

    if (!bScoreRead)
    {
        bScoreRead = true;
        MapScore = ReadBalanceScore(MapName());
        if (bLogFixes)
            Log("balance: " $ MapName() $ " score " $ MapScore $ " (" $ ScoreSource $ "), bot skill Goa'uld " $ TeamSkill(0) $ ", Tau'ri " $ TeamSkill(1), 'SUBotFix');
    }
    // fix 69: the gap learned between bots (SU-Antartica at 5: Goa'uld bots at skill 0.5, Tau'ri at 5.5) is held
    // to HumanMaxBias each way while a human plays, so nobody gets useless teammates or harmless enemies
    bWere = bHumansIn;
    bHumansIn = HumanPlaying();
    if (bHumansIn && !bWere && bLogFixes)
        Log("balance: " $ MapName() $ ", a human plays: bot skill Goa'uld " $ TeamSkill(0) $ ", Tau'ri " $ TeamSkill(1), 'SUBotFix');
    if (!bHumansIn && bWere && bLogFixes)
        Log("balance: " $ MapName() $ ", no human left: bot skill Goa'uld " $ TeamSkill(0) $ ", Tau'ri " $ TeamSkill(1), 'SUBotFix');
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.PlayerReplicationInfo == None || B.PlayerReplicationInfo.Team == None)
            continue;
        Want = TeamSkill(B.PlayerReplicationInfo.Team.TeamIndex);
        if (Abs(B.Skill - Want) > 0.01)
            B.InitializeSkill(Want);
    }
    if (!bScoreDone && Level.Game.IsInState('MatchOver') && Level.Game.GameReplicationInfo != None)
    {
        bScoreDone = true;
        W = TeamInfo(Level.Game.GameReplicationInfo.Winner);
        if (W == None || !bBalanceLearn)
            return;
        if (W.TeamIndex == 0)
            MapScore = Min(MapScore + 1, MaxScore());
        else
            MapScore = Max(MapScore - 1, -MaxScore());
        WriteBalanceScore(MapName(), MapScore);
        if (bLogFixes)
            Log("balance: " $ MapName() $ " won by team " $ W.TeamIndex $ ", score now " $ MapScore, 'SUBotFix');
    }
}

// co-op (Replicators): the bots' side may go twice as far (skill 7 at difficulty 3). Asgard[Medium] at
// skill 7 reached 6 of 7 objectives in 7 of 8 games, against 4-6 at skill 5
function int MaxScore()
{
    if (Level.Game.GetPropertyText("bReplicator") ~= "True")
        return 2 * MaxBalanceScore;
    return MaxBalanceScore;
}

function float TeamSkill(int Team)
{
    local float Bias;

    Bias = MapScore * BalanceStep;
    if (bHumansIn && HumanMaxBias >= 0 && !(Level.Game.GetPropertyText("bReplicator") ~= "True"))
        Bias = FClamp(Bias, -HumanMaxBias, HumanMaxBias);
    if (Team == 0)
        Bias = -Bias;
    return FClamp(Level.Game.GameDifficulty + Bias, 0, 7);
}

// fix 69: a human player in a team (not a spectator, not the web admin)
function bool HumanPlaying()
{
    local Controller C;

    if (bTestHuman)
        return true;
    for (C = Level.ControllerList; C != None; C = C.NextController)
        if (PlayerController(C) != None && MessagingSpectator(C) == None && C.PlayerReplicationInfo != None
            && !C.PlayerReplicationInfo.bOnlySpectator && !C.PlayerReplicationInfo.bBot)
            return true;
    return false;
}

// Fix 70: bots that seemed to teleport to the objective (a player's feedback, 2026-11-12). Every Tau'ri spawn of
// SU-Abydos is hopped (fixes 3 and 28: 60 k uu straight, 82-85 k uu of walk, to 11 k uu before the front), so a Tau'ri
// bot was back at the front a second after dying, while a player drives a Hummer for a minute (bots drive one at
// 400-1000 uu/s). While a human plays, a bot whose team only has hopped spawns stays dead as long as that drive
// takes at HopTransitSpeed, from the nearest of its team's spawns; then it respawns and hops as before. Not in
// co-op, and not for a team with a spawn that is walkable or left through rings (players use the rings too).
function HoldTransits()
{
    local Controller C;
    local Bot B;
    local int i;
    local float T;

    for (i = TransitBots.Length - 1; i >= 0; i--)
        if (TransitBots[i] == None || TransitBots[i].bDeleteMe || TransitBots[i].Pawn != None
            || !TransitBots[i].IsInState('Dead'))
        {
            TransitBots.Remove(i, 1);
            TransitUntil.Remove(i, 1);
        }
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn != None || B.PlayerReplicationInfo == None || !B.IsInState('Dead'))
            continue;
        for (i = 0; i < TransitBots.Length && TransitBots[i] != B; i++);
        if (i == TransitBots.Length)
        {
            T = 0;
            if (Level.Game.IsInState('MatchInProgress') && !Level.Game.bGameEnded && HumanPlaying()
                && !(Level.Game.GetPropertyText("bReplicator") ~= "True"))
                T = TransitTime(B.GetTeamNum());
            TransitBots[i] = B;
            TransitUntil[i] = Level.TimeSeconds + T;
            if (T >= 1)
            {
                NumTransits++;
                TransitSecs += T;
                if (bLogFixes)
                    Log("transit: " $ B.PlayerReplicationInfo.PlayerName $ " (team " $ B.GetTeamNum() $ ") respawns in " $ int(T)
                        $ " s, the drive from " $ TransitFrom.Name $ " to " $ TransitTo.Name, 'SUBotFix');
            }
        }
        // the Dead state restarts the bot 0.45-2 s after Begin: keep sending it back there
        if (Level.TimeSeconds < TransitUntil[i])
            B.GotoState('Dead', 'Begin');
    }
}

// fix 70: seconds of the drive from the team's nearest enabled spawn to its hop target, at HopTransitSpeed;
// 0 when one of the team's enabled spawns is not hopped, and on space maps (SU-Antartica: every start is "stranded",
// but bots spawn in their craft and are never hopped; the first version held them 67-70 s)
function float TransitTime(int Team)
{
    local NavigationPoint N;
    local PlayerStart S;
    local float D, Best;
    local int i;

    if (Level.Game.GetPropertyText("bSpaceCrafts") ~= "True")
        return 0;
    Best = -1;
    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        S = PlayerStart(N);
        if (S == None || !S.bEnabled || S.TeamNumber != Team)
            continue;
        for (i = 0; i < StrandedStarts.Length && StrandedStarts[i] != S; i++);
        if (i == StrandedStarts.Length || StrandedExit[i] == None)
            return 0;
        D = VSize(StrandedExit[i].Location - S.Location);
        if (Best < 0 || D < Best)
        {
            Best = D;
            TransitFrom = S;
            TransitTo = StrandedExit[i];
        }
    }
    if (Best < 0)
        return 0;
    return Best / HopTransitSpeed;
}

function string MapName()
{
    local string S;

    S = string(Level.Outer.Name);
    return S;
}

function int ReadBalanceScore(string M)
{
    local int i;

    if (BalData == None)
        BalData = new class'SUBalanceData';
    for (i = 0; i < BalData.Scores.Length; i++)
        if (Left(BalData.Scores[i], Len(M) + 1) ~= (M $ "="))
        {
            ScoreSource = "learned, SUBotFixBalance.ini";
            return Clamp(int(Mid(BalData.Scores[i], Len(M) + 1)), -MaxScore(), MaxScore());
        }
    // not learned yet: the starting score
    ScoreSource = "starting score";
    for (i = 0; i < BalanceScores.Length; i++)
        if (Left(BalanceScores[i], Len(M) + 1) ~= (M $ "="))
            return Clamp(int(Mid(BalanceScores[i], Len(M) + 1)), -MaxScore(), MaxScore());
    return 0;
}

function WriteBalanceScore(string M, int Score)
{
    local int i;

    if (BalData == None)
        BalData = new class'SUBalanceData';
    for (i = 0; i < BalData.Scores.Length; i++)
        if (Left(BalData.Scores[i], Len(M) + 1) ~= (M $ "="))
            break;
    BalData.Scores[i] = M $ "=" $ Score;
    BalData.SaveConfig();
}

// Fix 34 (bridges that appear): SU-IceDet's light bridge Mover7 ('pontlum') is toggled on by a
// trigger at stage 4, 16 k uu away, and is the only way to the last objective. During the load-time
// corridor floods, remote-triggered movers whose open position is a floor are put there; corridor
// links that touch them are only created once the mover really is open (GateLinks, every second).
function OpenBridges()
{
    local Mover M;
    local Trigger T;
    local bool bNear, bRemote;
    local vector Open, HL, HN, P;
    local Actor HitA;
    local int k;

    BridgeMovers.Length = 0;
    BridgeClosedLoc.Length = 0;
    foreach AllActors(class'Mover', M)
    {
        if (!M.bCollideActors || !M.bBlockActors || M.NumKeys < 2 || M.KeyNum != 0 || M.Tag == 'None' || M.Tag == ''
            || (M.InitialState != 'TriggerToggle' && M.InitialState != 'TriggerControl' && M.InitialState != 'TriggerOpenTimed'))
            continue;
        bNear = false;
        bRemote = false;
        foreach AllActors(class'Trigger', T)
            if (T.Event == M.Tag)
            {
                if (VSize(T.Location - M.Location) < 1500)
                    bNear = true;
                else
                    bRemote = true;
            }
        if (bNear || !bRemote)
            continue;
        BridgeMovers[BridgeMovers.Length] = M;
        BridgeClosedLoc[BridgeClosedLoc.Length] = M.Location;
        // KeyPos is too large to read from here (288 bytes): parse its text
        Open = M.BasePos + TextVector(M.GetPropertyText("KeyPos"), 1);
        M.SetLocation(Open);
        // a floor once open: something walkable on top of it, around its pivot (the pivot itself can
        // fall in a gap of the mesh)
        HitA = None;
        for (k = 0; k < 9 && HitA != M; k++)
        {
            P = Open + vect(1,0,0) * (((k % 3) - 1) * 300) + vect(0,1,0) * (((k / 3) - 1) * 300);
            HitA = Trace(HL, HN, P - vect(0,0,300), P + vect(0,0,200), false);
            if (HN.Z < 0.7)
                HitA = None;
        }
        if (HitA != M)
        {
            M.SetLocation(BridgeClosedLoc[BridgeClosedLoc.Length - 1]);
            BridgeMovers.Length = BridgeMovers.Length - 1;
            BridgeClosedLoc.Length = BridgeClosedLoc.Length - 1;
            continue;
        }
        if (bLogFixes)
            Log("bridges: " $ M.Name $ " ('" $ M.Tag $ "') is a floor once triggered: open during the corridor floods", 'SUBotFix');
    }
}

// element Index of an exported vector array: "(X=..,Y=..,Z=..),(X=..,Y=..,Z=..),..."
function vector TextVector(string S, int Index)
{
    local array<string> Parts, XYZ;
    local vector V;
    local int i;

    Split(S, "),(", Parts);
    if (Index >= Parts.Length)
        return V;
    S = Parts[Index];
    S = Repl(Repl(S, "(", ""), ")", "");
    Split(S, ",", XYZ);
    for (i = 0; i < XYZ.Length; i++)
    {
        if (Left(XYZ[i], 2) == "X=")
            V.X = float(Mid(XYZ[i], 2));
        else if (Left(XYZ[i], 2) == "Y=")
            V.Y = float(Mid(XYZ[i], 2));
        else if (Left(XYZ[i], 2) == "Z=")
            V.Z = float(Mid(XYZ[i], 2));
    }
    return V;
}

// Objectives with a proximity trigger right beside them that switches a mover elsewhere (SU-IceDet:
// Trigger2, 45 uu from SUTriggeredObjective0, turns the light bridge on). Players step on it while
// using the objective; bots use the objective from a little farther and never touched it, so the
// bridge never came. Once the objective is done, a bot near the trigger touches it (once).
function FindObjectiveTriggers()
{
    local GameObjective O;
    local Trigger T;
    local Mover M;
    local bool bRemote;

    ObjTrigObj.Length = 0;
    ObjTrigT.Length = 0;
    ObjTrigDone.Length = 0;
    ObjTrigNext.Length = 0;
    foreach AllActors(class'GameObjective', O)
        foreach AllActors(class'Trigger', T)
        {
            if (VSize(T.Location - O.Location) > 150 || T.Event == 'None' || T.Event == '' || !ProximityTrigger(T))
                continue;
            bRemote = false;
            foreach AllActors(class'Mover', M)
                if (M.Tag == T.Event && VSize(M.Location - T.Location) > 1500)
                    bRemote = true;
            if (!bRemote)
                continue;
            ObjTrigObj[ObjTrigObj.Length] = O;
            ObjTrigT[ObjTrigT.Length] = T;
            ObjTrigDone[ObjTrigDone.Length] = 0;
            if (bLogFixes)
                Log("objective trigger: " $ T.Name $ " beside " $ O.Name $ " switches '" $ T.Event $ "'", 'SUBotFix');
        }
}

// Fix 49: the trigger is stepped on only while its remote mover is closed and at rest. Mover7 is a
// toggle: bots doing SUTriggeredObjective0 had already walked over Trigger2 and opened the bridge,
// and the touch below shut it again (2 of 8 games stuck at stage 5 for 20 minutes). If nobody is
// near the trigger 10 s after the objective is done with the mover still closed, the attacking bot
// nearest to it walks there (SUBotSquadAI, ErrandGoalFor) and steps on it once within 300 uu, as a
// player would go back for it. (It used to step on it from anywhere: fix 54.)
function TouchObjectiveTriggers()
{
    local int i;
    local Controller C, Best;
    local Mover M;
    local bool bClosed;
    local float D, BestD;

    if (ErrandBot != None && (ErrandBot.Pawn == None || Level.TimeSeconds > ErrandUntil))
    {
        ErrandBot = None;
        ErrandGoal = None;
    }

    if (ObjTrigNext.Length < ObjTrigT.Length)
        ObjTrigNext.Length = ObjTrigT.Length;
    for (i = 0; i < ObjTrigT.Length; i++)
    {
        if (ObjTrigObj[i] == None || !ObjTrigObj[i].bDisabled || ObjTrigT[i] == None || Level.TimeSeconds < ObjTrigNext[i])
            continue;
        if (ObjTrigNext[i] == 0)
        {
            ObjTrigNext[i] = Level.TimeSeconds;      // when the objective was seen done
            ObjTrigDone[i] = 0;
        }
        bClosed = false;
        foreach AllActors(class'Mover', M)
            if (M.Tag == ObjTrigT[i].Event && VSize(M.Location - ObjTrigT[i].Location) > 1500 && M.KeyNum == 0 && !M.bInterpolating)
                bClosed = true;
        if (!bClosed)
            continue;
        Best = None;
        BestD = 300;
        if (ObjTrigDone[i] >= 10)
            BestD = 1000000;
        for (C = Level.ControllerList; C != None; C = C.NextController)
        {
            if (Bot(C) == None || C.Pawn == None || Vehicle(C.Pawn) != None || C.PlayerReplicationInfo == None
                || C.GetTeamNum() == ObjTrigObj[i].DefenderTeamIndex
                || (BestD > 300 && C != ErrandBot && BotTask(Bot(C)) != ''))
                continue;
            D = VSize(C.Pawn.Location - ObjTrigT[i].Location);
            if (D < BestD)
            {
                Best = C;
                BestD = D;
            }
        }
        if (Best == None)
        {
            if (ObjTrigDone[i] < 10)
                ObjTrigDone[i]++;               // seconds waited for a bot near the trigger
            continue;
        }
        if (BestD > 300)
        {
            // too far to step on it: send it there
            if (ErrandBot == None)
            {
                ErrandBot = Bot(Best);
                ErrandGoal = ObjTrigT[i];
                ErrandUntil = Level.TimeSeconds + 60;
                ErrandBot.WhatToDoNext(70);
                if (bLogFixes)
                    Log("objective trigger: " $ Best.PlayerReplicationInfo.PlayerName $ " goes back to " $ ObjTrigT[i].Name
                        $ " ('" $ ObjTrigT[i].Event $ "', " $ int(BestD) $ " uu away) after " $ ObjTrigObj[i].Name, 'SUBotFix');
            }
            continue;
        }
        if (ErrandGoal == ObjTrigT[i])
        {
            ErrandBot = None;
            ErrandGoal = None;
        }
        ObjTrigT[i].Touch(Best.Pawn);
        ObjTrigNext[i] = Level.TimeSeconds + 5;
        if (bLogFixes)
            Log("objective trigger: " $ Best.PlayerReplicationInfo.PlayerName $ " steps on " $ ObjTrigT[i].Name
                $ " ('" $ ObjTrigT[i].Event $ "', " $ int(BestD) $ " uu away) after " $ ObjTrigObj[i].Name, 'SUBotFix');
    }
}

function bool MoverAtOpenKey(Mover M)
{
    // (TriggerToggle movers keep bOpening set once open: the position alone tells)
    return M != None && M.KeyNum != 0
        && VSize(M.Location - (M.BasePos + TextVector(M.GetPropertyText("KeyPos"), M.KeyNum))) <= 8;
}

function ReachSpec SpecTo(NavigationPoint A, NavigationPoint B)
{
    local int i;

    for (i = 0; i < A.PathList.Length; i++)
        if (A.PathList[i] != None && A.PathList[i].End == B)
            return A.PathList[i];
    return None;
}

function CloseBridges()
{
    local int i;

    for (i = 0; i < BridgeMovers.Length; i++)
        if (BridgeMovers[i] != None)
        {
            BridgeMovers[i].SetLocation(BridgeClosedLoc[i]);
        }
    BridgeMovers.Length = 0;
    BridgeClosedLoc.Length = 0;
}

function AddGate(NavigationPoint From, NavigationPoint To, Mover M)
{
    GateFrom[GateFrom.Length] = From;
    GateTo[GateTo.Length] = To;
    GateMover[GateMover.Length] = M;
}

// links waiting for a mover: create them once it stands at its open key; then close them (R_PROSCRIBED)
// whenever the mover leaves it, and open them again when it is back (fix 49: Mover7 is a toggle)
function GateLinks()
{
    local int i;
    local Mover M;
    local bool bAny, bOpen;
    local ReachSpec R;

    for (i = GateFrom.Length - 1; i >= 0; i--)
    {
        M = GateMover[i];
        if (!MoverAtOpenKey(M))
            continue;
        Link(GateFrom[i], GateTo[i], 1);
        R = SpecTo(GateFrom[i], GateTo[i]);
        if (R != None)
        {
            GateSpec[GateSpec.Length] = R;
            GateSpecMover[GateSpecMover.Length] = M;
        }
        if (bLogFixes)
            Note("bridges: " $ M.Name $ " is open, linked " $ GateFrom[i].Name $ " -> " $ GateTo[i].Name);
        GateFrom.Remove(i, 1);
        GateTo.Remove(i, 1);
        GateMover.Remove(i, 1);
        bAny = true;
    }
    for (i = 0; i < GateSpec.Length; i++)
    {
        if (GateSpec[i] == None)
            continue;
        bOpen = MoverAtOpenKey(GateSpecMover[i]);
        if (bOpen && (GateSpec[i].reachFlags & 128) != 0)
        {
            GateSpec[i].reachFlags = GateSpec[i].reachFlags & ~128;
            bAny = true;
            Note("bridges: " $ GateSpecMover[i].Name $ " is open again, its links too");
        }
        else if (!bOpen && (GateSpec[i].reachFlags & 128) == 0)
        {
            GateSpec[i].reachFlags = GateSpec[i].reachFlags | 128;
            bAny = true;
            Note("bridges: " $ GateSpecMover[i].Name $ " closed again, its links closed too");
        }
    }
    if (bAny && RebridgeStep == 0)
        RebridgeStep = 3;       // reachability and approach points again
}

function bool HasSpec(NavigationPoint A, NavigationPoint B)
{
    local int k;

    for (k = 0; k < A.PathList.Length; k++)
        if (A.PathList[k] != None && A.PathList[k].End == B)
            return true;
    return false;
}

function bool DropRefused(NavigationPoint A, NavigationPoint B)
{
    local int k;

    for (k = 0; k < RefusedFrom.Length; k++)
        if (RefusedFrom[k] == A && RefusedTo[k] == B)
            return true;
    return false;
}

function CloseProximityDoors()
{
    local int i;

    for (i = 0; i < DoorMovers.Length; i++)
        if (DoorMovers[i] != None)
            DoorMovers[i].SetCollision(true, true, DoorBlocksPlayers[i] != 0);
    DoorMovers.Length = 0;
    DoorBlocksPlayers.Length = 0;
    bDoorsLogged = true;
}

function int FindComp(out array<int> UF, int c)
{
    while (UF[c] != c)
    {
        UF[c] = UF[UF[c]];
        c = UF[c];
    }
    return c;
}

// a plain floor node a gap link may join (no objective, door, lift, jump pad, flying node, water).
// Teleporters count: walking into one is how it is used (SU-IceDet Teleporter0, in the phase-2
// spawn room, had no link from that room at all)
function bool GapNode(NavigationPoint N)
{
    if (N == None || N.PhysicsVolume == None || N.PhysicsVolume.bWaterVolume)
        return false;
    if (N.IsA('FlyingPathNode') || N.IsA('RoadPathNode'))
        return false;
    return PathNode(N) != None || PlayerStart(N) != None || InventorySpot(N) != None || Teleporter(N) != None;
}

// Find a point M with walkable straight lines N -> M and M -> O, put a pool node there and link it.
function bool DogLeg(NavigationPoint N, NavigationPoint O)
{
    local vector Dir, Perp, M, HL, HN;
    local float Len, T, Off;
    local int ti, oi, s;
    local SUBotNavNode X;

    if (NodePool.Length == 0)
        return false;
    Len = VSize(O.Location - N.Location);
    Dir = Normal(O.Location - N.Location);
    Perp = Normal(Dir Cross vect(0,0,1));
    for (oi = 1; oi <= 4; oi++)
        for (s = -1; s <= 1; s += 2)
            for (ti = 1; ti <= 3; ti++)
            {
                T = Len * (0.25 * ti);
                Off = 150 * oi * s;
                M = N.Location + Dir * T + Perp * Off;
                if (Trace(HL, HN, M - vect(0,0,400), M + vect(0,0,200), false) == None || HN.Z < 0.7)
                    continue;
                M = HL + vect(0,0,45);
                if (!FastTrace(M, M - vect(0,0,40)) && !FastTrace(M + vect(0,0,60), M))
                    continue;
                if (!WalkLine(N.Location, M) || !WalkLine(M, InFront(O, M)))
                    continue;
                X = NodePool[NodePool.Length - 1];
                if (!X.SetLocation(M) || !RegisterNav(X))
                    return false;
                NodePool.Remove(NodePool.Length - 1, 1);
                if (Link(N, X, 1) == None || Link(X, O, 1) == None)
                    return false;
                Link(X, N, 1);
                Link(O, X, 1);
                if (bLogFixes)
                    Log("objective " $ O.Name $ " had no path: linked to " $ N.Name $ " through new node " $ X.Name
                        $ " at " $ int(M.X) $ "," $ int(M.Y) $ "," $ int(M.Z), 'SUBotFix');
                return true;
            }
    return false;
}

// append a runtime node to Level.NavigationPointList
function bool RegisterNav(NavigationPoint X)
{
    local NavigationPoint N, Tail;
    local int Guard;

    for (N = Level.NavigationPointList; N != None && Guard < 100000; N = N.NextNavigationPoint)
    {
        Guard++;
        if (N == X)
            return true;
        Tail = N;
    }
    if (Tail == None || Guard >= 100000)
        return false;
    return AppendNav(Tail, X);
}

// Can an SU pawn walk the straight line A -> B? Floor sampled every 32 uu: no step over 40 uu,
// walkable slope, body (floor+40) and head room (floor+80..112) clear between samples.
function bool WalkLine(vector A, vector B)
{
    local vector Dir, P, Up, Down, HL, HN, PrevFloor, Floor, BodyExt, HeadExt;
    local float Len, T;
    local int Steps, i;

    // body box 36..60 above the floor (a pawn steps over 35 uu), head box 86..110 (55 uu pawn)
    BodyExt = vect(18,18,12);
    HeadExt = vect(18,18,12);
    Len = VSize(B - A);
    if (Len < 1)
        return true;
    Dir = (B - A) / Len;
    Steps = Max(1, int(Len / 32));
    for (i = 0; i <= Steps; i++)
    {
        T = FMin(Len, i * 32.0);
        P = A + Dir * T;
        // start the floor trace below the ceiling: in low corridors P + 120 is inside the ceiling
        // slab and the trace hits its back face (SU-Abydos room under the rings)
        Up = P + vect(0,0,120);
        if (Trace(HL, HN, Up, P, false) != None)
            Up = HL - vect(0,0,4);
        Down = P - vect(0,0,300);
        if (Trace(HL, HN, Down, Up, false) == None || HN.Z < 0.7)
        {
            WalkWhy = "no walkable floor at sample " $ i $ "/" $ Steps $ " (normal z " $ HN.Z $ ")";
            return false;
        }
        Floor = HL;
        if (i > 0)
        {
            if (Abs(Floor.Z - PrevFloor.Z) > 40)
            {
                WalkWhy = "step of " $ int(Floor.Z - PrevFloor.Z) $ " uu at sample " $ i $ "/" $ Steps;
                return false;
            }
            if (Trace(HL, HN, Floor + vect(0,0,48), PrevFloor + vect(0,0,48), false, BodyExt) != None)
            {
                WalkWhy = "wall at sample " $ i $ "/" $ Steps;
                return false;
            }
            if (Trace(HL, HN, Floor + vect(0,0,98), PrevFloor + vect(0,0,98), false, HeadExt) != None)
            {
                WalkWhy = "low ceiling at sample " $ i $ "/" $ Steps;
                return false;
            }
        }
        PrevFloor = Floor;
    }
    return true;
}

// One-directional walk ReachSpec From -> To appended to From.PathList, or None. Start/End/PathList
// are const: written with POKE, every write verified. The spec gets an explicit name (after startup
// the engine names new objects like their class, and ImportText cannot resolve such names).
function ReachSpec Link(NavigationPoint From, NavigationPoint To, int Flags)
{
    local ReachSpec R;
    local int i;
    local array<ReachSpec> Orig;

    for (i = 0; i < From.PathList.Length; i++)
        if (From.PathList[i] != None && From.PathList[i].End == To)
            return From.PathList[i];
    R = new(Level.Outer, "SUBotFixSpec_" $ NumNewSpecs) class'ReachSpec';
    if (R == None)
        return None;
    Poke(R, "Start", Ref(From));
    Poke(R, "End", Ref(To));
    if ((R.Start != From || R.End != To) && !bBareRefs)
    {
        bBareRefs = true;
        Poke(R, "Start", Ref(From));
        Poke(R, "End", Ref(To));
    }
    if (R.Start != From || R.End != To)
    {
        Log("link " $ From.Name $ " -> " $ To.Name $ ": could not set the spec ends", 'SUBotFix');
        return None;
    }
    R.Distance = Max(1, int(VSize(To.Location - From.Location)));
    R.CollisionRadius = 40;
    R.CollisionHeight = Max(PawnHeight, 60);
    R.reachFlags = Flags;
    R.MaxLandingVelocity = 0;
    R.bPruned = 0;
    R.bForced = false;
    for (i = 0; i < From.PathList.Length; i++)
        if (From.PathList[i] != None)
            Orig[Orig.Length] = From.PathList[i];
    Poke(From, "PathList", PathListText(Orig, R));
    if (!PathListIs(From, Orig, R) && !bBareRefs)
    {
        bBareRefs = true;
        Poke(From, "PathList", PathListText(Orig, R));
    }
    if (!PathListIs(From, Orig, R))
    {
        Log("link " $ From.Name $ " -> " $ To.Name $ ": could not append to PathList", 'SUBotFix');
        return None;
    }
    // keep the node's cached max path size right (NavigationPoint.PostBeginPlay computes it at load)
    From.MaxPathSize.X = FMax(From.MaxPathSize.X, R.CollisionRadius);
    From.MaxPathSize.Y = From.MaxPathSize.X;
    From.MaxPathSize.Z = FMax(From.MaxPathSize.Z, R.CollisionHeight);
    NumNewSpecs++;
    return R;
}

function string PathListText(array<ReachSpec> Orig, ReachSpec R)
{
    local string S;
    local int i;

    S = "(";
    for (i = 0; i < Orig.Length; i++)
        S = S $ Ref(Orig[i]) $ ",";
    return S $ Ref(R) $ ")";
}

function bool PathListIs(NavigationPoint From, array<ReachSpec> Orig, ReachSpec R)
{
    local int i;

    if (From.PathList.Length != Orig.Length + 1 || From.PathList[Orig.Length] != R)
        return false;
    for (i = 0; i < Orig.Length; i++)
        if (From.PathList[i] != Orig[i])
            return false;
    return true;
}

// Text reference as ImportText expects it: Class'Package.Name', or the bare name.
function string Ref(Object O)
{
    if (O == None)
        return "None";
    if (bBareRefs)
        return string(O.Class.Name) $ "'" $ string(O.Name) $ "'";
    return string(O.Class.Name) $ "'" $ string(O) $ "'";
}

// Write one property of one object, ignoring const (Core's POKE console command).
function Poke(Object O, string Prop, string Value)
{
    ConsoleCommand("poke " $ O.Class.Name $ " " $ string(O) $ " " $ Prop $ " " $ Value);
}

// ---------------------------------------------------------------- space pilots

// Fix 11 (spacecraft maps: SU-Antartica, SU-Asteroid): bots spawn straight into flying craft
// (DeathGlider, X-302, Ha'tak, Daedalus...) on maps with no usable navigation, find no route and
// hover in RestFormation. Open space needs no waypoints: when a pilot has no enemy in sight, fly
// it straight at the nearest objective it can shoot down (else at the nearest enemy: crystals and
// proximity objectives cannot be done from a cockpit),
// and open fire on a destroyable objective once it is in sight. Dogfights stay with the stock AI.
function SpacePilots()
{
    local Controller C;
    local Bot B;
    local Actor T;
    local GameObjective O;
    local int i;
    local vector AP;

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn == None || Vehicle(B.Pawn) == None
            || (B.Pawn.Physics != PHYS_Flying && !B.Pawn.IsA('ONSChopperCraft')))
            continue;
        if (B.Squad != None && PlayerController(B.Squad.SquadLeader) != None)
            continue;       // following a human player's orders
        // Fix 38: a capital ship in a fight at long range closes in (SU-Antartica: the Daedalus
        // traded shots at 16 k uu while the Ha'tak shelled the Teltac from 4 k uu); stock combat
        // only takes over within CapitalFightRange
        if (B.Pawn.IsA('ONSChopperCraft') && ((B.Enemy != None && B.EnemyVisible()) || B.IsInState('RangedAttack')))
        {
            T = CapitalTarget(B);
            if (T == None || VSize(T.Location - B.Pawn.Location) < CapitalFightRange)
                continue;
        }
        else if (B.IsInState('RangedAttack') || (B.Enemy != None && B.EnemyVisible()))
            continue;
        i = PilotIndex(B);
        if (i >= 0 && (Level.TimeSeconds < Pilots[i].AvoidUntil || Level.TimeSeconds < Pilots[i].BreakUntil))
            continue;
        // Capital ships (Ha'tak, Daedalus, X-303: Karma choppers, which the PHYS_Flying test above
        // used to skip) sat in RestFormation, so their turret gunners never had an enemy in range
        // (SU-Antartica: one game in three without a fight). Close in on the enemy fleet, then let
        // the gunners and the stock AI fight from there.
        if (B.Pawn.IsA('ONSChopperCraft'))
        {
            // Fix 42: an attacking capital ship under the guns of an enemy capital ship fights it
            // before the objective (SU-Antartica: the Ha'tak kept shelling the Teltac while the
            // Daedalus and the X-303 shot it down six times a game; it respawned each time, and the
            // Teltac does not heal)
            T = DuelTarget(B);
            if (T != None)
            {
                if (B.Target != T || !B.IsInState('RangedAttack'))
                {
                    B.GoalString = "SUBotFix: capital ship fights " $ T.Name;
                    B.Focus = T;
                    B.DoRangedAttackOn(T);
                    NumDuels++;
                }
                continue;
            }
            T = CapitalTarget(B);
            if (T == None || VSize(T.Location - B.Pawn.Location) < 4500)
                continue;
            if (B.MoveTarget == T && B.IsInState('Roaming'))
                continue;
            B.GoalString = "SUBotFix: capital ship closes in on " $ T.Name;
            B.RouteGoal = T;
            B.MoveTarget = T;
            B.GotoState('Roaming', 'Begin');
            Note("capital ship: " $ B.PlayerReplicationInfo.PlayerName $ " (" $ B.Pawn.Class.Name $ ") closes in on " $ T.Name);
            continue;
        }
        T = PilotTarget(B);
        if (T == None)
            continue;
        O = GameObjective(T);
        if (O != None && O.bProjTarget && VSize(O.Location - B.Pawn.Location) < 6000 && B.LineOfSightTo(O))
        {
            B.GoalString = "SUBotFix: pilot attacks " $ O.Name;
            B.DoRangedAttackOn(O);
            continue;
        }
        // an objective on the face of an asteroid (SU-Asteroid's extractors: hittable from 5-17 of 26
        // directions): fly to a point 2500 uu out from which a shot reaches it, attack from there
        if (O != None && O.bProjTarget && VSize(O.Location - B.Pawn.Location) < 15000)
        {
            AP = AttackPoint(O, B.Pawn.Location);
            if (AP != vect(0,0,0))
            {
                if (VSize(AP - B.Pawn.Location) < PilotAttackRadius)
                {
                    B.GoalString = "SUBotFix: pilot attacks " $ O.Name $ " from its open side";
                    B.Focus = O;
                    B.DoRangedAttackOn(O);
                    continue;
                }
                if (i < 0)
                {
                    i = Pilots.Length;
                    Pilots.Length = i + 1;
                    Pilots[i].B = B;
                    Pilots[i].P = Spawn(class'SUBotFlyPoint',,, AP);
                }
                if (Pilots[i].P == None)
                    Pilots[i].P = Spawn(class'SUBotFlyPoint',,, AP);
                if (Pilots[i].P != None)
                {
                    Pilots[i].P.SetLocation(AP);
                    B.GoalString = "SUBotFix: pilot flies to the open side of " $ O.Name;
                    B.RouteGoal = O;
                    B.MoveTarget = Pilots[i].P;
                    B.GotoState('Roaming', 'Begin');
                    continue;
                }
            }
        }
        if (B.MoveTarget == T && (B.IsInState('Roaming') || B.IsInState('Fallback')))
            continue;
        B.GoalString = "SUBotFix: pilot flies to " $ T.Name;
        B.RouteGoal = T;
        B.MoveTarget = T;
        B.GotoState('Roaming', 'Begin');
        Note("space pilot: " $ B.PlayerReplicationInfo.PlayerName $ " (" $ B.Pawn.Class.Name $ ") flies to " $ T.Name);
    }
}

// SU fighters take ((impact speed - 200) / 100)^2 damage per collision (dead at ~2000 uu/s): look
// 1.5 s ahead along the velocity and steer to a clear point when an asteroid or a wall is in the way.
// Fix 40: fighters shoot objectives from close enough to be fought. On SU-Antartica the Goa'uld
// gliders shelled the Teltac (720 uu across) from more than 15 k uu, out of reach of the Tau'ri
// ships and turrets: in 6 games, 7600-10300 of its 12000 health went to glider shots (SUDiag DMGOBJ).
// The stock objective code attacks whatever is in sight; beyond PilotObjectiveRange the pilot
// flies closer first.
// Fix 43: capital ship gunners shoot through their own hull. Bots aim by line of sight, which a
// vehicle does not block, and the bolts hit the ship they are fired from (SU-Antartica, SUDiag DAMAGE:
// X-303 turret 743-1993 hits a game on the X-303, Daedalus turret 871-2470 on the Daedalus, Ha'tak
// turret 441-2501 on the Ha'tak, all wasted). A gunner whose shot would hit its own ship turns to an
// enemy it can hit, or holds fire. Fix 55 adds the Hummer rear gun: on SU-IceDet two thirds of its hits
// (169 of 257 in 16 games) landed on a Hummer, at about 2 damage each (friendly fire).
// Fix 72: defenders let the fighters destroy what they defend. On SU-Antartica, once the Goa'uld gliders stopped
// crashing (fix 71), they did most of the Teltac's damage and the Goa'uld won 8 games of 8, while the Tau'ri ships,
// their gunners and their X-302s shot at the Ha'tak (CTRL samples: Daedalus turret 434 on a capital ship against 164
// on a fighter). Their guns fire homing bolts at the bot's enemy (Weapon_DaedalusGun, Weapon_X303Gun). A bot in a
// ship, a ship's gun or a fighter, whose squad defends a destroyable objective, now turns on the enemy fighter
// nearest to it within GuardFighterRange, when it sees it (a gunner: when its own hull is not in the way).
function GuardFromFighters()
{
    local Controller C, E;
    local Bot B;
    local GameObjective O;
    local Vehicle V, Ship, F, Best;
    local ONSWeaponPawn W;
    local vector Start, HL, HN;
    local float D, BestD;
    local int Team;

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Squad == None || PlayerController(B.Squad.SquadLeader) != None)
            continue;
        V = Vehicle(B.Pawn);
        if (V == None)
            continue;
        W = ONSWeaponPawn(V);
        Ship = V;
        if (W != None)
            Ship = W.VehicleBase;
        if (Ship == None || !(Ship.IsA('ONSChopperCraft') || Ship.Physics == PHYS_Flying))
            continue;
        Team = B.GetTeamNum();
        O = B.Squad.SquadObjective;
        if (O == None || O.bDisabled || !O.bActive || !O.bProjTarget || O.DefenderTeamIndex != Team)
            continue;
        Start = V.Location;
        if (W != None && W.Gun != None && W.Gun.WeaponFireLocation != vect(0,0,0))
            Start = W.Gun.WeaponFireLocation;
        F = Vehicle(B.Enemy);
        if (F != None && GuardTarget(F, O, Team) && B.LineOfSightTo(F)
            && (W == None || Trace(HL, HN, F.Location, Start, true) != Ship))
            continue;
        Best = None;
        BestD = GuardFighterRange + O.CollisionRadius;
        for (E = Level.ControllerList; E != None; E = E.NextController)
        {
            F = Vehicle(E.Pawn);
            if (F == None || !GuardTarget(F, O, Team))
                continue;
            D = VSize(F.Location - O.Location);
            if (D >= BestD || VSize(F.Location - Start) > 15000 || !B.LineOfSightTo(F)
                || (W != None && Trace(HL, HN, F.Location, Start, true) == Ship))
                continue;
            BestD = D;
            Best = F;
        }
        if (Best == None)
            continue;
        NumGuardShots++;
        B.Enemy = Best;
        B.Target = Best;
        B.Focus = Best;
        if (W == None && Ship.Physics == PHYS_Flying)
        {
            B.GoalString = "SUBotFix: fighter goes for " $ Best.Name $ " attacking " $ O.Name;
            B.WhatToDoNext(72);
        }
        else if (!B.IsInState('RangedAttack'))
        {
            B.GoalString = "SUBotFix: fires at " $ Best.Name $ " attacking " $ O.Name;
            B.DoRangedAttackOn(Best);
        }
    }
}

// fix 72: an enemy fighter (not a capital ship), alive and flown, within GuardFighterRange of O
function bool GuardTarget(Vehicle F, GameObjective O, int Team)
{
    return F.Health > 0 && F.Controller != None && F.Physics == PHYS_Flying && !F.IsA('ONSChopperCraft')
        && F.GetTeamNum() != Team && F.GetTeamNum() != 255
        && VSize(F.Location - O.Location) < GuardFighterRange + O.CollisionRadius;
}

function TurretClearShots()
{
    local Controller C;
    local Bot B;
    local ONSWeaponPawn W;
    local Pawn T, P, Best;
    local vector Start, HL, HN;
    local float D, BestD;
    local Actor H;

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None)
            continue;
        W = ONSWeaponPawn(B.Pawn);
        if (W == None || W.Gun == None || W.VehicleBase == None
            || !(W.VehicleBase.IsA('ONSChopperCraft') || W.VehicleBase.IsA('SUHummer')))
            continue;
        T = B.Enemy;
        if (T == None)
            continue;
        Start = W.Gun.WeaponFireLocation;
        if (Start == vect(0,0,0))
            Start = W.Location;
        if (Trace(HL, HN, T.Location, Start, true) != W.VehicleBase)
            continue;
        Best = None;
        BestD = 20000;
        foreach DynamicActors(class'Pawn', P)
        {
            if (P == T || P.Health <= 0 || P.Controller == None || P.GetTeamNum() == B.GetTeamNum()
                || P.GetTeamNum() == 255)
                continue;
            D = VSize(P.Location - Start);
            if (D >= BestD)
                continue;
            H = Trace(HL, HN, P.Location, Start, true);
            if (H == P || (H == None && FastTrace(P.Location, Start)))
            {
                BestD = D;
                Best = P;
            }
        }
        NumTurretHolds++;
        if (Best != None)
        {
            B.Enemy = Best;
            B.Target = Best;
            B.Focus = Best;
        }
        else
            B.StopFiring();
    }
}

// Fix 71: fighters flew into what they attacked ("kamikaze", a player's feedback, 2026-11-12). Fix 40 and SpacePilots
// send a fighter to an objective as its move target, and nothing ended that move before it got there: on SU-Antartica
// (bTestHuman, 655 s) 10 of 37 deaths were Goa'uld gliders flying into the Teltac or the ice around it ("closes in on"
// or "flies to SUDestroyableObjective1", killer self/world), and about 6 more rammed the Daedalus and the X-303. A
// fighter flying at an objective it attacks now opens fire once within PilotStrikeRange and in sight.
function CloseInOnObjectives()
{
    local Controller C;
    local Bot B;
    local GameObjective O;
    local float D;
    local int i;

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn == None || Vehicle(B.Pawn) == None || B.Pawn.Physics != PHYS_Flying
            || B.Pawn.IsA('ONSChopperCraft')
            || (B.Squad != None && PlayerController(B.Squad.SquadLeader) != None))
            continue;
        i = PilotIndex(B);
        // Fix 71: attack runs. A fighter in RangedAttack stops (SU-Antartica gliders: about 200 uu/s, their least
        // speed) and fires as a turret, and a glider fires 200 damage every 0.85 s: once they no longer flew into the
        // Teltac (12000 health), gliders did 6900-11600 of its health from 6000 uu (400-3100 before) and the Goa'uld
        // won 8 games of 8. A fighter within PilotStrikeRange (+1000) of the objective it attacks for PilotStrikeTime
        // seconds, whatever the stock AI does meanwhile, flies off 6000 uu and stays away PilotBreakTime seconds
        // without firing, then comes back, as players do. (A first version timed only unbroken RangedAttack, which the
        // stock AI leaves and enters again all the time: 9-18 break-offs a game, no change.)
        if (i >= 0 && Level.TimeSeconds < Pilots[i].BreakUntil)
        {
            B.StopFiring();
            if (Pilots[i].P != None && B.MoveTarget != Pilots[i].P)
            {
                B.RouteGoal = Pilots[i].P;
                B.MoveTarget = Pilots[i].P;
                B.GotoState('Roaming', 'Begin');
            }
            continue;
        }
        O = StrikeObjective(B);
        if (O != None && PilotStrikeTime > 0 && VSize(O.Location - B.Pawn.Location) < PilotStrikeRange + O.CollisionRadius + 1000)
        {
            if (i < 0)
            {
                i = Pilots.Length;
                Pilots.Length = i + 1;
                Pilots[i].B = B;
            }
            if (Pilots[i].StrikeSince == 0)
                Pilots[i].StrikeSince = Level.TimeSeconds;
            else if (Level.TimeSeconds - Pilots[i].StrikeSince >= PilotStrikeTime && BreakOff(B, i, O))
                continue;
        }
        else if (i >= 0)
            Pilots[i].StrikeSince = 0;
        if (B.IsInState('Roaming') && PilotStrikeRange > 0)
        {
            O = GameObjective(B.MoveTarget);
            if (O == None || O.bDisabled || !O.bProjTarget || O.DefenderTeamIndex == B.GetTeamNum())
                continue;
            D = VSize(O.Location - B.Pawn.Location);
            if (D < PilotStrikeRange + O.CollisionRadius && B.LineOfSightTo(O))
            {
                B.GoalString = "SUBotFix: pilot opens fire on " $ O.Name $ " from " $ int(D) $ " uu";
                B.Focus = O;
                B.DoRangedAttackOn(O);
                NumStrikes++;
            }
            continue;
        }
        if (!B.IsInState('RangedAttack'))
            continue;
        O = GameObjective(B.Target);
        if (O == None || O.bDisabled || VSize(O.Location - B.Pawn.Location) < PilotObjectiveRange + O.CollisionRadius)
            continue;
        B.GoalString = "SUBotFix: pilot closes in on " $ O.Name;
        B.RouteGoal = O;
        B.MoveTarget = O;
        B.GotoState('Roaming', 'Begin');
        NumCloseIns++;
    }
}

// fix 71: the destroyable objective a fighter attacks: its target, its move target, or its squad's objective
function GameObjective StrikeObjective(Bot B)
{
    local GameObjective O;

    O = GameObjective(B.Target);
    if (O == None)
        O = GameObjective(B.MoveTarget);
    if (O == None && B.Squad != None)
        O = B.Squad.SquadObjective;
    if (O == None || O.bDisabled || !O.bActive || !O.bProjTarget || O.DefenderTeamIndex == B.GetTeamNum())
        return None;
    return O;
}

// fix 71: fly to a clear point 6000 uu away, to the side of the line to O and away from it, for PilotBreakTime seconds
function bool BreakOff(Bot B, int i, GameObjective O)
{
    local vector Away, Side, Cand, Try;
    local int k;

    Pilots[i].StrikeSince = 0;
    Away = Normal(B.Pawn.Location - O.Location);
    Side = Normal(Away Cross vect(0,0,1));
    if (FRand() < 0.5)
        Side = -Side;
    for (k = 0; k < 4; k++)
    {
        switch (k)
        {
            case 0: Cand = Normal(Away + Side + vect(0,0,0.4)); break;
            case 1: Cand = Normal(Away - Side + vect(0,0,0.4)); break;
            case 2: Cand = Normal(Away + vect(0,0,0.6)); break;
            case 3: Cand = Normal(Side + vect(0,0,0.6)); break;
        }
        if (FastTrace(B.Pawn.Location + Cand * 6000, B.Pawn.Location))
        {
            Try = B.Pawn.Location + Cand * 6000;
            break;
        }
    }
    if (k == 4)
        return false;
    if (Pilots[i].P == None)
        Pilots[i].P = Spawn(class'SUBotFlyPoint',,, Try);
    if (Pilots[i].P == None)
        return false;
    Pilots[i].P.SetLocation(Try);
    Pilots[i].BreakUntil = Level.TimeSeconds + PilotBreakTime;
    NumBreaks++;
    B.GoalString = "SUBotFix: pilot breaks off from " $ O.Name;
    B.StopFiring();
    B.RouteGoal = Pilots[i].P;
    B.MoveTarget = Pilots[i].P;
    B.GotoState('Roaming', 'Begin');
    return true;
}

function AvoidObstacles()
{
    local Controller C;
    local Bot B;
    local vector Ahead, HL, HN, Dir, Try, Perp, ToGoal, Cand;
    local float BestDot;
    local float Speed;
    local int i, k;
    local bool bClear, bImminent, bOnTarget;
    local Actor H;

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn == None || Vehicle(B.Pawn) == None || B.Pawn.Physics != PHYS_Flying)
            continue;
        Speed = VSize(B.Pawn.Velocity);
        if (Speed < 200)
            continue;
        Dir = B.Pawn.Velocity / Speed;
        Ahead = B.Pawn.Location + Dir * FMax(1500, Speed * 1.5);
        // fix 71: ships too, not only the level (traced from the fighter, which the trace skips); fighters
        // fly through soldiers (SUFighters.Bump ignores them)
        H = B.Pawn.Trace(HL, HN, Ahead, B.Pawn.Location, true);
        if (H == None || (Pawn(H) != None && Vehicle(H) == None))
            continue;
        // the obstacle is the target's own asteroid, or behind the target (SU-Asteroid: pilots
        // dodged the rock that carries the extractor they attacked and drifted 40 k uu away).
        // Fix 71: unless the fighter is about to hit it: that rule let gliders dive into the Teltac
        // and the ice around it, and ram the ships they chased.
        bOnTarget = B.IsInState('RangedAttack') || (B.RouteGoal != None && B.RouteGoal != B.Pawn
            && VSize(B.RouteGoal.Location - B.Pawn.Location) < VSize(HL - B.Pawn.Location) + 600);
        bImminent = PullOutTime > 0 && VSize(HL - B.Pawn.Location) < FMax(PullOutDist, Speed * PullOutTime);
        if (bOnTarget && !bImminent)
            continue;
        i = PilotIndex(B);
        if (i >= 0 && Level.TimeSeconds < Pilots[i].AvoidUntil)
            continue;
        Perp = Normal(Dir Cross vect(0,0,1));
        // the first clear escape direction (choosing the one closest to the way to the target did
        // worse in A/B runs and was removed)
        ToGoal = Dir;
        bClear = false;
        BestDot = -10;
        for (k = 0; k < 6; k++)
        {
            switch (k)
            {
                case 0: Cand = Normal(Dir + HN * 1.5); break;
                case 1: Cand = Normal(HN + vect(0,0,1)); break;
                case 2: Cand = Normal(HN - vect(0,0,1)); break;
                case 3: Cand = Normal(HN + Perp); break;
                case 4: Cand = Normal(HN - Perp); break;
                case 5: Cand = Normal(HN + ToGoal); break;
            }
            if (bClear)
                break;      // first clear one
            if ((Cand Dot ToGoal) <= BestDot || !FastTrace(B.Pawn.Location + Cand * 1500, B.Pawn.Location))
                continue;
            BestDot = Cand Dot ToGoal;
            Try = B.Pawn.Location + Cand * 1500;
            bClear = true;
        }
        if (!bClear)
            continue;
        if (i < 0)
        {
            i = Pilots.Length;
            Pilots.Length = i + 1;
            Pilots[i].B = B;
            Pilots[i].P = Spawn(class'SUBotFlyPoint',,, Try);
        }
        if (Pilots[i].P == None)        // an entry made by an attack run (fix 71) has no fly point yet
            Pilots[i].P = Spawn(class'SUBotFlyPoint',,, Try);
        if (Pilots[i].P == None)
            continue;
        Pilots[i].P.SetLocation(Try);
        Pilots[i].AvoidUntil = Level.TimeSeconds + 1.5;
        NumAvoid++;
        B.GoalString = "SUBotFix: pilot avoids " $ int(VSize(HL - B.Pawn.Location)) $ " uu obstacle";
        if (bOnTarget)
        {
            NumPullOuts++;
            B.GoalString = "SUBotFix: pilot pulls out " $ int(VSize(HL - B.Pawn.Location)) $ " uu before " $ H.Name;
        }
        B.MoveTarget = Pilots[i].P;
        B.GotoState('Roaming', 'Begin');
    }
}

// a point 2500 uu from O, on the side nearest to From, from which a trace reaches O (zero if none)
function vector AttackPoint(GameObjective O, vector From)
{
    local int D;
    local vector Dir, P, HL, HN, Best;
    local float Score, BestScore;
    local Actor H;

    BestScore = -10;
    for (D = 0; D < 27; D++)
    {
        if (D == 13)
            continue;       // the centre itself
        Dir.X = (D % 3) - 1;
        Dir.Y = ((D / 3) % 3) - 1;
        Dir.Z = (D / 9) - 1;
        Dir = Normal(Dir);
        Score = Dir Dot Normal(From - O.Location);
        if (Score <= BestScore)
            continue;
        P = O.Location + Dir * PilotAttackDist;
        H = Trace(HL, HN, O.Location, P, true);
        if (H == O && FastTrace(P, P + Dir * 300))
        {
            BestScore = Score;
            Best = P;
        }
    }
    return Best;
}

// Fix 39: a fighter heading for a destroyable objective it cannot shoot from where it is (SU-Asteroid's
// extractors, on the faces of asteroids) keeps flying to its attack point when enemies show up. The
// Tau'ri pilots dogfighted the Goa'uld fighters all round and never came within 11 k uu of an extractor.
// Fix 41 (SU bug): each map sets its round time (SUSetupTime.RoundTime: Asteroid and Asgard 10 min,
// IceDet 30) and SUGameInfo.InitGame puts it on the clock. But the warmup ends with Reset() on every
// actor, the game included, and DeathMatch.Reset() sets the clock back to TimeLimit (20 min by default):
// every SU round has lasted TimeLimit. Once the warmup is over, the map's own time goes back on.
function RestoreRoundTime()
{
    local Actor A;
    local int Mins;
    local DeathMatch DM;

    DM = DeathMatch(Level.Game);
    if (bRoundTimeDone || DM == None || !Level.Game.IsInState('MatchInProgress') || DM.TimeLimit <= 0)
        return;
    if (Level.Game.GetPropertyText("ResetCountDown") != "0")
    {
        bSawWarmup = true;
        return;
    }
    if (!bSawWarmup)
        return;
    bRoundTimeDone = true;
    foreach AllActors(class'Actor', A)
        if (A.IsA('SUSetupTime'))
            Mins = int(A.GetPropertyText("RoundTime"));
    if (Mins <= 0)
        return;
    DM.RemainingTime = Mins * 60;
    if (DM.GameReplicationInfo != None)
    {
        DM.GameReplicationInfo.RemainingTime = DM.RemainingTime;
        DM.GameReplicationInfo.RemainingMinute = DM.RemainingTime;
    }
    if (bLogFixes)
        Log("round time: " $ Mins $ " min, as the map sets it (the warmup reset had put " $ DM.TimeLimit $ " min back)", 'SUBotFix');
}

// what a capital ship heads for: the enemy objective it attacks if destroyable, else the nearest
// enemy capital ship, else the nearest enemy pilot
// the nearest enemy capital ship within CapitalDuelRange and in sight, for a capital ship whose
// squad attacks an objective
function Pawn DuelTarget(Bot B)
{
    local Controller C;
    local Pawn P, Best;
    local float D, BestD;
    local int Team;

    if (CapitalDuelRange <= 0 || B.Squad == None || B.Squad.SquadObjective == None
        || B.Squad.SquadObjective.DefenderTeamIndex == B.GetTeamNum())
        return None;
    Team = B.GetTeamNum();
    BestD = CapitalDuelRange;
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        P = C.Pawn;
        if (P == None || P.Health <= 0 || C.PlayerReplicationInfo == None || C.GetTeamNum() == Team
            || !P.IsA('ONSChopperCraft'))
            continue;
        D = VSize(P.Location - B.Pawn.Location);
        if (D < BestD && B.LineOfSightTo(P))
        {
            BestD = D;
            Best = P;
        }
    }
    return Best;
}

function Actor CapitalTarget(Bot B)
{
    local Controller C;
    local Pawn P, Best;
    local float D, BestD;
    local int Team;
    local GameObjective O;

    Team = B.GetTeamNum();
    if (B.Squad != None)
    {
        O = B.Squad.SquadObjective;
        if (O != None && !O.bDisabled && O.bActive && O.DefenderTeamIndex != Team && O.bProjTarget)
            return O;
        // Fix 38: defenders of a destroyable objective guard it: the enemy capital ship nearest to it
        // when one comes within 20 k uu, else the objective itself (they hold within 4500 uu)
        if (O != None && !O.bDisabled && O.bActive && O.DefenderTeamIndex == Team && O.bProjTarget)
        {
            BestD = 20000;
            for (C = Level.ControllerList; C != None; C = C.NextController)
            {
                P = C.Pawn;
                if (P == None || P.Health <= 0 || C.PlayerReplicationInfo == None || C.GetTeamNum() == Team
                    || !P.IsA('ONSChopperCraft'))
                    continue;
                D = VSize(P.Location - O.Location);
                if (D < BestD)
                {
                    BestD = D;
                    Best = P;
                }
            }
            if (Best != None)
                return Best;
            return O;
        }
    }
    BestD = 1000000000;
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        P = C.Pawn;
        if (P == None || P.Health <= 0 || C.PlayerReplicationInfo == None || C.GetTeamNum() == Team || Vehicle(P) == None)
            continue;
        D = VSize(P.Location - B.Pawn.Location);
        if (!P.IsA('ONSChopperCraft'))
            D += 100000;    // fighters only when there is no capital ship
        if (D < BestD)
        {
            BestD = D;
            Best = P;
        }
    }
    return Best;
}

// Fix 23 (bots never shot Replicators): in the co-op maps the bots met Replicators mostly in the
// Fallback state, whose fire timer only shoots when Focus == Enemy, and FaceActor kept their eyes on
// the move target: 0 bullet hits on Asgard, 16 bot deaths for 0-4 Replicators in 2-4 minutes. A bot
// that sees a monster (an enemy with no PlayerReplicationInfo) within 2000 uu looks at it and fires;
// it keeps walking its route meanwhile.
function FightMonsters()
{
    local Controller C;
    local Bot B;
    local GameObjective O;

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn == None || B.Enemy == None || Vehicle(B.Pawn) != None || B.Pawn.Weapon == None
            || B.Enemy.Controller == None || B.Enemy.Controller.PlayerReplicationInfo != None || B.Enemy.Health <= 0)
            continue;
        if (B.IsInState('RangedAttack') || VSize(B.Enemy.Location - B.Pawn.Location) > 2000 || !B.EnemyVisible()
            || !B.Pawn.Weapon.HasAmmo() || HealIndex(B) >= 0 || B.Pawn.Weapon.IsA('SyringeWeapon'))
            continue;
        // close to an objective to be done on foot: run for it (stock), the stage ends the wave sooner
        // (X303Down: with fire on the way the first objective was reached in 1 run of 4, 3 of 4 without)
        O = None;
        if (B.Squad != None)
            O = B.Squad.SquadObjective;
        if (!bFightOnTheWay && O != None && !O.bDisabled && O.bActive && O.DefenderTeamIndex != B.GetTeamNum()
            && !O.bProjTarget && ObjReachable(O, B.GetTeamNum()))
            continue;
        // shoot on the move (standing to shoot within 800 uu gained nothing and was removed)
        if (B.Focus != B.Enemy)
            B.Focus = B.Enemy;
        if (!B.Pawn.Weapon.IsFiring())
        {
            B.FireWeaponAt(B.Enemy);
            NumMonsterShots++;
        }
    }
}

// Fix 48 (bots never used the ammo crates). SU maps hold AmmoCrates (SU-Abydos 8, SU-IceDet 4,
// SU-Chulak 3, SU-TokRa 2, SU-P3X-548 1): a Tau'ri who "uses" one gets every weapon refilled
// (AmmoCrate.UsedBy). Bots never use anything, so a bot that had emptied its guns took its knife out
// and stood in a ranged attack 1 k+ uu from its enemy. With fire on the move (fix 47), 4-8 % of the
// Tau'ri bot samples held the knife, against 0-0.4 % before, nearly all on SU-IceDet's last stage,
// with every gun at 0. (SU reloads a bot's clip only after ClipCount seconds without an enemy in
// sight, and each reload throws away the rounds left in the clip.) A Tau'ri bot whose guns are all
// at or under RefillBelow of their ammo goes to a crate within RefillSeekDist of walk (DryRefillDist
// when it has no shot left) that it has a route to (SUBotSquadAI routes it there at each decision),
// and uses it once it touches it.
function float GunAmmo(Pawn P)
{
    local Inventory Inv;
    local Weapon W;
    local float Best;
    local int i;

    Best = -1;
    for (Inv = P.Inventory; Inv != None && i < 100; Inv = Inv.Inventory)
    {
        i++;
        W = Weapon(Inv);
        if (W != None && (W.IsA('SUReloadableWeapon') || W.IsA('M60Weapon')) && !W.IsA('ZatRifle'))
            Best = FMax(Best, W.AmmoStatus(0));
    }
    return Best;
}

function int RefillIndex(Bot B)
{
    local int i;

    for (i = 0; i < RefillBots.Length; i++)
        if (RefillBots[i] == B)
            return i;
    return -1;
}

// the crate a bot is on its way to (SUBotSquadAI.CheckSquadObjectives), or None
function Actor RefillCrateFor(Bot B)
{
    local int i;

    i = RefillIndex(B);
    if (i < 0)
        return None;
    return RefillCrate[i];
}

function DropRefill(Bot B)
{
    local int i;

    i = RefillIndex(B);
    if (i >= 0)
        RemoveRefillAt(i);
}

function RemoveRefillAt(int i)
{
    RefillBots.Remove(i, 1);
    RefillCrate.Remove(i, 1);
    RefillUntil.Remove(i, 1);
}

function RefillAmmo()
{
    local AmmoCrate K;
    local Controller C;
    local Bot B;
    local Actor Best;
    local vector D;
    local float BestD, Dist, Ammo;
    local int i;

    if (!bCratesListed)
    {
        bCratesListed = true;
        foreach AllActors(class'AmmoCrate', K)
        {
            Crates[Crates.Length] = K;
            if (bLogFixes)
                Log("ammo crate " $ K.Name $ " at " $ int(K.Location.X) $ "," $ int(K.Location.Y) $ "," $ int(K.Location.Z), 'SUBotFix');
        }
    }
    if (Crates.Length == 0)
        return;
    // bots on their way: arrived (use the crate), dead, in a vehicle or too late
    for (i = RefillBots.Length - 1; i >= 0; i--)
    {
        B = RefillBots[i];
        if (B == None || B.bDeleteMe || B.Pawn == None || B.Pawn.Health <= 0 || Vehicle(B.Pawn) != None
            || RefillCrate[i] == None || Level.TimeSeconds > RefillUntil[i])
        {
            RemoveRefillAt(i);
            continue;
        }
        D = RefillCrate[i].Location - B.Pawn.Location;
        if (Abs(D.Z) > RefillCrate[i].CollisionHeight + B.Pawn.CollisionHeight + 20)
            continue;
        D.Z = 0;
        if (VSize(D) > RefillCrate[i].CollisionRadius + B.Pawn.CollisionRadius + 40)
            continue;
        AmmoCrate(RefillCrate[i]).UsedBy(B.Pawn);
        NumRefills++;
        Note("refill: " $ B.PlayerReplicationInfo.PlayerName $ " used " $ RefillCrate[i].Name);
        RemoveRefillAt(i);
        if (!B.IsInState('Dead') && !B.IsInState('GameEnded'))
        {
            B.SwitchToBestWeapon();
            B.WhatToDoNext(68);
        }
    }
    // new trips, once a second
    if (Level.TimeSeconds - LastRefillScan < 1.0)
        return;
    LastRefillScan = Level.TimeSeconds;
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn == None || !B.Pawn.IsA('SUPawnTorri') || Vehicle(B.Pawn) != None || B.Pawn.Health <= 0
            || B.PlayerReplicationInfo == None || BotTask(B) != ''
            || B.IsInState('Dead') || B.IsInState('GameEnded') || CarriesCrystal(B.Pawn))
            continue;
        Ammo = GunAmmo(B.Pawn);
        if (Ammo > RefillBelow)
            continue;
        // nearest crate by walk (IceDet's last stage: the crate is 4.4 k uu away but 3 k uu below)
        Best = None;
        BestD = RefillSeekDist;
        if (Ammo <= 0)
            BestD = DryRefillDist;       // no shot left at all: a long walk beats a knife (IceDet: 11 k uu)
        for (i = 0; i < Crates.Length; i++)
        {
            Dist = VSize(Crates[i].Location - B.Pawn.Location);
            if (Dist >= BestD)
                continue;
            if (!B.ActorReachable(Crates[i]))
            {
                if (B.FindPathToward(Crates[i]) == None)
                    continue;
                Dist = FMax(Dist, B.RouteDist);
                if (Dist >= BestD)
                    continue;
            }
            Best = Crates[i];
            BestD = Dist;
        }
        if (Best == None)
        {
            Note("refill: " $ B.PlayerReplicationInfo.PlayerName $ " has " $ int(Ammo * 100) $ " % ammo at "
                $ int(B.Pawn.Location.X / 1000) $ "k," $ int(B.Pawn.Location.Y / 1000) $ "k and no crate within reach");
            continue;
        }
        i = RefillBots.Length;
        RefillBots[i] = B;
        RefillCrate[i] = Best;
        RefillUntil[i] = Level.TimeSeconds + 30;
        NumRefillTrips++;
        Note("refill: " $ B.PlayerReplicationInfo.PlayerName $ " is short of ammo, goes to " $ Best.Name
            $ " (" $ int(BestD) $ " uu)");
        B.WhatToDoNext(67);
    }
}

// Fix 47 (bots never fired while moving). SUPawn has bCanStrafe=False, so Bot.FaceActor always
// faces a moving bot along its route, and the fire timer only shoots when Focus is the enemy: a bot
// walking to an objective or to its post (Fallback, Retreating, Charging...) walked past enemies in
// plain sight without a shot (SUDiag CTRL lines: 0 of 103 samples firing on SU-IceDet, 0 of 43 on
// SU-P3X-548), and only bots standing in RangedAttack or a defense script fired. On SU-Chulak the
// Tau'ri walked into the computer room one by one and were zapped, 0 kills for 8 deaths each. As
// fix 23 does against monsters, a bot on foot that sees an enemy player within MoveFireRange looks
// at it and fires while it keeps walking its route.
function FireOnTheMove()
{
    local Controller C;
    local Bot B;

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn == None || B.Enemy == None || Vehicle(B.Pawn) != None || B.Pawn.Weapon == None
            || B.Enemy.Controller == None || B.Enemy.Controller.PlayerReplicationInfo == None || B.Enemy.Health <= 0)
            continue;
        if (B.IsInState('RangedAttack') || B.IsInState('TacticalMove') || B.IsInState('Scripting')
            || B.IsInState('StakeOut') || B.IsInState('Dead') || B.IsInState('GameEnded') || B.IsInState('Paralyzed')
            || B.Pawn.Weapon.bMeleeWeapon || !B.Pawn.Weapon.HasAmmo() || HealIndex(B) >= 0
            || VSize(B.Enemy.Location - B.Pawn.Location) > MoveFireRange || !B.EnemyVisible())
            continue;
        if (B.Focus != B.Enemy)
            B.Focus = B.Enemy;
        if (!B.Pawn.Weapon.IsFiring())
        {
            B.FireWeaponAt(B.Enemy);
            NumMoveShots++;
        }
    }
}

// Fix 44 (medic bots never healed). Human Tau'ri medics carry SyringeWeapon: its fire gives a
// teammate 50-100 health with a 110 uu trace from the medic's centre, 5 charges a life (SU bug: it
// sets a teammate above 100 back to 100, hence HealBelow). Bots never had it: SUBot.Classrequirement
// gives every Tau'ri bot the same guns whatever its class, so a medic bot was only a soldier with 150
// health. A medic bot now gets a syringe, and with charges left walks to a teammate (human or bot) at
// or under HealBelow health, in sight and walkable within HealSeekRange, takes the syringe out once in
// reach, faces the teammate and uses it, then goes back to its best gun. With an enemy in sight it
// only goes for a teammate within 500 uu.
function int HealIndex(Bot B)
{
    local int i;

    for (i = 0; i < Heals.Length; i++)
        if (Heals[i].B == B)
            return i;
    return -1;
}

function bool IsHealTarget(Pawn M)
{
    local int i;

    for (i = 0; i < Heals.Length; i++)
        if (Heals[i].M == M)
            return true;
    return false;
}

function Weapon SyringeOf(Pawn P)
{
    local Weapon S;

    S = Weapon(P.FindInventoryType(class'SyringeWeapon'));
    if (S != None && S.GetFireMode(0) != None && S.AmmoAmount(0) >= S.GetFireMode(0).AmmoPerFire)
        return S;
    return None;
}

function bool CarriesCrystal(Pawn P)
{
    local SUCrystalObject C;

    foreach DynamicActors(class'SUCrystalObject', C)
        if (C.Holder == P)
            return true;
    return false;
}

function FindHeals()
{
    local Controller C, MC;
    local Bot B;
    local Pawn P, M, Best;
    local float D, BestD;
    local int i;
    local Weapon S;

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B != None && B.Pawn != None && B.Pawn.Health > 0 && B.Pawn.IsA('SUPawnTorriMedicLieutenant')
            && B.Pawn.FindInventoryType(class'SyringeWeapon') == None)
        {
            S = Spawn(class'SyringeWeapon', B.Pawn);
            if (S != None)
            {
                S.GiveTo(B.Pawn);
                NumSyringesGiven++;
            }
        }
        if (B == None || B.Pawn == None || B.Pawn.Health <= 0 || Vehicle(B.Pawn) != None
            || B.PlayerReplicationInfo == None || BotTask(B) != ''
            || B.IsInState('Dead') || B.IsInState('GameEnded') || SyringeOf(B.Pawn) == None)
            continue;
        P = B.Pawn;
        Best = None;
        BestD = HealSeekRange;
        for (MC = Level.ControllerList; MC != None; MC = MC.NextController)
        {
            M = MC.Pawn;
            if (M == None || M == P || MC.PlayerReplicationInfo == None || SUPawn(M) == None || M.Health <= 0
                || M.Health > HealBelow || M.DrivenVehicle != None || MC.GetTeamNum() != B.GetTeamNum()
                || IsHealTarget(M))
                continue;
            D = VSize(M.Location - P.Location);
            if (D >= BestD || Abs(M.Location.Z - P.Location.Z) > 150 || !FastTrace(M.Location, P.Location))
                continue;
            if (D > 150 && !B.ActorReachable(M))
                continue;
            Best = M;
            BestD = D;
        }
        if (Best == None || (BestD > 500 && B.Enemy != None && B.EnemyVisible()) || CarriesCrystal(P))
            continue;
        i = Heals.Length;
        Heals.Length = i + 1;
        Heals[i].B = B;
        Heals[i].M = Best;
        Heals[i].H0 = Best.Health;
        Heals[i].Until = Level.TimeSeconds + 8;
        Heals[i].FiredAt = 0;
        NumHealTrips++;
        Note("medic " $ B.PlayerReplicationInfo.PlayerName $ " goes to heal "
            $ Best.GetHumanReadableName() $ " (health " $ Best.Health $ ", " $ int(BestD) $ " uu)");
    }
}

function EndHeal(int i)
{
    local Bot B;
    local Pawn M;
    local Weapon S;

    B = Heals[i].B;
    M = Heals[i].M;
    S = Heals[i].S;
    Heals.Remove(i, 1);
    if (S != None)
        S.AIRating = S.default.AIRating;
    if (B == None || B.bDeleteMe || B.Pawn == None || B.Pawn.Health <= 0)
        return;
    if ((B.Pawn.Weapon != None && B.Pawn.Weapon.IsA('SyringeWeapon'))
        || (B.Pawn.PendingWeapon != None && B.Pawn.PendingWeapon.IsA('SyringeWeapon')))
        B.SwitchToBestWeapon();
    if (M != None && B.MoveTarget == M && !B.IsInState('Dead') && !B.IsInState('GameEnded'))
        B.WhatToDoNext(66);
}

// Every frame while medics heal: walk to the teammate, syringe out once in reach, use it. The bot
// picks its weapon again at every decision (SwitchToBestWeapon), so while in reach the syringe is
// made its best weapon instead of being forced into its hands.
function DriveHeals()
{
    local int i;
    local Bot B;
    local Pawn P, M;
    local Weapon S;
    local WeaponFire F;
    local Pawn OldEnemy;
    local vector D;
    local rotator R;

    for (i = Heals.Length - 1; i >= 0; i--)
    {
        B = Heals[i].B;
        M = Heals[i].M;
        if (B == None || B.bDeleteMe || B.Pawn == None || B.Pawn.Health <= 0 || Vehicle(B.Pawn) != None
            || M == None || M.bDeleteMe || M.Health <= 0 || M.DrivenVehicle != None
            || Level.TimeSeconds > Heals[i].Until || B.IsInState('Dead') || B.IsInState('GameEnded'))
        {
            EndHeal(i);
            continue;
        }
        P = B.Pawn;
        if (Heals[i].FiredAt > 0)
        {
            if (M.Health > Heals[i].H0)
            {
                NumHeals++;
                NumHealHP += M.Health - Heals[i].H0;
                Note("medic " $ B.PlayerReplicationInfo.PlayerName $ " healed " $ M.GetHumanReadableName()
                    $ ": " $ Heals[i].H0 $ " -> " $ M.Health);
                EndHeal(i);
                continue;
            }
            if (Level.TimeSeconds - Heals[i].FiredAt < 0.3)
                continue;
            NumHealMisses++;            // missed: try again while charges and time last
            Heals[i].FiredAt = 0;
        }
        S = SyringeOf(P);
        if (S == None)
        {
            EndHeal(i);
            continue;
        }
        Heals[i].S = S;
        D = M.Location - P.Location;
        D.Z = 0;
        // the syringe trace is 110 uu long, level, from the medic's centre
        if (Abs(M.Location.Z - P.Location.Z) > 45 || VSize(D) > 115)
        {
            S.AIRating = S.default.AIRating;
            if (B.MoveTarget != M || !B.IsInState('Roaming'))
            {
                B.MoveTarget = M;
                B.GoalString = "SUBotFix: heal " $ M.GetHumanReadableName();
                B.GotoState('Roaming', 'Begin');
            }
            continue;
        }
        S.AIRating = 5;
        if (P.Weapon != S)
        {
            if (P.PendingWeapon != S)
                B.SwitchToBestWeapon();
            continue;
        }
        F = S.GetFireMode(0);
        if (S.ClientState != WS_ReadyToFire || F.NextFireTime > Level.TimeSeconds || !F.AllowFire())
            continue;
        // what SyringeFire.ModeDoFire does, facing the teammate (its aim takes the pitch from Enemy)
        R = rotator(D);
        P.SetRotation(R);
        B.SetRotation(R);
        B.Focus = M;
        Heals[i].H0 = M.Health;
        S.ConsumeAmmo(0, F.AmmoPerFire);
        OldEnemy = B.Enemy;
        B.Enemy = None;
        F.DoFireEffect();
        B.Enemy = OldEnemy;
        F.ServerPlayFiring();
        S.IncrementFlashCount(0);
        F.NextFireTime = Level.TimeSeconds + F.FireRate;
        Heals[i].FiredAt = Level.TimeSeconds;
    }
}

// Fix 30 (Zat bots cannot hurt objectives or vehicles). SUBot.Classrequirement gives a Goa'uld bot
// ONE weapon, a Zat or a staff (human Goa'uld have both). ZatFireStun only acts on pawns: its
// branch for anything else is commented out, so a Zat does nothing to an objective, a vehicle or a
// turret. On SU-P3X-548 the Goa'uld shot the ammo barrel 98 times with Zats and it stayed at
// 1000/1000. A Zat-only Goa'uld bot now gets a staff too; the Zat stays its favourite against
// soldiers. Against a non-pawn target the stock rating already prefers the staff (Bot.WeaponPreference
// is 0 then); against a vehicle, held-weapon stickiness keeps the Zat, so the switch is forced.
function ArmGoauld()
{
    local Controller C;
    local Bot B;
    local Pawn P;
    local Weapon W, Staff;
    local Actor T;

    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        B = Bot(C);
        if (B == None || B.Pawn == None || Vehicle(B.Pawn) != None || !B.Pawn.IsA('SUPawnGoa')
            || B.Pawn.Health <= 0)
            continue;
        P = B.Pawn;
        if (P.FindInventoryType(class'ZatRifle') == None)
            continue;
        Staff = Weapon(P.FindInventoryType(class'StaffWeapon'));
        if (Staff == None)
        {
            B.FavoriteWeapon = class'ZatRifle';
            Staff = Spawn(class'StaffWeapon', P);
            if (Staff == None)
                continue;
            Staff.GiveTo(P);
            NumStaffsGiven++;
        }
        W = P.Weapon;
        if (W == None || !W.IsA('ZatRifle') || P.PendingWeapon == Staff)
            continue;
        T = None;
        if (B.IsInState('RangedAttack'))
            T = B.Target;
        else if (B.Enemy != None && B.EnemyVisible())
            T = B.Enemy;
        if (T == None || (GameObjective(T) == None && Vehicle(T) == None))
            continue;
        P.PendingWeapon = Staff;
        B.StopFiring();
        W.PutDown();
        NumZatSwitches++;
    }
}

// Fix 29 (SU bug: every crystal scored for the Goa'uld). SUCaptureCrystal.Touch hands its
// Instigator to SUCountCrystal.CapturedCrystal, and that variable is None by then (logged as
// "Accessed None 'P'" on every capture: 25 of 25 in our tests). P.GetTeamNum() on None is 0, so every
// crystal counted for the Goa'uld and the Tau'ri could never win SU-Abydos or SU-TokRa, whoever
// brought the crystals in. We capture a little before the touch, with the carrier, doing what
// SUCaptureCrystal.FindCrystal and SUCountCrystal.CapturedCrystal do. Human players are covered too.
function CaptureCrystals()
{
    local SUCaptureCrystal S;
    local SUCrystalObject C;
    local Pawn P;
    local vector D;

    foreach DynamicActors(class'SUCrystalObject', C)
    {
        P = C.Holder;
        if (P == None || P.Health <= 0 || P.Controller == None || P.PlayerReplicationInfo == None
            || P.PlayerReplicationInfo.Team == None || C.bDisabled)
            continue;
        foreach DynamicActors(class'SUCaptureCrystal', S)
        {
            if (!S.IsActive() || S.CrystalCounter == None || P.GetTeamNum() == S.DefenderTeamIndex)
                continue;
            D = P.Location - S.Location;
            if (Abs(D.Z) > S.CollisionHeight + P.CollisionHeight + 80)
                continue;
            D.Z = 0;
            if (VSize(D) > S.CollisionRadius + P.CollisionRadius + 80)
                continue;
            // not through a wall or a floor (the spot's own touch never would); two points, in case
            // the spot's origin sits at floor level
            if (!FastTrace(S.Location + vect(0,0,30), P.Location)
                && !FastTrace(S.Location + vect(0,0,1) * S.CollisionHeight, P.Location))
                continue;
            CaptureFor(S, C, P);
            break;
        }
    }
}

function CaptureFor(SUCaptureCrystal S, SUCrystalObject C, Pawn P)
{
    local SUCountCrystal CC;
    local int Team;

    CC = S.CrystalCounter;
    Team = P.GetTeamNum();
    if (S.CaptureEvent != 'None')
        S.TriggerEvent(S.CaptureEvent, S, P);
    C.SilentDrop(vect(0,0,0));
    C.SetLocation(S.CapturedLocation);
    C.bDisabled = true;
    C.SetTimer(S.PostCaptureLife, false);
    C.SpecialLocalMessage(6, Team);
    NumCaptures++;
    if (bLogFixes)
        Log("crystal captured by " $ P.PlayerReplicationInfo.PlayerName $ " (team " $ Team $ ") at " $ S.Name
            $ ", " $ (CC.CrystalsInLevel - 1) $ " left", 'SUBotFix');
    // SUCountCrystal.CapturedCrystal, with the carrier
    if (CC.CrystalsInLevel <= 0)
        return;
    CC.CrystalsInLevel -= 1;
    P.PlayerReplicationInfo.Team.Score += 1;
    if (Team == 1)
        CC.TauriCrystals += 1;
    else
        CC.GoaCrystals += 1;
    if (CC.SUST != None)
    {
        if (CC.TauriCrystals > CC.GoaCrystals)
            CC.SUST.SetPropertyText("TimeWinner", "Tauri");
        else if (CC.TauriCrystals < CC.GoaCrystals)
            CC.SUST.SetPropertyText("TimeWinner", "GoaUld");
        else
            CC.SUST.SetPropertyText("TimeWinner", "Neither");
    }
    // Fix 60 (SU bug: the last crystal won the round). Disabling a spot ends the game in the name
    // of its instigator (SUGameObjective -> SUGameInfo.CheckGameObjectif -> EndGame(Player)), and SU
    // passes the last carrier: on SU-TokRa the Goa'uld won with 1 crystal against 8 because they
    // brought in the ninth. The instigator is now a pawn of the team with more crystals.
    if (CC.CrystalsInLevel <= 0)
    {
        if (CC.TauriCrystals > CC.GoaCrystals && CC.TauriSpot != None)
            CC.TauriSpot.DisableObjective(TeamPawn(1, P));
        else if (CC.TauriCrystals < CC.GoaCrystals && CC.GoaSpot != None)
            CC.GoaSpot.DisableObjective(TeamPawn(0, P));
        else
            Level.Game.EndGame(None, "TimeLimit");
    }
}

// a living pawn of Team with a controller (P itself when it is on that team), else P
function Pawn TeamPawn(int Team, Pawn P)
{
    local Controller C;

    if (P != None && P.GetTeamNum() == Team)
        return P;
    for (C = Level.ControllerList; C != None; C = C.NextController)
        if (C.Pawn != None && C.Pawn.Health > 0 && C.PlayerReplicationInfo != None
            && C.PlayerReplicationInfo.Team != None && C.PlayerReplicationInfo.Team.TeamIndex == Team)
        {
            if (bLogFixes)
                Log("crystals: the last one was brought by team " $ P.GetTeamNum() $ ", the round goes to team "
                    $ Team $ " (" $ C.PlayerReplicationInfo.PlayerName $ ")", 'SUBotFix');
            return C.Pawn;
        }
    return P;
}

function int PilotIndex(Bot B)
{
    local int i;

    for (i = Pilots.Length - 1; i >= 0; i--)
    {
        if (Pilots[i].B == None || Pilots[i].B.bDeleteMe)
        {
            if (Pilots[i].P != None)
                Pilots[i].P.Destroy();
            Pilots.Remove(i, 1);
        }
        else if (Pilots[i].B == B)
            return i;
    }
    return -1;
}

function Actor PilotTarget(Bot B)
{
    local GameObjective O, BestO;
    local Controller C;
    local Pawn P, BestP;
    local float D, BestD;
    local int Team;
    local bool bSkipObjectives;

    Team = B.GetTeamNum();
    // the squad's own objective first; when it must be done on foot (a proximity or triggered
    // objective on a ground map, SU-IceDet), go after enemies rather than a destroyable objective
    // of a later stage that sits indoors (IceDet's never took a hit from a glider)
    if (B.Squad != None && B.Squad.SquadObjective != None)
    {
        O = B.Squad.SquadObjective;
        if (!O.bDisabled && O.bActive && O.DefenderTeamIndex != Team)
        {
            if (O.bProjTarget)
                return O;
            bSkipObjectives = true;
        }
    }
    BestD = 1000000000;
    foreach AllActors(class'GameObjective', O)
    {
        if (bSkipObjectives)
            break;
        if (O.bDisabled || !O.bActive || O.DefenderTeamIndex == Team || !O.bProjTarget)
            continue;
        D = VSize(O.Location - B.Pawn.Location);
        if (D < BestD)
        {
            BestD = D;
            BestO = O;
        }
    }
    if (BestO != None)
        return BestO;
    BestD = 1000000000;
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        P = C.Pawn;
        if (P == None || P.Health <= 0 || C.PlayerReplicationInfo == None || C.GetTeamNum() == Team)
            continue;
        D = VSize(P.Location - B.Pawn.Location);
        if (D < BestD)
        {
            BestD = D;
            BestP = P;
        }
    }
    return BestP;
}

// ---------------------------------------------------------------- route following

function int FollowIndex(Bot B)
{
    local int i;

    for (i = 0; i < Follows.Length; i++)
        if (Follows[i].B == B)
            return i;
    return -1;
}

function StartFollow(Bot B)
{
    local int i, n;

    i = Follows.Length;
    Follows.Length = i + 1;
    Follows[i].B = B;
    for (n = 0; n < 15 && B.RouteCache[n + 1] != None; n++)
        Follows[i].Route[n] = NavigationPoint(B.RouteCache[n + 1]);
    Follows[i].Len = n;
    Follows[i].Idx = 0;
    Follows[i].Until = Level.TimeSeconds + 45;
    Note("anchor loop: " $ B.PlayerReplicationInfo.PlayerName $ " at " $ B.MoveTarget.Name $ ", follows the "
        $ n $ "-node route to " $ Follows[i].Route[n - 1].Name);
    B.MoveTarget = Follows[i].Route[0];
    B.GotoState('Roaming', 'Begin');
}

// Every frame while bots follow a route: move them on node by node, give up on enemies or timeout.
function Tick(float DeltaTime)
{
    local int i;
    local Bot B;
    local NavigationPoint T;

    if (Level.Game.IsInState('MatchInProgress'))
        CaptureCrystals();
    if (HopTransitSpeed > 0)
        HoldTransits();
    if (TimedWhat != "" && TimedWall >= 0)
    {
        if (bLogFixes)
            Log(TimedWhat $ ": that frame took " $ int(DeltaTime * 1000) $ " ms (wall clock " $ (WallMs() - TimedWall) $ " ms)", 'SUBotFix');
        TimedWhat = "";
    }
    if (Level.TimeSeconds - LastAvoid >= 0.25 && Level.Game.IsInState('MatchInProgress'))
    {
        LastAvoid = Level.TimeSeconds;
        AvoidObstacles();
        if (PilotObjectiveRange > 0)
            CloseInOnObjectives();
        if (GuardFighterRange > 0)
            GuardFromFighters();
        if (bTurretClearShots)
            TurretClearShots();
        if (bFireOnTheMove)
            FireOnTheMove();
        if (bFightMonsters)
            FightMonsters();
        if (bArmGoauld)
            ArmGoauld();
        if (bMedicHeal)
            FindHeals();
        if (bRefillAmmo)
            RefillAmmo();
        if (LinkBanTime > 0)
            UnstickShooters();
        if (bDefendersHunt)
            WatchObjectiveDamage();
        if (bBotsSprint)
            SprintBots();
        if (HopTo.Length > 0)
            FastHops();
        if (HummerEntryDist > 0)
            EnterVehicles();
    }
    if (Heals.Length > 0)
        DriveHeals();

    for (i = Follows.Length - 1; i >= 0; i--)
    {
        B = Follows[i].B;
        if (B == None || B.bDeleteMe || B.Pawn == None || Level.TimeSeconds > Follows[i].Until
            || (B.Enemy != None && B.EnemyVisible()) || Follows[i].Idx >= Follows[i].Len)
        {
            Follows.Remove(i, 1);
            continue;
        }
        T = Follows[i].Route[Follows[i].Idx];
        if (T == None)
        {
            Follows.Remove(i, 1);
            continue;
        }
        if (B.Pawn.ReachedDestination(T) || VSize(B.Pawn.Location - T.Location) < 60)
        {
            Follows[i].Idx++;
            if (Follows[i].Idx >= Follows[i].Len)
            {
                Follows.Remove(i, 1);
                B.WhatToDoNext(64);
                continue;
            }
            T = Follows[i].Route[Follows[i].Idx];
            B.MoveTarget = T;
            B.GotoState('Roaming', 'Begin');
        }
        else if (B.MoveTarget != T && !B.IsInState('Dead'))
        {
            B.MoveTarget = T;
            B.GotoState('Roaming', 'Begin');
        }
    }
}

// Closest navigation point within 800 uu that the bot can walk to from where it stands.
function NavigationPoint ReachableNodeNear(Bot B)
{
    local NavigationPoint N;
    local array<NavigationPoint> Cand;
    local array<float> Dist;
    local float D;
    local int i, k;

    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        D = VSize(N.Location - B.Pawn.Location);
        if (D > 800 || N.PathList.Length == 0)
            continue;
        // insertion into a short list sorted by distance
        for (i = 0; i < Cand.Length && Dist[i] <= D; i++);
        if (i >= 8)
            continue;
        Cand.Insert(i, 1);
        Dist.Insert(i, 1);
        Cand[i] = N;
        Dist[i] = D;
        if (Cand.Length > 8)
        {
            Cand.Length = 8;
            Dist.Length = 8;
        }
    }
    for (k = 0; k < Cand.Length; k++)
        if (B.ActorReachable(Cand[k]))
            return Cand[k];
    return None;
}

// Log a fix once (squads call this every decision; identical messages are dropped).
function Note(string Msg)
{
    local int i;

    if (!bLogFixes)
        return;
    for (i = 0; i < Notes.Length; i++)
        if (Notes[i] == Msg)
            return;
    if (Notes.Length < 200)
        Notes[Notes.Length] = Msg;
    Log(Msg, 'SUBotFix');
}

// ---------------------------------------------------------------- stranded spawns

// Fix 62: P was hopped to Escapes[j].Exit and can reach no node from there. Put it on the nearest of
// the nodes within 1500 uu from which a node is reachable, and send later hops to that exit there.
function FixExit(Pawn P, int j)
{
    local NavigationPoint N, Bad;
    local array<NavigationPoint> Cand;
    local array<float> Dist;
    local float D;
    local int i, k;

    Bad = Escapes[j].Exit;
    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        D = VSize(N.Location - Bad.Location);
        if (N == Bad || D > 1500 || N.PathList.Length == 0 || N.IsA('SUBotRingPad'))
            continue;
        for (i = 0; i < Cand.Length && Dist[i] <= D; i++);
        if (i >= 6)
            continue;
        Cand.Insert(i, 1);
        Dist.Insert(i, 1);
        Cand[i] = N;
        Dist[i] = D;
        if (Cand.Length > 6)
        {
            Cand.Length = 6;
            Dist.Length = 6;
        }
    }
    for (k = 0; k < Cand.Length; k++)
    {
        if (!PutPawn(P, Cand[k].Location + vect(0,0,15)) || ReachableNodeNear(Bot(P.Controller)) == None)
            continue;
        for (i = 0; i < StrandedExit.Length; i++)
            if (StrandedExit[i] == Bad)
                StrandedExit[i] = Cand[k];
        for (i = 0; i < Escapes.Length; i++)
            if (Escapes[i].Exit == Bad)
                Escapes[i].Exit = Cand[k];
        NumExitFixes++;
        Note("hop target " $ Bad.Name $ ": no node can be reached from it, hops now go to " $ Cand[k].Name
            $ " (" $ int(Dist[k]) $ " uu away)");
        return;
    }
    Note("hop target " $ Bad.Name $ ": no node can be reached from it, and none of the " $ Cand.Length
        $ " nodes around it works either");
}

// Fix 69: P could not be put at its hop target (someone stands there). Put it on one of the 6 nodes nearest to
// the target within 1500 uu instead, nodes no human sees first.
function bool PutNearExit(Pawn P, NavigationPoint Exit)
{
    local NavigationPoint N;
    local array<NavigationPoint> Cand;
    local array<float> Dist;
    local float D;
    local int i, k, Pass;

    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        D = VSize(N.Location - Exit.Location);
        if (N == Exit || D > 1500 || N.PathList.Length == 0 || N.IsA('SUBotRingPad') || N.IsA('Teleporter')
            || N.IsA('GameObjective') || Abs(N.Location.Z - Exit.Location.Z) > 400)
            continue;
        for (i = 0; i < Cand.Length && Dist[i] <= D; i++);
        if (i >= 6)
            continue;
        Cand.Insert(i, 1);
        Dist.Insert(i, 1);
        Cand[i] = N;
        Dist[i] = D;
        if (Cand.Length > 6)
        {
            Cand.Length = 6;
            Dist.Length = 6;
        }
    }
    for (Pass = 0; Pass < 2; Pass++)
        for (k = 0; k < Cand.Length; k++)
        {
            if (Pass == 0 && HumanSees(Cand[k].Location))
                continue;
            if (PutPawn(P, Cand[k].Location + vect(0,0,1) * (P.CollisionHeight - Cand[k].CollisionHeight + 4)))
            {
                NumExitAlternates++;
                if (bLogFixes)
                    Log(P.GetHumanReadableName() $ " hops next to " $ Exit.Name $ ", to " $ Cand[k].Name $ " (" $ int(Dist[k]) $ " uu away): someone stands on it", 'SUBotFix');
                return true;
            }
        }
    return false;
}

function HandleStrandedBots()
{
    local Controller C;
    local Pawn P;
    local int i, j;
    local bool bQueued;
    local vector Offset;

    // enqueue bots standing on a stranded spawn
    for (C = Level.ControllerList; C != None; C = C.NextController)
    {
        if (Bot(C) == None || C.Pawn == None || Vehicle(C.Pawn) != None || C.Pawn.Health <= 0)
            continue;
        P = C.Pawn;
        for (i = 0; i < StrandedStarts.Length; i++)
        {
            if (VSize(StrandedStarts[i].Location - P.Location) > 400)
                continue;
            bQueued = false;
            for (j = 0; j < Escapes.Length; j++)
                if (Escapes[j].P == P)
                    bQueued = true;
            if (!bQueued)
            {
                j = Escapes.Length;
                Escapes.Length = j + 1;
                Escapes[j].P = P;
                Escapes[j].R = StrandedEscape[i];
                Escapes[j].Exit = StrandedExit[i];
                Escapes[j].Time = Level.TimeSeconds;
                Escapes[j].Stage = 0;
            }
            break;
        }
    }

    for (j = Escapes.Length - 1; j >= 0; j--)
    {
        P = Escapes[j].P;
        if (P == None || P.bDeleteMe || P.Health <= 0
            || (Escapes[j].Exit == None && (Escapes[j].R == None || RingTarget(Escapes[j].R) == None)))
        {
            Escapes.Remove(j, 1);
            continue;
        }
        if (Escapes[j].Exit != None)
        {
            // a hop is quick: a bot left at its spawn for 2 s walks into the Hummer parked there
            if (Level.TimeSeconds - Escapes[j].Time < 0.3)
                continue;
            // not under a human player's eyes, unless it has waited 15 s (fix 54)
            if (Level.TimeSeconds - Escapes[j].Time < 15
                && (HumanSees(P.Location) || HumanSees(Escapes[j].Exit.Location)))
                continue;
            if (P.DrivenVehicle != None)
            {
                Escapes.Remove(j, 1);
                continue;
            }
            // no free place there now (the others hopped there stand on it): try again next second.
            // Fix 69: after 5 s, a node around the exit will do (SU-TokRa: a player standing by the valley's
            // exit blocked every hop, the escape was dropped after 15 s and the Goa'uld bots stayed in their
            // valley); the hop is given up only after 45 s.
            if (!PutPawn(P, Escapes[j].Exit.Location + vect(0,0,15)) && !PutPawn(P, Escapes[j].Exit.Location + vect(0,0,45))
                && (Level.TimeSeconds - Escapes[j].Time < 5 || !PutNearExit(P, Escapes[j].Exit)))
            {
                if (Level.TimeSeconds - Escapes[j].Time < 45)
                    continue;
                Note(P.GetHumanReadableName() $ " could not hop from its stranded spawn to " $ Escapes[j].Exit.Name $ " in 45 s");
                Escapes.Remove(j, 1);
                continue;
            }
            // fix 62: a hop target from which no node can be reached (SU-Chulak: PathNode744, among
            // crates by the generator) leaves the bot without an anchor, and the stock bot then jumps at
            // random and kills itself (Bot.FindRoamDest, NumRandomJumps > 4): defenders hopped there died
            // again and again. Try the nodes around it, and keep the first that works for later hops.
            if (Bot(P.Controller) != None && ReachableNodeNear(Bot(P.Controller)) == None)
                FixExit(P, j);
            P.Velocity = vect(0,0,0);
            P.Acceleration = vect(0,0,0);
            Note(P.GetHumanReadableName() $ " hops from its stranded spawn to " $ Escapes[j].Exit.Name);
            if (Bot(P.Controller) != None)
                Bot(P.Controller).WhatToDoNext(61);
            Escapes.Remove(j, 1);
            continue;
        }
        if (Escapes[j].Stage == 0)
        {
            if (Level.TimeSeconds - Escapes[j].Time < EscapeDelay || Escapes[j].R.IsInState('Activated'))
                continue;
            if (PutPawn(P, Escapes[j].R.Location + vect(0,0,1) * (P.CollisionHeight + 8)))
            {
                P.Velocity = vect(0,0,0);
                P.Acceleration = vect(0,0,0);
                Escapes[j].R.UsedBy(P);
                Escapes[j].Stage = 1;
                Escapes[j].Time = Level.TimeSeconds;
                if (bLogFixes)
                    Log(P.GetHumanReadableName() $ " uses rings " $ Escapes[j].R.Name $ " -> " $ RingTarget(Escapes[j].R).Name, 'SUBotFix');
            }
        }
        else if (Level.TimeSeconds - Escapes[j].Time >= 3.0)
        {
            // the rings only move pawns that touch them: finish the job if needed
            if (VSize(P.Location - Escapes[j].R.Location) < 300)
            {
                Offset = P.Location - Escapes[j].R.Location;
                if (!PutPawn(P, RingTarget(Escapes[j].R).Location + Offset))
                    PutPawn(P, RingTarget(Escapes[j].R).Location + vect(0,0,1) * (P.CollisionHeight + 8));
                if (bLogFixes)
                    Log(P.GetHumanReadableName() $ " moved to " $ RingTarget(Escapes[j].R).Name $ " (rings did not catch the pawn)", 'SUBotFix');
            }
            if (Bot(P.Controller) != None)
                Bot(P.Controller).WhatToDoNext(60);
            Escapes.Remove(j, 1);
        }
    }
}

// ---------------------------------------------------------------- analysis

function bool Walkable(ReachSpec R)
{
    if (R == None || R.End == None)
        return false;
    if ((R.reachFlags & 640) != 0)                      // R_PROSCRIBED | R_PLAYERONLY
        return false;
    if ((R.reachFlags & 2) != 0 && (R.reachFlags & 1) == 0)   // fly-only
        return false;
    // the native pathfinder skips specs smaller than the pawn
    if (R.CollisionHeight < PawnHeight || R.CollisionRadius < PawnRadius)
        return false;
    return true;
}

// Fix 5 (paths too small for SU pawns): maps were pathed with the stock 26x44 scout, but
// SUPawn is 20x50 and SUPawnGoa 20x55, so the native pathfinder refuses every 44-high spec
// (doorways, corridors...). Raise a spec to PawnHeight when the extra head room is really
// free along it: a thin box swept between the two nodes, from 80 to 112 uu above the floor
// (the 26x44 spec already proves 0..88 is clear).
function FixSpecSizes()
{
    local NavigationPoint N;
    local ReachSpec R;
    local int j, Raised, Kept, Doors, Small, NR;
    local bool bTrace, bJump;

    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
        for (j = 0; j < N.PathList.Length; j++)
        {
            R = N.PathList[j];
            if (R == None || R.Start == None || R.End == None)
                continue;
            if (R.CollisionHeight >= PawnHeight || R.CollisionHeight < 40 || R.CollisionRadius < PawnRadius)
                continue;   // big enough already, or a crouch path
            if ((R.reachFlags & 1) == 0 || (R.reachFlags & (2 | 4 | 32 | 64 | 128 | 512)) != 0)
                continue;   // walk (+jump/door) specs only
            // doors and ladders are built for players (the closed mover or the ladder itself
            // would block the head-room test)
            if ((R.reachFlags & 16) != 0 || Door(R.Start) != None || Door(R.End) != None
                || Ladder(R.Start) != None || Ladder(R.End) != None)
            {
                R.CollisionHeight = PawnHeight;
                Doors++;
                continue;
            }
            bTrace = HeadroomClear(R.Start, R.End, R);
            // the engine's own walk test with a scout of the real pawn size can only ADD specs: it
            // rejects some stairs and slopes that bots do walk (SU-Chulak PathNode425-427), so a
            // spec passing the head-room trace test is always raised
            NR = -1;
            if (bNativeSpecTest)
                NR = NativeReach(R.Start, R.End, PawnHeight);
            bJump = (R.reachFlags & 8) != 0 || R.MaxLandingVelocity > 0;
            if (NR == 1 || bTrace)
            {
                R.CollisionHeight = PawnHeight;
                Raised++;
                if (NR == 0)
                    NumJumpTrust++;
            }
            else if (NR == 0 && NativeReach(R.Start, R.End, SmallPawnHeight) == 1)
            {
                R.CollisionHeight = SmallPawnHeight;     // Tau'ri fit, Goa'uld do not
                Small++;
            }
            else
            {
                Kept++;
                if (bLogFixes && Kept <= 40)
                    Log("small spec kept " $ R.Start.Name $ " -> " $ R.End.Name $ " (" $ R.CollisionRadius $ "x"
                        $ R.CollisionHeight $ " flags " $ R.reachFlags $ ") at " $ int(R.End.Location.X) $ ","
                        $ int(R.End.Location.Y) $ "," $ int(R.End.Location.Z), 'SUBotFix');
            }
            if (NR == 1 && !bTrace)
                NumNativeOnly++;
            if (NR == 0 && bTrace && !bJump)
                NumTraceOnly++;
        }
    KillScout();
    if (bLogFixes)
        Log("spec sizes: raised " $ Raised $ " walk specs and " $ Doors $ " door specs to height " $ PawnHeight
            $ ", " $ Small $ " to " $ SmallPawnHeight $ " (Tau'ri only), " $ Kept $ " kept; native test "
            $ bNativeSpecTest $ ": " $ NumNativeOnly $ " passed only natively, " $ NumTraceOnly
            $ " passed only the trace test, " $ NumJumpTrust $ " jumps kept on the trace test, "
            $ NumPlaceFail $ " scout placements failed", 'SUBotFix');
}

// ---------------------------------------------------------------- native reach tests

// 1: a pawn of height H standing at A can walk to B (engine's PointReachable); 0: it cannot;
// -1: unknown (the scout could not be placed at A).
// Where a pawn coming from From stops in front of objective O (its own mesh fills the centre;
// triggered objectives are used within CollisionRadius + 40).
function vector InFront(Actor O, vector From)
{
    local vector Dir;

    Dir = From - O.Location;
    Dir.Z = 0;
    if (VSize(Dir) < 1)
        return O.Location;
    return O.Location + Normal(Dir) * FMin(O.CollisionRadius + 30, VSize(Dir) * 0.5);
}

// as NativeReach, to a point
function int NativeReachLoc(NavigationPoint A, vector Dest, float H)
{
    local vector HL, HN;

    if (!PlaceScout(A, H))
        return -1;
    if (Trace(HL, HN, Dest - vect(0,0,300), Dest + vect(0,0,50), false) != None)
        Dest.Z = HL.Z + H + 2;
    if (ScoutC.PointReachable(Dest))
        return 1;
    return 0;
}

function int NativeReach(NavigationPoint A, NavigationPoint B, float H)
{
    local vector Dest;

    if (!PlaceScout(A, H))
        return -1;
    Dest = B.Location;
    Dest.Z = FloorZ(B) + H + 2;
    if (ScoutC.PointReachable(Dest))
        return 1;
    return 0;
}

function bool PlaceScout(NavigationPoint N, float H)
{
    local vector Loc;

    Loc = N.Location;
    Loc.Z = FloorZ(N) + H + 2;
    if (Scout == None)
    {
        Scout = Spawn(class'SUBotScout',,, Loc);
        if (Scout == None)
        {
            NumPlaceFail++;
            return false;
        }
        ScoutC = Spawn(class'SUBotScoutController');
        ScoutC.Possess(Scout);
    }
    if (Scout.CollisionHeight != H)
        Scout.SetCollisionSize(PawnRadius, H);
    if (!Scout.SetLocation(Loc) && !Scout.SetLocation(Loc + vect(0,0,6)) && !Scout.SetLocation(Loc + vect(16,0,4))
        && !Scout.SetLocation(Loc + vect(-16,0,4)) && !Scout.SetLocation(Loc + vect(0,16,4)) && !Scout.SetLocation(Loc + vect(0,-16,4)))
    {
        NumPlaceFail++;
        return false;
    }
    Scout.SetPhysics(PHYS_Walking);
    Scout.Velocity = vect(0,0,0);
    Scout.Anchor = None;
    return true;
}

function KillScout()
{
    if (ScoutC != None)
    {
        ScoutC.UnPossess();
        ScoutC.Destroy();
    }
    if (Scout != None)
        Scout.Destroy();
    ScoutC = None;
    Scout = None;
}

// Fix 8 (objectives no shot can hit): some damageable objectives use static-mesh collision
// with a mesh that has none (SU-Chulak generator, StaticMesh SGs-Chul.circle): instant-hit
// shots pass through them, so neither bots nor players can damage them with guns. If a
// vertical trace through the objective misses it, switch it to its collision cylinder.
function FixShootableObjectives()
{
    local GameObjective O;
    local vector HitLocation, HitNormal, Up;
    local bool bBA, bBP;

    foreach AllActors(class'GameObjective', O)
    {
        if (!O.bProjTarget || O.bUseCylinderCollision || !O.bCollideActors)
            continue;
        Up = vect(0,0,1) * (O.CollisionHeight + 200);
        if (Trace(HitLocation, HitNormal, O.Location - Up, O.Location + Up, true) == O)
            continue;
        if (Trace(HitLocation, HitNormal, O.Location + vect(1,0,0) * (O.CollisionRadius + 200),
                  O.Location - vect(1,0,0) * (O.CollisionRadius + 200), true) == O)
            continue;
        O.bUseCylinderCollision = true;
        bBA = O.bBlockActors;
        bBP = O.bBlockPlayers;
        O.SetCollision(false, false, false);
        O.SetCollision(true, bBA, bBP);
        O.SetCollisionSize(FMax(O.CollisionRadius, 20), FMax(O.CollisionHeight, 20));
        if (bLogFixes)
            Log("objective " $ O.Name $ " '" $ O.ObjectiveName $ "' could not be hit by shots: now uses its collision cylinder "
                $ int(O.CollisionRadius) $ "x" $ int(O.CollisionHeight), 'SUBotFix');
    }
}

function float FloorZ(NavigationPoint N)
{
    local vector HitLocation, HitNormal;

    if (Trace(HitLocation, HitNormal, N.Location - vect(0,0,300), N.Location, false) != None)
        return HitLocation.Z;
    return N.Location.Z - 44;
}

// vertical clearance of 2*PawnHeight above the floor under N
function bool HeadroomAt(NavigationPoint N)
{
    local vector S, E, HitLocation, HitNormal;

    S = N.Location;
    S.Z = FloorZ(N) + 8;
    E = S;
    E.Z += 2 * PawnHeight;
    return Trace(HitLocation, HitNormal, E, S, false) == None;
}

function bool HeadroomClear(NavigationPoint A, NavigationPoint B, ReachSpec R)
{
    local vector S, E, HitLocation, HitNormal;
    local vector Ext;

    // jumps and drops do not follow the straight line: check both ends instead
    if ((R.reachFlags & 8) != 0 || R.MaxLandingVelocity > 0)
        return HeadroomAt(A) && HeadroomAt(B);

    S = A.Location;
    S.Z = FloorZ(A) + 96;
    E = B.Location;
    E.Z = FloorZ(B) + 96;
    Ext.X = PawnRadius;
    Ext.Y = PawnRadius;
    Ext.Z = 16;
    return Trace(HitLocation, HitNormal, E, S, false, Ext) == None;
}

// wall clock in ms within the day (LevelInfo copies the system time at the start of each frame).
// The next frame minus this frame is the real length of this frame: DeltaTime is capped at 0.4 s.
function int WallMs()
{
    return ((Level.Hour * 60 + Level.Minute) * 60 + Level.Second) * 1000 + Level.Millisecond;
}

function int IndexOf(NavigationPoint N)
{
    if (N == None || N.visitedWeight < 0 || N.visitedWeight >= Nodes.Length || Nodes[N.visitedWeight] != N)
        return -1;
    return N.visitedWeight;
}

// where bots aim at A: its ShootTarget when it has one (stock DestroyableObjective.GetShootTarget)
function vector AimPoint(Actor A)
{
    if (DestroyableObjective(A) != None && DestroyableObjective(A).ShootTarget != None)
        return DestroyableObjective(A).ShootTarget.Location;
    return A.Location;
}

// an actor trace from a soldier's eyes at N hits A itself (aiming where bots aim)
function bool ShotReaches(NavigationPoint N, Actor A)
{
    local vector Eye, HL, HN, T;

    Eye = N.Location + vect(0,0,30);
    T = AimPoint(A);
    return Trace(HL, HN, T + Normal(T - Eye) * 200, Eye, true) == A;
}

function bool CanSee(NavigationPoint N, Actor A)
{
    local vector Dir, Target, Side;

    if (FastTrace(A.Location, N.Location))
        return true;
    // an objective's own static mesh can block the trace to its centre
    Dir = Normal(N.Location - A.Location);
    Target = A.Location + Dir * FMin(A.CollisionRadius + 64, VSize(N.Location - A.Location) * 0.5);
    if (FastTrace(Target, N.Location))
        return true;
    // or it sits in a cave wall / on a ledge (SU-IceDet crystal): try the rim of its cylinder
    Side = Normal(Dir Cross vect(0,0,1)) * A.CollisionRadius * 0.9;
    return FastTrace(A.Location + Side, N.Location) || FastTrace(A.Location - Side, N.Location)
        || FastTrace(A.Location + vect(0,0,0.9) * A.CollisionHeight, N.Location)
        || FastTrace(A.Location - vect(0,0,0.9) * A.CollisionHeight, N.Location);
}

// nearest walkable node within MaxDist of Loc that has line of sight to Loc
function int NearestNode(vector Loc, float MaxDist)
{
    local int i, Best;
    local float D, BestD;

    Best = -1;
    BestD = MaxDist;
    for (i = 0; i < Nodes.Length; i++)
    {
        D = VSize(Nodes[i].Location - Loc);
        if (D < BestD && FastTrace(Loc, Nodes[i].Location))
        {
            Best = i;
            BestD = D;
        }
    }
    return Best;
}

// Closest PathNode of the playable network (it reaches an objective) to a stranded start,
// out of water and more than 1500 uu from any enemy spawn (no spawn camping). -1 if none.
function int EdgeNode(PlayerStart S, array<PlayerStart> Starts)
{
    local int k, i, Best;
    local float D, BestD;
    local bool bNearEnemy;

    Best = -1;
    BestD = 1000000000;
    for (k = 0; k < Nodes.Length; k++)
    {
        if (CanReachAny[k] == 0 || PathNode(Nodes[k]) == None)
            continue;
        if (Nodes[k].PhysicsVolume != None && Nodes[k].PhysicsVolume.bWaterVolume)
            continue;
        D = VSize(Nodes[k].Location - S.Location);
        if (D >= BestD)
            continue;
        bNearEnemy = false;
        for (i = 0; i < Starts.Length && !bNearEnemy; i++)
            if (Starts[i].TeamNumber != S.TeamNumber && VSize(Starts[i].Location - Nodes[k].Location) < 1500)
                bNearEnemy = true;
        if (bNearEnemy)
            continue;
        BestD = D;
        Best = k;
    }
    return Best;
}

// A spawn meant to be left by vehicle (SU-Abydos: the Tau'ri base is ~75k uu from the battle,
// players drive Hummers across unpathed desert) leaves walking bots out of the game for minutes.
// If the walking route from node From to the nearest objective of the team is longer than
// FastForwardDist, return the node of that route FrontDistance before its end (the bot "drove"
// the rest), otherwise From. Dijkstra over walkable specs (heap): runs once per stranded spawn.
// Diagnostics: the maps' alternate attack routes (AssaultPath chains, used by SU-Chulak and
// SU-P3X-548), with each point's walk to the team's objectives, against the walk from the team's
// nearest enabled spawn. Logged once per map and team.
function LogAssaultPaths(int Team, array<float> RD, array<PlayerStart> Starts)
{
    local GameObjective O;
    local AssaultPath A;
    local int i, Idx;
    local float MinStart;
    local string W;

    PathsLogged[Team] = 1;
    MinStart = 1000000000;
    for (i = 0; i < Starts.Length; i++)
    {
        Idx = IndexOf(Starts[i]);
        if (Idx >= 0 && Starts[i].TeamNumber == Team && Starts[i].bEnabled && RD[Idx] < MinStart)
            MinStart = RD[Idx];
    }
    foreach AllActors(class'GameObjective', O)
    {
        if (O.AlternatePaths == None || O.DefenderTeamIndex == Team || O.bDisabled)
            continue;
        Log("assault paths to " $ O.Name $ " for team " $ Team $ " (nearest spawn walks " $ int(MinStart) $ " uu):", 'SUBotFix');
        for (A = O.AlternatePaths; A != None; A = A.NextPath)
        {
            Idx = IndexOf(A);
            W = "?";
            if (Idx >= 0)
                W = string(int(RD[Idx]));
            Log("  " $ A.Name $ " pos " $ A.Position $ " tag " $ A.PathTag[0] $ "/" $ A.PathTag[1]
                $ " first=" $ A.bFirstPath $ " last=" $ A.bLastPath $ " enabled=" $ A.bEnabled
                $ " prio=" $ A.Priority $ " at " $ int(A.Location.X) $ "," $ int(A.Location.Y) $ "," $ int(A.Location.Z)
                $ " walk to objective " $ W, 'SUBotFix');
        }
    }
}

// RD[node] = length of the shortest walk from the node to an objective Team attacks (reverse
// Dijkstra from the objectives' target nodes; 1e9 when there is none)
function FrontDist(int Team, out array<float> RD, optional out byte bDefense)
{
    local int i, j, k, u, NumN;
    local float ND, Key;
    local array<byte> Done, IsTarget;
    local bool bAny;
    local array<float> HK;              // binary heap of (distance, node), stale entries skipped
    local array<int> HV;

    NumN = Nodes.Length;
    RD.Length = NumN;
    Done.Length = NumN;
    IsTarget.Length = NumN;
    for (i = 0; i < Objs.Length; i++)
        if (Objs[i].O.DefenderTeamIndex != Team && !Objs[i].O.bDisabled)
            for (j = Objs[i].CandStart; j < Objs[i].CandStart + Objs[i].CandCount; j++)
            {
                IsTarget[ObjCand[j]] = 1;
                bAny = true;
            }
    // a team that attacks nothing (SU-Chulak's Goa'uld): the objectives it defends (fix 37)
    bDefense = 0;
    if (!bAny)
        for (i = 0; i < Objs.Length; i++)
            if (Objs[i].O.DefenderTeamIndex == Team && !Objs[i].O.bDisabled && Objs[i].O.bActive)
                for (j = Objs[i].CandStart; j < Objs[i].CandStart + Objs[i].CandCount; j++)
                {
                    IsTarget[ObjCand[j]] = 1;
                    bAny = true;
                    bDefense = 1;
                }
    for (i = 0; i < NumN; i++)
    {
        RD[i] = 1000000000;
        if (IsTarget[i] != 0)
        {
            RD[i] = 0;
            HeapPush(HK, HV, 0, i);
        }
    }
    if (!bAny)
        return;
    // Dijkstra with a heap: the linear search for the next node cost about 100 ms per rebuild on
    // SU-Abydos (406 nodes, two teams)
    while (HK.Length > 0)
    {
        HeapPop(HK, HV, Key, u);
        if (Done[u] != 0 || Key > RD[u])
            continue;
        Done[u] = 1;
        // predecessors of u: nodes with a walk spec to u
        for (j = RevStart[u]; j < RevStart[u] + RevCount[u]; j++)
        {
            k = RevList[j];
            if (Done[k] != 0)
                continue;
            ND = RD[u] + SpecDist(k, u);
            if (ND < RD[k])
            {
                RD[k] = ND;
                HeapPush(HK, HV, ND, k);
            }
        }
    }
}

// Fix 57: each team's FrontDist, kept from the last ComputeReach (trapped bots)
function KeepFront(int Team, array<float> RD)
{
    local int i;

    // ComputeReach empties Nodes when it ends: keep the node order of RD
    FrontNodes.Length = Nodes.Length;
    for (i = 0; i < Nodes.Length; i++)
        FrontNodes[i] = Nodes[i];
    if (Team == 0)
    {
        FrontRD0.Length = RD.Length;
        for (i = 0; i < RD.Length; i++)
            FrontRD0[i] = RD[i];
    }
    else
    {
        FrontRD1.Length = RD.Length;
        for (i = 0; i < RD.Length; i++)
            FrontRD1[i] = RD[i];
    }
}

// FrontDist of node N for Team (-1: unknown)
function float FrontOf(int Team, NavigationPoint N)
{
    local int Idx;

    Idx = -1;
    if (N != None)
        for (Idx = FrontNodes.Length - 1; Idx >= 0 && FrontNodes[Idx] != N; Idx--);
    if (Idx < 0)
        return -1;
    if (Team == 0 && Idx < FrontRD0.Length)
        return FrontRD0[Idx];
    if (Team == 1 && Idx < FrontRD1.Length)
        return FrontRD1[Idx];
    return -1;
}

function HeapPush(out array<float> HK, out array<int> HV, float Key, int V)
{
    local int i, p;
    local float TK;
    local int TV;

    i = HK.Length;
    HK[i] = Key;
    HV[i] = V;
    while (i > 0)
    {
        p = (i - 1) / 2;
        if (HK[p] <= HK[i])
            break;
        TK = HK[p]; HK[p] = HK[i]; HK[i] = TK;
        TV = HV[p]; HV[p] = HV[i]; HV[i] = TV;
        i = p;
    }
}

function HeapPop(out array<float> HK, out array<int> HV, out float Key, out int V)
{
    local int i, c, n;
    local float TK;
    local int TV;

    Key = HK[0];
    V = HV[0];
    n = HK.Length - 1;
    HK[0] = HK[n];
    HV[0] = HV[n];
    HK.Length = n;
    HV.Length = n;
    i = 0;
    while (true)
    {
        c = 2 * i + 1;
        if (c >= n)
            break;
        if (c + 1 < n && HK[c + 1] < HK[c])
            c++;
        if (HK[i] <= HK[c])
            break;
        TK = HK[c]; HK[c] = HK[i]; HK[i] = TK;
        TV = HV[c]; HV[c] = HV[i]; HV[i] = TV;
        i = c;
    }
}

// length of the shortest walk spec A -> B (ring trips count 300, not the distance between the pads)
function float SpecDist(int A, int B)
{
    local int j;
    local float D;
    local ReachSpec R;

    D = 1000000000;
    for (j = 0; j < Nodes[A].PathList.Length; j++)
    {
        R = Nodes[A].PathList[j];
        if (R != None && R.End == Nodes[B] && Walkable(R))
            D = FMin(D, FMax(R.Distance, 1));
    }
    return D;
}

// the successor of node K on its shortest walk to the front
function int NextTowardFront(int K, array<float> RD)
{
    local int j, n, Best;
    local float D, BestD;
    local ReachSpec R;

    Best = K;
    BestD = RD[K];
    for (j = 0; j < Nodes[K].PathList.Length; j++)
    {
        R = Nodes[K].PathList[j];
        if (!Walkable(R))
            continue;
        n = IndexOf(R.End);
        if (n < 0)
            continue;
        D = RD[n] + FMax(R.Distance, 1);
        if (D <= BestD + 1 && RD[n] < RD[K])
        {
            BestD = D;
            Best = n;
        }
    }
    return Best;
}

function int FastForward(int From, int Team)
{
    local int i, j, k, u, Goal, NumN;
    local float ND, Key;
    local array<float> Dist, HK;
    local array<int> Prev, HV;
    local array<byte> Done, IsTarget;
    local ReachSpec R;

    NumN = Nodes.Length;
    Dist.Length = NumN;
    Prev.Length = NumN;
    Done.Length = NumN;
    IsTarget.Length = NumN;
    // targets: candidate nodes of the objectives this team attacks (all objectives for a pure defender)
    for (i = 0; i < Objs.Length; i++)
        if (Objs[i].O.DefenderTeamIndex != Team)
            for (j = Objs[i].CandStart; j < Objs[i].CandStart + Objs[i].CandCount; j++)
                IsTarget[ObjCand[j]] = 1;
    for (i = 0; i < NumN && Goal == 0; i++)
        if (IsTarget[i] != 0)
            Goal = 1;
    if (Goal == 0)
        for (i = 0; i < ObjCand.Length; i++)
            IsTarget[ObjCand[i]] = 1;
    for (i = 0; i < NumN; i++)
    {
        Dist[i] = 1000000000;
        Prev[i] = -1;
    }
    Dist[From] = 0;
    Goal = -1;
    HeapPush(HK, HV, 0, From);
    while (HK.Length > 0)
    {
        HeapPop(HK, HV, Key, u);
        if (Done[u] != 0 || Key > Dist[u])
            continue;
        Done[u] = 1;
        if (IsTarget[u] != 0)
        {
            Goal = u;
            break;
        }
        for (j = 0; j < Nodes[u].PathList.Length; j++)
        {
            R = Nodes[u].PathList[j];
            if (!Walkable(R))
                continue;
            k = IndexOf(R.End);
            if (k < 0 || Done[k] != 0)
                continue;
            ND = Dist[u] + FMax(R.Distance, 1);
            if (ND < Dist[k])
            {
                Dist[k] = ND;
                Prev[k] = u;
                HeapPush(HK, HV, ND, k);
            }
        }
    }
    if (Goal < 0 || Dist[Goal] < FastForwardDist)
        return From;
    k = Goal;
    while (Prev[k] >= 0 && Dist[Goal] - Dist[k] < FrontDistance)
        k = Prev[k];
    if (bLogFixes)
        Note("team " $ Team $ " route from " $ Nodes[From].Name $ " is " $ int(Dist[Goal]) $ " uu long: fast-forward to "
            $ Nodes[k].Name $ ", " $ int(Dist[Goal] - Dist[k]) $ " uu before " $ Nodes[Goal].Name);
    return k;
}

// forward BFS from the nodes already marked 1 in Mark (indices also in Queue)
function ForwardFlood()
{
    local int Head, i, j, k;

    Head = 0;
    while (Head < Queue.Length)
    {
        i = Queue[Head];
        Head++;
        for (j = 0; j < Nodes[i].PathList.Length; j++)
        {
            if (!Walkable(Nodes[i].PathList[j]))
                continue;
            k = IndexOf(Nodes[i].PathList[j].End);
            if (k >= 0 && Mark[k] == 0)
            {
                Mark[k] = 1;
                Queue[Queue.Length] = k;
            }
        }
    }
}

// reverse BFS (who can reach the nodes already marked) using RevList
function ReverseFlood()
{
    local int Head, i, j, k;

    Head = 0;
    while (Head < Queue.Length)
    {
        i = Queue[Head];
        Head++;
        for (j = RevStart[i]; j < RevStart[i] + RevCount[i]; j++)
        {
            k = RevList[j];
            if (Mark[k] == 0)
            {
                Mark[k] = 1;
                Queue[Queue.Length] = k;
            }
        }
    }
}

function ClearMarks()
{
    local int i;
    for (i = 0; i < Nodes.Length; i++)
        Mark[i] = 0;
    Queue.Length = 0;
}

// The load-time analysis, one step per timer tick (the order is unchanged). UnrealScript aborts a
// script that loops about 10 million times within one call from the engine, and the whole analysis
// was one call: IceDet's corridor floods took 830 ms there. Each step now has its own budget, and
// the hitch is spread. The bridges are opened and closed within step 3, never left open between ticks.
function Analyze(int Step)
{
    switch (Step)
    {
        case 1:
            FixSpecSizes();
            MonsterOnlySpecs();
            FixShootableObjectives();
            SetupRingPads();
            LinkOrphanObjectives();
            TimedWhat = "analysis (1/4, specs and orphan objectives)";
            break;
        case 2:
            BridgeGaps();
            TimedWhat = "analysis (2/4, gaps)";
            break;
        case 3:
            OpenBridges();
            BridgeGoals();
            CloseBridges();
            TimedWhat = "analysis (3/4, corridors)";
            break;
        case 4:
            FindObjectiveTriggers();
            ComputeReach();
            TimedWhat = "analysis";
            CountDone = DoneObjectives();
            break;
    }
    TimedWall = WallMs();
}

// number of disabled objectives (a stage was done: doors may have opened)
function int DoneObjectives()
{
    local GameObjective O;
    local int n;

    foreach AllActors(class'GameObjective', O)
        if (O.bDisabled)
            n++;
    return n;
}

// after a stage: doors and passages opened by its event let islands join the network
// one step per timer tick: done in one frame, the three took 73-145 ms (a visible hitch for players)
function Rebridge()
{
    switch (RebridgeStep)
    {
        case 1:
            ProscribeDoneForcedSpecs();
            BridgeGaps(true);
            TimedWhat = "navigation rebuilt after an objective (1/3, gaps)";
            TimedWall = WallMs();
            break;
        case 2:
            BridgeGoals(true);
            TimedWhat = "navigation rebuilt after an objective (2/3, corridors)";
            TimedWall = WallMs();
            break;
        default:
            ComputeReach();
            TimedWhat = "navigation rebuilt after an objective (3/3, reachability)";
            TimedWall = WallMs();
            RebridgeStep = 0;
            return;
    }
    RebridgeStep++;
}

// reachability per team, stranded spawns and their exits, approach points
function ComputeReach()
{
    local NavigationPoint N;
    local GameObjective O;
    local PlayerStart PS;
    local Actor R, BestR, RT;
    local array<PlayerStart> Starts;
    local array<int> EscapeSeedTeam, EscapeSeedNode;
    local int i, j, k, t, NumN, Oi, Idx, Best;
    local float D, BestD;
    local bool bShotTest;
    local array<float> RD;
    local float Far, Front;
    local byte bDef;

    // 1. index nodes
    Nodes.Length = 0;
    for (N = Level.NavigationPointList; N != None; N = N.NextNavigationPoint)
    {
        N.visitedWeight = Nodes.Length;
        Nodes[Nodes.Length] = N;
    }
    NumN = Nodes.Length;
    Mark.Length = NumN;
    CanReachAny.Length = NumN;
    TeamReach.Length = 2 * NumN;
    RevStart.Length = NumN;
    RevCount.Length = NumN;

    // 2. reverse adjacency (CSR)
    for (i = 0; i < NumN; i++)
        RevCount[i] = 0;
    for (i = 0; i < NumN; i++)
        for (j = 0; j < Nodes[i].PathList.Length; j++)
            if (Walkable(Nodes[i].PathList[j]))
            {
                k = IndexOf(Nodes[i].PathList[j].End);
                if (k >= 0)
                    RevCount[k]++;
            }
    k = 0;
    for (i = 0; i < NumN; i++)
    {
        RevStart[i] = k;
        k += RevCount[i];
        RevCount[i] = 0;
    }
    RevList.Length = k;
    for (i = 0; i < NumN; i++)
        for (j = 0; j < Nodes[i].PathList.Length; j++)
            if (Walkable(Nodes[i].PathList[j]))
            {
                k = IndexOf(Nodes[i].PathList[j].End);
                if (k >= 0)
                {
                    RevList[RevStart[k] + RevCount[k]] = i;
                    RevCount[k]++;
                }
            }

    // 3. objectives: target sets (objective node + nodes with line of sight), who can reach them
    for (i = 0; i < NumN; i++)
        CanReachAny[i] = 0;
    Objs.Length = 0;
    ObjCand.Length = 0;
    foreach AllActors(class'GameObjective', O)
    {
        Oi = Objs.Length;
        Objs.Length = Oi + 1;
        Objs[Oi].O = O;
        Objs[Oi].CandStart = ObjCand.Length;
        ClearMarks();
        Idx = IndexOf(O);
        if (Idx >= 0 && RevCount[Idx] > 0)
        {
            Mark[Idx] = 1;
            Queue[Queue.Length] = Idx;
        }
        // a destroyable objective is attacked from where a shot really reaches it (SU-P3X-548's
        // barrel: in sight of many nodes, but crates and walls stop the shots from 35 of 38)
        bShotTest = false;
        if (O.bProjTarget)
            for (i = 0; i < NumN && !bShotTest; i++)
                if (i != Idx && !Nodes[i].IsA('GameObjective') && VSize(Nodes[i].Location - O.Location) < ApproachRadius
                    && ShotReaches(Nodes[i], O))
                    bShotTest = true;
        for (i = 0; i < NumN; i++)
        {
            if (i == Idx || Nodes[i].IsA('GameObjective'))
                continue;
            if (VSize(Nodes[i].Location - O.Location) < ApproachRadius
                && ((!bShotTest && CanSee(Nodes[i], O)) || (bShotTest && ShotReaches(Nodes[i], O))))
            {
                ObjCand[ObjCand.Length] = i;
                if (Mark[i] == 0)
                {
                    Mark[i] = 1;
                    Queue[Queue.Length] = i;
                }
            }
        }
        // a target nothing is close to, but in range of a shot from farther away (SU-IceDet's crystal,
        // seen from the Goa'uld spawn area 4 k uu away): look again at twice the distance, shots only
        if (ObjCand.Length == Objs[Oi].CandStart && O.bProjTarget)
            for (i = 0; i < NumN; i++)
                if (i != Idx && !Nodes[i].IsA('GameObjective') && VSize(Nodes[i].Location - O.Location) < 2 * ApproachRadius
                    && ShotReaches(Nodes[i], O))
                {
                    ObjCand[ObjCand.Length] = i;
                    if (Mark[i] == 0)
                    {
                        Mark[i] = 1;
                        Queue[Queue.Length] = i;
                    }
                }
        Objs[Oi].CandCount = ObjCand.Length - Objs[Oi].CandStart;
        ReverseFlood();
        for (i = 0; i < NumN; i++)
            if (Mark[i] != 0)
                CanReachAny[i] = 1;
    }

    // 4. stranded spawns (cannot reach any objective) and their ring escape
    foreach AllActors(class'PlayerStart', PS)
        Starts[Starts.Length] = PS;
    StrandedStarts.Length = 0;
    StrandedEscape.Length = 0;
    StrandedExit.Length = 0;
    for (i = 0; i < Starts.Length; i++)
    {
        Idx = IndexOf(Starts[i]);
        if (Idx < 0 || CanReachAny[Idx] != 0)
            continue;
        // a) rings near the spawn: the way players leave it (Goa'uld Hatak on Abydos)
        BestR = None;
        BestD = RingEscapeRadius;
        Best = -1;
        foreach AllActors(class'Actor', R)
        {
            RT = RingTarget(R);
            if (RT == None)
                continue;
            k = NearestNode(RT.Location, 1000);
            if (k < 0 || CanReachAny[k] == 0)
                continue;
            D = VSize(R.Location - Starts[i].Location);
            if (D < BestD)
            {
                BestD = D;
                BestR = R;
                Best = k;
            }
        }
        // b) otherwise the spawn is left through something bots cannot plan (a long drive across
        //    unpathed desert on Abydos, a trap door on TokRa): hop to the closest node of the
        //    playable network, away from enemy spawns
        if (BestR == None)
            Best = EdgeNode(Starts[i], Starts);
        if (BestR == None && Best >= 0)
            Best = FastForward(Best, Starts[i].TeamNumber);
        if (BestR == None && Best < 0)
        {
            if (bLogFixes)
                Log("stranded spawn " $ Starts[i].Name $ " (team " $ Starts[i].TeamNumber $ ") has no escape", 'SUBotFix');
            continue;
        }
        StrandedStarts[StrandedStarts.Length] = Starts[i];
        StrandedEscape[StrandedEscape.Length] = BestR;
        if (BestR == None)
            StrandedExit[StrandedExit.Length] = Nodes[Best];
        else
            StrandedExit[StrandedExit.Length] = None;
        EscapeSeedTeam[EscapeSeedTeam.Length] = Starts[i].TeamNumber;
        EscapeSeedNode[EscapeSeedNode.Length] = Best;
        if (bLogFixes && BestR == None)
            Note("stranded spawn " $ Starts[i].Name $ " (team " $ Starts[i].TeamNumber $ "): no exit on foot, hop to "
                $ Nodes[Best].Name $ " " $ int(VSize(Nodes[Best].Location - Starts[i].Location)) $ " uu away");
    }

    // 4b. Fix 28: starts that do reach an objective, but only after a very long walk (SU-Abydos:
    // part of the Tau'ri base, 80 k uu from the fight, a Hummer drive across the desert, so the two
    // Tau'ri attackers spent the round driving and the Goa'uld always won the crystal race). Hop
    // them FrontDistance before the end of their route, like the stranded ones.
    // Fix 37: a team that only defends hops from spawns farther than DefenderSpawnDist to
    // DefenderFront before what it defends (SU-Chulak: the Goa'uld respawn 16-23 k uu from the
    // computer and the generator; the Tau'ri took the computer before the defenders arrived, 4 of 4)
    for (t = 0; t < 2; t++)
    {
        FrontDist(t, RD, bDef);
        KeepFront(t, RD);
        if (bDef == 0 && bLogFixes && PathsLogged[t] == 0)
            LogAssaultPaths(t, RD, Starts);
        Far = FarSpawnDist;
        Front = FrontDistance;
        if (bDef != 0)
        {
            Far = DefenderSpawnDist;
            Front = DefenderFront;
        }
        if (Far <= 0)
            continue;
        for (i = 0; i < Starts.Length; i++)
        {
            Idx = IndexOf(Starts[i]);
            if (Idx < 0 || Starts[i].TeamNumber != t || RD[Idx] < Far || RD[Idx] >= 1000000000)
                continue;
            for (j = 0; j < StrandedStarts.Length && StrandedStarts[j] != Starts[i]; j++);
            if (j < StrandedStarts.Length)
                continue;
            k = Idx;
            for (Best = 0; Best < 2000 && RD[k] > Front; Best++)
                k = NextTowardFront(k, RD);
            if (k == Idx)
                continue;
            StrandedStarts[StrandedStarts.Length] = Starts[i];
            StrandedEscape[StrandedEscape.Length] = None;
            StrandedExit[StrandedExit.Length] = Nodes[k];
            EscapeSeedTeam[EscapeSeedTeam.Length] = t;
            EscapeSeedNode[EscapeSeedNode.Length] = k;
            if (bLogFixes)
                Note("far spawn " $ Starts[i].Name $ " (team " $ t $ "): " $ int(RD[Idx]) $ " uu from the front, hop to "
                    $ Nodes[k].Name $ " (" $ int(RD[k]) $ " uu)");
        }
    }

    // 5. what each team can reach on foot (from its spawns and ring exits)
    for (t = 0; t < 2; t++)
    {
        ClearMarks();
        for (i = 0; i < Starts.Length; i++)
        {
            Idx = IndexOf(Starts[i]);
            if (Idx >= 0 && Starts[i].TeamNumber == t && Mark[Idx] == 0)
            {
                Mark[Idx] = 1;
                Queue[Queue.Length] = Idx;
            }
        }
        for (i = 0; i < EscapeSeedNode.Length; i++)
            if (EscapeSeedTeam[i] == t && Mark[EscapeSeedNode[i]] == 0)
            {
                Mark[EscapeSeedNode[i]] = 1;
                Queue[Queue.Length] = EscapeSeedNode[i];
            }
        ForwardFlood();
        for (i = 0; i < NumN; i++)
            TeamReach[t * NumN + i] = Mark[i];
    }

    // 6. approach points for objectives a team cannot path to
    for (Oi = 0; Oi < Objs.Length; Oi++)
    {
        O = Objs[Oi].O;
        Idx = IndexOf(O);
        for (t = 0; t < 2; t++)
        {
            Objs[Oi].Approach[t] = None;
            Objs[Oi].bUnreachable[t] = 0;
            if (Idx >= 0 && RevCount[Idx] > 0 && TeamReach[t * NumN + Idx] != 0)
                continue;   // normal pathing works
            Objs[Oi].bUnreachable[t] = 1;
            BestD = 1000000;
            for (j = Objs[Oi].CandStart; j < Objs[Oi].CandStart + Objs[Oi].CandCount; j++)
            {
                k = ObjCand[j];
                if (TeamReach[t * NumN + k] == 0)
                    continue;
                D = VSize(Nodes[k].Location - O.Location);
                if (D < BestD)
                {
                    BestD = D;
                    Objs[Oi].Approach[t] = Nodes[k];
                }
            }
            if (bLogFixes)
                Log("objective " $ O.Name $ " '" $ O.ObjectiveName $ "' team " $ t $ ": no path, approach="
                    $ Objs[Oi].Approach[t] $ " dist=" $ int(BestD), 'SUBotFix');
        }
    }

    if (bLogFixes)
        Log("analysis: " $ NumN $ " navpoints, " $ Objs.Length $ " objectives, " $ StrandedStarts.Length
            $ " stranded spawns with ring escape", 'SUBotFix');

    // 7. leave the engine's scratch field clean, drop temporary data
    for (i = 0; i < NumN; i++)
        Nodes[i].visitedWeight = 0;
    Nodes.Length = 0;
    RevStart.Length = 0;
    RevCount.Length = 0;
    RevList.Length = 0;
    Mark.Length = 0;
    Queue.Length = 0;
    CanReachAny.Length = 0;
    TeamReach.Length = 0;
    ObjCand.Length = 0;
}

defaultproperties
{
    bLogFixes=true
    ApproachRadius=3000
    EscapeDelay=2.0
    RingEscapeRadius=2500
    FastForwardDist=20000
    FrontDistance=12000
    FarSpawnDist=70000
    DefenderSpawnDist=12000
    DefenderFront=3000
    PawnHeight=55
    PawnRadius=20
    SmallPawnHeight=50
    bNativeSpecTest=true
    OrphanLinkRadius=1500
    GapRadius=640
    MaxGapTests=600
    MaxFloodCells=10000
    bFightMonsters=true
    bArmGoauld=true
    bFightOnTheWay=true
    CapitalFightRange=8000
    PilotObjectiveRange=8000
    CapitalDuelRange=8000
    bTurretClearShots=true
    bMedicHeal=true
    HealBelow=60
    HealSeekRange=1200
    DefendPostDist=3000
    bFireOnTheMove=true
    MoveFireRange=3000
    bRefillAmmo=true
    RefillBelow=0.25
    RefillSeekDist=8000
    DryRefillDist=20000
    LinkBanTime=120
    bDefendersHunt=true
    bBotsSprint=true
    HummerEntryDist=300
    TrappedTime=20
    bKeepSoleLinks=true
    DriverStuckTime=12
    DriverStuckDist=150
    FarEnemyDist=2500
    bMapRoundTime=true
    PilotAttackDist=2500
    PilotAttackRadius=1500
    bAutoBalance=true
    HumanMaxBias=1.0
    HopTransitSpeed=1000
    PullOutTime=1.2
    PullOutDist=1500
    PilotStrikeRange=6000
    PilotStrikeTime=1
    PilotBreakTime=16
    GuardFighterRange=8000
    bBalanceLearn=true
    BalanceStep=0.5
    MaxBalanceScore=6
    BalanceScores(0)="SU-TokRa=1"
    BalanceScores(1)="SU-P3X-548=-5"
    BalanceScores(2)="SU-Antartica=4"
    BalanceScores(3)="SU-IceDet=-5"
    BalanceScores(4)="SU-Asteroid=2"
    BalanceScores(5)="SU-X303Down=8"
    BalanceScores(6)="SU-Asgard[Medium]=8"
    BalanceScores(7)="SU-Asgard[Hard]=8"
    BalanceScores(8)="SU-Chulak=-1"
    BalanceScores(9)="SU-Abydos=-1"
    DefaultMapList="(\"SU-P3X-548\",\"SU-Abydos\",\"SU-Chulak\",\"SU-TokRa\",\"SU-IceDet\",\"SU-Antartica\",\"SU-Asteroid\",\"SU-X303Down\",\"SU-Asgard[Medium]\",\"SU-Asgard[Hard]\")"
    MaxDropRise=260
    PoolNodes=256
    StuckTime=10
    FriendlyName="SU Bot Fix"
    Description="Server-side fixes for Special Unit bots: objectives after warmup, objectives without paths, stranded spawns."
    GroupName="SUBotFix"
}
