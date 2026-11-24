package top.overdustd7.alttabpipe;

import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;

public final class PairedUdpTest {
    public static void main(String[] args) throws Exception {
        InetAddress loopback = InetAddress.getByName("127.0.0.1");
        int port = Integer.parseInt(args[0]);
        String code = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        try (PairedUdp client = new PairedUdp("f" + code.substring(1), loopback, port)) {
            try {
                if (client.authenticate()) throw new AssertionError("Wrong key was accepted");
            } catch (SocketTimeoutException expected) { }
        }
        try (PairedUdp client = new PairedUdp(code, loopback, port)) {
            if (!client.authenticate()) throw new AssertionError("Host authentication failed");
            client.send("KEY 117 1".getBytes(StandardCharsets.US_ASCII));
            if (!client.authenticate()) throw new AssertionError("Host renewal failed");
            client.send("RELEASE_ALL".getBytes(StandardCharsets.US_ASCII));
        }
    }
}
