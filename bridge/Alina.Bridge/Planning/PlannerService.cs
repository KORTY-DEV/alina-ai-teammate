using System.Text.Json;
using Alina.Bridge.Configuration;
using Alina.Bridge.Ollama;
using Alina.Bridge.Protocol;

namespace Alina.Bridge.Planning;

public sealed class PlannerService(OllamaClient ollama, SafetyOptions safety)
{
    private readonly PlanValidator _validator = new(safety.MaxMineAmount);

    public async Task<Plan> CreatePlanAsync(AddressedChatPayload chat, CancellationToken cancellationToken)
    {
        // Автономный цикл не должен каждые несколько минут грузить GPU на 99%.
        // Кандидаты уже детерминированно рассчитаны Factorio, поэтому выбираем
        // безопасный приоритет без LLM: питание -> реальный дефицит -> no-op.
        if (string.Equals(chat.Source, "autonomous", StringComparison.Ordinal))
        {
            return CreateDeterministicAutonomousPlan(chat);
        }

        try
        {
            var result = await ollama.CreateDecisionAsync(chat, cancellationToken);
            Console.WriteLine(
                $"[ollama] {result.WallTime.TotalSeconds:F2}s, prompt={result.PromptTokens}, " +
                $"generated={result.GeneratedTokens}, load={result.LoadDurationNanoseconds / 1_000_000.0:F0}ms");
            Console.WriteLine(
                $"[ollama] decision={result.Decision.Decision}, resource={result.Decision.Resource}, " +
                $"target_item={result.Decision.TargetItem}, amount={result.Decision.Amount}, " +
                $"confirmation={result.Decision.RequiresConfirmation}");

            var decision = EnsureRussianReply(result.Decision);
            return _validator.ValidateAndBuild(chat.RequestId, decision, chat.Snapshot);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            Console.Error.WriteLine($"[ollama] План не получен: {exception.Message}");
            return new Plan(
                1,
                chat.RequestId,
                "respond_only",
                "Связь с локальной моделью сейчас не сработала; ничего не меняю.",
                false,
                []);
        }
    }

    private static Plan CreateDeterministicAutonomousPlan(AddressedChatPayload chat)
    {
        var power = AutonomyRouter.FindPowerIssueEntities(chat.Snapshot);
        if (power.Count > 0)
        {
            var target = power[0];
            var args = JsonSerializer.SerializeToElement(new RepairPowerArgs(target), JsonDefaults.Options);
            return new Plan(
                1,
                chat.RequestId,
                "repair_power",
                $"Проверю питание {target} и безопасно продолжу существующую электросеть.",
                false,
                [new PlanAction("power-1", "repair_power", args)]);
        }

        var deficits = AutonomyRouter.FindDeficitItems(chat.Snapshot);
        if (deficits.Count > 0)
        {
            var item = deficits[0];
            var args = JsonSerializer.SerializeToElement(new ResolveShortageArgs(item), JsonDefaults.Options);
            return new Plan(
                1,
                chat.RequestId,
                "resolve_shortage",
                $"Проверю дефицит {item} и исправлю его, если это можно сделать без ломки вашей линии.",
                false,
                [new PlanAction("diagnose-1", "resolve_shortage", args)]);
        }

        // До появления безопасного клонирования/расширения автоматических линий
        // не используем development_candidates: старый контур строил одиночные
        // печи и сборщики без постоянной логистики.
        return new Plan(
            1,
            chat.RequestId,
            "respond_only",
            "Сейчас не вижу безопасной проблемы, которую можно исправить без перестройки вашей автоматизации.",
            false,
            []);
    }

    private static PlannerDecision EnsureRussianReply(PlannerDecision decision)
    {
        var reply = decision.Reply?.Trim() ?? string.Empty;
        if (ContainsCyrillic(reply)) return decision;

        var fallback = decision.Decision switch
        {
            "mine_resource" => string.IsNullOrWhiteSpace(decision.Resource)
                ? "Добуду нужный ресурс."
                : $"Добуду {decision.Resource}.",
            "resolve_shortage" => string.IsNullOrWhiteSpace(decision.TargetItem)
                ? "Проверю дефицит и найду безопасное узкое место."
                : $"Проверю нехватку {decision.TargetItem} и исправлю то, что можно без ломки базы.",
            "repair_power" => "Проверю питание и продолжу существующую электросеть.",
            "continue_factory" => "Продолжу улучшать базу и сначала разберусь с реальными проблемами.",
            _ => "Сейчас безопасного действия не вижу; ничего не меняю."
        };
        return decision with { Reply = fallback };
    }

    private static bool ContainsCyrillic(string value) =>
        value.Any(character => character is >= '\u0400' and <= '\u04FF');
}
