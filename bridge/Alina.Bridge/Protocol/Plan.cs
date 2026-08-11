using System.Text.Json;

namespace Alina.Bridge.Protocol;

public sealed record PlannerDecision(
    string Decision,
    string Resource,
    string TargetItem,
    int Amount,
    string Reply,
    bool RequiresConfirmation);

public sealed record Plan(
    int Version,
    string RequestId,
    string Intent,
    string Reply,
    bool RequiresConfirmation,
    IReadOnlyList<PlanAction> Actions);

public sealed record PlanAction(
    string Id,
    string Type,
    JsonElement Args);

public sealed record MineResourceArgs(string Resource, int Amount);

public sealed record ResolveShortageArgs(string Item);

public sealed record RepairPowerArgs(string Entity);
