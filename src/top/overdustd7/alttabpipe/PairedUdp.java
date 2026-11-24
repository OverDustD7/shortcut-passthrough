package top.overdustd7.alttabpipe;

import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

final class PairedUdp implements AutoCloseable {
    private static final SecureRandom RANDOM = new SecureRandom();
    private final DatagramSocket socket;
    private final byte[] authenticationKey;
    private final SecretKeySpec encryptionKey;
    private final String session = randomHex();
    private String epoch;
    private long sequence;

    PairedUdp(String code, InetAddress address, int port) throws GeneralSecurityException, IOException {
        if (!isPairingCode(code)) throw new IllegalArgumentException("Invalid pairing code");
        byte[] key = unhex(code);
        authenticationKey = mac(key, "ATP1 authentication");
        encryptionKey = new SecretKeySpec(mac(key, "ATP1 encryption"), "AES");
        socket = new DatagramSocket();
        socket.connect(address, port);
        socket.setSoTimeout(200);
    }

    static boolean isPairingCode(String code) {
        return code != null && code.matches("[0-9a-fA-F]{64}");
    }

    boolean authenticate() throws IOException, GeneralSecurityException {
        String nonce = randomHex();
        sendWire(sign("ATP1 H " + nonce));
        byte[] bytes = new byte[256];
        DatagramPacket response = new DatagramPacket(bytes, bytes.length);
        socket.receive(response);
        String[] fields = new String(bytes, 0, response.getLength(), StandardCharsets.US_ASCII).split(" ", -1);
        if (fields.length != 5 || !fields[0].equals("ATP1") || !fields[1].equals("C")
                || !fields[2].equals(nonce) || !fields[3].matches("[0-9a-f]{32}")
                || !fields[4].matches("[0-9a-f]{64}")) return false;
        String body = "ATP1 C " + nonce + " " + fields[3];
        if (!MessageDigest.isEqual(mac(authenticationKey, body), unhex(fields[4]))) return false;
        if (!fields[3].equals(epoch)) {
            epoch = fields[3];
            sequence = 0;
        }
        return true;
    }

    void send(byte[] command) throws IOException, GeneralSecurityException {
        if (epoch == null) throw new IllegalStateException("Pairing handshake required");
        byte[] iv = new byte[16];
        RANDOM.nextBytes(iv);
        Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        cipher.init(Cipher.ENCRYPT_MODE, encryptionKey, new IvParameterSpec(iv));
        String body = "ATP1 D " + epoch + " " + session + " " + (++sequence)
                + " " + hex(iv) + " " + hex(cipher.doFinal(command));
        sendWire(sign(body));
    }

    private void sendWire(String wire) throws IOException {
        byte[] bytes = wire.getBytes(StandardCharsets.US_ASCII);
        socket.send(new DatagramPacket(bytes, bytes.length));
    }

    private String sign(String body) throws GeneralSecurityException {
        return body + " " + hex(mac(authenticationKey, body));
    }

    private static byte[] mac(byte[] key, String body) throws GeneralSecurityException {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        return mac.doFinal(body.getBytes(StandardCharsets.US_ASCII));
    }

    private static String randomHex() {
        byte[] bytes = new byte[16];
        RANDOM.nextBytes(bytes);
        return hex(bytes);
    }

    private static String hex(byte[] bytes) {
        final String digits = "0123456789abcdef";
        StringBuilder out = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            out.append(digits.charAt((b & 255) >>> 4));
            out.append(digits.charAt(b & 15));
        }
        return out.toString();
    }

    private static byte[] unhex(String text) {
        byte[] out = new byte[text.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) (Character.digit(text.charAt(i * 2), 16) * 16
                    + Character.digit(text.charAt(i * 2 + 1), 16));
        }
        return out;
    }

    @Override public void close() { socket.close(); }
}
