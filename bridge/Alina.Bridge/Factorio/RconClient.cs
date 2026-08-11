using System.Net.Sockets;
using System.Text.Json;
using Alina.Bridge.Configuration;
using Alina.Bridge.Protocol;

namespace Alina.Bridge.Factorio;

public sealed class RconClient(FactorioOptions options)
{
    public async Task<string> SubmitPlanAsync(Plan plan, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(options.RconPassword))
        {
            throw new InvalidOperationException(
                "Пароль RCON не задан. Укажите ALINA_RCON_PASSWORD перед запуском bridge.");
        }

        var json = JsonSerializer.Serialize(plan, JsonDefaults.Options);
        var lua = LuaLongString.Encode(json);
        var command = $"/silent-command remote.call(\"alina_ai\", \"submit_plan\", {lua})";
        return await ExecuteAsync(command, cancellationToken);
    }

    public async Task<string> ExecuteAsync(string command, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(options.RconTimeoutSeconds));
        var operationToken = timeout.Token;

        try
        {
            return await ExecuteCoreAsync(command, operationToken);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException($"Factorio RCON не ответила за {options.RconTimeoutSeconds} секунд.");
        }
    }

    private async Task<string> ExecuteCoreAsync(string command, CancellationToken cancellationToken)
    {
        using var client = new TcpClient();
        await client.ConnectAsync(options.RconHost, options.RconPort, cancellationToken);
        await using var stream = client.GetStream();

        await stream.WriteAsync(new RconPacket(1, 3, options.RconPassword).Encode(), cancellationToken);
        var auth = await RconPacket.ReadAsync(stream, cancellationToken);
        if (auth.Type != 2 && auth.Id != -1)
        {
            auth = await RconPacket.ReadAsync(stream, cancellationToken);
        }
        if (auth.Id == -1)
        {
            throw new UnauthorizedAccessException("Factorio отклонила пароль RCON.");
        }
        if (auth.Id != 1)
        {
            throw new InvalidDataException($"Неожиданный id ответа аутентификации RCON: {auth.Id}.");
        }

        await stream.WriteAsync(new RconPacket(2, 2, command).Encode(), cancellationToken);
        var response = await RconPacket.ReadAsync(stream, cancellationToken);
        if (response.Id != 2)
        {
            throw new InvalidDataException($"Неожиданный id RCON-ответа: {response.Id}.");
        }

        return response.Body;
    }
}

public static class LuaLongString
{
    public static string Encode(string value)
    {
        for (var level = 0; level < 16; level++)
        {
            var equals = new string('=', level);
            var terminator = $"]{equals}]";
            if (!value.Contains(terminator, StringComparison.Ordinal))
            {
                return $"[{equals}[{value}]{equals}]";
            }
        }

        throw new InvalidDataException("Не удалось безопасно закодировать JSON для Lua.");
    }
}
