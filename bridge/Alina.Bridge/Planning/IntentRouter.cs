using System.Text.Json;

namespace Alina.Bridge.Planning;

public enum IntentHint
{
    Ambiguous,
    Mining,
    Shortage,
    FactoryDevelopment
}

public static class IntentRouter
{
    private static readonly string[] ShortageMarkers =
    [
        "не хватает",
        "нехват",
        "дефицит",
        "узкое место",
        "бутылочное горлышко",
        "заканчивается",
        "кончилось",
        " слишком мало",
        " мало "
    ];

    private static readonly string[] MiningMarkers =
    [
        "добуд",
        "добывай",
        "накопай",
        "нарой",
        "собери руд",
        "принеси руд"
    ];

    private static readonly string[] FactoryDevelopmentMarkers =
    [
        "продолжай развивать базу",
        "продолжи развивать базу",
        "развивай базу",
        "улучшай базу",
        "улучши базу",
        "продолжай улучшать базу",
        "продолжи улучшать базу",
        "занимайся базой",
        "займись базой",
        "продолжай развитие",
        "разберись с базой"
    ];

    public static IntentHint Classify(string command)
    {
        var normalized = $" {command.Trim().ToLowerInvariant()} ";
        if (FactoryDevelopmentMarkers.Any(normalized.Contains)) return IntentHint.FactoryDevelopment;
        if (ShortageMarkers.Any(normalized.Contains)) return IntentHint.Shortage;
        if (MiningMarkers.Any(normalized.Contains)) return IntentHint.Mining;
        return IntentHint.Ambiguous;
    }
}

public static class AutonomyRouter
{
    private static IReadOnlySet<string> FindLocallyProducedItems(JsonElement snapshot)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        if (!snapshot.TryGetProperty("factory", out var factory)
            || !factory.TryGetProperty("active_recipes", out var recipes)
            || recipes.ValueKind != JsonValueKind.Array)
        {
            return result;
        }

        foreach (var recipe in recipes.EnumerateArray())
        {
            if (!recipe.TryGetProperty("products", out var products)
                || products.ValueKind != JsonValueKind.Array)
            {
                continue;
            }
            foreach (var product in products.EnumerateArray())
            {
                if (product.TryGetProperty("type", out var type)
                    && string.Equals(type.GetString(), "item", StringComparison.Ordinal)
                    && product.TryGetProperty("name", out var name)
                    && !string.IsNullOrWhiteSpace(name.GetString()))
                {
                    result.Add(name.GetString()!);
                }
            }
        }
        return result;
    }

    public static IReadOnlySet<string> FindSuppressedItems(JsonElement snapshot)
    {
        if (!snapshot.TryGetProperty("autonomy_suppressed_items", out var items)
            || items.ValueKind != JsonValueKind.Array)
        {
            return new HashSet<string>(StringComparer.Ordinal);
        }

        return items.EnumerateArray()
            .Select(item => item.GetString())
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Select(item => item!)
            .ToHashSet(StringComparer.Ordinal);
    }

    public static IReadOnlyList<string> FindDeficitItems(JsonElement snapshot)
    {
        if (!snapshot.TryGetProperty("factory", out var factory)
            || !factory.TryGetProperty("item_flows", out var flows)
            || flows.ValueKind != JsonValueKind.Array)
        {
            return [];
        }

        var candidates = new List<(string Name, double Deficit)>();
        foreach (var flow in flows.EnumerateArray())
        {
            if (!flow.TryGetProperty("name", out var nameValue)
                || string.IsNullOrWhiteSpace(nameValue.GetString()))
            {
                continue;
            }

            var produced = ReadNumber(flow, "produced_per_minute");
            var consumed = ReadNumber(flow, "consumed_per_minute");
            if (consumed > produced * 1.05 && consumed - produced > 0.001)
            {
                candidates.Add((nameValue.GetString()!, consumed - produced));
            }
        }

        var suppressed = FindSuppressedItems(snapshot);
        var locallyProduced = FindLocallyProducedItems(snapshot);
        return candidates
            // Пока нет безопасного расширителя автоматических линий, автономия
            // обслуживает только то, что уже реально производится рядом. Это
            // исключает случайные модовые intermediate items без существующей линии.
            .Where(candidate => locallyProduced.Contains(candidate.Name))
            .Where(candidate => !suppressed.Contains(candidate.Name))
            .OrderByDescending(candidate => candidate.Deficit)
            .ThenBy(candidate => candidate.Name, StringComparer.Ordinal)
            .Take(8)
            .Select(candidate => candidate.Name)
            .ToArray();
    }

    public static IReadOnlyList<string> FindPowerIssueEntities(JsonElement snapshot)
    {
        if (!snapshot.TryGetProperty("factory", out var factory)
            || !factory.TryGetProperty("issues", out var issues)
            || issues.ValueKind != JsonValueKind.Array)
        {
            return [];
        }

        return issues.EnumerateArray()
            .Where(issue => issue.TryGetProperty("status", out var status)
                && string.Equals(status.GetString(), "no_power", StringComparison.Ordinal)
                && issue.TryGetProperty("count", out var count)
                && count.TryGetInt32(out var value) && value > 0)
            .Select(issue => new
            {
                Name = issue.TryGetProperty("name", out var name) ? name.GetString() : null,
                Count = issue.GetProperty("count").GetInt32()
            })
            .Where(issue => !string.IsNullOrWhiteSpace(issue.Name))
            .GroupBy(issue => issue.Name!, StringComparer.Ordinal)
            .Select(group => new { Name = group.Key, Count = group.Sum(issue => issue.Count) })
            .OrderByDescending(issue => issue.Count)
            .ThenBy(issue => issue.Name, StringComparer.Ordinal)
            .Take(8)
            .Select(issue => issue.Name)
            .ToArray();
    }


    public static IReadOnlyList<string> FindDevelopmentItems(JsonElement snapshot)
    {
        if (!snapshot.TryGetProperty("factory", out var factory)
            || !factory.TryGetProperty("development_candidates", out var candidates)
            || candidates.ValueKind != JsonValueKind.Array)
        {
            return [];
        }

        return candidates.EnumerateArray()
            .Select(candidate => new
            {
                Item = candidate.TryGetProperty("item", out var item) ? item.GetString() : null,
                Score = candidate.TryGetProperty("score", out var score) && score.TryGetDouble(out var value) ? value : 0
            })
            .Where(candidate => !string.IsNullOrWhiteSpace(candidate.Item))
            .OrderByDescending(candidate => candidate.Score)
            .ThenBy(candidate => candidate.Item, StringComparer.Ordinal)
            .Take(8)
            .Select(candidate => candidate.Item!)
            .ToArray();
    }

    private static double ReadNumber(JsonElement parent, string property) =>
        parent.TryGetProperty(property, out var value) && value.TryGetDouble(out var number) ? number : 0;
}
