using System.Buffers.Binary;
using System.Text;

namespace Alina.Bridge.Factorio;

public sealed record RconPacket(int Id, int Type, string Body)
{
    public byte[] Encode()
    {
        var body = Encoding.UTF8.GetBytes(Body);
        var payloadLength = checked(4 + 4 + body.Length + 2);
        var packet = new byte[4 + payloadLength];

        BinaryPrimitives.WriteInt32LittleEndian(packet.AsSpan(0, 4), payloadLength);
        BinaryPrimitives.WriteInt32LittleEndian(packet.AsSpan(4, 4), Id);
        BinaryPrimitives.WriteInt32LittleEndian(packet.AsSpan(8, 4), Type);
        body.CopyTo(packet.AsSpan(12));
        packet[^2] = 0;
        packet[^1] = 0;
        return packet;
    }

    public static async Task<RconPacket> ReadAsync(Stream stream, CancellationToken cancellationToken)
    {
        var lengthBytes = new byte[4];
        await ReadExactlyAsync(stream, lengthBytes, cancellationToken);
        var length = BinaryPrimitives.ReadInt32LittleEndian(lengthBytes);
        if (length is < 10 or > 16_777_216)
        {
            throw new InvalidDataException($"Некорректная длина RCON-пакета: {length}.");
        }

        var payload = new byte[length];
        await ReadExactlyAsync(stream, payload, cancellationToken);
        var id = BinaryPrimitives.ReadInt32LittleEndian(payload.AsSpan(0, 4));
        var type = BinaryPrimitives.ReadInt32LittleEndian(payload.AsSpan(4, 4));
        var bodyLength = length - 10;
        var body = bodyLength == 0 ? string.Empty : Encoding.UTF8.GetString(payload, 8, bodyLength);
        return new RconPacket(id, type, body);
    }

    private static async Task ReadExactlyAsync(Stream stream, Memory<byte> buffer, CancellationToken cancellationToken)
    {
        var read = 0;
        while (read < buffer.Length)
        {
            var count = await stream.ReadAsync(buffer[read..], cancellationToken);
            if (count == 0)
            {
                throw new EndOfStreamException("RCON-соединение закрыто до конца пакета.");
            }

            read += count;
        }
    }
}

