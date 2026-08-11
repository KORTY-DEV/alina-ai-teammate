using System.Text;
using Alina.Bridge.Configuration;
using Alina.Bridge.Factorio;
using Alina.Bridge.Ollama;
using Alina.Bridge.Planning;

namespace Alina.Bridge;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        var selfTest = args.Contains("--self-test", StringComparer.Ordinal);
        var planEvent = ReadArgument(args, "--plan-event");
        var rconSmoke = args.Contains("--rcon-smoke", StringComparer.Ordinal);
        var rconCommand = ReadArgument(args, "--rcon-command");
        var configPath = ReadArgument(args, "--config")
            ?? (selfTest || planEvent is not null || rconSmoke || rconCommand is not null
                ? "bridge/appsettings.example.json"
                : "bridge/appsettings.local.json");

        try
        {
            var options = BridgeOptions.Load(Path.GetFullPath(configPath));
            using var cancellation = new CancellationTokenSource();
            Console.CancelKeyPress += (_, eventArgs) =>
            {
                eventArgs.Cancel = true;
                cancellation.Cancel();
            };

            if (selfTest)
            {
                return await SelfTest.RunAsync(options, cancellation.Token);
            }

            if (planEvent is not null)
            {
                return await SelfTest.RunEventAsync(options, Path.GetFullPath(planEvent), cancellation.Token);
            }

            if (rconSmoke)
            {
                var smokeRcon = new RconClient(options.Factorio);
                var response = await smokeRcon.ExecuteAsync(
                    "/silent-command rcon.print(helpers.table_to_json(remote.call(\"alina_ai\", \"status\")))",
                    cancellation.Token);
                Console.WriteLine(response);
                return response.Contains("schema_version", StringComparison.Ordinal) ? 0 : 3;
            }

            if (rconCommand is not null)
            {
                var commandRcon = new RconClient(options.Factorio);
                Console.WriteLine(await commandRcon.ExecuteAsync(rconCommand, cancellation.Token));
                return 0;
            }

            using var ollama = new OllamaClient(options.Ollama);
            var planner = new PlannerService(ollama, options.Safety);
            await using IFactorioTransport transport = string.Equals(
                options.Factorio.Transport, "udp", StringComparison.OrdinalIgnoreCase)
                ? new UdpFactorioTransport(options.Factorio)
                : new FileRconTransport(new EventTailer(options.Factorio), new RconClient(options.Factorio));
            Console.WriteLine($"[bridge] Transport: {options.Factorio.Transport}.");
            var worker = new BridgeWorker(transport, ollama, planner);
            await worker.RunAsync(cancellation.Token);
            return 0;
        }
        catch (OperationCanceledException)
        {
            Console.WriteLine("[bridge] Остановлен.");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"[bridge] Ошибка: {exception.Message}");
            return 1;
        }
    }

    private static string? ReadArgument(string[] args, string name)
    {
        for (var index = 0; index < args.Length - 1; index++)
        {
            if (string.Equals(args[index], name, StringComparison.Ordinal))
            {
                return args[index + 1];
            }
        }

        return null;
    }
}
