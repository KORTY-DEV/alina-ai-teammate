using System.Diagnostics;
using System.Net.Http.Json;
using System.Text.Json;
using Alina.Bridge.Configuration;
using Alina.Bridge.Planning;
using Alina.Bridge.Protocol;

namespace Alina.Bridge.Ollama;

public sealed record OllamaPlanResult(
    PlannerDecision Decision,
    TimeSpan WallTime,
    long TotalDurationNanoseconds,
    long LoadDurationNanoseconds,
    int PromptTokens,
    int GeneratedTokens);

public sealed class OllamaClient : IDisposable
{
    private static JsonElement BuildDecisionSchema(IReadOnlyList<string> decisions) =>
        JsonSerializer.SerializeToElement(new
    {
        type = "object",
        additionalProperties = false,
        properties = new
        {
            decision = new { type = "string", @enum = decisions },
            resource = new { type = "string" },
            target_item = new { type = "string" },
            amount = new { type = "integer", minimum = 0, maximum = 1000 },
            reply = new { type = "string", maxLength = 240 },
            requires_confirmation = new { type = "boolean" }
        },
        required = new[] { "decision", "resource", "target_item", "amount", "reply", "requires_confirmation" }
    }, JsonDefaults.Options);

    private const string SystemPrompt = """
Ты Алина, локальный AI-тиммейт в Factorio. Отвечай кратко и естественно по-русски.
Сейчас разрешены пять решений: mine_resource, resolve_shortage, repair_power, continue_factory и respond_only.
Для mine_resource выбери resource только из snapshot.nearby_resources[].name. Не выдумывай прототипы.
Пользователь говорит обычными словами и может назвать материал или результат, а не техническое имя залежи.
Сопоставляй смысл команды с name и products ближайших ресурсов. Если это явная просьба добыть и есть
семантически подходящий ресурс, обязательно выбери mine_resource; не спорь о словах «руда», «минерал» и «ресурс».
Пример: команда «добудь железа» при доступных iron-ore и copper-ore означает mine_resource для iron-ore.
Не проси уточнить материал, если такое смысловое соответствие однозначно среди переданных кандидатов.
Количество должно быть небольшим и соответствовать просьбе; если число не названо, выбери 25.
Обычная добыча не требует подтверждения. Опасные, разрушительные или неподдержанные просьбы не выполняй: respond_only.
Если игрок сообщает о нехватке материала и просит разобраться, выбери resolve_shortage. target_item бери только
из snapshot.factory.item_flows[].name, ingredients/products активных рецептов или products ближайших ресурсов.
«Железа не хватает» в контексте фабрики обычно означает iron-plate, если он присутствует в фабричном снимке;
не подменяй диагностику простой добычей руды. resolve_shortage безопасно диагностирует и может пополнить либо
построить один локальный производитель; подтверждение для этого первого контура не требуется.
Если игрок просит «продолжай развивать базу» или равнозначно поручает самостоятельно заниматься существующей
фабрикой, выбери continue_factory. Это включает редкий автономный анализ; не подменяй его разовой добычей.
Для автономного repair_power выбери target_item только из autonomous_power_candidates. Это безопасное продолжение
существующей электрической сети к уже поставленным потребителям; resource оставь пустым, amount равным 0.
Если source равен autonomous, игрок не отдавал команду. Сначала исправляй подтверждённое отсутствие питания, затем
доказанный дефицит, где consumed_per_minute заметно выше produced_per_minute. Если таких проблем нет, но передан
autonomous_development_candidates, можно выбрать resolve_shortage ровно для одного предмета из этого списка: это
grounded-фронтир следующего простого производства, который уже вычислен по открытым рецептам и реально доступным
ингредиентам. Не выбирай автономную добычу и не выдумывай цели вне переданных списков. Если все списки пусты,
верни respond_only; такой ответ не будет показан игроку.
Для mine_resource оставь target_item пустым; для resolve_shortage оставь resource пустым и amount равным 0.
Верни только объект по заданной JSON Schema. Не используй vision и не создавай скрытых действий.
""";

    private readonly HttpClient _http;
    private readonly OllamaOptions _options;

    public OllamaClient(OllamaOptions options)
    {
        _options = options;
        _http = new HttpClient
        {
            BaseAddress = new Uri(options.BaseUrl.TrimEnd('/') + "/"),
            Timeout = TimeSpan.FromSeconds(options.TimeoutSeconds)
        };
    }

