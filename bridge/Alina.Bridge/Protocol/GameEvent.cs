using System.Text.Json;

namespace Alina.Bridge.Protocol;

public sealed record GameEvent(
    int Version,
    long EventId,
    long Tick,
    string Event,
    JsonElement Payload);

public sealed record NearbyResource(string Name, long Amount, int Entities, double NearestDistance);

public sealed record AddressedChatPayload(
    string RequestId,
    int PlayerIndex,
    string PlayerName,
    string Message,
    string Command,
    JsonElement Snapshot,
    string? Source = null);
