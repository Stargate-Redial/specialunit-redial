// Squad used for SU bots when MutSUBotFix is active (set through TeamAI.SquadType).
// Adds a fallback for objectives the team cannot path to: go to the precomputed
// approach point (reachable, line of sight), then let the objective's own bot logic
// (ranged attack for destroyables, "use" for triggered objectives) take over.
class SUBotSquadAI extends SquadAI;

var MutSUBotFix Fix;

function MutSUBotFix GetFix()
{
    local MutSUBotFix M;

    if (Fix == None)
        foreach DynamicActors(class'MutSUBotFix', M)
        {
            Fix = M;
            break;
        }
    return Fix;
}

// Stock freelance squads only head for an objective when their team trails or leads by more than 2
// points (TeamAI.ReAssessStrategy); otherwise their bots roam the map at random (FindRoamDest).
// On SU's objective maps that wasted 7-25 % of the bots, all of them on IceDet. A freelance squad
// whose objective is an enemy one attacks it; freelance defenders keep roaming (they hunt attackers).
function name GetOrders()
{
    if (PlayerController(SquadLeader) == None && bFreelance && !bFreelanceAttack && !bFreelanceDefend
        && SquadObjective != None && SquadObjective.DefenderTeamIndex != Team.TeamIndex
        && !SquadObjective.bDisabled && SquadObjective.bActive)
    {
        if (CurrentOrders != 'Attack')
        {
            NetUpdateTime = Level.TimeSeconds - 1;
            CurrentOrders = 'Attack';
        }
        return CurrentOrders;
    }
    return Super.GetOrders();
}

function bool FindPathToObjective(Bot B, Actor O)
{
    local GameObjective GO;
    local NavigationPoint AP;

    if (O == None)
        O = SquadObjective;
    GO = GameObjective(O);
    if (GO != None && B.Pawn != None && Vehicle(B.Pawn) == None && GetFix() != None)
    {
        AP = Fix.GetApproach(GO, Team.TeamIndex);
        if (AP != None)
            return GoNear(B, GO, AP);
    }
    return Super.FindPathToObjective(B, O);
}

function bool GoNear(Bot B, GameObjective GO, NavigationPoint AP)
{
    if (B.ActorReachable(GO))
    {
        if (B.Pawn.ReachedDestination(GO))
        {
            GO.Touch(B.Pawn);
            return false;
        }
        B.GoalString = "SUBotFix: straight to " $ GO;
        B.RouteGoal = GO;
        B.MoveTarget = GO;
        B.SetAttractionState();
        return true;
    }
    if (B.Pawn.ReachedDestination(AP) || VSize(B.Pawn.Location - AP.Location) < 150)
    {
        // at the approach point: the objective could not be attacked from here, close in
        B.GoalString = "SUBotFix: at " $ AP $ ", closing in on " $ GO;
        B.RouteGoal = GO;
        B.MoveTarget = GO;
        B.SetAttractionState();
        return true;
    }
    B.GoalString = "SUBotFix: approach " $ GO $ " via " $ AP;
    return B.SetRouteToGoal(AP);
}

