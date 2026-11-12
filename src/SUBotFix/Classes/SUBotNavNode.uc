// Path node added at runtime by MutSUBotFix (spawned during InitGame into a pool, so that its
// name resolves for POKE; placed and linked into Level.NavigationPointList when needed).
class SUBotNavNode extends PathNode
    notplaceable;

defaultproperties
{
    bStatic=False
    bNoDelete=False
    bCollideWhenPlacing=False
    bHidden=True
    RemoteRole=ROLE_None
}
