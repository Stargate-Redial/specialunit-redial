// Invisible pawn used only for native reachability tests (Controller.PointReachable), sized like
// an SU soldier (SetCollisionSize before each test). Adapted from the SUNav research prototype.
class SUBotScout extends Pawn
    notplaceable;

defaultproperties
{
    bDontPossess=True
    bHidden=True
    bCollideActors=False
    bBlockActors=False
    bProjTarget=False
    bCanBeDamaged=False
    bCanPickupInventory=False
    RemoteRole=ROLE_None
    ControllerClass=None
    bCanJump=True
    bCanWalkOffLedges=True
    bCanWalk=True
    bCanCrouch=False
    bCanSwim=False
    bCanFly=False
    CollisionRadius=20.000000
    CollisionHeight=55.000000
    JumpZ=350.000000
    GroundSpeed=250.000000
    Physics=PHYS_Walking
    bStasis=True
}