function bool CheckSquadObjectives(Bot B)
{
    local NavigationPoint AP;
    local Actor T;
    local SUCrystalObject K;
    local SUCaptureCrystal Spot;
    local Vehicle V;
    local bool bHumanLed;
    local GameObjective O;
    local Pawn HP;

    // Stock bug: SquadAI only releases an unreachable defense/freelance script when the
    // path target IS the script, but GetMoveTarget() returns its AIMarker, so a bot whose
    // script marker is off the nav graph (SU-Chulak) retries it forever near its spawn.
    if (B.GoalScript != None && B.Pawn != None && Vehicle(B.Pawn) == None && HoldSpot(B.GoalScript) == None)
    {
        T = B.GoalScript.GetMoveTarget();
        if (T != None && T != B.Pawn && !B.Pawn.ReachedDestination(T)
            && !B.ActorReachable(T) && B.FindPathToward(T) == None)
        {
            if (GetFix() != None)
                Fix.Note("dropped unreachable script " $ B.GoalScript.Name $ " (" $ T.Name $ ") for " $ B.PlayerReplicationInfo.PlayerName);
            B.GoalScript.bAvoid = true;
            B.FreeScript();
        }
    }

    // Fix 48: a Tau'ri bot short of ammo walks to the crate MutSUBotFix.RefillAmmo picked for it
    // (it uses the crate once it touches it)
    if (B.Pawn != None && Vehicle(B.Pawn) == None && GetFix() != None)
    {
        T = Fix.RefillCrateFor(B);
        if (T != None)
        {
            B.GoalString = "SUBotFix: refill at " $ T.Name;
            if (B.ActorReachable(T))
            {
                B.RouteGoal = T;
                B.MoveTarget = T;
                B.SetAttractionState();
                return true;
            }
            if (B.SetRouteToGoal(T))
                return true;
            Fix.DropRefill(B);
        }
    }

    // Fix 54: a bot sent back to an objective trigger (MutSUBotFix.TouchObjectiveTriggers)
    if (B.Pawn != None && Vehicle(B.Pawn) == None && GetFix() != None)
    {
        T = Fix.ErrandGoalFor(B);
        if (T != None)
        {
            B.GoalString = "SUBotFix: back to " $ T.Name;
            if (B.ActorReachable(T))
            {
                B.RouteGoal = T;
                B.MoveTarget = T;
                B.SetAttractionState();
                return true;
            }
            if (B.SetRouteToGoal(T))
                return true;
        }
    }

    // Fix 50: a defender sent after whoever shoots its objective (MutSUBotFix.WatchObjectiveDamage)
    if (B.Pawn != None && Vehicle(B.Pawn) == None && GetFix() != None)
    {
        HP = Fix.HuntTargetFor(B);
        if (HP != None)
        {
            if (B.Enemy != HP)
                SetEnemy(B, HP);
            if (B.LineOfSightTo(HP))
            {
                B.FightEnemy(true, 0);
                return true;
            }
            B.GoalString = "SUBotFix: hunt " $ HP.GetHumanReadableName() $ ", who shoots the objective";
            if (B.SetRouteToGoal(HP))
                return true;
        }
    }

    // Ground vehicles at an objective that must be done on foot (SU-IceDet: a Hummer parked on the
    // ledge of SUProximityObjective0, its driver charging enemies from the seat for minutes). The
    // stock bail-out lives in ProximityObjective.TellBotHowToDisable, which a driver in a fight never
    // reaches (SquadAI.CheckVehicle keeps it busy). Get out within 1200 uu, then carry on on foot.
    // A driver whose vehicle has no route to the objective (IceDet's roads stop short of it) roams
    // between two road nodes for the whole round: get out and walk.
    // Squads led by a human player follow the player (stock behaviour): only the crystal delivery
    // below applies to them.
    bHumanLed = PlayerController(SquadLeader) != None && SquadLeader.Pawn != None;
    V = Vehicle(B.Pawn);
    if (!bHumanLed && V != None && V.Driver != None && V.Physics != PHYS_Flying && !NeverBail(V) && SquadObjective != None
        && !SquadObjective.bDisabled && SquadObjective.bActive && SquadObjective.DefenderTeamIndex != Team.TeamIndex)
    {
        if (!SquadObjective.bProjTarget && VSize(V.Location - SquadObjective.Location) < 1200
            && (ProximityObjective(SquadObjective) != None || SquadObjective.IsA('SUTriggeredObjective')))
        {
            V.TeamUseTime = Level.TimeSeconds + 6;
            V.KDriverLeave(false);
            if (B.Pawn == None)
                return true;    // between the vehicle and the driver: AssignSquadResponsibility would read B.Pawn
            if (Vehicle(B.Pawn) != None)
                return false;
            B.GoalString = "SUBotFix: got out of " $ V.Name $ " at " $ SquadObjective.Name;
        }
        // (drivers only: a gunner seat has no route of its own, and may be a human player's passenger)
        else if (!V.IsA('ONSWeaponPawn') && (B.Enemy == None || !B.EnemyVisible()) && B.FindPathToward(SquadObjective) == None)
        {
            AP = None;
            if (GetFix() != None)
                AP = Fix.GetApproach(SquadObjective, Team.TeamIndex);
            if (AP == None || B.FindPathToward(AP) == None)
            {
                V.VehicleLostTime = Level.TimeSeconds + 30;
                V.TeamUseTime = Level.TimeSeconds + 30;
                V.KDriverLeave(false);
                if (B.Pawn == None)
                return true;    // between the vehicle and the driver: AssignSquadResponsibility would read B.Pawn
            if (Vehicle(B.Pawn) != None)
                    return false;
                if (GetFix() != None)
                    Fix.Note("no road to " $ SquadObjective.Name $ " for " $ V.Class.Name $ ": driver gets out and walks");
                B.GoalString = "SUBotFix: no road to " $ SquadObjective.Name $ ", out of " $ V.Name;
            }
        }
    }

    // Crystal carriers: SUCaptureCrystal.TellBotHowToDisable calls FindCrystal, which "captures"
    // the crystal the bot holds (disables it, moves it away) without scoring (only Touch scores),
    // so the stock path destroyed every crystal a bot picked up. Carriers never go through it:
    // they walk to their team's capture spot, whose Touch does the real capture.
    if (B.Pawn != None && CarriedCrystal(B.Pawn) != None)
    {
        Spot = CaptureSpotFor(Team.TeamIndex);
        if (Spot != None)
        {
            B.GoalString = "SUBotFix: carry crystal to " $ Spot.Name;
            if (B.ActorReachable(Spot))
            {
                B.MoveTarget = Spot;
                B.SetAttractionState();
                return true;
            }
            AP = None;
            if (GetFix() != None)
                AP = Fix.GetApproach(Spot, Team.TeamIndex);
            if (AP != None && VSize(B.Pawn.Location - AP.Location) > 150 && B.SetRouteToGoal(AP))
                return true;
            if (B.SetRouteToGoal(Spot))
                return true;
            if (AP != None)
            {
                B.MoveTarget = Spot;      // at the approach point: close in
                B.SetAttractionState();
                return true;
            }
        }
        return false;
    }

    // Crystals (SU-Abydos last stage, SU-TokRa): SUCaptureCrystal only guides a bot that already
    // carries a crystal, so nobody ever fetched one. Attackers of a capture spot go and get the
    // nearest free crystal, or chase the enemy who carries it.
    if (!bHumanLed && B.Pawn != None && Vehicle(B.Pawn) == None && SUCaptureCrystal(SquadObjective) != None
        && SquadObjective.DefenderTeamIndex != Team.TeamIndex && !SquadObjective.bDisabled
        && CarriedCrystal(B.Pawn) == None && (B.Enemy == None || !B.EnemyVisible()))
    {
        K = NearestCrystal(B);
        if (K != None)
        {
            if (K.Holder == None)
            {
                B.GoalString = "SUBotFix: fetch crystal " $ K.Name;
                if (B.ActorReachable(K))
                {
                    B.MoveTarget = K;
                    B.SetAttractionState();
                    return true;
                }
                if (B.SetRouteToGoal(K))
                    return true;
            }
            else if (K.Holder.GetTeamNum() != Team.TeamIndex)
            {
                B.GoalString = "SUBotFix: chase crystal carrier " $ K.Holder.GetHumanReadableName();
                if (B.SetRouteToGoal(K.Holder))
                    return true;
            }
        }
        // no crystal within reach yet (SU-Abydos: the chamber opens when the Tau'ri have done the
        // Temple and the DHD): instead of waiting next to it, which won the Goa'uld the race in every
        // game, defend the team's own objectives until a crystal can be fetched
        O = Team.AI.GetLeastDefendedObjective();
        if (O != None && O.DefenderTeamIndex == Team.TeamIndex && !O.bDisabled && O.bActive
            && SUCaptureCrystal(O) == None && VSize(O.Location - B.Pawn.Location) > 1500)
        {
            B.GoalString = "SUBotFix: no crystal to fetch yet, defends " $ O.Name;
            if (B.SetRouteToGoal(O))
                return true;
        }
    }

    // Defenders of a capture spot (SU-Abydos, SU-TokRa): standing on it does not stop a carrier, and
    // the crystal race went to the Goa'uld in 8 games of 8. Chase the enemy carrier, or fetch a free
    // crystal for the team.
    if (!bHumanLed && B.Pawn != None && Vehicle(B.Pawn) == None && SUCaptureCrystal(SquadObjective) != None
        && SquadObjective.DefenderTeamIndex == Team.TeamIndex && CarriedCrystal(B.Pawn) == None
        && (B.Enemy == None || !B.EnemyVisible()))
    {
        K = NearestCrystal(B);
        if (K != None && K.Holder != None && K.Holder.GetTeamNum() != Team.TeamIndex)
        {
            B.GoalString = "SUBotFix: intercept crystal carrier " $ K.Holder.GetHumanReadableName();
            if (B.SetRouteToGoal(K.Holder))
                return true;
        }
        else if (K != None && K.Holder == None && CaptureSpotFor(Team.TeamIndex) != None)
        {
            B.GoalString = "SUBotFix: defender fetches crystal " $ K.Name;
            if (B.ActorReachable(K))
            {
                B.MoveTarget = K;
                B.SetAttractionState();
                return true;
            }
            if (B.SetRouteToGoal(K))
                return true;
        }
    }

    // Fix 45: defenders far from their post stopped to fight any enemy in sight (stock: a defender
    // with a visible enemy always gets FightEnemy, which picks a ranged attack two times in three at
    // skill 3). On SU-Abydos's open desert they shot at attackers 5-10 k uu away for minutes, 6+ k uu
    // from what they defend, and hardly ever hit. A defender farther than DefendPostDist from its
    // post, whose enemy is farther than FarEnemyDist, heads for the post and fights on the move.
    if (!bHumanLed && B.Pawn != None && Vehicle(B.Pawn) == None && SquadObjective != None && GetOrders() == 'Defend'
        && SquadObjective.DefenderTeamIndex == Team.TeamIndex && !SquadObjective.bDisabled && SquadObjective.bActive
        && B.Enemy != None && B.EnemyVisible() && GetFix() != None && Fix.DefendPostDist > 0
        && VSize(B.Enemy.Location - B.Pawn.Location) > Fix.FarEnemyDist)
    {
        T = None;
        if (B.GoalScript != None)
            T = B.GoalScript.GetMoveTarget();
        if (T == None || T == B.Pawn)
            T = SquadObjective;
        if (VSize(T.Location - B.Pawn.Location) > Fix.DefendPostDist)
        {
            AP = None;
            if (T == SquadObjective)
                AP = Fix.GetApproach(SquadObjective, Team.TeamIndex);
            if (AP != None)
                T = AP;
            B.GoalString = "SUBotFix: back to post " $ T.Name $ ", fighting on the way";
            if (B.SetRouteToGoal(T))
            {
                Fix.NumPostReturns++;
                return true;
            }
        }
    }

    // defenders of an objective they cannot path to: hold the approach point
    if (!bHumanLed && B.Pawn != None && SquadObjective != None && GetOrders() == 'Defend'
        && SquadObjective.DefenderTeamIndex == Team.TeamIndex
        && B.GoalScript == None && Vehicle(B.Pawn) == None && GetFix() != None
        && (B.Enemy == None || !B.EnemyVisible()))
    {
        AP = Fix.GetApproach(SquadObjective, Team.TeamIndex);
        if (AP != None && VSize(B.Pawn.Location - AP.Location) > 300
            && (VSize(SquadObjective.Location - B.Pawn.Location) > 1200 || !B.LineOfSightTo(SquadObjective)))
        {
            B.GoalString = "SUBotFix: defend " $ SquadObjective $ " via " $ AP;
            if (B.SetRouteToGoal(AP))
                return true;
        }
    }
    return Super.CheckSquadObjectives(B);
}

// the spot where Team brings crystals (the one it attacks)
function SUCaptureCrystal CaptureSpotFor(int TeamIndex)
{
    local SUCaptureCrystal S;

    foreach AllActors(class'SUCaptureCrystal', S)
        if (S.DefenderTeamIndex != TeamIndex && !S.bDisabled)
            return S;
    return None;
}

function SUCrystalObject CarriedCrystal(Pawn P)
{
    local SUCrystalObject K;

    foreach DynamicActors(class'SUCrystalObject', K)
        if (K.Holder == P)
            return K;
    return None;
}

// free crystal closest to the bot (or one an enemy carries), None when all are captured or held by friends
function SUCrystalObject NearestCrystal(Bot B)
{
    local SUCrystalObject K, Best;
    local float D, BestD;

    BestD = 1000000000;
    foreach DynamicActors(class'SUCrystalObject', K)
    {
        if (K.bDisabled || (K.Holder != None && K.Holder.GetTeamNum() == Team.TeamIndex))
            continue;
        D = VSize(K.Location - B.Pawn.Location);
        if (D < BestD)
        {
            BestD = D;
            Best = K;
        }
    }
    return Best;
}

defaultproperties
{
    RemoteRole=ROLE_None
}