    public async Task EnsureModelAvailableAsync(CancellationToken cancellationToken)
    {
        using var response = await _http.GetAsync("api/tags", cancellationToken);
        response.EnsureSuccessStatusCode();
        using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken));

        var found = document.RootElement.GetProperty("models")
            .EnumerateArray()
            .Any(model => model.TryGetProperty("name", out var name)
                && string.Equals(name.GetString(), _options.Model, StringComparison.Ordinal));

        if (!found)
        {
            throw new InvalidOperationException($"Модель Ollama '{_options.Model}' не установлена.");
        }
    }

    public async Task<OllamaPlanResult> CreateDecisionAsync(
        AddressedChatPayload chat,
        CancellationToken cancellationToken)
    {
        var autonomous = string.Equals(chat.Source, "autonomous", StringComparison.Ordinal);
        var autonomousTargets = autonomous ? AutonomyRouter.FindDeficitItems(chat.Snapshot) : [];
        var autonomousPowerTargets = autonomous ? AutonomyRouter.FindPowerIssueEntities(chat.Snapshot) : [];
        var autonomousDevelopmentTargets = autonomous ? AutonomyRouter.FindDevelopmentItems(chat.Snapshot) : [];
        var hint = autonomous ? IntentHint.Ambiguous : IntentRouter.Classify(chat.Command);
        var allowedDecisions = autonomous
            ? autonomousPowerTargets.Count > 0
                ? new[] { "repair_power" }
                : autonomousTargets.Count > 0 || autonomousDevelopmentTargets.Count > 0
                    ? new[] { "resolve_shortage" }
                    : new[] { "respond_only" }
            : hint switch
        {
            IntentHint.Mining => new[] { "mine_resource", "respond_only" },
            IntentHint.Shortage => new[] { "resolve_shortage", "respond_only" },
            IntentHint.FactoryDevelopment => new[] { "continue_factory", "respond_only" },
            _ => new[] { "mine_resource", "resolve_shortage", "continue_factory", "respond_only" }
        };
        var decisionSchema = BuildDecisionSchema(allowedDecisions);
        var hintInstruction = autonomous
            ? autonomousTargets.Count > 0 || autonomousPowerTargets.Count > 0 || autonomousDevelopmentTargets.Count > 0
                ? "\nЭто автономная оценка. Кандидаты дефицита предметов: "
                  + string.Join(", ", autonomousTargets)
                  + ". Кандидаты потребителей без питания: "
                  + string.Join(", ", autonomousPowerTargets)
                  + ". Кандидаты безопасного следующего производства: "
                  + string.Join(", ", autonomousDevelopmentTargets)
                  + ". Приоритет: питание, реальный дефицит, затем развитие. Выбери одну задачу и target_item только из соответствующего списка."
                : "\nЭто автономная оценка без поддерживаемой безопасной цели: верни respond_only."
            : hint switch
        {
            IntentHint.Mining => "\nЭта команда явно про добычу: выбирай только mine_resource или respond_only.",
            IntentHint.Shortage => "\nЭта команда явно сообщает о дефиците: выбирай только resolve_shortage или respond_only.",
            IntentHint.FactoryDevelopment => "\nИгрок поручает развитие существующей базы: выбирай continue_factory.",
            _ => ""
        };
        var groundedInput = JsonSerializer.Serialize(new
        {
            command = chat.Command,
            player = chat.PlayerName,
            source = chat.Source ?? "direct_player",
            autonomous_deficit_candidates = autonomousTargets,
            autonomous_power_candidates = autonomousPowerTargets,
            autonomous_development_candidates = autonomousDevelopmentTargets,
            snapshot = chat.Snapshot,
            output_schema = decisionSchema
        }, JsonDefaults.Options);

        var messages = new List<object>
        {
            new { role = "system", content = SystemPrompt + hintInstruction }
        };
        if (hint is not IntentHint.Shortage)
        {
            messages.Add(new
            {
                role = "user",
                content = "{\"command\":\"добудь железа\",\"available_resources\":[{\"name\":\"iron-ore\",\"products\":[{\"name\":\"iron-ore\"}]},{\"name\":\"copper-ore\",\"products\":[{\"name\":\"copper-ore\"}]}]}"
            });
            messages.Add(new
            {
                role = "assistant",
                content = "{\"decision\":\"mine_resource\",\"resource\":\"iron-ore\",\"target_item\":\"\",\"amount\":25,\"reply\":\"Добуду железную руду.\",\"requires_confirmation\":false}"
            });
        }
        if (hint is not IntentHint.Mining)
        {
            messages.Add(new
            {
                role = "user",
                content = "{\"command\":\"железа не хватает, разберись\",\"factory\":{\"item_flows\":[{\"name\":\"iron-plate\"}],\"active_recipes\":[{\"name\":\"iron-gear-wheel\",\"ingredients\":[{\"type\":\"item\",\"name\":\"iron-plate\"}]}]}}"
            });
            messages.Add(new
            {
                role = "assistant",
                content = "{\"decision\":\"resolve_shortage\",\"resource\":\"\",\"target_item\":\"iron-plate\",\"amount\":0,\"reply\":\"Проверю производство железных плит и найду узкое место.\",\"requires_confirmation\":false}"
            });
        }
        messages.Add(new { role = "user", content = groundedInput });

        var request = new
        {
            model = _options.Model,
            stream = false,
            think = false,
            keep_alive = _options.KeepAlive,
            format = decisionSchema,
            messages,
            options = new
            {
                num_ctx = _options.ContextTokens,
                temperature = 0.0,
                seed = 42,
                num_predict = 160
            }
        };

        var stopwatch = Stopwatch.StartNew();
        using var response = await _http.PostAsJsonAsync("api/chat", request, JsonDefaults.Options, cancellationToken);
        var responseText = await response.Content.ReadAsStringAsync(cancellationToken);
        stopwatch.Stop();

        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"Ollama вернула HTTP {(int)response.StatusCode}: {responseText}");
        }

        using var envelope = JsonDocument.Parse(responseText);
        var root = envelope.RootElement;
        var content = root.GetProperty("message").GetProperty("content").GetString()
            ?? throw new InvalidDataException("Ollama вернула пустой content.");
        var decision = JsonSerializer.Deserialize<PlannerDecision>(content, JsonDefaults.Options)
            ?? throw new InvalidDataException("Ollama вернула пустое решение.");

        return new OllamaPlanResult(
            decision,
            stopwatch.Elapsed,
            ReadInt64(root, "total_duration"),
            ReadInt64(root, "load_duration"),
            ReadInt32(root, "prompt_eval_count"),
            ReadInt32(root, "eval_count"));
    }

    private static long ReadInt64(JsonElement root, string property) =>
        root.TryGetProperty(property, out var value) && value.TryGetInt64(out var number) ? number : 0;

    private static int ReadInt32(JsonElement root, string property) =>
        root.TryGetProperty(property, out var value) && value.TryGetInt32(out var number) ? number : 0;

    public void Dispose() => _http.Dispose();
}
