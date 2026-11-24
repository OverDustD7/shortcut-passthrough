using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

public sealed class PairedUdpReceiver
{
    private readonly string epoch;
    private readonly byte[] authenticationKey;
    private readonly byte[] encryptionKey;
    private readonly Dictionary<string, long> latest = new Dictionary<string, long>(StringComparer.Ordinal);

    public PairedUdpReceiver(string code)
    {
        if (!Regex.IsMatch(code ?? "", @"\A[0-9a-fA-F]{64}\z"))
            throw new ArgumentException("Invalid pairing code");
        byte[] key = Unhex(code);
        authenticationKey = Mac(key, "ATP1 authentication");
        encryptionKey = Mac(key, "ATP1 encryption");
        byte[] random = new byte[16];
        using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(random);
        epoch = Hex(random);
    }

    public string Challenge(string wire)
    {
        if (!Regex.IsMatch(wire, @"\AATP1 H [0-9a-f]{32} [0-9a-f]{64}\z") || !ValidMac(wire))
            return null;
        string body = "ATP1 C " + wire.Substring(7, 32) + " " + epoch;
        return body + " " + Hex(Mac(authenticationKey, body));
    }

    public string Open(string wire)
    {
        if (!Regex.IsMatch(wire, @"\AATP1 D [0-9a-f]{32} [0-9a-f]{32} [1-9][0-9]{0,18} [0-9a-f]{32} (?:[0-9a-f]{32}){1,2} [0-9a-f]{64}\z"))
            return null;
        string[] fields = wire.Split(' ');
        long sequence, last;
        if (fields[2] != epoch || !long.TryParse(fields[4], NumberStyles.None, CultureInfo.InvariantCulture, out sequence))
            return null;
        bool known = latest.TryGetValue(fields[3], out last);
        if ((known && sequence <= last) || (!known && latest.Count >= 4096) || !ValidMac(wire))
            return null;
        byte[] plaintext;
        try {
            using (var aes = Aes.Create()) {
                aes.Key = encryptionKey;
                aes.IV = Unhex(fields[5]);
                aes.Mode = CipherMode.CBC;
                aes.Padding = PaddingMode.PKCS7;
                byte[] ciphertext = Unhex(fields[6]);
                using (var decryptor = aes.CreateDecryptor())
                    plaintext = decryptor.TransformFinalBlock(ciphertext, 0, ciphertext.Length);
            }
        } catch (CryptographicException) { return null; }
        string command = Encoding.ASCII.GetString(plaintext);
        if (!Regex.IsMatch(command, @"\A(?:PING|ALT_TAB|ALT_TAB_REV|RELEASE_ALL|KEY [0-9]{1,5} [01])\z"))
            return null;
        latest[fields[3]] = sequence;
        return command;
    }

    private bool ValidMac(string wire)
    {
        int split = wire.LastIndexOf(' ');
        byte[] expected = Mac(authenticationKey, wire.Substring(0, split));
        byte[] supplied = Unhex(wire.Substring(split + 1));
        int difference = 0;
        for (int i = 0; i < expected.Length; i++) difference |= expected[i] ^ supplied[i];
        return difference == 0;
    }

    private static byte[] Mac(byte[] key, string body)
    {
        using (var mac = new HMACSHA256(key)) return mac.ComputeHash(Encoding.ASCII.GetBytes(body));
    }

    private static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant(); }

    private static byte[] Unhex(string value)
    {
        byte[] bytes = new byte[value.Length / 2];
        for (int i = 0; i < bytes.Length; i++)
            bytes[i] = byte.Parse(value.Substring(i * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        return bytes;
    }
}
