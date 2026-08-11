using System.Text.Json;

namespace Alina.Bridge.Configuration;

public sealed class BridgeOptions
{
    private static readonly JsonSerializerOptions ConfigJsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };

    public OllamaOptions Ollama { get; init; } = new();
    public FactorioOptions Factorio { get; init; } = new();
    public SafetyOptions Safety { get; init; } = new();

    public static BridgeOptions Load(string path)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Файл конфигурации не найден: {path}", path);
        }

        var json = File.ReadAllText(path);
        var options = JsonSerializer.Deserialize<BridgeOptions>(json, ConfigJsonOptions)
            ?? throw new InvalidDataException("Конфигурация bridge пуста или имеет неверный формат.");

        options.Factorio.EventFile = Environment.ExpandEnvironmentVariables(options.Factorio.EventFile);
        var password = Environment.GetEnvironmentVariable("ALINA_RCON_PASSWORD");
        if (!string.IsNullOrWhiteSpace(password))
        {
            options.Factorio.RconPassword = password;
        }

        options.Validate();
        return options;
    }

    public void Validate()
    {
        if (!Uri.TryCreate(Ollama.BaseUrl, UriKind.Absolute, out var uri) || !uri.IsLoopback)
        {
            throw new InvalidDataException("Ollama baseUrl должен быть локальным абсолютным URL.");
        }

        if (string.IsNullOrWhiteSpace(Ollama.Model))
        {
            throw new InvalidDataException("Не задана модель Ollama.");
        }

        if (Ollama.ContextTokens is < 2048 or > 32768)
        {
            throw new InvalidDataException("contextTokens должен быть в диапазоне 2048..32768.");
        }

        if (!string.Equals(Factorio.Transport, "udp", StringComparison.OrdinalIgnoreCase)
            && !string.Equals(Factorio.Transport, "file-rcon", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("factorio.transport должен быть 'udp' или 'file-rcon'.");
        }

        if (Factorio.RconPort is < 1 or > 65535)
        {
            throw new InvalidDataException("Некорректный порт RCON.");
        }

        if (Factorio.UdpBridgePort is < 1 or > 65535 || Factorio.UdpFactorioPort is < 1 or > 65535
            || Factorio.UdpBridgePort == Factorio.UdpFactorioPort)
        {
            throw new InvalidDataException("Некорректные UDP-порты Factorio/bridge.");
        }

        if (Factorio.UdpHeartbeatMilliseconds is < 250 or > 10000)
        {
            throw new InvalidDataException("udpHeartbeatMilliseconds должен быть в диапазоне 250..10000.");
        }

        if (Factorio.PollMilliseconds is < 50 or > 5000)
        {
            throw new InvalidDataException("pollMilliseconds должен быть в диапазоне 50..5000.");
        }

        if (Factorio.RconTimeoutSeconds is < 1 or > 60)
        {
            throw new InvalidDataException("rconTimeoutSeconds должен быть в диапазоне 1..60.");
        }

        if (Safety.MaxMineAmount is < 1 or > 1000)
        {
            throw new InvalidDataException("maxMineAmount должен быть в диапазоне 1..1000.");
        }
    }
}

public sealed class OllamaOptions
{
    public string BaseUrl { get; init; } = "http://127.0.0.1:11434";
    public string Model { get; init; } = "qwen3.5:4b";
    public int ContextTokens { get; init; } = 8192;
    public string KeepAlive { get; init; } = "0";
    public int TimeoutSeconds { get; init; } = 60;
}

public sealed class FactorioOptions
{
    // "udp" is the preferred single-process playable transport.
    // "file-rcon" is kept for the isolated legacy E2E harness.
    public string Transport { get; init; } = "file-rcon";
    public int UdpBridgePort { get; init; } = 34198;
    public int UdpFactorioPort { get; init; } = 34199;
    public int UdpHeartbeatMilliseconds { get; init; } = 1000;
    public string EventFile { get; set; } = "%APPDATA%\\Factorio\\script-output\\alina\\events.jsonl";
    public string CursorFile { get; init; } = "bridge\\state\\cursor.json";
    public string RconHost { get; init; } = "127.0.0.1";
    public int RconPort { get; init; } = 34198;
    public string RconPassword { get; set; } = string.Empty;
    public int RconTimeoutSeconds { get; init; } = 10;
    public bool ReplayExistingEvents { get; init; }
    public int PollMilliseconds { get; init; } = 250;
}

public sealed class SafetyOptions
{
    public int MaxMineAmount { get; init; } = 100;
}
