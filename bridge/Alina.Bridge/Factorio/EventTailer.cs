using System.Text;
using System.Text.Json;
using Alina.Bridge.Configuration;
using Alina.Bridge.Protocol;

namespace Alina.Bridge.Factorio;

public sealed class EventTailer(FactorioOptions options)
{
    private long _offset = -1;

    public async IAsyncEnumerable<GameEvent> ReadAsync(
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        LoadCursor();
        if (_offset < 0 && !File.Exists(options.EventFile))
        {
            // The bridge started before Factorio created this session's journal.
            // Its first bytes are new and must not be mistaken for old history.
            _offset = 0;
        }

        while (!cancellationToken.IsCancellationRequested)
        {
            if (!File.Exists(options.EventFile))
            {
                await Task.Delay(options.PollMilliseconds, cancellationToken);
                continue;
            }

            List<string> lines;
            try
            {
                lines = ReadNewLines();
            }
            catch (IOException)
            {
                await Task.Delay(options.PollMilliseconds, cancellationToken);
                continue;
            }

            foreach (var line in lines)
            {
                GameEvent? gameEvent;
                try
                {
                    gameEvent = JsonSerializer.Deserialize<GameEvent>(line, JsonDefaults.Options);
                }
                catch (JsonException exception)
                {
                    Console.Error.WriteLine($"[bridge] Пропущена повреждённая строка события: {exception.Message}");
                    continue;
                }

                if (gameEvent is not null && gameEvent.Version == 1)
                {
                    yield return gameEvent;
                }
            }

            await Task.Delay(options.PollMilliseconds, cancellationToken);
        }
    }

    private List<string> ReadNewLines()
    {
        using var stream = new FileStream(
            options.EventFile,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete);

        if (_offset < 0)
        {
            _offset = options.ReplayExistingEvents ? 0 : stream.Length;
        }
        else if (_offset > stream.Length)
        {
            _offset = 0;
        }

        stream.Seek(_offset, SeekOrigin.Begin);
        var remaining = checked((int)(stream.Length - _offset));
        if (remaining == 0)
        {
            return [];
        }

        var bytes = new byte[remaining];
        stream.ReadExactly(bytes);
        var lastNewline = Array.LastIndexOf(bytes, (byte)'\n');
        if (lastNewline < 0)
        {
            return [];
        }

        var text = new UTF8Encoding(false, true).GetString(bytes, 0, lastNewline + 1);
        var lines = text
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.TrimEnd('\r'))
            .Where(line => !string.IsNullOrWhiteSpace(line))
            .ToList();

        _offset += lastNewline + 1;
        SaveCursor();
        return lines;
    }

    private void LoadCursor()
    {
        if (!File.Exists(options.CursorFile))
        {
            return;
        }

        try
        {
            var state = JsonSerializer.Deserialize<CursorState>(File.ReadAllText(options.CursorFile), JsonDefaults.Options);
            if (state is not null
                && string.Equals(state.EventFile, options.EventFile, StringComparison.OrdinalIgnoreCase))
            {
                _offset = state.Offset;
            }
        }
        catch (Exception exception) when (exception is IOException or JsonException)
        {
            Console.Error.WriteLine($"[bridge] Cursor не прочитан, начинаю безопасно с конца: {exception.Message}");
        }
    }

    private void SaveCursor()
    {
        var directory = Path.GetDirectoryName(options.CursorFile);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var state = new CursorState(options.EventFile, _offset);
        File.WriteAllText(options.CursorFile, JsonSerializer.Serialize(state, JsonDefaults.Options));
    }

    private sealed record CursorState(string EventFile, long Offset);
}
