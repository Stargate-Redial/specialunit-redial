// SUTweaks.MutSUSpeed - faster movement for Special Unit (optional, server choice).
// Special Unit's soldiers walk at 250 uu/s (UT2004: 440), 150 with a heavy weapon. This mutator
// multiplies every SU pawn class's GroundSpeed by SpeedScale (1.4: 250 -> 350, class differences
// kept) and raises the heavy-weapon speed to HeavySpeed (250). Movement is predicted on the client,
// so the same values must apply there: SUSpeedInfo (replicated) applies them on every client.
// SUTweaks must be in ServerPackages (clients download it); it does not depend on SpecialUnit.u.
class MutSUSpeed extends Mutator
    config;

var() config float SpeedScale;
var() config int HeavySpeed;

function PostBeginPlay()
{
    local SUSpeedInfo I;

    Super.PostBeginPlay();
    I = Spawn(class'SUSpeedInfo');
    if (I != None)
    {
        I.SpeedScale = FClamp(SpeedScale, 0.5, 3.0);
        I.HeavySpeed = Clamp(HeavySpeed, 0, 1000);
        I.Apply();
    }
}

defaultproperties
{
    SpeedScale=1.4
    HeavySpeed=250
    FriendlyName="SU Speed"
    Description="Faster movement for Special Unit: x1.4 walking speed for every class, heavy weapons at 250."
    GroupName="SUSpeed"
}
