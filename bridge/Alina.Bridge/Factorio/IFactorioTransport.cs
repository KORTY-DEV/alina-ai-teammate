using Alina.Bridge.Protocol;

namespace Alina.Bridge.Factorio;

public interface IFactorioTransport : IAsyncDisposable
{
    IAsyncEnumerable<GameEvent> ReadAsync(CancellationToken cancellationToken);
    Task SubmitPlanAsync(Plan plan, CancellationToken cancellationToken);
    Task RunHeartbeatAsync(CancellationToken cancellationToken);
}
