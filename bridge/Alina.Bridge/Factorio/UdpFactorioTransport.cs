using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Alina.Bridge.Configuration;
using Alina.Bridge.Protocol;

namespace Alina.Bridge.Factorio;

public sealed class UdpFactorioTransport : IFactorioTransport
{
    private const int MaxDatagramBytes = 60 * 1024;
    private readonly FactorioOptions _options;
    private readonly UdpClient _socket;
    private readonly IPEndPoint _factorioEndpoint;

    public UdpFactorioTransport(FactorioOptions options)
    {
        _options = options;
        // One loopback-bound socket is used in both directions so Factorio can
        // verify event.source_port and reject packets from unrelated local apps.
        _socket = new UdpClient(new IPEndPoint(IPAddress.Loopback, options.UdpBridgePort));
        _factorioEndpoint = new IPEndPoint(IPAddress.Loopback, options.UdpFactorioPort);
    }

    public async IAsyncEnumerable<GameEvent> ReadAsync(
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            UdpReceiveResult packet;
            try
            {
                packet = await _socket.ReceiveAsync(cancellationToken);
            }
            catch (OperationCanceledException)
            {
                yield break;
            }
            catch (SocketException exception) when (!cancellationToken.IsCancellationRequested)
            {
                Console.Error.WriteLine($"[udp] Ошибка приёма: {exception.Message}");
                await Task.Delay(250, cancellationToken);
                continue;
            }

            if (!IPAddress.IsLoopback(packet.RemoteEndPoint.Address))
            {
                continue;
            }
            if (packet.Buffer.Length == 0 || packet.Buffer.Length > MaxDatagramBytes)
            {
                Console.Error.WriteLine($"[udp] Пропущен пакет недопустимого размера: {packet.Buffer.Length} байт.");
                continue;
            }

            GameEvent? gameEvent;
            try
            {
                gameEvent = JsonSerializer.Deserialize<GameEvent>(packet.Buffer, JsonDefaults.Options);
            }
            catch (JsonException exception)
            {
                Console.Error.WriteLine($"[udp] Пропущен повреждённый пакет события: {exception.Message}");
                continue;
            }

            if (gameEvent is not null && gameEvent.Version == 1)
            {
                yield return gameEvent;
            }
        }
    }

    public async Task SubmitPlanAsync(Plan plan, CancellationToken cancellationToken)
    {
        var packet = JsonSerializer.SerializeToUtf8Bytes(new
        {
            version = 1,
            kind = "plan",
            plan
        }, JsonDefaults.Options);
        if (packet.Length > MaxDatagramBytes)
        {
            throw new InvalidDataException($"План слишком велик для локального UDP: {packet.Length} байт.");
        }

        // Localhost UDP is normally reliable in practice. Three tiny identical datagrams
        // make the playable path resilient to a packet being dropped while Factorio is
        // entering/leaving a save pause. Factorio rejects duplicates by request_id.
        for (var attempt = 0; attempt < 3; attempt++)
        {
            await _socket.SendAsync(packet, _factorioEndpoint, cancellationToken);
            if (attempt < 2)
            {
                await Task.Delay(80, cancellationToken);
            }
        }
    }

    public async Task RunHeartbeatAsync(CancellationToken cancellationToken)
    {
        var packet = JsonSerializer.SerializeToUtf8Bytes(new
        {
            version = 1,
            kind = "heartbeat",
            status = "connected"
        }, JsonDefaults.Options);

        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await _socket.SendAsync(packet, _factorioEndpoint, cancellationToken);
                await Task.Delay(_options.UdpHeartbeatMilliseconds, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (SocketException exception) when (!cancellationToken.IsCancellationRequested)
            {
                Console.Error.WriteLine($"[udp] Heartbeat не отправлен: {exception.Message}");
                await Task.Delay(1000, cancellationToken);
            }
        }
    }

    public ValueTask DisposeAsync()
    {
        _socket.Dispose();
        return ValueTask.CompletedTask;
    }
}
