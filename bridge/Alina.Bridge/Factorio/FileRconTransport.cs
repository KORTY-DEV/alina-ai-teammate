using Alina.Bridge.Protocol;

namespace Alina.Bridge.Factorio;

public sealed class FileRconTransport(EventTailer tailer, RconClient rcon) : IFactorioTransport
{
    public IAsyncEnumerable<GameEvent> ReadAsync(CancellationToken cancellationToken) => tailer.ReadAsync(cancellationToken);

    public async Task SubmitPlanAsync(Plan plan, CancellationToken cancellationToken)
    {
        await rcon.SubmitPlanAsync(plan, cancellationToken);
    }

    public Task RunHeartbeatAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
