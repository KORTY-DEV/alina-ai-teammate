using System.Text.Json;
using Alina.Bridge.Factorio;
using Alina.Bridge.Ollama;
using Alina.Bridge.Planning;
using Alina.Bridge.Protocol;

namespace Alina.Bridge;

public sealed class BridgeWorker(
    IFactorioTransport transport,
    OllamaClient ollama,
    PlannerService planner)
{
    public async Task RunAsync(CancellationToken cancellationToken)
    {
        await ollama.EnsureModelAvailableAsync(cancellationToken);
        Console.WriteLine("[bridge] Ollama и модель доступны. Ожидаю обращения к Алине.");

        using var heartbeatCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var heartbeat = transport.RunHeartbeatAsync(heartbeatCancellation.Token);
        try
        {
            await foreach (var gameEvent in transport.ReadAsync(cancellationToken))
            {
                if (!string.Equals(gameEvent.Event, "addressed_chat", StringComparison.Ordinal)
                    && !string.Equals(gameEvent.Event, "autonomy_requested", StringComparison.Ordinal))
                {
                    continue;
                }

                var chat = gameEvent.Payload.Deserialize<AddressedChatPayload>(JsonDefaults.Options);
                if (chat is null)
                {
                    Console.Error.WriteLine($"[bridge] Событие {gameEvent.EventId} не содержит payload чата.");
                    continue;
                }

                var autonomous = string.Equals(chat.Source, "autonomous", StringComparison.Ordinal);
                Console.WriteLine(autonomous
                    ? "[factorio] Автономная оценка фабрики."
                    : $"[factorio] {chat.PlayerName}: {chat.Command}");
                var plan = await planner.CreatePlanAsync(chat, cancellationToken);
                try
                {
                    await transport.SubmitPlanAsync(plan, cancellationToken);
                    Console.WriteLine($"[bridge] План {plan.RequestId} доставлен: {plan.Intent}.");
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    Console.Error.WriteLine($"[transport] План не доставлен: {exception.Message}");
                }
            }
        }
        finally
        {
            heartbeatCancellation.Cancel();
            try { await heartbeat; } catch (OperationCanceledException) { }
        }
    }
}
