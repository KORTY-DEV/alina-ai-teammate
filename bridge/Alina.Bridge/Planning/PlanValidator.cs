using System.Text.Json;
using Alina.Bridge.Protocol;

namespace Alina.Bridge.Planning;

public sealed class PlanValidator(int maxMineAmount)
{
    public Plan ValidateAndBuild(string requestId, PlannerDecision decision, JsonElement snapshot)
    {
        var reply = string.IsNullOrWhiteSpace(decision.Reply)
            ? "Не смогла сформулировать ответ."
            : decision.Reply.Trim();

        if (reply.Length > 240)
        {
            reply = reply[..240];
        }

        if (string.Equals(decision.Decision, "continue_factory", StringComparison.Ordinal))
        {
            var continueArgs = JsonSerializer.SerializeToElement(new { }, JsonDefaults.Options);
            return new Plan(
                1,
                requestId,
                "continue_factory",
                reply,
                false,
                [new PlanAction("continue-1", "continue_factory", continueArgs)]);
        }

        if (string.Equals(decision.Decision, "repair_power", StringComparison.Ordinal))
        {
            var entity = decision.TargetItem.Trim();
            if (string.IsNullOrWhiteSpace(entity) || !HasFactoryIssue(snapshot, entity, "no_power"))
            {
                return new Plan(1, requestId, "respond_only", "Не вижу подтверждённого потребителя без питания.", false, []);
            }
            var powerArgs = JsonSerializer.SerializeToElement(new RepairPowerArgs(entity), JsonDefaults.Options);
            return new Plan(
                1,
                requestId,
                "repair_power",
                reply,
                false,
                [new PlanAction("power-1", "repair_power", powerArgs)]);
        }

        if (string.Equals(decision.Decision, "resolve_shortage", StringComparison.Ordinal))
        {
            var item = decision.TargetItem.Trim();
            if (string.IsNullOrWhiteSpace(item) || !ItemExists(snapshot, item))
            {
                return new Plan(
                    1,
                    requestId,
                    "respond_only",
                    "Не вижу такого материала в текущем снимке фабрики; ничего не меняю.",
                    false,
                    []);
            }

            var shortageArgs = JsonSerializer.SerializeToElement(new ResolveShortageArgs(item), JsonDefaults.Options);
            return new Plan(
                1,
                requestId,
                "resolve_shortage",
                reply,
                false,
                [new PlanAction("diagnose-1", "resolve_shortage", shortageArgs)]);
        }

        if (!string.Equals(decision.Decision, "mine_resource", StringComparison.Ordinal))
        {
            return new Plan(1, requestId, "respond_only", reply, false, []);
        }

        if (decision.RequiresConfirmation)
        {
            return new Plan(1, requestId, "mine_resource", reply, true, []);
        }

        var resource = decision.Resource.Trim();
        if (string.IsNullOrWhiteSpace(resource) || !ResourceExists(snapshot, resource))
        {
            return new Plan(
                1,
                requestId,
                "respond_only",
                "Рядом не вижу подходящего ресурса; пока ничего не трогаю.",
                false,
                []);
        }

        var amount = Math.Clamp(decision.Amount, 1, maxMineAmount);
        var args = JsonSerializer.SerializeToElement(new MineResourceArgs(resource, amount), JsonDefaults.Options);
        return new Plan(
            1,
            requestId,
            "mine_resource",
            reply,
            false,
            [new PlanAction("mine-1", "mine_resource", args)]);
    }

    private static bool ResourceExists(JsonElement snapshot, string resource)
    {
        if (!snapshot.TryGetProperty("nearby_resources", out var resources) || resources.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        foreach (var item in resources.EnumerateArray())
        {
            if (item.TryGetProperty("name", out var name)
                && string.Equals(name.GetString(), resource, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    private static bool ItemExists(JsonElement snapshot, string item)
    {
        if (snapshot.TryGetProperty("factory", out var factory))
        {
            if (factory.TryGetProperty("item_flows", out var flows) && ContainsName(flows, item))
            {
                return true;
            }

            if (factory.TryGetProperty("active_recipes", out var recipes)
                && recipes.ValueKind == JsonValueKind.Array)
            {
                foreach (var recipe in recipes.EnumerateArray())
                {
                    if (recipe.TryGetProperty("ingredients", out var ingredients) && ContainsItem(ingredients, item))
                    {
                        return true;
                    }
                    if (recipe.TryGetProperty("products", out var products) && ContainsItem(products, item))
                    {
                        return true;
                    }
                }
            }

            if (factory.TryGetProperty("development_candidates", out var development)
                && development.ValueKind == JsonValueKind.Array
                && development.EnumerateArray().Any(candidate =>
                    candidate.TryGetProperty("item", out var candidateItem)
                    && string.Equals(candidateItem.GetString(), item, StringComparison.Ordinal)))
            {
                return true;
            }
        }

        if (snapshot.TryGetProperty("nearby_resources", out var resources)
            && resources.ValueKind == JsonValueKind.Array)
        {
            foreach (var resource in resources.EnumerateArray())
            {
                if (resource.TryGetProperty("products", out var products) && ContainsItem(products, item))
                {
                    return true;
                }
            }
        }
        return false;
    }

    private static bool HasFactoryIssue(JsonElement snapshot, string entity, string expectedStatus)
    {
        if (!snapshot.TryGetProperty("factory", out var factory)
            || !factory.TryGetProperty("issues", out var issues)
            || issues.ValueKind != JsonValueKind.Array)
        {
            return false;
        }
        return issues.EnumerateArray().Any(issue =>
            issue.TryGetProperty("name", out var name)
            && string.Equals(name.GetString(), entity, StringComparison.Ordinal)
            && issue.TryGetProperty("status", out var status)
            && string.Equals(status.GetString(), expectedStatus, StringComparison.Ordinal));
    }

    private static bool ContainsName(JsonElement values, string expected)
    {
        if (values.ValueKind != JsonValueKind.Array) return false;
        return values.EnumerateArray().Any(value =>
            value.TryGetProperty("name", out var name)
            && string.Equals(name.GetString(), expected, StringComparison.Ordinal));
    }

    private static bool ContainsItem(JsonElement values, string expected)
    {
        if (values.ValueKind != JsonValueKind.Array) return false;
        return values.EnumerateArray().Any(value =>
            (!value.TryGetProperty("type", out var type) || string.Equals(type.GetString(), "item", StringComparison.Ordinal))
            && value.TryGetProperty("name", out var name)
            && string.Equals(name.GetString(), expected, StringComparison.Ordinal));
    }
}
