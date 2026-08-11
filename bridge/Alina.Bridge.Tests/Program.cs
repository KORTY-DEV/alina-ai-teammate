using System.Buffers.Binary;
using System.Text.Json;
using Alina.Bridge;
using Alina.Bridge.Factorio;
using Alina.Bridge.Planning;
using Alina.Bridge.Protocol;

var tests = new (string Name, Func<Task> Body)[]
{
    ("RCON packet framing", () => Sync(TestRconPacket)),
    ("Lua long string escaping", () => Sync(TestLuaLongString)),
    ("Grounded mining plan", () => Sync(TestGroundedPlan)),
    ("Unknown resource rejected", () => Sync(TestUnknownResource)),
    ("Mine amount clamped", () => Sync(TestAmountClamped)),
    ("Grounded shortage diagnosis", () => Sync(TestGroundedShortage)),
    ("Unknown shortage item rejected", () => Sync(TestUnknownShortage)),
    ("Intent routing hints", () => Sync(TestIntentRouting)),
    ("Factory development plan", () => Sync(TestFactoryDevelopmentPlan)),
    ("Autonomous payload source", () => Sync(TestAutonomousPayload)),
    ("Autonomous deficit candidates", () => Sync(TestAutonomousDeficits)),
    ("Autonomous development candidates", () => Sync(TestAutonomousDevelopment)),
    ("Grounded power repair", () => Sync(TestPowerRepair)),
    ("Camel-case bridge config", () => Sync(TestCamelCaseConfig)),
    ("New journal first event and partial line", TestNewJournalAndPartialLine)
};

var failed = 0;
foreach (var test in tests)
{
    try
    {
        await test.Body();
        Console.WriteLine($"PASS {test.Name}");
    }
    catch (Exception exception)
    {
        failed++;
        Console.Error.WriteLine($"FAIL {test.Name}: {exception.Message}");
    }
}

Console.WriteLine($"TESTS: {tests.Length - failed} passed, {failed} failed");
return failed == 0 ? 0 : 1;

static void TestRconPacket()
{
    var packet = new RconPacket(7, 2, "тест").Encode();
    Assert(BinaryPrimitives.ReadInt32LittleEndian(packet.AsSpan(0, 4)) == packet.Length - 4, "length");
    Assert(BinaryPrimitives.ReadInt32LittleEndian(packet.AsSpan(4, 4)) == 7, "id");
    Assert(BinaryPrimitives.ReadInt32LittleEndian(packet.AsSpan(8, 4)) == 2, "type");
    Assert(packet[^1] == 0 && packet[^2] == 0, "terminators");
}

static void TestLuaLongString()
{
    var encoded = LuaLongString.Encode("{\"reply\":\"]] и ]=]\"}");
    Assert(encoded.StartsWith("[==[", StringComparison.Ordinal), "delimiter level");
    Assert(encoded.EndsWith("]==]", StringComparison.Ordinal), "terminator");
}

static void TestGroundedPlan()
{
    var snapshot = Snapshot();
    var decision = new PlannerDecision("mine_resource", "iron-ore", "", 25, "Иду за железом.", false);
    var plan = new PlanValidator(100).ValidateAndBuild("r1", decision, snapshot);
    Assert(plan.Actions.Count == 1, "action count");
    Assert(plan.Intent == "mine_resource", "intent");
}

static void TestUnknownResource()
{
    var decision = new PlannerDecision("mine_resource", "invented-ore", "", 25, "Иду.", false);
    var plan = new PlanValidator(100).ValidateAndBuild("r2", decision, Snapshot());
    Assert(plan.Actions.Count == 0, "unknown resource must not execute");
}

static void TestAmountClamped()
{
    var decision = new PlannerDecision("mine_resource", "iron-ore", "", 999, "Иду.", false);
    var plan = new PlanValidator(40).ValidateAndBuild("r3", decision, Snapshot());
    var args = plan.Actions[0].Args.Deserialize<MineResourceArgs>(JsonDefaults.Options);
    Assert(args?.Amount == 40, "amount clamp");
}

