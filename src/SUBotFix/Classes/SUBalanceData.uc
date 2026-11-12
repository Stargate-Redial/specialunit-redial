// Learned win balance scores (fix 36), kept apart from MutSUBotFix's own settings: saving the
// mutator's config would write every SUBotFix setting into the server ini, and later releases could
// no longer change their defaults there.
class SUBalanceData extends Object
    config(SUBotFixBalance);

var config array<string> Scores;       // "SU-Chulak=-2": Goa'uld wins minus Tau'ri wins, recent rounds
