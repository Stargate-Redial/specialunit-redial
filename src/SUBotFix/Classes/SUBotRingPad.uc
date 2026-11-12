// Navigation node on a rings pad (TheRings, or a map's own TheRingsTemp), added by MutSUBotFix.
// A ReachSpec links the pad of the rings a bot stands on to this pad; when the bot starts that move
// the engine calls SuggestMovePreparation here (bSpecialMove): the rings are activated for the
// effect and the trip is completed (the rings rarely catch a bot that walks on).
class SUBotRingPad extends SUBotNavNode
    notplaceable;

var Actor MyRings;                  // the rings this pad stands on
var Actor PartnerRings;             // rings at the pad bots come from
var NavigationPoint PartnerPad;
var int Trips;

event bool SuggestMovePreparation(Pawn Other)
{
    local MutSUBotFix M;

    if (PartnerPad == None || Other == None || Other.Controller == None)
        return false;
    if (VSize(Other.Location - PartnerPad.Location) > 260)
        return false;               // not starting from the partner pad
    if (PartnerRings != None && !PartnerRings.IsInState('Activated'))
        PartnerRings.UsedBy(Other);
    // not onto a pawn standing on this pad (fix 61: that pawn would kill the one arriving)
    foreach DynamicActors(class'MutSUBotFix', M)
        break;
    if ((M != None && (M.PutPawn(Other, Location + vect(0,0,1) * (Other.CollisionHeight - 30))
            || M.PutPawn(Other, Location + vect(0,0,40))))
        || (M == None && (Other.SetLocation(Location + vect(0,0,1) * (Other.CollisionHeight - 30))
            || Other.SetLocation(Location + vect(0,0,40)))))
    {
        Other.Velocity = vect(0,0,0);
        Other.Acceleration = vect(0,0,0);
        Trips++;
    }
    return false;
}

defaultproperties
{
    bSpecialMove=True
}
