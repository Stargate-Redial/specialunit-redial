// Applies MutSUSpeed's values on the server and on every client (class defaults, so that the
// client's movement prediction matches the server), and keeps heavy-weapon carriers at HeavySpeed.
class SUSpeedInfo extends ReplicationInfo;

var float SpeedScale;
var int HeavySpeed;
var bool bApplied;

replication
{
    reliable if (bNetInitial && Role == ROLE_Authority)
        SpeedScale, HeavySpeed;
}

simulated function PostNetBeginPlay()
{
    Super.PostNetBeginPlay();
    if (Role < ROLE_Authority)
        Apply();
}

// every SU soldier class, by name (no compile-time dependency on SpecialUnit.u), with the walking
// speed Special Unit gives it. The speed is set from that base, never multiplied from the current
// default: a child class loaded after its parent was changed inherits the changed value (the first version
// gave a Jaffa 686 instead of 350), and SpecialUnit's classes outlive a map change while this package
// is loaded again, so a factor applied to the current default grew at every map (x1.4 per map).
simulated function Apply()
{
    local int i;
    local class<Pawn> C;
    local array<string> Names;
    local array<float> Base;

    if (bApplied || SpeedScale <= 0)
        return;
    bApplied = true;
    Names[Names.Length] = "SUPawn"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnTorri"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnGoa"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnGoaAnubisSClass"; Base[Base.Length] = 200;
    Names[Names.Length] = "SUPawnGoaAnubisFClass"; Base[Base.Length] = 200;
    Names[Names.Length] = "SUPawnGoaAnubis"; Base[Base.Length] = 200;
    Names[Names.Length] = "SUPawnGoaAnubisPrima"; Base[Base.Length] = 200;
    Names[Names.Length] = "SUPawnGoaHorusSClass"; Base[Base.Length] = 300;
    Names[Names.Length] = "SUPawnGoaHorusFClass"; Base[Base.Length] = 300;
    Names[Names.Length] = "SUPawnGoaHorus"; Base[Base.Length] = 350;
    Names[Names.Length] = "SUPawnGoaHorusPrima"; Base[Base.Length] = 350;
    Names[Names.Length] = "SUPawnGoaJaffaSClass"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnGoaJaffaFClass"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnGoaJaffa"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnGoaJaffaPrima"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnTorriLightInfantryLieutenant"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnTorriLightInfantryMajor"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnTorriLightInfantryColonel"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnTorriLightInfantry"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnTorriMachineGunnerLieutenant"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnTorriMachineGunnerMajor"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnTorriMachineGunnerColonel"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnTorriMachineGunner"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnTorriMedicLieutenant"; Base[Base.Length] = 300;
    Names[Names.Length] = "SUPawnTorriMedicMajor"; Base[Base.Length] = 300;
    Names[Names.Length] = "SUPawnTorriMedicColonel"; Base[Base.Length] = 300;
    Names[Names.Length] = "SUPawnTorriMedic"; Base[Base.Length] = 300;
    Names[Names.Length] = "SUPawnTorriSniperLieutenant"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnTorriSniperMajor"; Base[Base.Length] = 250;
    Names[Names.Length] = "SUPawnTorriSniperColonel"; Base[Base.Length] = 300;
    Names[Names.Length] = "SUPawnTorriSniper"; Base[Base.Length] = 300;
    for (i = 0; i < Names.Length; i++)
    {
        C = class<Pawn>(DynamicLoadObject("SpecialUnit." $ Names[i], class'Class', true));
        if (C != None)
            C.default.GroundSpeed = Base[i] * SpeedScale;
    }
    Log("SU Speed: walking speeds x" $ SpeedScale $ ", heavy weapons " $ HeavySpeed, 'SUTweaks');
}

// heavy weapons: SU sets GroundSpeed to 150 (Tau'ri) when one is drawn; Goa'uld are reset to
// their default every tick by SU itself, so only raise speeds below HeavySpeed
simulated function Tick(float DeltaTime)
{
    local xPawn P;

    if (HeavySpeed <= 0)
        return;
    foreach DynamicActors(class'xPawn', P)
        if (P.WeaponAttachment != None && P.WeaponAttachment.bHeavy && P.GroundSpeed < HeavySpeed
            && P.IsA('SUPawn') && P.Health > 0)
            P.GroundSpeed = HeavySpeed;
}

defaultproperties
{
    bAlwaysRelevant=True
    RemoteRole=ROLE_SimulatedProxy
    NetUpdateFrequency=1
}