static void TestGroundedShortage()
{
    var decision = new PlannerDecision("resolve_shortage", "", "iron-plate", 0, "Проверяю.", false);
    var plan = new PlanValidator(100).ValidateAndBuild("r4", decision, FactorySnapshot());
    Assert(plan.Intent == "resolve_shortage", "shortage intent");
    Assert(plan.Actions.Count == 1 && plan.Actions[0].Type == "resolve_shortage", "shortage action");
    var args = plan.Actions[0].Args.Deserialize<ResolveShortageArgs>(JsonDefaults.Options);
    Assert(args?.Item == "iron-plate", "shortage target");
}

static void TestUnknownShortage()
{
    var decision = new PlannerDecision("resolve_shortage", "", "invented-plate", 0, "Проверяю.", false);
    var plan = new PlanValidator(100).ValidateAndBuild("r5", decision, FactorySnapshot());
    Assert(plan.Actions.Count == 0, "unknown shortage item must not execute");
}

static void TestIntentRouting()
{
    Assert(IntentRouter.Classify("добудь железа") == IntentHint.Mining, "mining hint");
    Assert(IntentRouter.Classify("железа не хватает, разберись") == IntentHint.Shortage, "shortage hint");
    Assert(IntentRouter.Classify("продолжай развивать базу") == IntentHint.FactoryDevelopment, "factory hint");
    Assert(IntentRouter.Classify("помоги с базой") == IntentHint.Ambiguous, "ambiguous hint");
}

static void TestFactoryDevelopmentPlan()
{
    var decision = new PlannerDecision("continue_factory", "", "", 0, "Продолжу развивать базу.", false);
    var plan = new PlanValidator(100).ValidateAndBuild("factory-1", decision, FactorySnapshot());
    Assert(plan.Intent == "continue_factory", "factory intent");
    Assert(plan.Actions.Count == 1 && plan.Actions[0].Type == "continue_factory", "factory action");
}

static void TestAutonomousPayload()
{
    var json = """
    {"request_id":"auto-1","player_index":1,"player_name":"Игрок","message":"","command":"оцени фабрику","snapshot":{},"source":"autonomous"}
    """;
    var request = JsonSerializer.Deserialize<AddressedChatPayload>(json, JsonDefaults.Options);
    Assert(request?.Source == "autonomous", "autonomous source binding");
}

static void TestAutonomousDeficits()
{
    var candidates = AutonomyRouter.FindDeficitItems(FactorySnapshot());
    Assert(candidates.Count == 1 && candidates[0] == "iron-plate", "grounded deficit candidate");

    var balanced = JsonSerializer.SerializeToElement(new
    {
        factory = new
        {
            item_flows = new[] { new { name = "iron-plate", produced_per_minute = 20, consumed_per_minute = 20 } }
        }
    }, JsonDefaults.Options);
    Assert(AutonomyRouter.FindDeficitItems(balanced).Count == 0, "balanced flow must not trigger autonomy");
}


static void TestAutonomousDevelopment()
{
    var snapshot = JsonSerializer.SerializeToElement(new
    {
        factory = new
        {
            item_flows = Array.Empty<object>(),
            active_recipes = Array.Empty<object>(),
            development_candidates = new[]
            {
                new { item = "iron-gear-wheel", recipe = "iron-gear-wheel", score = 200 }
            }
        },
        nearby_resources = Array.Empty<object>()
    }, JsonDefaults.Options);
    var candidates = AutonomyRouter.FindDevelopmentItems(snapshot);
    Assert(candidates.Count == 1 && candidates[0] == "iron-gear-wheel", "development candidate");
    var decision = new PlannerDecision("resolve_shortage", "", "iron-gear-wheel", 0, "Сделаю шестерни.", false);
    var plan = new PlanValidator(100).ValidateAndBuild("dev-1", decision, snapshot);
    Assert(plan.Actions.Count == 1 && plan.Intent == "resolve_shortage", "development plan grounding");
}

static void TestPowerRepair()
{
    var snapshot = JsonSerializer.SerializeToElement(new
    {
        factory = new
        {
            issues = new[] { new { name = "assembling-machine-1", status = "no_power", count = 2 } },
            item_flows = Array.Empty<object>()
        }
    }, JsonDefaults.Options);
    var candidates = AutonomyRouter.FindPowerIssueEntities(snapshot);
    Assert(candidates.Count == 1 && candidates[0] == "assembling-machine-1", "power candidate");
    var decision = new PlannerDecision("repair_power", "", "assembling-machine-1", 0, "Подключу питание.", false);
    var plan = new PlanValidator(100).ValidateAndBuild("power-1", decision, snapshot);
    Assert(plan.Intent == "repair_power" && plan.Actions.Count == 1, "power plan");
}

