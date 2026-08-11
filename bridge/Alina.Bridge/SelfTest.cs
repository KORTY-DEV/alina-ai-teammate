using System.Text.Json;
using Alina.Bridge.Configuration;
using Alina.Bridge.Ollama;
using Alina.Bridge.Planning;
using Alina.Bridge.Protocol;

namespace Alina.Bridge;

public static class SelfTest
{
    public static async Task<int> RunAsync(BridgeOptions options, CancellationToken cancellationToken)
    {
        using var ollama = new OllamaClient(options.Ollama);
        await ollama.EnsureModelAvailableAsync(cancellationToken);

        var snapshot = JsonSerializer.SerializeToElement(new
        {
            schema_version = 1,
            surface = "nauvis",
            player_position = new { x = 0.0, y = 0.0 },
            alina = new
            {
                present = true,
                surface = "nauvis",
                position = new { x = 2.0, y = 1.0 },
                empty_inventory_slots = 80
            },
            nearby_resources = new[]
            {
                new
                {
                    name = "iron-ore", amount = 12000, entities = 48, nearest_distance = 14.2,
                    resource_category = "basic-solid",
                    products = new[] { new { type = "item", name = "iron-ore", amount = 1 } }
                },
                new
                {
                    name = "copper-ore", amount = 8000, entities = 35, nearest_distance = 19.8,
                    resource_category = "basic-solid",
                    products = new[] { new { type = "item", name = "copper-ore", amount = 1 } }
                }
            },
            resources_truncated = true,
            sensor_radius = 64,
            paused = false
        }, JsonDefaults.Options);
        var chat = new AddressedChatPayload(
            "self-test-1",
            1,
            "Игрок",
            "Аля, добудь железа",
            "добудь железа",
            snapshot);

        var result = await ollama.CreateDecisionAsync(chat, cancellationToken);
        var plan = new PlanValidator(options.Safety.MaxMineAmount)
            .ValidateAndBuild(chat.RequestId, result.Decision, snapshot);

        Console.WriteLine(JsonSerializer.Serialize(plan, new JsonSerializerOptions(JsonDefaults.Options) { WriteIndented = true }));
        Console.WriteLine(
            $"SELF-TEST OK: wall={result.WallTime.TotalSeconds:F2}s, " +
            $"load={result.LoadDurationNanoseconds / 1_000_000.0:F0}ms, " +
            $"prompt={result.PromptTokens}, generated={result.GeneratedTokens}");
        return plan.Actions.Count == 1 && plan.Actions[0].Type == "mine_resource" ? 0 : 2;
    }

    public static async Task<int> RunEventAsync(
        BridgeOptions options,
        string eventFile,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(eventFile))
        {
            throw new FileNotFoundException("Журнал событий для проверки не найден.", eventFile);
        }

        AddressedChatPayload? chat = null;
        foreach (var line in File.ReadLines(eventFile))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            var gameEvent = JsonSerializer.Deserialize<GameEvent>(line, JsonDefaults.Options);
            if (gameEvent is not null && string.Equals(gameEvent.Event, "addressed_chat", StringComparison.Ordinal))
            {
                chat = gameEvent.Payload.Deserialize<AddressedChatPayload>(JsonDefaults.Options);
            }
        }
        if (chat is null)
        {
            throw new InvalidDataException("В журнале нет события addressed_chat.");
        }

        using var ollama = new OllamaClient(options.Ollama);
        await ollama.EnsureModelAvailableAsync(cancellationToken);
        var result = await ollama.CreateDecisionAsync(chat, cancellationToken);
        var plan = new PlanValidator(options.Safety.MaxMineAmount)
            .ValidateAndBuild(chat.RequestId, result.Decision, chat.Snapshot);

        Console.WriteLine(JsonSerializer.Serialize(new
        {
            result.Decision,
            Plan = plan,
            WallSeconds = result.WallTime.TotalSeconds,
            LoadMilliseconds = result.LoadDurationNanoseconds / 1_000_000.0,
            result.PromptTokens,
            result.GeneratedTokens
        }, new JsonSerializerOptions(JsonDefaults.Options) { WriteIndented = true }));
        return plan.Actions.Count == 1 && plan.Actions[0].Type == "mine_resource" ? 0 : 2;
    }
}