static void TestCamelCaseConfig()
{
    var directory = Path.Combine(Path.GetTempPath(), "alina-bridge-tests", Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, "config.json");
    try
    {
        File.WriteAllText(path, """
        {
          "ollama": { "baseUrl": "http://127.0.0.1:11434", "model": "test-model", "contextTokens": 4096 },
          "factorio": { "transport": "udp", "udpBridgePort": 45001, "udpFactorioPort": 45002, "eventFile": "events.jsonl", "cursorFile": "cursor.json", "rconPort": 43210, "rconTimeoutSeconds": 7, "pollMilliseconds": 125 },
          "safety": { "maxMineAmount": 17 }
        }
        """);
        var options = Alina.Bridge.Configuration.BridgeOptions.Load(path);
        Assert(options.Ollama.Model == "test-model", "model binding");
        Assert(options.Ollama.ContextTokens == 4096, "context binding");
        Assert(options.Factorio.Transport == "udp", "transport binding");
        Assert(options.Factorio.UdpBridgePort == 45001 && options.Factorio.UdpFactorioPort == 45002, "UDP port binding");
        Assert(options.Factorio.RconPort == 43210, "RCON port binding");
        Assert(options.Factorio.RconTimeoutSeconds == 7, "RCON timeout binding");
        Assert(options.Factorio.PollMilliseconds == 125, "poll binding");
        Assert(options.Safety.MaxMineAmount == 17, "safety binding");
    }
    finally
    {
        Directory.Delete(directory, recursive: true);
    }
}

static async Task TestNewJournalAndPartialLine()
{
    var directory = Path.Combine(Path.GetTempPath(), "alina-tailer-tests", Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(directory);
    var eventFile = Path.Combine(directory, "events.jsonl");
    var options = new Alina.Bridge.Configuration.FactorioOptions
    {
        EventFile = eventFile,
        CursorFile = Path.Combine(directory, "cursor.json"),
        ReplayExistingEvents = false,
        PollMilliseconds = 50
    };
    using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    await using var enumerator = new EventTailer(options).ReadAsync(cancellation.Token).GetAsyncEnumerator();
    try
    {
        var pending = enumerator.MoveNextAsync().AsTask();
        await Task.Delay(100, cancellation.Token);
        var line = "{\"version\":1,\"event_id\":7,\"tick\":42,\"event\":\"addressed_chat\",\"payload\":{}}";
        var split = line.Length / 2;
        await File.WriteAllTextAsync(eventFile, line[..split], cancellation.Token);
        await Task.Delay(100, cancellation.Token);
        Assert(!pending.IsCompleted, "partial JSONL line must wait");
        await File.AppendAllTextAsync(eventFile, line[split..] + "\n", cancellation.Token);
        Assert(await pending.WaitAsync(cancellation.Token), "first event should be yielded");
        Assert(enumerator.Current.EventId == 7, "first event id");
    }
    finally
    {
        cancellation.Cancel();
        Directory.Delete(directory, recursive: true);
    }
}

static Task Sync(Action action)
{
    action();
    return Task.CompletedTask;
}

static JsonElement Snapshot() => JsonSerializer.SerializeToElement(new
{
    nearby_resources = new[] { new { name = "iron-ore", amount = 5000 } }
}, JsonDefaults.Options);

static JsonElement FactorySnapshot() => JsonSerializer.SerializeToElement(new
{
    nearby_resources = Array.Empty<object>(),
    factory = new
    {
        item_flows = new[] { new { name = "iron-plate", produced_per_minute = 10, consumed_per_minute = 20 } },
        active_recipes = new[]
        {
            new
            {
                name = "iron-plate",
                ingredients = new[] { new { type = "item", name = "iron-ore", amount = 1 } },
                products = new[] { new { type = "item", name = "iron-plate", amount = 1 } }
            },
            new
            {
                name = "iron-gear-wheel",
                ingredients = new[] { new { type = "item", name = "iron-plate", amount = 2 } },
                products = new[] { new { type = "item", name = "iron-gear-wheel", amount = 1 } }
            }
        }
    }
}, JsonDefaults.Options);

static void Assert(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}
